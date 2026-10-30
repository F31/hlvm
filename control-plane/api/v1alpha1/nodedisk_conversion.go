package v1alpha1

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/conversion"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// 本文件实现 v1alpha1 作为 spoke 的双向转换（hub 在 api/v1beta1）。
//
// 字段映射（唯一一处语义变化）：
//
//	v1alpha1 `spec.deviceRef`（string）  ⇄  v1beta1 `spec.device.path`（struct 字段）
//
// 采用**逐字段显式映射**而不是 `unsafe` 指针转换：两边结构体不保证同布局
// （v1beta1 已把字符串换成结构体），装箱转换会静默读错内存。
//
// 为什么空字符串映射为 nil 而不是 `&DiskDevice{}`：nil 与 `""` 在语义上都表示
// 「Agent 尚未写入设备引用」；若映射成空结构体，往返（v1alpha1→v1beta1→v1alpha1）
// 会得到 `{}` 而不是省略字段，读写双方需要额外判断"空设备"，反而更易出错。

// ConvertTo 把 v1alpha1 NodeDisk 转换为 hub 版本（v1beta1）。
func (src *NodeDisk) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.NodeDisk)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeDisk，实际是 %T", dstRaw)
	}
	convertNodeDiskToBeta(src, dst)
	return nil
}

// ConvertFrom 把 hub 版本（v1beta1）转换回 v1alpha1。
func (src *NodeDisk) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.NodeDisk)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeDisk，实际是 %T", srcRaw)
	}
	convertNodeDiskFromBeta(hub, src)
	return nil
}

// ConvertTo 把 v1alpha1 NodeDiskList 转换为 hub 版本。
func (src *NodeDiskList) ConvertTo(dstRaw conversion.Hub) error {
	dst, ok := dstRaw.(*storagev1beta1.NodeDiskList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeDiskList，实际是 %T", dstRaw)
	}
	dst.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "NodeDiskList",
	}
	dst.ListMeta = src.ListMeta
	dst.Items = make([]storagev1beta1.NodeDisk, len(src.Items))
	for i := range src.Items {
		convertNodeDiskToBeta(&src.Items[i], &dst.Items[i])
	}
	return nil
}

// ConvertFrom 把 hub 版本的 NodeDiskList 转换回 v1alpha1。
func (src *NodeDiskList) ConvertFrom(srcRaw conversion.Hub) error {
	hub, ok := srcRaw.(*storagev1beta1.NodeDiskList)
	if !ok {
		return fmt.Errorf("期望 *v1beta1.NodeDiskList，实际是 %T", srcRaw)
	}
	src.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "NodeDiskList",
	}
	src.ListMeta = hub.ListMeta
	src.Items = make([]NodeDisk, len(hub.Items))
	for i := range hub.Items {
		convertNodeDiskFromBeta(&hub.Items[i], &src.Items[i])
	}
	return nil
}

func convertNodeDiskToBeta(in *NodeDisk, out *storagev1beta1.NodeDisk) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: storagev1beta1.GroupVersion.String(),
		Kind:       "NodeDisk",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = storagev1beta1.DiskSpec{
		NodeName:      in.Spec.NodeName,
		Adopt:         in.Spec.Adopt,
		Device:        deviceToBeta(in.Spec.DeviceRef),
		ConfirmSerial: in.Spec.ConfirmSerial,
		WipePolicy:    storagev1beta1.WipePolicy(in.Spec.WipePolicy),
	}
	out.Status = statusToBeta(in.Status)
}

func convertNodeDiskFromBeta(in *storagev1beta1.NodeDisk, out *NodeDisk) {
	out.TypeMeta = metav1.TypeMeta{
		APIVersion: GroupVersion.String(),
		Kind:       "NodeDisk",
	}
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = DiskSpec{
		NodeName:      in.Spec.NodeName,
		Adopt:         in.Spec.Adopt,
		DeviceRef:     deviceFromBeta(in.Spec.Device),
		ConfirmSerial: in.Spec.ConfirmSerial,
		WipePolicy:    WipePolicy(in.Spec.WipePolicy),
	}
	out.Status = statusFromBeta(in.Status)
}

// deviceToBeta：空 deviceRef → nil；非空 → 单个 path 字段。
func deviceToBeta(deviceRef string) *storagev1beta1.DiskDevice {
	if deviceRef == "" {
		return nil
	}
	return &storagev1beta1.DiskDevice{Path: deviceRef}
}

// deviceFromBeta：nil → 空 deviceRef（与 deviceToBeta 互逆，保证往返无损）。
func deviceFromBeta(device *storagev1beta1.DiskDevice) string {
	if device == nil {
		return ""
	}
	return device.Path
}

func statusToBeta(in DiskStatus) storagev1beta1.DiskStatus {
	return storagev1beta1.DiskStatus{
		Identity: storagev1beta1.DiskIdentity{
			Serial: in.Identity.Serial,
			WWN:    in.Identity.WWN,
			Model:  in.Identity.Model,
			ByID:   in.Identity.ByID,
		},
		CurrentDevice: in.CurrentDevice,
		CapacityBytes: in.CapacityBytes,
		Phase:         storagev1beta1.DiskPhase(in.Phase),
		Health:        storagev1beta1.DiskHealth(in.Health),
		Smart: storagev1beta1.DiskSMART{
			LastProbeTime:         in.Smart.LastProbeTime.DeepCopy(),
			OverallStatus:         in.Smart.OverallStatus,
			CriticalWarning:       in.Smart.CriticalWarning,
			AvailableSparePercent: in.Smart.AvailableSparePercent,
			PercentUsed:           in.Smart.PercentUsed,
			TemperatureCelsius:    in.Smart.TemperatureCelsius,
			MediaErrors:           in.Smart.MediaErrors,
			MediaErrorsLastProbe:  in.Smart.MediaErrorsLastProbe,
			UnsafeShutdowns:       in.Smart.UnsafeShutdowns,
		},
		OccupiedBy:   storagev1beta1.OccupiedBy(in.OccupiedBy),
		IsSystemDisk: in.IsSystemDisk,
		Raid:         raidToBeta(in.Raid),
		VgRef:        in.VgRef,
		Conditions:   conditionsToBeta(in.Conditions),
	}
}

func statusFromBeta(in storagev1beta1.DiskStatus) DiskStatus {
	return DiskStatus{
		Identity: DiskIdentity{
			Serial: in.Identity.Serial,
			WWN:    in.Identity.WWN,
			Model:  in.Identity.Model,
			ByID:   in.Identity.ByID,
		},
		CurrentDevice: in.CurrentDevice,
		CapacityBytes: in.CapacityBytes,
		Phase:         DiskPhase(in.Phase),
		Health:        DiskHealth(in.Health),
		Smart: DiskSMART{
			LastProbeTime:         in.Smart.LastProbeTime.DeepCopy(),
			OverallStatus:         in.Smart.OverallStatus,
			CriticalWarning:       in.Smart.CriticalWarning,
			AvailableSparePercent: in.Smart.AvailableSparePercent,
			PercentUsed:           in.Smart.PercentUsed,
			TemperatureCelsius:    in.Smart.TemperatureCelsius,
			MediaErrors:           in.Smart.MediaErrors,
			MediaErrorsLastProbe:  in.Smart.MediaErrorsLastProbe,
			UnsafeShutdowns:       in.Smart.UnsafeShutdowns,
		},
		OccupiedBy:   OccupiedBy(in.OccupiedBy),
		IsSystemDisk: in.IsSystemDisk,
		Raid:         raidFromBeta(in.Raid),
		VgRef:        in.VgRef,
		Conditions:   conditionsFromBeta(in.Conditions),
	}
}

func raidToBeta(in *DiskRaid) *storagev1beta1.DiskRaid {
	if in == nil {
		return nil
	}
	return &storagev1beta1.DiskRaid{MemberOf: in.MemberOf, Degraded: in.Degraded}
}

func raidFromBeta(in *storagev1beta1.DiskRaid) *DiskRaid {
	if in == nil {
		return nil
	}
	return &DiskRaid{MemberOf: in.MemberOf, Degraded: in.Degraded}
}

// conditionsToBeta：nil 保持 nil（不产生空切片），保证往返 JSON 等价。
func conditionsToBeta(in []metav1.Condition) []metav1.Condition {
	if in == nil {
		return nil
	}
	out := make([]metav1.Condition, len(in))
	copy(out, in)
	return out
}

func conditionsFromBeta(in []metav1.Condition) []metav1.Condition {
	return conditionsToBeta(in)
}
