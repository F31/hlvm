package controller

import (
	"context"
	"fmt"
	"reflect"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// PolicySingletonName 是集群级 ThinPoolPolicy 单例名（设计 §3.3，name=default）。
const PolicySingletonName = "default"

// CapacityReconciler 在 NodeVG.status.conditions 上发布的容量治理条件（§3.3 1.4/1.5、§3 3.2）。
const (
	CondCapacityForecast     = "CapacityForecast"
	CondFreeVGInsufficient   = "FreeVGInsufficient"
	CondThinPoolAutoExtend   = "ThinPoolAutoExtend"
	CondThinPoolExtendCapped = "ThinPoolExtendCapped"
)

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

// Reconcile 计算并落盘容量状态、预测告警、空闲空间校验、lvm.conf 渲染与兜底扩容，并维护节点锁标签。
//
// 覆盖 tasks（§3.3 1.1–1.6、§3 3.2）：
//   - 1.1–1.3 capacityStatus 评估（带滞回） + 节点锁标签；
//   - 1.4 预测告警（growth 已知时按恒定速率估算 timeToFull，Warning<阈值/Critical<阈值）；
//   - 1.5 requireFreeVGSpace：VG 空闲不足转人工（发布 FreeVGInsufficient=True 条件）；
//   - 1.6 渲染 lvm.conf autoextend 片段写入 status.LvmdConfig（供 Agent 应用）；
//   - 3.2 thinpool 兜底扩容：data 越过 AutoExtendPercent 且未达 VG 上限时计算目标，超限转人工。
//
// 单次 MergeFrom patch（仅下发 status），不覆盖 VGReconciler 写入的 pendingOps 等其余字段。
func (r *CapacityReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerCapacity, start, err) }()

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

	base := vg.DeepCopy()
	p := ResolveThresholds(&policy, vg.Spec.Tier)
	data := vg.Status.ThinPool.DataPercent
	meta := vg.Status.ThinPool.MetadataPercent
	oos := vg.Status.ThinPool.OutOfSpace

	// 1.1–1.3 capacityStatus（带滞回）。
	next := NextCapacityStatus(vg.Status.CapacityStatus, data, meta, oos, p)
	vg.Status.CapacityStatus = next

	// 1.4 预测告警（growth 已知时恒定速率预测；否则条件置 False，不误报）。
	warn, crit := parseForecastDurations(policy.Spec.Forecast)
	if lvl, ttf := ForecastCapacityAlert(data, vg.Status.ThinPool.CurrentSizeBytes,
		float64(vg.Status.GrowthBytesPerHour), warn, crit); lvl != AlertNone {
		msg := "增长速率已知，timeToFull 充足"
		if ttf != nil {
			msg = fmt.Sprintf("thinpool 预计 %s 写满", ttf.Round(time.Minute))
		}
		reason := "CapacityForecastWarning"
		if lvl == AlertCritical {
			reason = "CapacityForecastCritical"
		}
		setCond(&vg, CondCapacityForecast, metav1.ConditionTrue, reason, msg)
	} else {
		setCond(&vg, CondCapacityForecast, metav1.ConditionFalse, "CapacityForecastNone",
			"增长速率未知或 timeToFull 充足")
	}

	// 1.5 requireFreeVGSpace：空闲不足转人工（条件 True）；未配置或充足则 False。
	if ok, reqBytes, err := CheckFreeVGSpace(vg.Status.FreeBytes, policy.Spec.RequireFreeVGSpace); err != nil {
		logger.Error(err, "解析 requireFreeVGSpace 失败", "require", policy.Spec.RequireFreeVGSpace)
	} else if policy.Spec.RequireFreeVGSpace != "" && !ok {
		setCond(&vg, CondFreeVGInsufficient, metav1.ConditionTrue, "FreeVGSpaceBelowRequired",
			fmt.Sprintf("VG 空闲 %d 字节 < 要求 %d 字节，需人工介入扩容", vg.Status.FreeBytes, reqBytes))
	} else {
		setCond(&vg, CondFreeVGInsufficient, metav1.ConditionFalse, "FreeVGSpaceSufficient",
			"VG 空闲空间满足策略要求")
	}

	// 1.6 渲染 lvm.conf autoextend 片段（供 Agent 拉取应用）。
	vg.Status.LvmdConfig = RenderLVMConfAutoExtend(p)

	// §3.2 thinpool 兜底扩容（dmeventd 第一防线失效时控制面触发；受 VG 可用上限约束）。
	maxBytes := vg.Status.ThinPool.CurrentSizeBytes + vg.Status.FreeBytes
	if p.AutoExtendPercent > 0 && data >= float64(p.AutoExtendPercent) &&
		vg.Status.ThinPool.CurrentSizeBytes > 0 && maxBytes > vg.Status.ThinPool.CurrentSizeBytes {
		target, capped := PlanThinPoolExtend(vg.Status.ThinPool.CurrentSizeBytes, maxBytes, p.AutoExtendStepPercent)
		if capped {
			setCond(&vg, CondThinPoolExtendCapped, metav1.ConditionTrue, "ThinPoolExtendOverMax",
				fmt.Sprintf("兜底扩容目标 %d 字节超出 VG 可用上限 %d，转人工", target, maxBytes))
			setCond(&vg, CondThinPoolAutoExtend, metav1.ConditionFalse, "ThinPoolAutoExtendNotNeeded", "")
		} else {
			setCond(&vg, CondThinPoolAutoExtend, metav1.ConditionTrue, "ThinPoolAutoExtendPlanned",
				fmt.Sprintf("兜底扩容至 %d 字节（dmeventd 失效时触发）", target))
			setCond(&vg, CondThinPoolExtendCapped, metav1.ConditionFalse, "ThinPoolExtendWithinMax", "")
		}
	} else {
		setCond(&vg, CondThinPoolAutoExtend, metav1.ConditionFalse, "ThinPoolAutoExtendNotNeeded", "")
		setCond(&vg, CondThinPoolExtendCapped, metav1.ConditionFalse, "ThinPoolExtendWithinMax", "")
	}

	// 统一一次 patch（仅下发 status 变更，不覆盖 VGReconciler 的 pendingOps 等其余字段）。
	if !reflect.DeepEqual(base.Status, vg.Status) {
		if err := r.Status().Patch(ctx, &vg, client.MergeFrom(base)); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("容量治理状态更新", "vg", vg.Name, "capacityStatus", next)
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

// parseForecastDurations 解析策略中的 timeToFull 阈值（默认值 24h / 4h，解析失败回退默认）。
func parseForecastDurations(f storagev1alpha1.ThinPoolForecast) (warn, crit time.Duration) {
	warn, crit = 24*time.Hour, 4*time.Hour
	if f.TimeToFullWarning != "" {
		if d, err := time.ParseDuration(f.TimeToFullWarning); err == nil {
			warn = d
		}
	}
	if f.TimeToFullCritical != "" {
		if d, err := time.ParseDuration(f.TimeToFullCritical); err == nil {
			crit = d
		}
	}
	return
}

// setCond 在 NodeVG.status.conditions 上幂等设置条件（保留 LastTransitionTime）。
func setCond(vg *storagev1alpha1.NodeVG, condType string, status metav1.ConditionStatus, reason, msg string) {
	meta.SetStatusCondition(&vg.Status.Conditions, metav1.Condition{
		Type:               condType,
		Status:             status,
		Reason:             reason,
		Message:            msg,
		ObservedGeneration: vg.Generation,
	})
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
		Named("nodevg-capacity").
		Complete(r)
}
