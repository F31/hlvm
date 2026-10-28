package controller

import (
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// EvaluateCapacityStatus 依据 thinpool 数据/元数据水位、是否 outOfSpace 与策略阈值计算容量状态。
//
// 映射规则（设计 §3.3）：
//   data% >= CriticalPercent 或 metadata% >= MetadataCriticalPercent 或 outOfSpace => Locked
//   data% >= WarningPercent => Pressure
//   否则 => Available
//
// 滞回解锁由调用方在水位回落到 UnlockPercent 以下时处理，本函数只做瞬时判定。
func EvaluateCapacityStatus(dataPercent, metadataPercent float64, outOfSpace bool, p storagev1alpha1.ThinPoolThresholds) storagev1alpha1.CapacityStatus {
	if outOfSpace ||
		dataPercent >= float64(p.CriticalPercent) ||
		metadataPercent >= float64(p.MetadataCriticalPercent) {
		return storagev1alpha1.CapacityLocked
	}
	if dataPercent >= float64(p.WarningPercent) {
		return storagev1alpha1.CapacityPressure
	}
	return storagev1alpha1.CapacityAvailable
}

// DefaultThresholds 是 ThinPoolPolicy 缺省阈值（设计 §3.3 推荐值，零阈值兜底，防止缺失策略时误锁）。
func DefaultThresholds() storagev1alpha1.ThinPoolThresholds {
	return storagev1alpha1.ThinPoolThresholds{
		WarningPercent:         75,
		CriticalPercent:        85,
		UnlockPercent:          80,
		MetadataCriticalPercent: 75,
	}
}

// ResolveThresholds 解析最终阈值：默认阈值 → 集群策略（非零覆盖）→ tier 覆盖（非零覆盖），
// 保证任意字段缺失时回退到缺省，避免零阈值导致一切皆锁（设计 §3.3 tierOverrides 继承语义）。
func ResolveThresholds(policy *storagev1alpha1.ThinPoolPolicy, tier string) storagev1alpha1.ThinPoolThresholds {
	t := DefaultThresholds()
	overlay := func(o storagev1alpha1.ThinPoolThresholds) {
		if o.WarningPercent != 0 {
			t.WarningPercent = o.WarningPercent
		}
		if o.CriticalPercent != 0 {
			t.CriticalPercent = o.CriticalPercent
		}
		if o.UnlockPercent != 0 {
			t.UnlockPercent = o.UnlockPercent
		}
		if o.MetadataWarningPercent != 0 {
			t.MetadataWarningPercent = o.MetadataWarningPercent
		}
		if o.MetadataCriticalPercent != 0 {
			t.MetadataCriticalPercent = o.MetadataCriticalPercent
		}
		if o.AutoExtendPercent != 0 {
			t.AutoExtendPercent = o.AutoExtendPercent
		}
		if o.AutoExtendStepPercent != 0 {
			t.AutoExtendStepPercent = o.AutoExtendStepPercent
		}
	}
	if policy != nil {
		overlay(policy.Spec.Thresholds)
		if tier != "" {
			if o, ok := policy.Spec.TierOverrides[tier]; ok {
				overlay(o)
			}
		}
	}
	return t
}

// NextCapacityStatus 在瞬时判定基础上加入滞回解锁（设计 §3.3：回落到 unlockPercent 以下才解锁，边界不抖动）。
//
// 规则：
//   - 当前非 Locked：直接采用瞬时判定（可自由升级到 Pressure/Locked）。
//   - 当前 Locked 且瞬时仍 Locked：保持 Locked。
//   - 当前 Locked 但瞬时已脱离锁定区：仅当 data% < UnlockPercent 且 metadata% < MetadataCriticalPercent
//     且未 outOfSpace 时才解锁；解锁后若 data% >= WarningPercent 则降为 Pressure，否则 Available。
func NextCapacityStatus(current storagev1alpha1.CapacityStatus, dataPercent, metadataPercent float64, outOfSpace bool, p storagev1alpha1.ThinPoolThresholds) storagev1alpha1.CapacityStatus {
	instant := EvaluateCapacityStatus(dataPercent, metadataPercent, outOfSpace, p)
	if current != storagev1alpha1.CapacityLocked {
		return instant
	}
	if instant != storagev1alpha1.CapacityLocked {
		if dataPercent < float64(p.UnlockPercent) &&
			metadataPercent < float64(p.MetadataCriticalPercent) &&
			!outOfSpace {
			if dataPercent >= float64(p.WarningPercent) {
				return storagev1alpha1.CapacityPressure
			}
			return storagev1alpha1.CapacityAvailable
		}
		return storagev1alpha1.CapacityLocked
	}
	return storagev1alpha1.CapacityLocked
}

// LockLabelName 返回 tier 对应的锁标签（设计 §2.2/§3.3：locked 节点排除调度）。
func LockLabelName(tier string) string {
	return "storage.example.io/" + tier + "-locked"
}

// IsNodeStale 判定节点是否失联超过阈值（设计 §7 disk-ctrl：默认 30min）。
// lastReady 为空表示从未就绪，不视为 stale（由其他机制处理）。
func IsNodeStale(lastReady *metav1.Time, threshold time.Duration, now time.Time) bool {
	if lastReady == nil {
		return false
	}
	return now.Sub(lastReady.Time) > threshold
}
