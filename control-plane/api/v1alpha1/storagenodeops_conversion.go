package v1alpha1

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/conversion"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// 本文件实现 v1alpha1 作为 spoke 的双向转换（hub 在 api/v1beta1）。
//
// 字段映射：StorageNodeOps 在 v1alpha1 与 v1beta1 之间是**逐字段恒等**（本轮仅建立版本化机制，
// schema 未变；v1beta1 作为存储版本承担未来演进）。

// ConvertTo 把 v1alpha1 StorageNodeOps 转换为 hub 版本（v1beta1）。
func (src *StorageNodeOps) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.StorageNodeOps)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageNodeOps，实际是 %T", dstRaw)
	}
	convertStorageNodeOpsToBeta(src, dst)
	return nil
}

// ConvertFrom 把 hub 版本（v1beta1）转换回 v1alpha1。
func (src *StorageNodeOps) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.StorageNodeOps)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageNodeOps，实际是 %T", srcRaw)
	}
	convertStorageNodeOpsFromBeta(hub, src)
	return nil
}

// ConvertTo 把 v1alpha1 StorageNodeOpsList 转换为 hub 版本。
func (src *StorageNodeOpsList) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.StorageNodeOpsList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageNodeOpsList，实际是 %T", dstRaw)
	}
	dst.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "StorageNodeOpsList",
	}
	dst.ListMeta = src.ListMeta
	dst.Items = make([]storagev1beta1.StorageNodeOps, len(src.Items))
	for i := range src.Items {
		convertStorageNodeOpsToBeta(&src.Items[i], &dst.Items[i])
	}
	return nil
}

// ConvertFrom 把 hub 版本的 StorageNodeOpsList 转换回 v1alpha1。
func (src *StorageNodeOpsList) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.StorageNodeOpsList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.StorageNodeOpsList，实际是 %T", srcRaw)
	}
	src.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "StorageNodeOpsList",
	}
	src.ListMeta = hub.ListMeta
	src.Items = make([]StorageNodeOps, len(hub.Items))
	for i := range hub.Items {
		convertStorageNodeOpsFromBeta(&hub.Items[i], &src.Items[i])
	}
	return nil
}

func convertStorageNodeOpsToBeta(in *StorageNodeOps, out *storagev1beta1.StorageNodeOps) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "StorageNodeOps",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = storagev1beta1.StorageNodeOpsSpec{
		NodeName:  in.Spec.NodeName,
		Operation: storagev1beta1.NodeOperation(in.Spec.Operation),
		Force:     in.Spec.Force,
	}
	out.Status = storagev1beta1.StorageNodeOpsStatus{
		Phase:        storagev1beta1.NodeOpsPhase(in.Status.Phase),
		BlockingPVCs: append([]string(nil), in.Status.BlockingPVCs...),
	}
}

func convertStorageNodeOpsFromBeta(in *storagev1beta1.StorageNodeOps, out *StorageNodeOps) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "StorageNodeOps",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = StorageNodeOpsSpec{
		NodeName:  in.Spec.NodeName,
		Operation: NodeOperation(in.Spec.Operation),
		Force:     in.Spec.Force,
	}
	out.Status = StorageNodeOpsStatus{
		Phase:        NodeOpsPhase(in.Status.Phase),
		BlockingPVCs: append([]string(nil), in.Status.BlockingPVCs...),
	}
}
