package controller

import (
	"context"
	"time"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// OrphanGCReconciler 检测 Retain 后 Released 的 PV 与孤儿 LV，提醒人工回收（§3.1）。
//
// 原则：平台 SHALL NOT 自动删除，仅记录并提醒人工回收（Retain 的长期隐形容量成本）。
// 当前控制面已接入 PV 侧对账（Released+Retain）；lvs 三方对账待 agent LV 上报后启用。
type OrphanGCReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// +kubebuilder:rbac:groups="",resources=persistentvolumes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile 扫描集群 PV，找出 Retain 后 Released 的孤儿 PV 并告警提醒（不自动删除）。
func (r *OrphanGCReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerOrphanGC, start, err) }()

	var pvs corev1.PersistentVolumeList
	if err := r.List(ctx, &pvs); err != nil {
		return ctrl.Result{}, err
	}
	released := FindReleasedRetainPVs(pvs.Items)
	if len(released) == 0 {
		return ctrl.Result{}, nil
	}

	for _, pv := range released {
		q := pv.Spec.Capacity[corev1.ResourceStorage]
		msg := fmt.Sprintf("Retain Released PV 待人工回收（隐形容量成本）；容量 %s。平台不会自动删除，请核实后回收", q.String())
		logger.Info("orphan-gc 提醒", "pv", pv.Name, "bytes", q.Value())
		if r.Recorder != nil {
			r.Recorder.Event(&pv, corev1.EventTypeWarning, "OrphanPV", msg)
		}
	}
	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器：监听 PersistentVolume。
func (r *OrphanGCReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.PersistentVolume{}).
		Complete(r)
}
