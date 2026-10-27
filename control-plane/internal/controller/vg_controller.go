package controller

import (
	"context"

	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// VGReconciler 是 NodeVG 的控制器（add-crd-controller-skeleton 阶段）。
//
// 当前实现对账职责：
//   - 删盘保护：校验 removeDisks 候选无 LV 占用、移除不导致冗余丧失；失败则将原因写入
//     status.pendingOps 并拒绝下发 vgreduce（设计 §3.4 / 规格 vg-ctrl 删盘保护）。
//   - 依据 spec.disks 生成 StorageTask（vgcreate/vgextend/vgreduce）由后续 change 补全。
type VGReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=storage.example.io,resources=nodedisks,verbs=get;list;watch

// Reconcile 对 NodeVG 做对账：执行删盘保护校验并写入 status.pendingOps。
func (r *VGReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var vg storagev1alpha1.NodeVG
	if err := r.Get(ctx, req.NamespacedName, &vg); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	candidates := vg.Spec.Operations.RemoveDisks
	if len(candidates) == 0 {
		// 无删盘意图时清空历史 pendingOps（保留其他来源需另计，此处为删盘保护专用）。
		if len(vg.Status.PendingOps) > 0 {
			vg.Status.PendingOps = nil
			if err := r.Status().Update(ctx, &vg); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// 构建占用图：盘若仍被 LV 占用则阻塞。scaffold 阶段从 NodeDisk 状态推断——
	// 仍 phase=InVG 且 VgRef 指向本 VG 的盘视为"未 drain、占用中"。
	occupancy := make(map[string][]string)
	for _, d := range candidates {
		inUse, err := r.diskStillInUse(ctx, vg.Spec.NodeName, vg.Name, d)
		if err != nil {
			return ctrl.Result{}, err
		}
		if inUse {
			occupancy[d] = []string{"<still InVG, not drained>"}
		}
	}

	remainingAfterRemoval := len(vg.Spec.Disks) - len(candidates)
	redLost := RedundancyWouldBeLost(vg.Spec.Layout, vg.Spec.Redundancy, remainingAfterRemoval)
	plan := PlanRemoveDisks(candidates, occupancy, redLost)

	// 幂等：仅当 pendingOps 变化才写回 status（etcd 写放大控制，§7）。
	if !equalStringSlice(vg.Status.PendingOps, plan.PendingOps) {
		vg.Status.PendingOps = plan.PendingOps
		if err := r.Status().Update(ctx, &vg); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("remove-disk protection evaluated",
			"vg", vg.Name, "approved", plan.Approved, "blocked", len(plan.Blocked), "pendingOps", plan.PendingOps)
	}

	return ctrl.Result{}, nil
}

// diskStillInUse 判定候选盘是否仍被 LV 占用（即仍 InVG 且归属于本 VG）。
func (r *VGReconciler) diskStillInUse(ctx context.Context, nodeName, vgName, diskByID string) (bool, error) {
	var list storagev1alpha1.NodeDiskList
	if err := r.List(ctx, &list); err != nil {
		return false, err
	}
	for _, d := range list.Items {
		if d.Spec.NodeName != nodeName {
			continue
		}
		if d.Status.VgRef != vgName {
			continue
		}
		// 设备匹配：NodeDisk 的 by-id 与候选盘一致。
		if d.Status.Identity.ByID == diskByID || d.Status.CurrentDevice == diskByID {
			if d.Status.Phase == storagev1alpha1.DiskPhaseInVG {
				return true, nil
			}
		}
	}
	return false, nil
}

func equalStringSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// SetupWithManager 注册控制器。
func (r *VGReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeVG{}).
		Complete(r)
}
