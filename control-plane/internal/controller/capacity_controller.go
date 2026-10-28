package controller

import (
	"context"
	"reflect"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// PolicySingletonName 是集群级 ThinPoolPolicy 单例名（设计 §3.3，name=default）。
const PolicySingletonName = "default"

// CapacityReconciler 是容量治理控制器（add-capacity-governance）。
//
// 职责（设计 §3.3 / tasks 1.1–1.3）：
//   - 读取 ThinPoolPolicy（默认单例 + tier 覆盖）与 NodeVG 容量水位；
//   - 计算 capacityStatus，带滞回解锁（避免边界抖动）；
//   - locked 时给对应节点打 storage.example.io/<tier>-locked 标签（调度排除，供 webhook 消费）。
//
// 单写者：NodeVG.status.capacityStatus 与节点锁标签的本侧写者。容量计算只读，
// 不做实时拦截（拦截在 webhook 侧，读取本状态，§2.2）。
//
// 与 VGReconciler 共享 NodeVG.status 子资源：本控制器仅用 Status().Patch(MergeFrom) 写入
// capacityStatus 字段，避免覆盖 VGReconciler 写入的 pendingOps（已知轻度协同类竞争，已在 risk 登记）。
type CapacityReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=storage.example.io,resources=thinpoolpolicies,verbs=get;list;watch
// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch
// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch;patch

// Reconcile 计算并落盘容量状态与节点锁标签。
func (r *CapacityReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var vg storagev1alpha1.NodeVG
	if err := r.Get(ctx, req.NamespacedName, &vg); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	var policy storagev1alpha1.ThinPoolPolicy
	if err := r.Get(ctx, client.ObjectKey{Name: PolicySingletonName}, &policy); err != nil {
		if !apierrors.IsNotFound(err) {
			return ctrl.Result{}, err
		}
		// 策略缺失：用默认阈值（不阻断容量评估），记录告警级日志。
		logger.Info("ThinPoolPolicy 单例缺失，使用默认阈值", "policy", PolicySingletonName)
	}

	p := ResolveThresholds(&policy, vg.Spec.Tier)
	data := vg.Status.ThinPool.DataPercent
	meta := vg.Status.ThinPool.MetadataPercent
	oos := vg.Status.ThinPool.OutOfSpace
	old := vg.Status.CapacityStatus
	next := NextCapacityStatus(old, data, meta, oos, p)

	// 状态变化才写（etcd 写放大控制，§7）。用 MergeFrom 仅下发 capacityStatus 字段。
	if next != old {
		base := vg.DeepCopy()
		vg.Status.CapacityStatus = next
		if err := r.Status().Patch(ctx, &vg, client.MergeFrom(base)); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("capacityStatus 更新", "vg", vg.Name, "from", old, "to", next)
	}

	// 节点锁标签：locked 时打标，否则摘除（仅当 tier 与 nodeName 均已知）。
	if vg.Spec.NodeName != "" && vg.Spec.Tier != "" {
		if err := r.applyLockLabel(ctx, vg.Spec.NodeName, vg.Spec.Tier, next == storagev1alpha1.CapacityLocked); err != nil {
			// 锁标签失败不阻断容量状态落盘，但告警（调度排除会滞后，由 webhook FailurePolicy=Ignore 兜底）。
			logger.Error(err, "应用节点锁标签失败", "node", vg.Spec.NodeName, "tier", vg.Spec.Tier)
		}
	}

	return ctrl.Result{}, nil
}

// applyLockLabel 给节点打/摘 storage.example.io/<tier>-locked 标签（idempotent）。
// 节点不存在（测试/拓扑不一致）时静默跳过，不阻断 reconcile。
func (r *CapacityReconciler) applyLockLabel(ctx context.Context, nodeName, tier string, locked bool) error {
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
	key := LockLabelName(tier)
	if locked {
		node.Labels[key] = "true"
	} else {
		delete(node.Labels, key)
	}
	if reflect.DeepEqual(base.Labels, node.Labels) {
		return nil
	}
	return r.Patch(ctx, &node, client.MergeFrom(base))
}

// SetupWithManager 注册控制器。
func (r *CapacityReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeVG{}).
		Complete(r)
}
