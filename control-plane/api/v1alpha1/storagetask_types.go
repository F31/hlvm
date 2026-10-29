package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// 节点任务类型（取代 v1.0 的 annotation 指令队列，见 §3.4）。
const (
	TaskWipe           TaskType = "wipe"
	TaskPVCreate       TaskType = "pvcreate"
	TaskVGCreate       TaskType = "vgcreate"
	TaskVGExtend       TaskType = "vgextend"
	TaskVGReduce       TaskType = "vgreduce"
	TaskThinpoolExtend TaskType = "thinpool-extend"
	TaskMDRepair       TaskType = "md-repair"
)

// 任务阶段。
const (
	TaskPending   TaskPhase = "Pending"
	TaskRunning   TaskPhase = "Running"
	TaskSucceeded TaskPhase = "Succeeded"
	TaskFailed    TaskPhase = "Failed"
	TaskUnknown   TaskPhase = "Unknown"
)

// TaskType 是节点任务类型。
// +kubebuilder:validation:Enum=wipe;pvcreate;vgcreate;vgextend;vgreduce;thinpool-extend;md-repair
type TaskType string

// TaskPhase 是任务阶段。
// +kubebuilder:validation:Enum=Pending;Running;Succeeded;Failed;Unknown
type TaskPhase string

// TaskTarget 是任务作用目标。
type TaskTarget struct {
	// DiskRef 引用 NodeDisk 对象名（{node}-{serial/wwn 短名}）。
	DiskRef string `json:"diskRef,omitempty"`
}

// StorageTaskSpec 是节点任务声明（唯一 PV/VG/pool 写路径，见 §3.4/§5）。
type StorageTaskSpec struct {
	// NodeName 是任务目标节点。
	// +kubebuilder:validation:Required
	NodeName string `json:"nodeName"`
	// Type 是任务类型（白名单枚举）。
	// +kubebuilder:validation:Required
	Type     TaskType `json:"type"`
	Target   TaskTarget `json:"target,omitempty"`
	// Disks 是 vgcreate/vgextend 等多盘操作的盘列表（by-id）；单盘任务可只用 Target。
	Disks []string `json:"disks,omitempty"`
	// ConfirmSerial 破坏性任务必须与目标盘 serial 一致。
	// +kubebuilder:validation:MaxLength=128
	ConfirmSerial string `json:"confirmSerial,omitempty"`
	// DryRun 只预检不执行。
	DryRun bool `json:"dryRun,omitempty"`
	// ApprovedBy 破坏性任务必须有审批人（webhook 校验）。
	ApprovedBy string `json:"approvedBy,omitempty"`
	// TTL 是任务**执行窗口**（如 "1h"）：自 metadata.creationTimestamp 起算，超时后不再执行。
	// 仅对尚未开始（phase 为空或 Pending）的任务生效；到期由控制面标记 Failed（DeadlineExceeded）
	// 并保留对象，不自动重试（对齐 K8s Job 的 activeDeadlineSeconds）。
	// 无法解析或 <= 0 时按失败关闭处理（拒绝执行），避免执行时限不可评估的破坏性任务。
	TTL string `json:"ttl,omitempty"`
}

// StorageTaskStatus 是节点任务状态。幂等以 taskID 去重（见 §3.4）。
type StorageTaskStatus struct {
	Phase       TaskPhase    `json:"phase,omitempty"`
	StartedAt   *metav1.Time `json:"startedAt,omitempty"`
	CompletedAt *metav1.Time `json:"completedAt,omitempty"`
	Result      string       `json:"result,omitempty"`
	// Message 携带执行回执细节（拒绝原因、命令回显等），由节点 Agent 写入（单写者原则：仅 Agent 写 status）。
	Message string `json:"message,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster

// StorageTask 是节点侧执行的一次性任务（稳定 taskID 去重、TTL、幂等）。
type StorageTask struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   StorageTaskSpec   `json:"spec,omitempty"`
	Status StorageTaskStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// StorageTaskList 是 StorageTask 的集合。
type StorageTaskList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []StorageTask `json:"items"`
}

func init() {
	SchemeBuilder.Register(&StorageTask{}, &StorageTaskList{})
}
