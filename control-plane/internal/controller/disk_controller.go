package controller

import (
	"context"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// 默认节点失联阈值（设计 §7 disk-ctrl）。
const defaultNodeStaleThreshold = 30 * time.Minute

// DiskReconciler 是 NodeDisk 的控制器骨架（add-crd-controller-skeleton 阶段）。
//
// 完整职责（后续 change 补全）：
//   - 汇总健康度、节点失联超过阈值标 stale 并创建 StorageNodeOps(isolate)。
//   - 监听 Node，联动 §4 调度约束。
// 当前骨架仅完成对象的获取与基础对账，确保控制面可编译、可运行。
type DiskReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	// NodeStaleThreshold 节点失联判定阈值，默认 30min（可配）。
	NodeStaleThreshold time.Duration
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodedisks,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=storage.example.io,resources=nodedisks/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch

// Reconcile 对 NodeDisk 做基础对账。
func (r *DiskReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var disk storagev1alpha1.NodeDisk
	if err := r.Get(ctx, req.NamespacedName, &disk); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 占位：stale 判定与 isolate 剧本由 lifecycle-ops change 补全。
	threshold := r.NodeStaleThreshold
	if threshold == 0 {
		threshold = defaultNodeStaleThreshold
	}
	logger.Info("reconciling NodeDisk",
		"name", disk.Name,
		"node", disk.Spec.NodeName,
		"phase", disk.Status.Phase,
		"health", disk.Status.Health,
		"staleThreshold", threshold.String())

	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器。
func (r *DiskReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeDisk{}).
		Complete(r)
}
