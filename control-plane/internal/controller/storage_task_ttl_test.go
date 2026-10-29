package controller

import (
	"context"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func taskWithTTL(name, ttl string, createdAgo time.Duration, phase storagev1alpha1.TaskPhase) storagev1alpha1.StorageTask {
	task := storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{
			Name:              name,
			CreationTimestamp: metav1.NewTime(time.Now().UTC().Add(-createdAgo)),
			Labels:            map[string]string{LabelOwnerKind: "NodeVG", LabelOwnerName: "vg1"},
		},
		Spec: storagev1alpha1.StorageTaskSpec{
			NodeName: "n1",
			Type:     storagev1alpha1.TaskVGCreate,
			TTL:      ttl,
		},
	}
	task.Status.Phase = phase
	return task
}

func TestEvaluateTaskTTL(t *testing.T) {
	now := time.Now().UTC()

	none := EvaluateTaskTTL(taskWithTTL("t0", "", time.Hour, ""), now)
	if none.State != TaskTTLNone {
		t.Fatalf("未声明 TTL 应返回 TaskTTLNone，实际 %v", none.State)
	}

	waiting := EvaluateTaskTTL(taskWithTTL("t1", "1h", time.Minute, ""), now)
	if waiting.State != TaskTTLWaiting {
		t.Fatalf("窗口内应返回 TaskTTLWaiting，实际 %v", waiting.State)
	}
	if waiting.RequeueAfter <= 0 || waiting.RequeueAfter > time.Hour {
		t.Fatalf("RequeueAfter 应为剩余时间（0,1h]，实际 %v", waiting.RequeueAfter)
	}

	expired := EvaluateTaskTTL(taskWithTTL("t2", "1h", 2*time.Hour, ""), now)
	if expired.State != TaskTTLExpired || expired.Err != nil {
		t.Fatalf("已超期应返回 TaskTTLExpired（无 err），实际 state=%v err=%v", expired.State, expired.Err)
	}

	// 非法 TTL：失败关闭（Expired + err），绝不执行。
	for _, bad := range []string{"bogus", "1x", "-5m", "0s"} {
		ev := EvaluateTaskTTL(taskWithTTL("t3", bad, 0, ""), now)
		if ev.State != TaskTTLExpired || ev.Err == nil {
			t.Fatalf("非法 TTL %q 应按失败关闭处理（Expired+err），实际 state=%v err=%v", bad, ev.State, ev.Err)
		}
	}
}

func TestStorageTaskReconciler_ExpiresPendingTask(t *testing.T) {
	vg := storagev1alpha1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg1"}, Spec: storagev1alpha1.VGSpec{NodeName: "n1"}}
	// 未开始（phase 为空）+ TTL 1s + 创建于 10s 前 → 应被标记 Failed 且不执行。
	task := taskWithTTL("vg-vg1-vgcreate", "1s", 10*time.Second, "")
	c := fakeClient(&vg, &task)
	rec := record.NewFakeRecorder(10)
	r := &StorageTaskReconciler{Client: c, Scheme: testScheme(), Recorder: rec}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var got storagev1alpha1.StorageTask
	if err := c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &got); err != nil {
		t.Fatalf("get task: %v", err)
	}
	if got.Status.Phase != storagev1alpha1.TaskFailed {
		t.Fatalf("超期任务应标记 Failed，实际 %q", got.Status.Phase)
	}
	if !strings.HasPrefix(got.Status.Result, TaskExpiredMessagePrefix) {
		t.Fatalf("result 应带 DeadlineExceeded 前缀，实际 %q", got.Status.Result)
	}
	if got.Status.CompletedAt == nil {
		t.Fatal("超期任务应写 completedAt")
	}
	select {
	case ev := <-rec.Events:
		if !strings.Contains(ev, TaskExpiredEventReason) {
			t.Fatalf("应发出 DeadlineExceeded 警告事件，实际 %q", ev)
		}
	default:
		t.Fatal("超期任务应发出事件")
	}

	// 再次 reconcile：终态路径把失败回写拥有者（VGReady=False），并标记结果已应用。
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}}); err != nil {
		t.Fatalf("second reconcile err: %v", err)
	}
	var vgAfter storagev1alpha1.NodeVG
	if err := c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &vgAfter); err != nil {
		t.Fatalf("get vg: %v", err)
	}
	if len(vgAfter.Status.Conditions) == 0 || vgAfter.Status.Conditions[0].Reason != "TaskFailed" {
		t.Fatalf("超期失败应回写 VGReady=False，实际 %+v", vgAfter.Status.Conditions)
	}
	if err := c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &got); err != nil {
		t.Fatalf("get task: %v", err)
	}
	if got.Labels[LabelResultApplied] != "true" {
		t.Fatalf("结果应标记已应用，实际 labels=%v", got.Labels)
	}
}

func TestStorageTaskReconciler_WaitsForTTL(t *testing.T) {
	task := taskWithTTL("vg-vg1-vgcreate", "1h", time.Minute, "")
	c := fakeClient(&task)
	r := &StorageTaskReconciler{Client: c, Scheme: testScheme()}

	res, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}})
	if err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if res.RequeueAfter <= 0 || res.RequeueAfter > time.Hour {
		t.Fatalf("窗口内应 RequeueAfter 到截止时刻，实际 %v", res.RequeueAfter)
	}

	var got storagev1alpha1.StorageTask
	if err := c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &got); err != nil {
		t.Fatalf("get task: %v", err)
	}
	if got.Status.Phase != "" {
		t.Fatalf("窗口内不应改写 phase，实际 %q", got.Status.Phase)
	}
}

func TestStorageTaskReconciler_DoesNotOverrideRunningTask(t *testing.T) {
	// agent 已开始执行：即使超过 TTL，控制面也不得改写结果（单写者原则）。
	task := taskWithTTL("vg-vg1-vgcreate", "1s", time.Hour, storagev1alpha1.TaskRunning)
	c := fakeClient(&task)
	r := &StorageTaskReconciler{Client: c, Scheme: testScheme()}

	res, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}})
	if err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if res.RequeueAfter != 0 {
		t.Fatalf("执行中的任务不应再按 TTL 排队，实际 %v", res.RequeueAfter)
	}

	var got storagev1alpha1.StorageTask
	if err := c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &got); err != nil {
		t.Fatalf("get task: %v", err)
	}
	if got.Status.Phase != storagev1alpha1.TaskRunning {
		t.Fatalf("执行中任务不应被改写，实际 %q", got.Status.Phase)
	}
}
