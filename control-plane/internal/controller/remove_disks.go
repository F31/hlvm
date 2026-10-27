package controller

import (
	"fmt"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// BlockedDisk 是删盘保护中因校验失败被阻塞的盘及其原因。
type BlockedDisk struct {
	Disk   string
	Reason string
}

// RemovePlan 是 vg-ctrl 删盘保护的结果（设计 §3.4 / 规格 vg-ctrl 删盘保护）。
type RemovePlan struct {
	// Approved 是校验通过、可安全下发 vgreduce 任务的盘。
	Approved []string
	// Blocked 是校验失败被拒绝的盘。
	Blocked []BlockedDisk
	// PendingOps 与 Blocked 一一对应（或整体冗余丧失）的阻塞原因，写入 status.pendingOps。
	PendingOps []string
}

// RedundancyWouldBeLost 判定移除候选盘后 VG 是否将丧失冗余。
//
// 仅当 layout=pooled 且 redundancy 为镜像类（md-raid1 / lvm-raid1）时，剩余成员盘 < 2 视为冗余丧失；
// per-disk 布局（一盘一 VG）或 none 冗余的移除是正常退役路径，不算冗余丧失。
func RedundancyWouldBeLost(layout storagev1alpha1.VGLayout, redundancy storagev1alpha1.Redundancy, remainingDisks int) bool {
	if layout != storagev1alpha1.VGLayoutPooled {
		return false
	}
	if redundancy != storagev1alpha1.RedundancyMDRAID1 && redundancy != storagev1alpha1.RedundancyLVRAID1 {
		return false
	}
	return remainingDisks < 2
}

// PlanRemoveDisks 校验 removeDisks 候选（设计 §3.4 vg-ctrl 删盘保护，纯函数）。
//
// 每块候选盘需满足：
//   - (a) 无 LV 占用：occupancy[disk] 为空或空切片；
//   - (b) 整体移除不会导致冗余丧失（redundancyLost 由调用方依据 layout/redundancy 计算）。
//
// 校验失败 SHALL 拒绝并将原因写入 PendingOps；若 redundancyLost 为真，则即便 (a) 通过的盘也整体拒绝。
//
// occupancy：盘 by-id -> 占用该盘的 LV 列表（非空表示被占用）。
func PlanRemoveDisks(candidates []string, occupancy map[string][]string, redundancyLost bool) RemovePlan {
	var plan RemovePlan
	for _, d := range candidates {
		if lvs, ok := occupancy[d]; ok && len(lvs) > 0 {
			reason := fmt.Sprintf("disk %s 仍被 LV 占用: %v，拒绝移除", d, lvs)
			plan.Blocked = append(plan.Blocked, BlockedDisk{Disk: d, Reason: reason})
			plan.PendingOps = append(plan.PendingOps, reason)
			continue
		}
		plan.Approved = append(plan.Approved, d)
	}

	if redundancyLost && len(plan.Approved) > 0 {
		reason := "移除候选盘将导致 VG 冗余丧失，整体拒绝下发 vgreduce"
		plan.PendingOps = append(plan.PendingOps, reason)
		for _, d := range plan.Approved {
			plan.Blocked = append(plan.Blocked, BlockedDisk{Disk: d, Reason: reason})
		}
		plan.Approved = nil
	}
	return plan
}
