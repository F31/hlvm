package controller

import (
	"testing"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func TestBadDiskPlaybookFor(t *testing.T) {
	// 无 RAID pooled → 全部 LV 不可恢复，Critical，需 vgreduce 审批。
	p := BadDiskPlaybookFor(storagev1alpha1.VGLayoutPooled, storagev1alpha1.RedundancyNone)
	if p.Classification != "pooled-unrecoverable" || !p.Critical || !p.VGReduceApproval {
		t.Fatalf("pooled 无 RAID 应为 Critical+需审批，got %+v", p)
	}
	// 无 RAID per-disk → 单盘影响，Warning，需 vgreduce 审批。
	d := BadDiskPlaybookFor(storagev1alpha1.VGLayoutPerDisk, storagev1alpha1.RedundancyNone)
	if d.Classification != "per-disk-single" || d.Critical || !d.VGReduceApproval {
		t.Fatalf("per-disk 无 RAID 应为 Warning+需审批，got %+v", d)
	}
	// 有 RAID → 重建流程，非 Critical，无需 vgreduce 审批。
	r := BadDiskPlaybookFor(storagev1alpha1.VGLayoutPooled, storagev1alpha1.RedundancyHWRAID)
	if r.Classification != "raid-rebuild" || r.Critical || r.VGReduceApproval {
		t.Fatalf("有 RAID 应为重建流程且非 Critical，got %+v", r)
	}
}
