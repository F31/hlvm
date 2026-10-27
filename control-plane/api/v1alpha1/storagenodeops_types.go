package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// 节点运维操作类型（见 §3.5）。
const (
	NodeOpRetire      NodeOperation = "retire"
	NodeOpIsolate     NodeOperation = "isolate"
	NodeOpRecoverDisk NodeOperation = "recover-disk"
)

// 节点运维状态机阶段（见 §3.5/§9）。
const (
	NodeOpsValidate       NodeOpsPhase = "validate"
	NodeOpsDrain          NodeOpsPhase = "drain"
	NodeOpsWaitPVCCleanup NodeOpsPhase = "wait-pvc-cleanup"
	NodeOpsWipe           NodeOpsPhase = "wipe"
	NodeOpsDone           NodeOpsPhase = "done"
)

// NodeOperation 是节点运维操作类型。
type NodeOperation string

// NodeOpsPhase 是节点运维状态机阶段。
type NodeOpsPhase string

// StorageNodeOpsSpec 是节点运维剧本声明（允许一个节点多次操作，不再"一节点一对象"）。
type StorageNodeOpsSpec struct {
	NodeName  string        `json:"nodeName"`
	Operation NodeOperation `json:"operation"`
	Force     bool          `json:"force,omitempty"`
}

// StorageNodeOpsStatus 是节点运维剧本状态。
type StorageNodeOpsStatus struct {
	Phase        NodeOpsPhase `json:"phase,omitempty"`
	BlockingPVCs []string     `json:"blockingPVCs,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:subresource:status

// StorageNodeOps 是节点退役/隔离/盘迁移的运维剧本。
type StorageNodeOps struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   StorageNodeOpsSpec   `json:"spec,omitempty"`
	Status StorageNodeOpsStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// StorageNodeOpsList 是 StorageNodeOps 的集合。
type StorageNodeOpsList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []StorageNodeOps `json:"items"`
}

func init() {
	SchemeBuilder.Register(&StorageNodeOps{}, &StorageNodeOpsList{})
}
