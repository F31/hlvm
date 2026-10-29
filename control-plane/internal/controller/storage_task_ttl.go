package controller

import (
	"fmt"
	"time"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// 任务 TTL 的语义（对齐 K8s Job 的 activeDeadlineSeconds）：
//
//   - spec.ttl 是**执行窗口**：自 metadata.creationTimestamp 起算，超过窗口的任务不再执行；
//   - 只对**尚未开始**的任务生效（phase 为空或 Pending）。一旦 agent 写入 Running，执行已经发生，
//     控制面不再改写其结果（单写者原则：agent 写 StorageTask.status，控制面只在端态回写拥有者）；
//   - 到期任务标记为 Failed（Result 以 DeadlineExceeded 开头），对象**保留**供排查，不自动重试；
//     与 Job 一致：重试需人工删除任务对象，由 desired-state 控制器重新下发；
//   - TTL 无法解析或 <= 0 时**失败关闭**（视为已过期）：绝不执行一个时限无法评估的破坏性任务。
const (
	// TaskExpiredEventReason 是任务超期事件的 reason。
	TaskExpiredEventReason = "DeadlineExceeded"
	// TaskExpiredMessagePrefix 是写入 status.result 的前缀，便于检索与断言。
	TaskExpiredMessagePrefix = "DeadlineExceeded: "
)

// TaskTTLState 是 TTL 评估结果。
type TaskTTLState int

const (
	// TaskTTLNone 表示任务未声明 TTL（不限制执行窗口）。
	TaskTTLNone TaskTTLState = iota
	// TaskTTLWaiting 表示仍在窗口内，需在 RequeueAfter 后复查。
	TaskTTLWaiting
	// TaskTTLExpired 表示已超出窗口（或 TTL 非法），不应执行。
	TaskTTLExpired
)

// TaskTTLEvaluation 是 TTL 评估的完整结果。
type TaskTTLEvaluation struct {
	State TaskTTLState
	// Deadline 是执行截止时间（State 为 TaskTTLNone 时为零值）。
	Deadline time.Time
	// RequeueAfter 是距离截止的剩余时间（仅 TaskTTLWaiting 有意义）。
	RequeueAfter time.Duration
	// Err 非空表示 TTL 非法（State 必为 TaskTTLExpired，失败关闭）。
	Err error
}

// EvaluateTaskTTL 评估任务的执行窗口。now 由调用方注入，便于测试。
func EvaluateTaskTTL(task storagev1alpha1.StorageTask, now time.Time) TaskTTLEvaluation {
	raw := task.Spec.TTL
	if raw == "" {
		return TaskTTLEvaluation{State: TaskTTLNone}
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		return TaskTTLEvaluation{
			State: TaskTTLExpired,
			Err:   fmt.Errorf("spec.ttl %q 不是合法时长: %w", raw, err),
		}
	}
	if d <= 0 {
		return TaskTTLEvaluation{
			State: TaskTTLExpired,
			Err:   fmt.Errorf("spec.ttl %q 必须为正时长", raw),
		}
	}
	deadline := task.CreationTimestamp.Time.Add(d)
	if !now.Before(deadline) {
		return TaskTTLEvaluation{State: TaskTTLExpired, Deadline: deadline}
	}
	return TaskTTLEvaluation{State: TaskTTLWaiting, Deadline: deadline, RequeueAfter: deadline.Sub(now)}
}

// ttlApplies 判断任务是否仍在「可被过期拦截」的阶段。
//
// 新建任务的 status.phase 为空（尚未被 agent 认领），与显式 Pending 等价；
// Running/Unknown 表示执行已开始或状态不明，交由 agent 收尾，控制面不覆盖。
func ttlApplies(task storagev1alpha1.StorageTask) bool {
	return task.Status.Phase == "" || task.Status.Phase == storagev1alpha1.TaskPending
}
