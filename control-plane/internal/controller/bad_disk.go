package controller

import (
	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// BadDiskPlaybook 是无 RAID / RAID 坏盘差异化处置剧本（设计 §9.3）。
type BadDiskPlaybook struct {
	// Classification：pooled-unrecoverable / per-disk-single / raid-rebuild。
	Classification string
	// Critical 是否 Critical 级告警（pooled 无 RAID 数据不可恢复）。
	Critical bool
	// Steps 是推荐处置步骤（文案）。
	Steps []string
	// VGReduceApproval 指示 vgreduce --removemissing 须经审批（§9.3）。
	VGReduceApproval bool
}

// BadDiskPlaybookFor 依据 VG 布局与冗余类型生成差异化坏盘处置剧本（§9.3）。
//
//	有 RAID：降级告警 → 换盘 → 重建 → 监控重建进度（数据由冗余保护，非 Critical）。
//	无 RAID pooled：该 VG 全部 LV 不可恢复 → Critical。
//	无 RAID per-disk：爆炸半径限于单盘 → Warning。
//
// vgreduce --removemissing 在两类无 RAID 场景均需审批（--force 仅在人工确认后）。
func BadDiskPlaybookFor(layout storagev1alpha1.VGLayout, redundancy storagev1alpha1.Redundancy) BadDiskPlaybook {
	switch {
	case redundancy != storagev1alpha1.RedundancyNone:
		return BadDiskPlaybook{
			Classification:   "raid-rebuild",
			Critical:         false,
			VGReduceApproval: false,
			Steps: []string{
				"Warning：RAID 降级告警",
				"多副本业务继续由其他副本提供服务，不受影响",
				"热插拔更换故障盘",
				"触发重建（硬件 RAID 自动 / mdadm --add / LVM RAID lvconvert --repair）",
				"监控重建进度与重建期性能（重建期 IO 受限）",
			},
		}
	case layout == storagev1alpha1.VGLayoutPooled:
		return BadDiskPlaybook{
			Classification:   "pooled-unrecoverable",
			Critical:         true,
			VGReduceApproval: true,
			Steps: []string{
				"Critical：该 VG 一块盘损坏且无冗余，全部 LV 数据不可恢复",
				"通知业务从其他副本重建数据（单副本本地卷将丢失）",
				"业务重建一致后，经审批的 StorageTask 执行 vgreduce --removemissing（--force 仅在确认后）",
				"换盘后走新 Disk 对象重新纳管，不复用旧对象",
			},
		}
	default:
		return BadDiskPlaybook{
			Classification:   "per-disk-single",
			Critical:         false,
			VGReduceApproval: true,
			Steps: []string{
				"Warning：单盘损坏，影响限于该盘所在 VG（一盘一 VG）",
				"通知受影响的单副本业务从副本重建（如有）",
				"经审批的 StorageTask 执行 vgreduce --removemissing（--force 仅在确认后）",
				"换盘后走新 Disk 对象重新纳管",
			},
		}
	}
}
