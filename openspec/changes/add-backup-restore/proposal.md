# Proposal: add-backup-restore

## Why

设计方案 v1.1 §7 备份实现建议与风险登记 #21：v1.0 自研 S3 导出代价大且缺一致性/限速/恢复演练，v1.1 明确**优先采用成熟方案（Velero + CSI 快照 + Kopia/Restic 数据移动）**，且"没有被验证过的备份不算备份"——恢复演练与 RTO/RPO 验证是发布门禁。快照不是备份（快照与源卷同盘同 VG，COW 消耗 thinpool），跨存储备份闭环是阶段 2 必交付能力（§10 阶段 2 第 2 项）。

## What Changes

- backup-ctrl：VolumeSnapshot 编排，对接 Velero + CSI 快照 + Kopia/Restic 数据移动（不自研导出 Job）。
- 备份策略：生产 PVC 默认开启备份到对象存储；RPO ≤24h（§11 非功能指标）。
- 数据库一致性 pre-hook：备份前 flush/锁表（§6 使用规范第 5 条）。
- 备份 IO 限速：避免备份挤占业务 IO（§7 自研路径要求，Velero 侧配置限速）。
- 恢复演练自动化：定期恢复演练 Job + RTO/RPO 实测报告；演练作为发布门禁（每季度一次，§11）。
- 备份监控：备份成功/失败/时长/RPO 达标指标与告警（扩展 add-observability 指标）。

## 前置核实清单

1. POC 已完成 Velero/Kopia 恢复演练并实测 RTO/RPO（add-poc-decision-gate 任务 5.3），确认方案可行。
2. 对象存储端点与凭证、网络路径（走代理或专线）确认。

## Out of Scope

- 自研快照导出 Job（仅当 Velero 方案被证明不可行时才评估，需另行立项）。
- 快照本身的生命周期（TopoLVM CSI 能力）。

## Impact

- **Affected specs**: `backup-restore`（新增）
- **Affected code**: `internal/controller/backup.go`、Velero 安装与配置 manifests、pre-hook 脚本、恢复演练 Job、监控指标扩展。
- **验证回路**：envtest（编排逻辑）+ 端到端演练（备份 → 删卷 → 恢复 → 数据校验）→ RTO/RPO 报告。
