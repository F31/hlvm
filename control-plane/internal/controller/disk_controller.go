package controller

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// 默认节点失联阈值（设计 §7 disk-ctrl）。
const defaultNodeStaleThreshold = 30 * time.Minute

// DiskReconciler 是 NodeDisk 的控制器（add-crd-controller-skeleton 阶段）。
//
// 当前实现对账职责：
//   - 汇总健康度、节点失联超过阈值标 stale 并创建 StorageNodeOps(isolate) 入口。
//   - 监听 Node，依据 Ready 条件联动 §4 调度约束。
// 完整三方对账与漂移检测由后续 lifecycle-ops / drift-detector change 补全。
type DiskReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	// NodeStaleThreshold 节点失联判定阈值，默认 30min（可配）。
	NodeStaleThreshold time.Duration
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodedisks,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=storage.example.io,resources=nodedisks/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=storage.example.io,resources=storagenodeops,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch

// Reconcile 对 NodeDisk 做对账：联动节点 Ready 状态，失联超限则标 stale 并触发隔离入口。
func (r *DiskReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerDisk, start, err) }()

	var disk storagev1alpha1.NodeDisk
	if err := r.Get(ctx, req.NamespacedName, &disk); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	threshold := r.NodeStaleThreshold
	if threshold == 0 {
		threshold = defaultNodeStaleThreshold
	}

	// 读取节点 Ready 条件。
	var node corev1.Node
	nodeReady, lastReady := false, (*metav1.Time)(nil)
	if err := r.Get(ctx, client.ObjectKey{Name: disk.Spec.NodeName}, &node); err != nil {
		if !apierrors.IsNotFound(err) {
			return ctrl.Result{}, err
		}
		// 节点对象缺失：视为从未就绪，不自动隔离。
		logger.Info("node object not found; treat as never ready", "node", disk.Spec.NodeName)
	} else {
		for _, c := range node.Status.Conditions {
			if c.Type == corev1.NodeReady {
				nodeReady = c.Status == corev1.ConditionTrue
				if !nodeReady {
					lt := c.LastTransitionTime
					lastReady = &lt
				}
				break
			}
		}
	}

	decision := DecideStaleAction(nodeReady, lastReady, threshold, time.Now())

	changed := false
	if decision.ShouldIsolate {
		if err := r.ensureIsolateOps(ctx, disk.Spec.NodeName); err != nil {
			return ctrl.Result{}, err
		}
		if apimeta.SetStatusCondition(&disk.Status.Conditions, metav1.Condition{
			Type:    "Stale",
			Status:  metav1.ConditionTrue,
			Reason:  "NodeNotReady",
			Message: decision.Reason,
		}) {
			changed = true
		}
	} else {
		if apimeta.SetStatusCondition(&disk.Status.Conditions, metav1.Condition{
			Type:    "Stale",
			Status:  metav1.ConditionFalse,
			Reason:  "NodeReady",
			Message: decision.Reason,
		}) {
			changed = true
		}
	}

	if changed {
		if err := r.Status().Update(ctx, &disk); err != nil {
			return ctrl.Result{}, err
		}
	}

	// 下发纳管任务（wipe→pvcreate，幂等）。身份/phase 已判定，未就绪则不重复下发。
	if desired := DesiredStorageTasksForDisk(disk); desired != nil {
		if _, err := ensureStorageTask(ctx, r.Client, *desired); err != nil {
			return ctrl.Result{}, err
		}
	}

	return ctrl.Result{}, nil
}

// ensureIsolateOps 幂等创建节点隔离剧本（自动命名 auto-isolate-<node>）。
func (r *DiskReconciler) ensureIsolateOps(ctx context.Context, nodeName string) error {
	name := fmt.Sprintf("auto-isolate-%s", nodeName)
	var ops storagev1alpha1.StorageNodeOps
	err := r.Get(ctx, client.ObjectKey{Name: name}, &ops)
	if err == nil {
		return nil
	}
	if !apierrors.IsNotFound(err) {
		return err
	}
	ops = storagev1alpha1.StorageNodeOps{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: storagev1alpha1.StorageNodeOpsSpec{
			NodeName:  nodeName,
			Operation: storagev1alpha1.NodeOpIsolate,
		},
	}
	if err := r.Create(ctx, &ops); err != nil && !apierrors.IsAlreadyExists(err) {
		return err
	}
	return nil
}

// SetupWithManager 注册控制器：For NodeDisk，并监听 Node 以联动 Ready 状态。
func (r *DiskReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeDisk{}).
		Watches(&corev1.Node{}, nodeEventHandler(r)).
		Complete(r)
}

// nodeEventHandler 将 Node 事件映射到该节点上的全部 NodeDisk 对账请求。
func nodeEventHandler(r *DiskReconciler) handler.EventHandler {
	return handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
		nodeName := obj.GetName()
		var list storagev1alpha1.NodeDiskList
		if err := r.List(ctx, &list); err != nil {
			return nil
		}
		reqs := make([]reconcile.Request, 0, len(list.Items))
		for _, d := range list.Items {
			if d.Spec.NodeName == nodeName {
				reqs = append(reqs, reconcile.Request{NamespacedName: client.ObjectKeyFromObject(&d)})
			}
		}
		return reqs
	})
}
