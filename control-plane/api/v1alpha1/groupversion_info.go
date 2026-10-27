// Package v1alpha1 定义 hlvm 自研控制面的 CRD API。
//
// API Group: storage.example.io/v1alpha1（上线前替换占位域名）。
// 所有对象 cluster-scoped。Kind 命名采纳设计文档附录 B#30 建议（NodeDisk/NodeVG），
// 以避免与 OpenEBS BlockDevice 等冲突。
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion 是 hlvm CRD 的 API group/version。
	GroupVersion = schema.GroupVersion{Group: "storage.example.io", Version: "v1alpha1"}

	// SchemeBuilder 用于向 runtime.Scheme 注册类型。
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme 将本包所有类型注册进给定的 scheme。
	AddToScheme = SchemeBuilder.AddToScheme
)
