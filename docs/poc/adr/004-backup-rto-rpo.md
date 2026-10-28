# ADR-004：备份方案 RTO/RPO（设计 §7 / §10 / add-poc-decision-gate §5.3）

- **状态**：待 POC 演练实测（框架）
- **日期**：2026-10-28
- **决策人**：平台团队

## 背景

设计 §7 规定跨存储备份优先用 Velero + CSI 快照 + Kopia/Restic，平台不自研导出 Job。
设计 §11 设定 RPO ≤24h、恢复演练每季度一次。本 ADR 记录 POC 阶段 Velero/Kopia 恢复演练的
实测 RTO/RPO，与 `control-plane` 的 `add-backup-restore` change（M11/M11b）对齐。

## 方案

- 备份引擎：Velero + TopoLVM CSI 快照（csi-topolvm 快照）+ Kopia/Restic 数据移动。
- 一致性：MySQL 等数据库用 Velero hook 执行 `FLUSH TABLES WITH READ LOCK` 静默窗口（见
  `config/backup/02-mysql-prehook.yaml`）。
- 恢复演练：从最近备份恢复到同节点临时 PVC → 数据校验 → 写 `DrillRecord` 到
  `hlvm-system/hlvm-backup-drill`（见 `config/backup/03-drill-job.yaml` + 控制面 `DrillReconciler`）。

## 实测目标（POC 演练回填）

| 指标 | 目标（设计假设） | 实测 | 达标 |
| --- | --- | --- | --- |
| RPO | ≤24h | ___ | □ |
| RTO（单 PVC 恢复） | 记录实测 | ___ | □ |
| 演练频率 | 每季度 | ___ | □ |
| 一致性（有/无 pre-hook 恢复对比） | 有 hook 一致 | ___ | □ |

## 影响

- RTO/RPO 实测作为 `add-backup-restore` 告警阈值（RPO 超限 Critical）的校准依据；
- 演练 Job 与 DrillReconciler 已落地（M11/M11b），POC 仅执行并回填数据。
