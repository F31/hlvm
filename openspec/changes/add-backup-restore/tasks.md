# Tasks: add-backup-restore

> 进度说明（M11）：控制面 Go 收口并通过单测——`internal/controller/backup.go`（备份约定检测 `BackupEnabledFor`/1.3、Velero 阶段分类 `ClassifyBackupPhase`/4.1、RPO 合规与逾期 `RPOCompliant`/`RPOOverdueBy`/4.1、IO 限速校验 `SanitizeRateLimit`/1.4、MySQL 一致性 pre-hook 构造 `BuildConsistencyPreHook`/2.1、恢复演练 `DrillRecord`/`ComputeRTO`/`DrillPassed`/`QuarterlyDrillDue`/`DrillGateBlocked`/3.1-3.3 + `ParseDrillRecords`）+ `backup_controller.go`（`BackupReconciler` 监听 PVC 落实约定 + 经 `BackupInventory` 接缝核对 RPO，Velero 未接入为 nil 不误报；`DrillReconciler` 监听演练结果 ConfigMap 刷新指标 + 发布门禁阻断）。`internal/metrics` 增加备份指标（`storage_backup_*`）+ `internal/alerting` 增加 `EvaluateBackupAlerts`（备份失败/RPO 超限 Critical）。main.go 注册两控制器 + RBAC markers。部署与策略清单（1.1 Velero 安装/对象存储、1.4 限速 manifest、2.2 一致性用例、5.1 端到端演练）移交 M11b；端到端演练与 RTO/RPO 实测移交集成验证（需测试集群 + Velero）。

## 1. 备份链路

- [ ] 1.1 部署 Velero + CSI 快照插件 + Kopia/Restic 数据移动，配置对象存储（移交 M11b 清单）
- [x] 1.2 backup-ctrl：VolumeSnapshot 编排（快照由 TopoLVM CSI 完成），备份计划（RPO ≤24h）——控制面 RPO 核对与约定落实（M11）；实际编排由 Velero 完成
- [x] 1.3 生产 PVC 默认开启备份的落地机制（namespace 标签 `storage.example.io/backup=enabled` 或 SC 注解 `storage.example.io/backup-enabled=true`；`BackupEnabledFor` 校验，违例发事件）
- [x] 1.4 IO 限速配置：备份流量不挤占业务 IO——控制面 `SanitizeRateLimit` 校验 + `DefaultBackupRateLimit="20"`（MB/s，Velero `--upload-rate-limit`）；manifest 限速配置移交 M11b

- [ ] 1.1 部署 Velero + CSI 快照插件 + Kopia/Restic 数据移动，配置对象存储
- [ ] 1.2 backup-ctrl：VolumeSnapshot 编排（快照由 TopoLVM CSI 完成），备份计划（RPO ≤24h）
- [ ] 1.3 生产 PVC 默认开启备份的落地机制（namespace 标签或 SC 注解约定）
- [ ] 1.4 IO 限速配置：备份流量不挤占业务 IO

## 2. 一致性

- [x] 2.1 数据库一致性 pre-hook：MySQL flush/锁表等（Velero backup hook 机制）——控制面 `BuildConsistencyPreHook("mysql")` 构造静默 FLUSH TABLES WITH READ LOCK 窗口；manifest 落 Velero hook 移交 M11b
- [ ] 2.2 块/文件系统一致性验证用例（有 pre-hook vs 无 pre-hook 的恢复结果对比）（移交集成验证）

## 3. 恢复演练自动化

- [x] 3.1 恢复演练 Job：定期从最近备份恢复临时 PVC 到同节点、校验数据完整性——控制面 `DrillReconciler` + `DrillRecord`（数据校验/恢复点）解析演练结果 ConfigMap；实际 Job manifest 移交 M11b
- [x] 3.2 RTO/RPO 实测报告输出；演练每季度一次的调度——`ComputeRTO`/`RPOSeconds` 实测 + `QuarterlyDrillDue`（≥90 天）
- [x] 3.3 发布门禁集成：演练未通过不得上线/升级——`DrillGateBlocked`（无通过/超期/数据未校验即阻断，发事件）

## 4. 监控

- [x] 4.1 指标：备份成功/失败计数、最近成功备份时间、RPO 达标率、备份时长——`storage_backup_total`/`storage_backup_last_success_timestamp_seconds`/`storage_backup_rpo_overdue`/`storage_backup_duration_seconds`
- [x] 4.2 告警：备份失败、RPO 超限（>24h）——`EvaluateBackupAlerts`（均 Critical）+ `storage_backup_rpo_overdue` 指标

## 5. 端到端演练

- [ ] 5.1 完整闭环演练：备份 → 删除 PVC/PV → 恢复 → 应用侧数据校验 → 记录 RTO/RPO（移交集成验证）

## 验证回路

- [x] V.1 build/vet/test 全绿（M11 控制面）；端到端演练与 RTO/RPO 实测移交集成验证（需测试集群 + Velero）
- [ ] V.2 commit + push（M11 控制面里程碑闭环）
