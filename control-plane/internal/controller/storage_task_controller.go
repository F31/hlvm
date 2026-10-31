package controller

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// StorageTaskReconciler 消费节点任务终态结果，回写拥有者（NodeDisk/NodeVG）状态。
//
// 闭环：controller 下发 StorageTask → agent 执行并写 StorageTask.status → 本控制器读终态并写
// NodeDisk/NodeVG.status（单写者原则：控制面是 CRD status 的唯一写者）。
// 破坏性任务（wipe/secure-erase、vgreduce）完成时写审计事件（设计 §4.1/§4.3：磁盘擦除/退役须入审计）。
type StorageTaskReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// +kubebuilder:rbac:groups=storage.example.io,resources=storagetasks,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=storage.example.io,resources=storagetasks/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile 仅处理 Succeeded/Failed 且尚未回写的 StorageTask。
func (r *StorageTaskReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerStorageTask, start, err) }()

	var task storagev1alpha1.StorageTask
	if err := r.Get(ctx, req.NamespacedName, &task); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if task.Status.Phase != storagev1alpha1.TaskSucceeded && task.Status.Phase != storagev1alpha1.TaskFailed {
		// 非终态：先判执行窗口（spec.ttl）。过期任务一律不执行（失败关闭）。
		ev := EvaluateTaskTTL(task, time.Now().UTC())
		if ev.State == TaskTTLExpired {
			if !ttlApplies(task) {
				// 已开始执行（Running/Unknown）：不覆盖 agent 的结果，仅记录。
				logger.Info("任务执行中已超出 spec.ttl，控制面不覆盖 agent 结果",
					"task", task.Name, "ttl", task.Spec.TTL)
				return ctrl.Result{}, nil
			}
			reason := fmt.Sprintf("%s任务超出 spec.ttl（%q）执行窗口，未执行", TaskExpiredMessagePrefix, task.Spec.TTL)
			if ev.Err != nil {
				reason = fmt.Sprintf("%s%v；按失败关闭策略拒绝执行", TaskExpiredMessagePrefix, ev.Err)
			}
			if err := r.expireTask(ctx, &task, reason); err != nil {
				return ctrl.Result{}, err
			}
			logger.Info("任务已超出执行窗口，标记 Failed 且不执行", "task", task.Name, "ttl", task.Spec.TTL)
			return ctrl.Result{}, nil
		}
		if ev.State == TaskTTLWaiting && ttlApplies(task) {
			// 精确到期复查，避免轮询。
			return ctrl.Result{RequeueAfter: ev.RequeueAfter}, nil
		}
		return ctrl.Result{}, nil // 非终态，等 agent 推进。
	}
	if task.Labels[LabelResultApplied] == "true" {
		return ctrl.Result{}, nil // 已回写，幂等跳过。
	}

	kind := task.Labels[LabelOwnerKind]
	name := task.Labels[LabelOwnerName]

	switch kind {
	case "NodeDisk":
		var disk storagev1beta1.NodeDisk
		if err := r.Get(ctx, client.ObjectKey{Name: name}, &disk); err != nil {
			if apierrors.IsNotFound(err) {
				return ctrl.Result{}, nil
			}
			return ctrl.Result{}, err
		}
		updated, changed := ApplyTaskResultToDisk(disk, task)
		if changed {
			if err := r.Status().Update(ctx, &updated); err != nil {
				return ctrl.Result{}, err
			}
		}
		// 破坏性磁盘操作（wipe/secure-erase）完成时写审计（§4.1/§4.3）。
		if task.Status.Phase == storagev1alpha1.TaskSucceeded && task.Spec.Type == storagev1alpha1.TaskWipe {
			RecordAuditEvent(r.Recorder, &disk, NewAuditEntry(
				operatorOf(task), "NodeDisk", disk.Name, "pending",
				"wipe:"+string(disk.Spec.WipePolicy), AuditSourceController))
		}
	case "NodeVG":
		var vg storagev1alpha1.NodeVG
		if err := r.Get(ctx, client.ObjectKey{Name: name}, &vg); err != nil {
			if apierrors.IsNotFound(err) {
				return ctrl.Result{}, nil
			}
			return ctrl.Result{}, err
		}
		updated, changed := ApplyTaskResultToVG(vg, task)
		if changed {
			if err := r.Status().Update(ctx, &updated); err != nil {
				return ctrl.Result{}, err
			}
		}
		// 破坏性 VG 操作（vgreduce 退役盘）完成时写审计（§4.1/§4.3）。
		if task.Status.Phase == storagev1alpha1.TaskSucceeded && task.Spec.Type == storagev1alpha1.TaskVGReduce {
			RecordAuditEvent(r.Recorder, &vg, NewAuditEntry(
				operatorOf(task), "NodeVG", vg.Name, "pending",
				"vgreduce:"+joinDisks(task.Spec.Disks), AuditSourceController))
		}
	default:
		logger.Info("storageTask has no owner label; skipping", "task", task.Name)
		return ctrl.Result{}, nil
	}

	// 标记已回写，防止重复回写。
	if task.Labels == nil {
		task.Labels = map[string]string{}
	}
	task.Labels[LabelResultApplied] = "true"
	if err := r.Update(ctx, &task); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器。
func (r *StorageTaskReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.StorageTask{}).
		Complete(r)
}

// expireTask 将任务标记为 Failed（超出执行窗口），对象保留供排查。
//
// 语义对齐 K8s Job 的 activeDeadlineSeconds：不删除对象、不自动重试；
// 重试需人工删除任务，由 desired-state 控制器重新下发（ADR-006）。
func (r *StorageTaskReconciler) expireTask(ctx context.Context, task *storagev1alpha1.StorageTask, reason string) error {
	now := metav1.NewTime(time.Now().UTC())
	task.Status.Phase = storagev1alpha1.TaskFailed
	task.Status.Result = reason
	task.Status.Message = "控制面在任务开始前检测到执行窗口已过期，按失败关闭策略拒绝执行"
	task.Status.CompletedAt = &now
	if err := r.Status().Update(ctx, task); err != nil {
		return err
	}
	if r.Recorder != nil {
		r.Recorder.Event(task, corev1.EventTypeWarning, TaskExpiredEventReason, reason)
	}
	return nil
}

// operatorOf 取得破坏性任务的 operator（人工审批者），缺省 "system"（§4.1/§4.3 审计）。
func operatorOf(task storagev1alpha1.StorageTask) string {
	if op := task.Labels[LabelTaskOperator]; op != "" {
		return op
	}
	return "system"
}

// joinDisks 将盘名列表拼接为逗号分隔串（审计消息用）。
func joinDisks(disks []string) string {
	out := ""
	for i, d := range disks {
		if i > 0 {
			out += ","
		}
		out += d
	}
	return out
}
