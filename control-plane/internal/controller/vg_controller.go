package controller

import (
	"context"

	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// VGReconciler 是 NodeVG 的控制器骨架（add-crd-controller-skeleton 阶段）。
//
// 完整职责（后续 change 补全）：
//   - 声明式 reconcile：依据 spec.disks 生成 StorageTask（vgcreate/vgextend/vgreduce）。
//   - 删盘保护：校验无 LV 占用、冗余不丧失，否则拒绝并写入 status.pendingOps。
// 当前骨架仅完成对象获取与基础对账。
type VGReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=storage.example.io,resources=storagetasks,verbs=get;list;watch;create;update;patch;delete

// Reconcile 对 NodeVG 做基础对账。
func (r *VGReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var vg storagev1alpha1.NodeVG
	if err := r.Get(ctx, req.NamespacedName, &vg); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 占位：StorageTask 下发与删盘保护由本 change 后续补全。
	logger.Info("reconciling NodeVG",
		"name", vg.Name,
		"node", vg.Spec.NodeName,
		"tier", vg.Spec.Tier,
		"disks", len(vg.Spec.Disks),
		"capacityStatus", vg.Status.CapacityStatus)

	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器。
func (r *VGReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeVG{}).
		Complete(r)
}
