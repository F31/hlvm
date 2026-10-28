package controller

import (
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/api/resource"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// AlertLevel 是预测告警等级（设计 §3.3 1.4）。
type AlertLevel string

const (
	AlertNone     AlertLevel = "None"
	AlertWarning  AlertLevel = "Warning"
	AlertCritical AlertLevel = "Critical"
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

// --- 预测告警（§3.3 1.4，恒定速率预测；突发/衰减需 Agent 历史采样，POC 阶段不建模）---

// ForecastTimeToFull 按恒定增长速率估算填满剩余容量的时间。
// 任意输入非正（无增长/无容量）返回 nil（无法预测，不应误报）。
func ForecastTimeToFull(remainingBytes int64, growthBytesPerHour float64) *time.Duration {
	if growthBytesPerHour <= 0 || remainingBytes <= 0 {
		return nil
	}
	secs := float64(remainingBytes) / growthBytesPerHour * 3600
	d := time.Duration(secs * float64(time.Second))
	return &d
}

// ForecastCapacityAlert 依据数据区填充率、容量上限与增长速率给出预测告警等级与 timeToFull。
//   - 已 >=100% 填充 → Critical（立即写满）；
//   - timeToFull <= crit → Critical；timeToFull <= warn → Warning；否则 None。
// warn/crit 为时长阈值（如 24h / 4h）。无增长或容量为 0 时返回 None 且 ttf=nil。
func ForecastCapacityAlert(dataPercent float64, capacityBytes int64, growthBytesPerHour float64, warn, crit time.Duration) (AlertLevel, *time.Duration) {
	if growthBytesPerHour <= 0 || capacityBytes <= 0 {
		return AlertNone, nil
	}
	if dataPercent >= 100 {
		zero := time.Duration(0)
		return AlertCritical, &zero
	}
	remaining := int64((1 - dataPercent/100) * float64(capacityBytes))
	ttf := ForecastTimeToFull(remaining, growthBytesPerHour)
	if ttf == nil {
		return AlertNone, nil
	}
	if *ttf <= crit {
		return AlertCritical, ttf
	}
	if *ttf <= warn {
		return AlertWarning, ttf
	}
	return AlertNone, ttf
}

// --- requireFreeVGSpace 检查（§3.3 1.5，空间不足转人工工单）---

// ParseSize 解析人类可读容量（如 "50Gi" / "100G" / "1073741824"），返回字节数。
func ParseSize(s string) (int64, error) {
	q, err := resource.ParseQuantity(s)
	if err != nil {
		return 0, fmt.Errorf("无法解析容量 %q: %w", s, err)
	}
	return q.Value(), nil
}

// CheckFreeVGSpace 校验 VG 空闲空间是否满足策略要求。
// require 为空表示未配置要求（直接通过）。返回是否充足、要求字节数、解析错误。
func CheckFreeVGSpace(freeBytes int64, require string) (ok bool, requireBytes int64, err error) {
	if require == "" {
		return true, 0, nil
	}
	rb, e := ParseSize(require)
	if e != nil {
		return false, 0, e
	}
	return freeBytes >= rb, rb, nil
}

// --- lvm.conf autoextend 渲染（§3.3 1.6，与 Agent 下发对接）---

// RenderLVMConfAutoExtend 由阈值渲染 lvm.conf 的 thin pool autoextend 片段。
// AutoExtendPercent 为 dmeventd 触发阈值（thin_pool_autoextend_threshold），
// AutoExtendStepPercent 为单次扩容步长（thin_pool_autoextend_percent）。
// 未配置任一值时返回空串（不渲染，由 dmeventd 默认行为接管）。
func RenderLVMConfAutoExtend(t storagev1alpha1.ThinPoolThresholds) string {
	if t.AutoExtendPercent == 0 && t.AutoExtendStepPercent == 0 {
		return ""
	}
	return fmt.Sprintf(`# hlvm autoextend (rendered from ThinPoolPolicy)
activation {
    thin_pool_autoextend_threshold = %d
    thin_pool_autoextend_percent = %d
}`, t.AutoExtendPercent, t.AutoExtendStepPercent)
}

// --- thinpool 兜底扩容（§3 3.2，受 VG 剩余空间硬上限约束）---

// PlanThinPoolExtend 计算 thinpool 下一次扩容目标（dmeventd 失效时的控制面兜底）。
// 步长 = 当前尺寸 × stepPercent%；目标超过 maxBytes（VG 可用上限）则截断为 maxBytes 并标记 capped。
// currentSizeBytes<=0 或已无剩余空间时返回 (currentSizeBytes, false)，调用方不应触发扩容。
func PlanThinPoolExtend(currentSizeBytes, maxBytes int64, stepPercent int32) (target int64, capped bool) {
	if currentSizeBytes <= 0 || maxBytes <= currentSizeBytes {
		return currentSizeBytes, false
	}
	step := int64(float64(currentSizeBytes) * float64(stepPercent) / 100.0)
	if step <= 0 {
		step = 1 << 30 // 至少扩 1GiB
	}
	t := currentSizeBytes + step
	if t > maxBytes {
		return maxBytes, true
	}
	return t, false
}
