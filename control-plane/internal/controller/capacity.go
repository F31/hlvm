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

// IsNodeStale 判定节点是否失联超过阈值（设计 §7 disk-ctrl：默认 30min）。
// lastReady 为空表示从未就绪，不视为 stale（由其他机制处理）。
func IsNodeStale(lastReady *metav1.Time, threshold time.Duration, now time.Time) bool {
	if lastReady == nil {
		return false
	}
	return now.Sub(lastReady.Time) > threshold
}
