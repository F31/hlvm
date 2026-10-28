package controller

import (
	corev1 "k8s.io/api/core/v1"
)

// OrphanReport 是孤儿对象检测结果（设计 §3.5/§7/§3.1 orphan-gc）。
type OrphanReport struct {
	// ReleasedRetainPVs 是 Retain 后 Released 的 PV（隐形容量成本）。
	ReleasedRetainPVs []string
	// OrphanLVs 是实际存在但无对应 PV/CR 的 LV（三方对账；待 agent LV 上报后启用）。
	OrphanLVs []ActualLV
	// TotalBytes 是孤儿占用的总字节数（Released PV 容量之和）。
	TotalBytes int64
}

// IsOrphan 表示存在需人工回收的孤儿对象。
func (r OrphanReport) IsOrphan() bool {
	return len(r.ReleasedRetainPVs) > 0 || len(r.OrphanLVs) > 0
}

// FindReleasedRetainPVs 返回 Retain 回收策略且处于 Released 的 PV（§7）。
//
// 这些是 PVC 删除后平台按 Retain 策略保留的 PV，仍占用节点容量，
// 构成 Retain 的长期隐形容量成本，需人工回收（平台 SHALL NOT 自动删除）。
func FindReleasedRetainPVs(pvs []corev1.PersistentVolume) []corev1.PersistentVolume {
	var out []corev1.PersistentVolume
	for _, pv := range pvs {
		if pv.Status.Phase != corev1.VolumeReleased {
			continue
		}
		if pv.Spec.PersistentVolumeReclaimPolicy != corev1.PersistentVolumeReclaimRetain {
			continue
		}
		out = append(out, pv)
	}
	return out
}

// FindOrphanLVs 三方对账：返回实际 lvs 中存在、但无对应 managed（PV/CR）的 LV（§3.1）。
//
// 平台 SHALL NOT 自动删除，仅记录并提醒人工回收。managed 为空时（agent LV 上报未接入）
// 返回空，避免误报。
func FindOrphanLVs(managed []ManagedLV, actual []ActualLV) []ActualLV {
	// managed 为空（agent LV 上报未接入或采集失败）时无法对账，返回空避免误报。
	if len(managed) == 0 {
		return nil
	}
	managedSet := make(map[string]struct{}, len(managed))
	for _, m := range managed {
		managedSet[lvKey(m.Node, m.VG, m.Name)] = struct{}{}
	}
	var out []ActualLV
	for _, a := range actual {
		if _, ok := managedSet[lvKey(a.Node, a.VG, a.Name)]; !ok {
			out = append(out, a)
		}
	}
	return out
}
