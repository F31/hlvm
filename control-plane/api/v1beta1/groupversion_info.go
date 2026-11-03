// Package v1beta1 定义 hlvm 自研控制面的 CRD API 的 beta 契约。
//
// API Group: storage.example.io/v1beta1。
//
// 版本策略（见 openspec add-hardening-rollout 3.1b）：
//   - v1beta1 是 **存储版本（served + storage）**；v1alpha1 作为 served 兼容层，
//     其读写经 conversion webhook（cmd/crd-conversion）转到 v1beta1。
//   - 控制器 / dashboard / agent 一律走 v1beta1（存储版本），读写不经 webhook，
//     因此 conversion webhook 不可用时只有显式使用 v1alpha1 的老客户端受影响。
//   - 这是「迁消费者到存储版本」的意义：把 conversion 从控制面关键路径上摘下来。
//
// 已按此模式版本化的 Kind：NodeDisk（03b）、NodeVG（03c），其余 Kind 仍只有 v1alpha1，
// 待逐个按同一模式推广（见 scripts 与 runbook §10.18）。
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
