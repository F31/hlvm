package v1alpha1

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/conversion"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// 本文件实现 v1alpha1 作为 spoke 的双向转换（hub 在 api/v1beta1）。
//
// 字段映射：NodeVG 在 v1alpha1 与 v1beta1 之间是**逐字段恒等**（本轮仅建立版本化机制，
// schema 未变；v1beta1 作为存储版本承担未来演进）。采用逐字段显式映射而不是 `unsafe`
// 指针转换，确保任何字段漏映射都能在往返测试中暴露（见 nodevg_conversion_test.go）。

// ConvertTo 把 v1alpha1 NodeVG 转换为 hub 版本（v1beta1）。
func (src *NodeVG) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.NodeVG)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeVG，实际是 %T", dstRaw)
	}
	convertNodeVGToBeta(src, dst)
	return nil
}

// ConvertFrom 把 hub 版本（v1beta1）转换回 v1alpha1。
func (src *NodeVG) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.NodeVG)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeVG，实际是 %T", srcRaw)
	}
	convertNodeVGFromBeta(hub, src)
	return nil
}

// ConvertTo 把 v1alpha1 NodeVGList 转换为 hub 版本。
func (src *NodeVGList) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.NodeVGList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeVGList，实际是 %T", dstRaw)
	}
	dst.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "NodeVGList",
	}
	dst.ListMeta = src.ListMeta
	dst.Items = make([]storagev1beta1.NodeVG, len(src.Items))
	for i := range src.Items {
		convertNodeVGToBeta(&src.Items[i], &dst.Items[i])
	}
	return nil
}

// ConvertFrom 把 hub 版本的 NodeVGList 转换回 v1alpha1。
func (src *NodeVGList) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.NodeVGList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeVGList，实际是 %T", srcRaw)
	}
	src.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "NodeVGList",
	}
	src.ListMeta = hub.ListMeta
	src.Items = make([]NodeVG, len(hub.Items))
	for i := range hub.Items {
		convertNodeVGFromBeta(&hub.Items[i], &src.Items[i])
	}
	return nil
}

func convertNodeVGToBeta(in *NodeVG, out *storagev1beta1.NodeVG) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "NodeVG",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = storagev1beta1.VGSpec{
		NodeName:        in.Spec.NodeName,
		Tier:            in.Spec.Tier,
		DeviceClassName: in.Spec.DeviceClassName,
		Layout:          storagev1beta1.VGLayout(in.Spec.Layout),
		Redundancy:      storagev1beta1.Redundancy(in.Spec.Redundancy),
		Disks:           append([]string(nil), in.Spec.Disks...),
		ThinPool:        thinPoolToBeta(in.Spec.ThinPool),
		Operations:      storagev1beta1.VGOperations{RemoveDisks: append([]string(nil), in.Spec.Operations.RemoveDisks...)},
	}
	out.Status = vgStatusToBeta(in.Status)
}

func convertNodeVGFromBeta(in *storagev1beta1.NodeVG, out *NodeVG) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "NodeVG",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = VGSpec{
		NodeName:        in.Spec.NodeName,
		Tier:            in.Spec.Tier,
		DeviceClassName: in.Spec.DeviceClassName,
		Layout:          VGLayout(in.Spec.Layout),
		Redundancy:      Redundancy(in.Spec.Redundancy),
		Disks:           append([]string(nil), in.Spec.Disks...),
		ThinPool:        thinPoolFromBeta(in.Spec.ThinPool),
		Operations:      VGOperations{RemoveDisks: append([]string(nil), in.Spec.Operations.RemoveDisks...)},
	}
	out.Status = vgStatusFromBeta(in.Status)
}

func thinPoolToBeta(in ThinPoolSpec) storagev1beta1.ThinPoolSpec {
	return storagev1beta1.ThinPoolSpec{
		Name:               in.Name,
		InitialSizePercent: in.InitialSizePercent,
		MaxSizePercent:     in.MaxSizePercent,
		MetadataSize:       in.MetadataSize,
		ChunkSize:          in.ChunkSize,
		OverprovisionRatio: in.OverprovisionRatio,
	}
}

func thinPoolFromBeta(in storagev1beta1.ThinPoolSpec) ThinPoolSpec {
	return ThinPoolSpec{
		Name:               in.Name,
		InitialSizePercent: in.InitialSizePercent,
		MaxSizePercent:     in.MaxSizePercent,
		MetadataSize:       in.MetadataSize,
		ChunkSize:          in.ChunkSize,
		OverprovisionRatio: in.OverprovisionRatio,
	}
}

func vgStatusToBeta(in VGStatus) storagev1beta1.VGStatus {
	return storagev1beta1.VGStatus{
		VGExists:            in.VGExists,
		VGUUID:              in.VGUUID,
		TotalBytes:          in.TotalBytes,
		FreeBytes:           in.FreeBytes,
		ThinPool:            vgThinPoolToBeta(in.ThinPool),
		CapacityStatus:      storagev1beta1.CapacityStatus(in.CapacityStatus),
		LastDriftCheck:      in.LastDriftCheck.DeepCopy(),
		PendingOps:          append([]string(nil), in.PendingOps...),
		Conditions:          conditionsToBeta(in.Conditions),
		GrowthBytesPerHour:  in.GrowthBytesPerHour,
		LvmdConfig:          in.LvmdConfig,
	}
}

func vgStatusFromBeta(in storagev1beta1.VGStatus) VGStatus {
	return VGStatus{
		VGExists:            in.VGExists,
		VGUUID:              in.VGUUID,
		TotalBytes:          in.TotalBytes,
		FreeBytes:           in.FreeBytes,
		ThinPool:            vgThinPoolFromBeta(in.ThinPool),
		CapacityStatus:      CapacityStatus(in.CapacityStatus),
		LastDriftCheck:      in.LastDriftCheck.DeepCopy(),
		PendingOps:          append([]string(nil), in.PendingOps...),
		Conditions:          conditionsFromBeta(in.Conditions),
		GrowthBytesPerHour:  in.GrowthBytesPerHour,
		LvmdConfig:          in.LvmdConfig,
	}
}

func vgThinPoolToBeta(in VGThinPoolStatus) storagev1beta1.VGThinPoolStatus {
	return storagev1beta1.VGThinPoolStatus{
		CurrentSizeBytes: in.CurrentSizeBytes,
		DataPercent:      in.DataPercent,
		MetadataPercent:  in.MetadataPercent,
		ProvisionedBytes: in.ProvisionedBytes,
		State:            in.State,
		OutOfSpace:       in.OutOfSpace,
	}
}

func vgThinPoolFromBeta(in storagev1beta1.VGThinPoolStatus) VGThinPoolStatus {
	return VGThinPoolStatus{
		CurrentSizeBytes: in.CurrentSizeBytes,
		DataPercent:      in.DataPercent,
		MetadataPercent:  in.MetadataPercent,
		ProvisionedBytes: in.ProvisionedBytes,
		State:            in.State,
		OutOfSpace:       in.OutOfSpace,
	}
}
