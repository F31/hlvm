package controller

import (
	"context"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"

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
		return ctrl.Result{}, nil // 非终态，等 agent 推进。
	}
	if task.Labels[LabelResultApplied] == "true" {
		return ctrl.Result{}, nil // 已回写，幂等跳过。
	}

	kind := task.Labels[LabelOwnerKind]
	name := task.Labels[LabelOwnerName]

	switch kind {
	case "NodeDisk":
		var disk storagev1alpha1.NodeDisk
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
