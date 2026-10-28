package webhook

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// PVCValidator 是第 1 层 tier 级 PVC 准入校验器（设计 §4 / 变更 §2.1）。
//
// 仅对使用本平台 StorageClass 的 PVC 生效（provisioner=topolvm.io）；判定"该 tier 是否存在至少一个可用节点"
// 而非某个具体 VG；覆盖 CREATE 与扩容 UPDATE。拒绝信息脱敏（仅含 tier），内部细节只进审计与告警。
// 容量类拦截 FailurePolicy=Ignore（见 M9b 清单配置），因此内部读取失败时一律放行，不阻塞集群。
type PVCValidator struct {
	client.Reader
	Recorder record.EventRecorder
}

var _ admission.CustomValidator = &PVCValidator{}

// +kubebuilder:rbac:groups=storage.k8s.io,resources=storageclasses,verbs=get;list;watch
// +kubebuilder:rbac:groups=hlvm.example.io,resources=nodevgs,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

func (v *PVCValidator) ValidateCreate(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	pvc, ok := obj.(*corev1.PersistentVolumeClaim)
	if !ok {
		return nil, nil
	}
	return v.admit(ctx, pvc)
}

func (v *PVCValidator) ValidateUpdate(ctx context.Context, oldObj, newObj runtime.Object) (admission.Warnings, error) {
	oldPVC, ok1 := oldObj.(*corev1.PersistentVolumeClaim)
	newPVC, ok2 := newObj.(*corev1.PersistentVolumeClaim)
	if !ok1 || !ok2 {
		return nil, nil
	}
	// 非扩容更新（如标签/注解变更）不触发容量准入。
	if !IsExpand(oldPVC, newPVC) {
		return nil, nil
	}
	return v.admit(ctx, newPVC)
}

func (v *PVCValidator) ValidateDelete(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	return nil, nil
}

// admit 执行 tier 可用节点判定（仅平台 PVC；非平台直通）。
func (v *PVCValidator) admit(ctx context.Context, pvc *corev1.PersistentVolumeClaim) (admission.Warnings, error) {
	tier, platform, err := PVCTier(ctx, v.Reader, pvc)
	if err != nil {
		// 容量类：内部错误放行，不阻塞集群。
		ctrl.Log.Error(err, "PVC 准入内部错误，按容量类策略放行", "pvc", pvc.Name)
		return nil, nil
	}
	if !platform {
		return nil, nil // 非本平台 PVC 直通，绝不经过本平台策略。
	}
	var list storagev1alpha1.NodeVGList
	if err := v.List(ctx, &list); err != nil {
		ctrl.Log.Error(err, "PVC 准入读取 NodeVG 失败，按容量类策略放行")
		return nil, nil
	}
	if !TierHasAvailableNode(list.Items, tier) {
		msg := SanitizedDenyMessage(tier)
		if v.Recorder != nil {
			v.Recorder.Event(pvc, corev1.EventTypeWarning, "StorageAdmissionDenied", msg)
		}
		return admission.Warnings{"该存储等级暂无可用容量节点"}, fmt.Errorf("%s", msg)
	}
	// 单副本业务未声明 replicas 标签：仅提示不强拦（设计 §6，避免误杀 StatefulSet）。
	if !ReplicasDeclared(pvc) {
		return admission.Warnings{"建议为单副本业务声明 storage.example.io/replicas 以留痕多副本评审"}, nil
	}
	return nil, nil
}
