package v1alpha1

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/conversion"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// 本文件实现 v1alpha1 作为 spoke 的双向转换（hub 在 api/v1beta1）。
//
// 字段映射：StorageTask 在 v1alpha1 与 v1beta1 之间是**逐字段恒等**（本轮仅建立版本化机制，
// schema 未变；v1beta1 作为存储版本承担未来演进）。采用逐字段显式映射而不是 `unsafe`
// 指针转换，确保任何字段漏映射都能在往返测试中暴露（见 storagetask_conversion_test.go）。

// ConvertTo 把 v1alpha1 StorageTask 转换为 hub 版本（v1beta1）。
func (src *StorageTask) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.StorageTask)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageTask，实际是 %T", dstRaw)
	}
	convertStorageTaskToBeta(src, dst)
	return nil
}

// ConvertFrom 把 hub 版本（v1beta1）转换回 v1alpha1。
func (src *StorageTask) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.StorageTask)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageTask，实际是 %T", srcRaw)
	}
	convertStorageTaskFromBeta(hub, src)
	return nil
}

// ConvertTo 把 v1alpha1 StorageTaskList 转换为 hub 版本。
func (src *StorageTaskList) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.StorageTaskList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageTaskList，实际是 %T", dstRaw)
	}
	dst.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "StorageTaskList",
	}
	dst.ListMeta = src.ListMeta
	dst.Items = make([]storagev1beta1.StorageTask, len(src.Items))
	for i := range src.Items {
		convertStorageTaskToBeta(&src.Items[i], &dst.Items[i])
	}
	return nil
}

// ConvertFrom 把 hub 版本的 StorageTaskList 转换回 v1alpha1。
func (src *StorageTaskList) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.StorageTaskList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageTaskList，实际是 %T", srcRaw)
	}
	src.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "StorageTaskList",
	}
	src.ListMeta = hub.ListMeta
	src.Items = make([]StorageTask, len(hub.Items))
	for i := range hub.Items {
		convertStorageTaskFromBeta(&hub.Items[i], &src.Items[i])
	}
	return nil
}

func convertStorageTaskToBeta(in *StorageTask, out *storagev1beta1.StorageTask) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "StorageTask",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = storagev1beta1.StorageTaskSpec{
		NodeName:      in.Spec.NodeName,
		Type:          storagev1beta1.TaskType(in.Spec.Type),
		Target:        storagev1beta1.TaskTarget{DiskRef: in.Spec.Target.DiskRef},
		Disks:         append([]string(nil), in.Spec.Disks...),
		ConfirmSerial: in.Spec.ConfirmSerial,
		DryRun:        in.Spec.DryRun,
		ApprovedBy:    in.Spec.ApprovedBy,
		TTL:           in.Spec.TTL,
	}
	out.Status = storagev1beta1.StorageTaskStatus{
		Phase:       storagev1beta1.TaskPhase(in.Status.Phase),
		StartedAt:   in.Status.StartedAt.DeepCopy(),
		CompletedAt: in.Status.CompletedAt.DeepCopy(),
		Result:      in.Status.Result,
		Message:     in.Status.Message,
	}
}

func convertStorageTaskFromBeta(in *storagev1beta1.StorageTask, out *StorageTask) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "StorageTask",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = StorageTaskSpec{
		NodeName:      in.Spec.NodeName,
		Type:          TaskType(in.Spec.Type),
		Target:        TaskTarget{DiskRef: in.Spec.Target.DiskRef},
		Disks:         append([]string(nil), in.Spec.Disks...),
		ConfirmSerial: in.Spec.ConfirmSerial,
		DryRun:        in.Spec.DryRun,
		ApprovedBy:    in.Spec.ApprovedBy,
		TTL:           in.Spec.TTL,
	}
	out.Status = StorageTaskStatus{
		Phase:       TaskPhase(in.Status.Phase),
		StartedAt:   in.Status.StartedAt.DeepCopy(),
		CompletedAt: in.Status.CompletedAt.DeepCopy(),
		Result:      in.Status.Result,
		Message:     in.Status.Message,
	}
}
