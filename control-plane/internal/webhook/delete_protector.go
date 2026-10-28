package webhook

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// DeleteProtector 是删除保护器（设计 §4 / 变更 §2.4）：节点处于 retire 流程且仍有在用 PV 时，
// 拒绝删除该节点的相关存储对象（StorageNodeOps / NodeVG）。FailurePolicy=Fail（安全类），仅作用于本平台对象。
//
// 安全类策略：读取失败一律返回错误 → 拒绝（宁可拒绝也不误删）。
type DeleteProtector struct {
	client.Reader
}

var _ admission.CustomValidator = &DeleteProtector{}

// +kubebuilder:rbac:groups=hlvm.example.io,resources=storagenodeops;nodevgs,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=persistentvolumes,verbs=get;list;watch

func (v *DeleteProtector) ValidateCreate(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	return nil, nil
}

func (v *DeleteProtector) ValidateUpdate(ctx context.Context, oldObj, newObj runtime.Object) (admission.Warnings, error) {
	return nil, nil
}

func (v *DeleteProtector) ValidateDelete(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	nodeName := nodeNameOf(obj)
	if nodeName == "" {
		return nil, nil
	}
	var list storagev1alpha1.StorageNodeOpsList
	if err := v.List(ctx, &list); err != nil {
		// 安全类：读取失败 → 拒绝。
		return nil, fmt.Errorf("删除保护读取 StorageNodeOps 失败：%v", err)
	}
	for i := range list.Items {
		ops := &list.Items[i]
		if ops.Spec.NodeName != nodeName || ops.Spec.Operation != storagev1alpha1.NodeOpRetire {
			continue
		}
		if !RetireInFlight(ops) {
			continue
		}
		n, err := CountInUsePVs(ctx, v.Reader, nodeName)
		if err != nil {
			return nil, fmt.Errorf("删除保护统计在用 PV 失败：%v", err)
		}
		if n > 0 {
			// 脱敏：不暴露具体 PV 名，仅说明退役流程与在用卷。
			return nil, fmt.Errorf("节点处于退役流程且仍有在用卷，拒绝删除相关存储对象（请联系管理员）")
		}
	}
	return nil, nil
}

// nodeNameOf 从受保护对象取出所属节点名。
func nodeNameOf(obj runtime.Object) string {
	switch o := obj.(type) {
	case *storagev1alpha1.StorageNodeOps:
		return o.Spec.NodeName
	case *storagev1alpha1.NodeVG:
		return o.Spec.NodeName
	}
	return ""
}
