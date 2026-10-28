package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ThinPoolThresholds 定义 thinpool 容量阈值与滞回（见设计 §3.3）。
type ThinPoolThresholds struct {
	// AutoExtendPercent dmeventd 触发扩容的数据区阈值。
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	AutoExtendPercent int32 `json:"autoExtendPercent,omitempty"`
	// AutoExtendStepPercent dmeventd 单次扩容步长。
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	AutoExtendStepPercent int32 `json:"autoExtendStepPercent,omitempty"`
	// WarningPercent capacityStatus 进入 pressure 的下界。
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	WarningPercent int32 `json:"warningPercent,omitempty"`
	// CriticalPercent capacityStatus 进入 locked 的下界。
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	CriticalPercent int32 `json:"criticalPercent,omitempty"`
	// UnlockPercent 滞回解锁阈值，回落到该值以下才解锁，避免边界抖动。
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	UnlockPercent int32 `json:"unlockPercent,omitempty"`
	// MetadataWarningPercent 元数据告警阈值。
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	MetadataWarningPercent int32 `json:"metadataWarningPercent,omitempty"`
	// MetadataCriticalPercent 元数据进入 locked 的阈值。
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	MetadataCriticalPercent int32 `json:"metadataCriticalPercent,omitempty"`
}

// ThinPoolForecast 定义按增长速率的预测告警。
type ThinPoolForecast struct {
	// TimeToFullWarning 早于写满该时长发 Warning（如 "24h"）。
	TimeToFullWarning string `json:"timeToFullWarning,omitempty"`
	// TimeToFullCritical 早于写满该时长发 Critical（如 "4h"）。
	TimeToFullCritical string `json:"timeToFullCritical,omitempty"`
}

// ThinPoolLock 定义锁的拦截范围（见设计 §3.3）。
type ThinPoolLock struct {
	// BlockNewPVC 锁定时拦截新 PVC。
	BlockNewPVC bool `json:"blockNewPVC,omitempty"`
	// BlockPVCExpansion 锁定时拦截存量 PVC 扩容（v1.0 遗漏）。
	BlockPVCExpansion bool `json:"blockPVCExpansion,omitempty"`
}

// ThinPoolPolicySpec 是容量策略，集群级单例（name=default），可按 tier 覆盖。
type ThinPoolPolicySpec struct {
	Thresholds     ThinPoolThresholds   `json:"thresholds,omitempty"`
	Forecast       ThinPoolForecast     `json:"forecast,omitempty"`
	Lock           ThinPoolLock         `json:"lock,omitempty"`
	RequireFreeVGSpace string           `json:"requireFreeVGSpace,omitempty"`
	AlertChannels  []string             `json:"alertChannels,omitempty"`
	// TierOverrides 按 tier 覆盖 ThinPoolThresholds（不覆盖的部分继承默认）。
	TierOverrides map[string]ThinPoolThresholds `json:"tierOverrides,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster

// ThinPoolPolicy 是集群级容量策略单例。
type ThinPoolPolicy struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec ThinPoolPolicySpec `json:"spec,omitempty"`
}

// +kubebuilder:object:root=true

// ThinPoolPolicyList 是 ThinPoolPolicy 的集合。
type ThinPoolPolicyList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ThinPoolPolicy `json:"items"`
}

func init() {
	SchemeBuilder.Register(&ThinPoolPolicy{}, &ThinPoolPolicyList{})
}
