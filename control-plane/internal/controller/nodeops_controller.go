package controller

import (
	"context"
	"time"
	"fmt"
	"reflect"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// NodeOpsReconciler 是节点运维剧本控制器（add-lifecycle-ops §1 StorageNodeOps 状态机）。
//
// 职责（设计 §3.5 / §9）：
//   - 驱动 StorageNodeOps 状态机（validate→drain→wait-pvc-cleanup→wipe→done）；
//   - retire：drain 阶段 cordon 节点，wait-pvc-cleanup 阶段按 PV 标注统计阻塞 PVC，无阻塞进入 wipe；
//   - isolate：打节点存储故障标签（非污点），供调度约束消费；
//   - recover-disk：需人工确认（force）才收口，不自动迁移数据。
//
// 单写者：StorageNodeOps.status 的本侧写者（phase/blockingPVCs），统一 MergeFrom 落盘。
// 破坏性动作（实际 wipe/vgreduce）后续经 StorageTask 下发（M8b），本控制器只做编排与门控。
type NodeOpsReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=storage.example.io,resources=storagenodeops,verbs=get;list;watch
// +kubebuilder:rbac:groups=storage.example.io,resources=storagenodeops/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch;patch
// +kubebuilder:rbac:groups="",resources=persistentvolumes,verbs=get;list;watch

// Reconcile 推进节点运维剧本的一个相位并施加相应副作用。
func (r *NodeOpsReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerNodeOps, start, err) }()

	var ops storagev1alpha1.StorageNodeOps
	if err := r.Get(ctx, req.NamespacedName, &ops); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if ops.Spec.NodeName == "" {
		return ctrl.Result{}, nil
	}

	base := ops.DeepCopy()
	phase := ops.Status.Phase
	blocking := 0
	if ops.Spec.Operation == storagev1alpha1.NodeOpRetire {
		pvcs, err := r.blockingPVCs(ctx, ops.Spec.NodeName)
		if err != nil {
			return ctrl.Result{}, err
		}
		ops.Status.BlockingPVCs = pvcs
		blocking = len(pvcs)
	}

	next := NextNodeOpsPhase(ops.Spec.Operation, phase, blocking, ops.Spec.Force)

	// isolate：进入 done 时打节点存储故障标签。
	if ops.Spec.Operation == storagev1alpha1.NodeOpIsolate {
		if err := r.applyIsolateLabel(ctx, ops.Spec.NodeName, next == storagev1alpha1.NodeOpsDone); err != nil {
			logger.Error(err, "应用隔离标签失败", "node", ops.Spec.NodeName)
		}
	}
	// retire：进入 drain 阶段 cordon 节点（停止新调度，业务确认后清理 PVC）。
	if ops.Spec.Operation == storagev1alpha1.NodeOpRetire && next == storagev1alpha1.NodeOpsDrain {
		if err := r.cordonNode(ctx, ops.Spec.NodeName, true); err != nil {
			logger.Error(err, "cordon 节点失败", "node", ops.Spec.NodeName)
		}
	}

	ops.Status.Phase = next
	if !reflect.DeepEqual(base.Status, ops.Status) {
		if err := r.Status().Patch(ctx, &ops, client.MergeFrom(base)); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("StorageNodeOps 状态推进", "ops", ops.Name, "operation", ops.Spec.Operation, "to", next)
	}

	return ctrl.Result{}, nil
}

// blockingPVCs 统计仍在节点的 Bound PV 所对应 PVC（retire 阻塞判定，§9.2）。
// 依据 PV 上的 hlvm.dev/node 注解（由动态供给/agent 写入）与 Bound 状态。
// 注：注解非标签，无法用标签选择器高效过滤，故列出后按注解在代码内筛选。
func (r *NodeOpsReconciler) blockingPVCs(ctx context.Context, nodeName string) ([]string, error) {
	var pvs corev1.PersistentVolumeList
	if err := r.List(ctx, &pvs); err != nil {
		return nil, err
	}
	var out []string
	for _, pv := range pvs.Items {
		if pv.Status.Phase != corev1.VolumeBound || pv.Annotations[PVNodeAnnotation] != nodeName {
			continue
		}
		if ref := pv.Spec.ClaimRef; ref != nil {
			out = append(out, fmt.Sprintf("%s/%s", ref.Namespace, ref.Name))
		} else {
			out = append(out, pv.Name)
		}
	}
	return out, nil
}

// applyIsolateLabel 给节点打/摘存储故障标签（idempotent；节点不存在静默跳过）。
func (r *NodeOpsReconciler) applyIsolateLabel(ctx context.Context, nodeName string, isolated bool) error {
	var node corev1.Node
	if err := r.Get(ctx, client.ObjectKey{Name: nodeName}, &node); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	base := node.DeepCopy()
	if node.Labels == nil {
		node.Labels = map[string]string{}
	}
	if isolated {
		node.Labels[NodeIsolatedLabel] = "true"
	} else {
		delete(node.Labels, NodeIsolatedLabel)
	}
	if reflect.DeepEqual(base.Labels, node.Labels) {
		return nil
	}
	return r.Patch(ctx, &node, client.MergeFrom(base))
}

// cordonNode 设置/取消节点不可调度（drain 阶段 cordon，idempotent；节点不存在静默跳过）。
func (r *NodeOpsReconciler) cordonNode(ctx context.Context, nodeName string, cordon bool) error {
	var node corev1.Node
	if err := r.Get(ctx, client.ObjectKey{Name: nodeName}, &node); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	base := node.DeepCopy()
	node.Spec.Unschedulable = cordon
	if reflect.DeepEqual(base.Spec, node.Spec) {
		return nil
	}
	return r.Patch(ctx, &node, client.MergeFrom(base))
}

// SetupWithManager 注册控制器。
func (r *NodeOpsReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.StorageNodeOps{}).
		Complete(r)
}
