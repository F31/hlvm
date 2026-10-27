package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VG 布局策略（见设计 §3.2）。
const (
	// VGLayoutPooled 多盘一个 VG，容量灵活但任一盘损坏整个 VG 全部 LV 丢失。
	VGLayoutPooled VGLayout = "pooled"
	// VGLayoutPerDisk 一盘一 VG，爆炸半径限于单盘；无 RAID 的 tier 默认 per-disk。
	VGLayoutPerDisk VGLayout = "per-disk"
)

// 冗余类型（RAID 置于 LVM 之下，见 §3.2）。
const (
	RedundancyNone     Redundancy = "none"
	RedundancyHWRAID   Redundancy = "hw-raid"
	RedundancyMDRAID1  Redundancy = "md-raid1"
	RedundancyLVRAID1  Redundancy = "lvm-raid1"
)

// 容量状态（含滞回解锁，见 §3.3）。
const (
	CapacityAvailable CapacityStatus = "available"
	CapacityPressure  CapacityStatus = "pressure"
	CapacityLocked    CapacityStatus = "locked"
)

// VGLayout 是 VG 布局策略。
type VGLayout string

// Redundancy 是 VG 冗余类型。
type Redundancy string

// CapacityStatus 是 VG 容量状态。
type CapacityStatus string

// ThinPoolSpec 定义 thinpool 的容量与超分参数。
type ThinPoolSpec struct {
	Name               string  `json:"name"`
	InitialSizePercent int32   `json:"initialSizePercent,omitempty"`
	MaxSizePercent     int32   `json:"maxSizePercent,omitempty"`
	MetadataSize       string  `json:"metadataSize,omitempty"`
	ChunkSize          string  `json:"chunkSize,omitempty"`
	OverprovisionRatio float64 `json:"overprovisionRatio,omitempty"`
}

// VGOperations 是需要节点执行的操作意图（由 vg-ctrl 渲染为 StorageTask）。
type VGOperations struct {
	// RemoveDisks 待移除盘；vg-ctrl 在下发前校验无 LV 占用且冗余不丧失。
	RemoveDisks []string `json:"removeDisks,omitempty"`
}

// VGSpec 定义卷组的声明（spec 不可被控制器回写，避免 GitOps 漂移，见 §3.2）。
type VGSpec struct {
	NodeName   string       `json:"nodeName"`
	Tier       string       `json:"tier,omitempty"`
	Layout     VGLayout     `json:"layout,omitempty"`
	Redundancy Redundancy   `json:"redundancy,omitempty"`
	Disks      []string     `json:"disks,omitempty"`
	ThinPool   ThinPoolSpec `json:"thinPool,omitempty"`
	Operations VGOperations `json:"operations,omitempty"`
}

// VGThinPoolStatus 是 thinpool 的运行时状态（自动扩容结果写 status，不回写 spec）。
type VGThinPoolStatus struct {
	CurrentSizeBytes int64   `json:"currentSizeBytes,omitempty"`
	DataPercent      float64 `json:"dataPercent,omitempty"`
	MetadataPercent  float64 `json:"metadataPercent,omitempty"`
	ProvisionedBytes int64   `json:"provisionedBytes,omitempty"`
	State            string  `json:"state,omitempty"`
	OutOfSpace       bool    `json:"outOfSpace,omitempty"`
}

// VGStatus 是卷组的运行时状态。
type VGStatus struct {
	VGExists        bool             `json:"vgExists,omitempty"`
	VGUUID          string           `json:"vgUUID,omitempty"`
	TotalBytes      int64            `json:"totalBytes,omitempty"`
	FreeBytes       int64            `json:"freeBytes,omitempty"`
	ThinPool        VGThinPoolStatus `json:"thinPool,omitempty"`
	CapacityStatus  CapacityStatus   `json:"capacityStatus,omitempty"`
	LastDriftCheck  *metav1.Time     `json:"lastDriftCheck,omitempty"`
	PendingOps      []string         `json:"pendingOps,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:subresource:status

// NodeVG 是单节点卷组的声明。
type NodeVG struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   VGSpec   `json:"spec,omitempty"`
	Status VGStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// NodeVGList 是 NodeVG 的集合。
type NodeVGList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []NodeVG `json:"items"`
}

func init() {
	SchemeBuilder.Register(&NodeVG{}, &NodeVGList{})
}
