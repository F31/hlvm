package webhook

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// PodMutator 是第 2 层节点级调度约束注入器（设计 §4 / 变更 §2.2）。
//
// 为引用本平台 PVC 的新 Pod 注入 nodeAffinity，排除 locked 节点（消费 controller.LockLabelName 标签）。
// 仅对新建 Pod 生效（CustomDefaulter.Default），已有 Pod 不受影响。
// FailurePolicy=Ignore：注入失败时放行，不阻塞调度（容量类拦截缺失由 capacity-ctrl 兜底）。
type PodMutator struct {
	client.Reader
}

var _ admission.CustomDefaulter = &PodMutator{}

// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=persistentvolumeclaims,verbs=get;list;watch
// +kubebuilder:rbac:groups=storage.k8s.io,resources=storageclasses,verbs=get;list;watch

func (m *PodMutator) Default(ctx context.Context, obj runtime.Object) error {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return nil
	}
	tiers, err := PodReferencedPlatformTiers(ctx, m.Reader, pod)
	if err != nil {
		ctrl.Log.Error(err, "Pod 调度约束注入内部错误，放行", "pod", pod.Name)
		return nil
	}
	if len(tiers) == 0 {
		return nil
	}
	MergeNodeAffinity(pod, BuildLockedNodeAffinity(tiers))
	return nil
}
