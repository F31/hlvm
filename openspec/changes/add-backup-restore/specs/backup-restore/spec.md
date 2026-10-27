# backup-restore 规格 Delta

## ADDED Requirements

### Requirement: 备份采用成熟方案
跨存储备份 SHALL 优先采用 Velero + CSI 快照 + Kopia/Restic 数据移动，SHALL NOT 自研导出 Job；快照由 TopoLVM CSI 完成。

#### Scenario: 备份链路
- **WHEN** 生产 PVC 的备份计划触发
- **THEN** 经 CSI 快照 + 数据移动将备份写入对象存储，RPO ≤24h

### Requirement: 备份一致性
数据库类业务备份 SHALL 支持一致性 pre-hook（flush/锁表）；备份 IO SHALL 限速以不挤占业务 IO。

#### Scenario: 数据库备份一致性
- **WHEN** 对带 pre-hook 的 MySQL PVC 执行备份并恢复
- **THEN** 恢复后数据库可通过一致性校验并正常启动

### Requirement: 恢复演练为发布门禁
恢复演练 SHALL 自动化（定期恢复演练 Job + 数据完整性校验），实测 RTO/RPO；演练 SHALL 每季度至少一次，未通过 SHALL 阻止上线与升级。

#### Scenario: 演练不通过
- **WHEN** 恢复演练数据校验失败
- **THEN** 发布门禁阻断，告警通知并要求修复备份链路

#### Scenario: 备份未验证不算备份
- **WHEN** 某备份策略从未完成过一次恢复演练
- **THEN** 该策略不视为有效备份能力，监控标记为未验证
