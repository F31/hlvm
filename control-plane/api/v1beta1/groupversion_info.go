// Package v1beta1 定义 hlvm 自研控制面的 CRD API 的 beta 契约。
//
// API Group: storage.example.io/v1beta1。
//
// 版本策略（见 openspec add-hardening-rollout 3.1b）：
//   - v1beta1 目前处于 **served 但非存储版本** 状态：写入仍以 v1alpha1 落盘，
//     v1beta1 的读写经 conversion webhook（cmd/crd-conversion）转换。
//   - 这样做把爆炸半径压到最小：conversion webhook 不可用时，只有 v1beta1 读写失败，
//     v1alpha1（存储版本）读路径不经过 webhook，控制器与既有对象不受影响。
//   - 待 v1beta1 稳定后再切 storedVersions（需迁移方案），切换前 v1alpha1 必须保持 served。
//
// 本轮只对 NodeDisk 做版本化试点；其余 Kind 仍只有 v1alpha1，
// 待 NodeDisk 的转换链路（含证书轮换与集群验证）跑通后按同一模式推广。
//
// +kubebuilder:object:generate=true
package v1beta1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion 是 hlvm CRD 的 API group/version。
	GroupVersion = schema.GroupVersion{Group: "storage.example.io", Version: "v1beta1"}

	// SchemeBuilder 用于向 runtime.Scheme 注册类型。
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme 将本包所有类型注册进给定的 scheme。
	AddToScheme = SchemeBuilder.AddToScheme
)
