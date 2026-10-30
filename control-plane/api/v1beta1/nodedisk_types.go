package v1beta1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// 磁盘生命周期阶段（phase 与 health 两维度分离，见设计 §3.1）。
const (
	DiskPhaseDiscovered DiskPhase = "Discovered"
	DiskPhaseCandidate  DiskPhase = "Candidate"
	DiskPhasePreChecked DiskPhase = "PreChecked"
	DiskPhaseWiped      DiskPhase = "Wiped"
	DiskPhaseInVG       DiskPhase = "InVG"
	DiskPhaseDraining   DiskPhase = "Draining"
	DiskPhaseRemoved    DiskPhase = "Removed"
)

// 磁盘健康度（与 phase 独立）。
const (
	DiskHealthHealthy  DiskHealth = "healthy"
	DiskHealthWarning  DiskHealth = "warning"
	DiskHealthCritical DiskHealth = "critical"
	DiskHealthFailed   DiskHealth = "failed"
)

// 介质类型。
const (
	MediaNVMe MediaType = "nvme"
	MediaSSD  MediaType = "ssd"
	MediaHDD  MediaType = "hdd"
)

// 擦除策略（破坏性操作前必须与 status.identity.serial 一致）。
const (
	WipeNone        WipePolicy = "none"
	WipeZero        WipePolicy = "zero"
	WipeSecureErase WipePolicy = "secure-erase"
)

// 占用类型（预检规则枚举）。
const (
	OccupiedNone       OccupiedBy = "none"
	OccupiedFilesystem OccupiedBy = "filesystem"
	OccupiedLVMPV      OccupiedBy = "lvm-pv"
	OccupiedMD         OccupiedBy = "md"
	OccupiedMPath      OccupiedBy = "mpath"
	OccupiedHolder     OccupiedBy = "holder"
	OccupiedUnknown    OccupiedBy = "unknown"
)

// DiskPhase 是磁盘生命周期阶段。
// +kubebuilder:validation:Enum=Discovered;Candidate;PreChecked;Wiped;InVG;Draining;Removed
type DiskPhase string

// DiskHealth 是磁盘健康度。
// +kubebuilder:validation:Enum=healthy;warning;critical;failed
type DiskHealth string

// MediaType 是磁盘介质类型。
// +kubebuilder:validation:Enum=nvme;ssd;hdd
type MediaType string

// WipePolicy 是磁盘退役擦除策略。
// +kubebuilder:validation:Enum=none;zero;secure-erase
type WipePolicy string

// OccupiedBy 是磁盘当前被何种结构占用。
// +kubebuilder:validation:Enum=none;filesystem;lvm-pv;md;mpath;holder;unknown
type OccupiedBy string

// DiskDevice 是设备引用（v1beta1 由 v1alpha1 的 `spec.deviceRef` 字符串演进而来）。
//
// 为什么改用结构体而不是继续加字符串字段：设备引用后续要承载
//   - `path`：节点上的块设备路径（如 /dev/sda）；
//   - 将来的 `byId` / 分区信息 / 多路径成员选择。
//
// 用结构体可以逐字段增量演进，不需要再开 v1gamma；字符串则每次新增都得换字段名。
type DiskDevice struct {
	// Path 是磁盘在节点上的设备路径（如 /dev/sda），由 Agent 写入，用于定位物理盘。
	// 仅作引用，磁盘身份仍以 status.identity(serial/wwn) 为准（见设计 §3.1）。
	// +kubebuilder:validation:MaxLength=256
	Path string `json:"path,omitempty"`
}

// DiskSpec 定义纳管意图。
type DiskSpec struct {
	// NodeName 是磁盘所在节点。
	// +kubebuilder:validation:Required
	NodeName string `json:"nodeName"`
	// Adopt 为 true 才进入纳管流程（Candidate→PreChecked 由预检自动完成，后续需 Adopt=true 且被 VG 引用）。
	Adopt bool `json:"adopt,omitempty"`
	// Device 是磁盘设备引用；未写入（nil）等价于 v1alpha1 的空 deviceRef。
	Device *DiskDevice `json:"device,omitempty"`
	// ConfirmSerial 破坏性操作前必须与 status.identity.serial 一致，防误选盘。
	// +kubebuilder:validation:MaxLength=128
	ConfirmSerial string `json:"confirmSerial,omitempty"`
	// WipePolicy 擦除策略。
	WipePolicy WipePolicy `json:"wipePolicy,omitempty"`
}

// DiskIdentity 是磁盘稳定身份（以 WWN/serial 为准，不用设备名）。
type DiskIdentity struct {
	Serial string `json:"serial,omitempty"`
	WWN    string `json:"wwn,omitempty"`
	Model  string `json:"model,omitempty"`
	ByID   string `json:"byId,omitempty"`
}

// DiskSMART 是 SMART 健康采样。全量采样只进 Prometheus，status 仅变化或 10 分钟低频刷新。
type DiskSMART struct {
	LastProbeTime         *metav1.Time `json:"lastProbeTime,omitempty"`
	OverallStatus         string       `json:"overallStatus,omitempty"`
	CriticalWarning       int32        `json:"criticalWarning,omitempty"`
	AvailableSparePercent int32        `json:"availableSparePercent,omitempty"`
	PercentUsed           int32        `json:"percentUsed,omitempty"`
	TemperatureCelsius    int32        `json:"temperatureCelsius,omitempty"`
	// MediaErrors 累计值，按增量判定（见设计 §3.1）。
	MediaErrors int64 `json:"mediaErrors,omitempty"`
	// MediaErrorsLastProbe 用于增量比较，避免累计值非 0 但无增长时误报。
	MediaErrorsLastProbe int64 `json:"mediaErrorsLastProbe,omitempty"`
	UnsafeShutdowns      int32 `json:"unsafeShutdowns,omitempty"`
}

// DiskRaid 表达磁盘的 RAID 成员关系（统一在 Disk/VG status 表达，避免两处重复，见 §3.2）。
type DiskRaid struct {
	MemberOf string `json:"memberOf,omitempty"`
	Degraded bool   `json:"degraded,omitempty"`
}

// DiskStatus 是磁盘运行时状态。
type DiskStatus struct {
	Identity      DiskIdentity       `json:"identity,omitempty"`
	CurrentDevice string             `json:"currentDevice,omitempty"`
	CapacityBytes int64              `json:"capacityBytes,omitempty"`
	Phase         DiskPhase          `json:"phase,omitempty"`
	Health        DiskHealth         `json:"health,omitempty"`
	Smart         DiskSMART          `json:"smart,omitempty"`
	OccupiedBy    OccupiedBy         `json:"occupiedBy,omitempty"`
	IsSystemDisk  bool               `json:"isSystemDisk,omitempty"`
	Raid          *DiskRaid          `json:"raid,omitempty"`
	VgRef         string             `json:"vgRef,omitempty"`
	Conditions    []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:subresource:status
// +kubebuilder:storageversion=false

// NodeDisk 是单块被纳管磁盘的声明。
type NodeDisk struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   DiskSpec   `json:"spec,omitempty"`
	Status DiskStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// NodeDiskList 是 NodeDisk 的集合。
type NodeDiskList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []NodeDisk `json:"items"`
}

func init() {
	SchemeBuilder.Register(&NodeDisk{}, &NodeDiskList{})
}
