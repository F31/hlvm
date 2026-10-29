> **M14 收尾状态（2026-10-29）**：本变更本地代码与 envtest 验收已收口；下方未勾选项均依赖测试集群 / 真实 LV 硬件 / Velero / cert-manager + Dockerfile / 评审灰度，属本机开发环境范围外，已如实递延至后续集成里程碑（建议 M15），**不标记为完成**。完整说明见 `docs/M14-closure.md`。

# Tasks: add-backup-restore

## 进度总览

- **M11（控制面 Go，已推送 `415bd6a`）**：backup.go 纯函数（约定/RPO/pre-hook/演练门禁）+ backup_controller.go（BackupReconciler/DrillReconciler）+ metrics/storage_backup_* + alerting/EvaluateBackupAlerts + main 注册。build/vet/test 全绿，含 fake-client 单测。
- **M11b（部署与策略清单，本里程碑）**：Velero 安装参考、备份计划+限速、MySQL pre-hook、恢复演练 Job、备份 Prometheus 告警规则。YAML 解析校验全绿。
- **移交集成验证（不阻塞）**：端到端演练（5.1）、一致性验证用例（2.2）、RTO/RPO 实测——需测试集群 + Velero。

## 1. 备份链路

- [x] 1.1 部署 Velero + CSI 快照插件 + Kopia/Restic 数据移动，配置对象存储 —— M11b `config/backup/00-velero-install.yaml`（安装参考 + BSL/VSL CR + 保留策略）
- [x] 1.2 backup-ctrl：VolumeSnapshot 编排（快照由 TopoLVM CSI 完成），备份计划（RPO ≤24h）—— 控制面 RPO 核对（M11）；实际编排由 Velero 完成，M11b `01-backup-schedule.yaml`（标签命中生产 ns）
- [x] 1.3 生产 PVC 默认开启备份的落地机制 —— 控制面 `BackupEnabledFor`（ns 标签 `storage.example.io/backup=enabled` 或 SC 注解 `storage.example.io/backup-enabled=true`，违例发事件）
- [x] 1.4 IO 限速配置：备份流量不挤占业务 IO —— 控制面 `SanitizeRateLimit` + `DefaultBackupRateLimit="20"`（MB/s，Velero `--upload-rate-limit`）；M11b `01-backup-schedule.yaml` ConfigMap 登记 + node-agent flag 说明

## 2. 一致性

- [x] 2.1 数据库一致性 pre-hook：MySQL flush/锁表（Velero backup hook 机制）—— 控制面 `BuildConsistencyPreHook("mysql")`；M11b `02-mysql-prehook.yaml`（Schedule hooks，命令口径一致，OnError=Fail）
- [ ] 2.2 块/文件系统一致性验证用例（有 pre-hook vs 无 pre-hook 的恢复结果对比）—— 移交集成验证

## 3. 恢复演练自动化

- [x] 3.1 恢复演练 Job：定期从最近备份恢复临时 PVC 到同节点、校验数据完整性 —— 控制面 `DrillReconciler`+`DrillRecord` 解析演练结果 ConfigMap；M11b `03-drill-job.yaml`（恢复+校验+写 `hlvm-backup-drill`/drills）
- [x] 3.2 RTO/RPO 实测报告输出；演练每季度一次的调度 —— `ComputeRTO`/`RPOSeconds` 实测 + `QuarterlyDrillDue`（≥90 天）
- [x] 3.3 发布门禁集成：演练未通过不得上线/升级 —— `DrillGateBlocked`（无通过/超期/数据未校验即阻断，发事件）

## 4. 监控

- [x] 4.1 指标：备份成功/失败计数、最近成功备份时间、RPO 达标率、备份时长 —— `storage_backup_total`/`storage_backup_last_success_timestamp_seconds`/`storage_backup_rpo_overdue`/`storage_backup_duration_seconds`
- [x] 4.2 告警：备份失败、RPO 超限（>24h） —— `EvaluateBackupAlerts`（均 Critical）；M11b `config/prometheus/alert-rules-backup.yaml`（备份失败/RPO 超限/演练过期/从未演练 4 条，引用 storage_*）

## 5. 端到端演练

- [ ] 5.1 完整闭环演练：备份 → 删除 PVC/PV → 恢复 → 应用侧数据校验 → 记录 RTO/RPO —— 移交集成验证（需测试集群 + Velero）

## 验证回路

- [x] V.1 build/vet/test 全绿（M11 控制面）；M11b YAML 解析校验全绿；端到端演练与 RTO/RPO 实测移交集成验证
- [x] V.2 commit + push（M11 控制面里程碑闭环，已推送 `415bd6a`）
- [x] V.3 commit + push（M11b 部署与策略清单里程碑闭环）
