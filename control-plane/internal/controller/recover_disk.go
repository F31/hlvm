package controller

import (
	"fmt"
)

// RecoverDiskCheck 是 recover-disk 在 foreign VG 导入前的对应关系校验结果（设计 §9.2 第 4 步）。
type RecoverDiskCheck struct {
	// Safe 表示 LV/PV 对应关系一致，可在人工确认后执行 vgimport。
	Safe bool
	// Reasons 列出校验发现，供人工复核。
	Reasons []string
}

// ValidateForeignVGCorrespondence 校验 foreign VG 的 LV 与 PV 对应关系（§9.2）。
//
// 规则：
//   - 空 VG（无 LV）视为安全（无数据可丢失），但仍需人工确认。
//   - 发现 LV 但无任何 PV：数据无法映射，判为不安全（可能盘已丢失）。
//   - 其余情况交由人工在 vgimport 前复核（平台绝不自动迁移/恢复数据）。
func ValidateForeignVGCorrespondence(vgName string, lvs, pvs []string) RecoverDiskCheck {
	check := RecoverDiskCheck{}
	if len(lvs) == 0 {
		check.Safe = true
		check.Reasons = append(check.Reasons, fmt.Sprintf("VG %s 未发现任何 LV，可能为空 VG 或采集失败；仍须人工确认", vgName))
		return check
	}
	if len(pvs) == 0 {
		check.Safe = false
		check.Reasons = append(check.Reasons, fmt.Sprintf("VG %s 发现 %d 个 LV 但无 PV，数据无法映射，疑似盘丢失", vgName, len(lvs)))
		return check
	}
	check.Safe = true
	check.Reasons = append(check.Reasons,
		fmt.Sprintf("VG %s 发现 %d 个 LV / %d 个 PV，请在 vgimport 前人工复核 LV↔PV 归属一致", vgName, len(lvs), len(pvs)))
	return check
}

// PlanRecoverDisk 决定 recover-disk 是否允许进入导入（§9.2：全程人工确认，不自动迁移数据）。
//
// 仅当 force（人工确认）为真且对应关系校验通过时才允许；否则停在确认态，等待人工操作。
func PlanRecoverDisk(vgName string, lvs, pvs []string, force bool) (allowed bool, why string) {
	if !force {
		return false, "缺少人工确认（force=false），recover-disk 不执行 vgimport，等待人工确认"
	}
	c := ValidateForeignVGCorrespondence(vgName, lvs, pvs)
	if !c.Safe {
		return false, fmt.Sprintf("foreign VG %s 对应关系校验未通过：%v", vgName, c.Reasons)
	}
	return true, "人工确认已就绪且对应关系校验通过，可经 StorageTask 执行 vgimport（仍不自动迁移数据）"
}
