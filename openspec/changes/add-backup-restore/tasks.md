# Tasks: add-backup-restore

## 1. 备份链路

- [ ] 1.1 部署 Velero + CSI 快照插件 + Kopia/Restic 数据移动，配置对象存储
- [ ] 1.2 backup-ctrl：VolumeSnapshot 编排（快照由 TopoLVM CSI 完成），备份计划（RPO ≤24h）
- [ ] 1.3 生产 PVC 默认开启备份的落地机制（namespace 标签或 SC 注解约定）
- [ ] 1.4 IO 限速配置：备份流量不挤占业务 IO

## 2. 一致性

- [ ] 2.1 数据库一致性 pre-hook：MySQL flush/锁表等（Velero backup hook 机制）
- [ ] 2.2 块/文件系统一致性验证用例（有 pre-hook vs 无 pre-hook 的恢复结果对比）

## 3. 恢复演练自动化

- [ ] 3.1 恢复演练 Job：定期从最近备份恢复临时 PVC 到同节点、校验数据完整性
- [ ] 3.2 RTO/RPO 实测报告输出；演练每季度一次的调度
- [ ] 3.3 发布门禁集成：演练未通过不得上线/升级

## 4. 监控

- [ ] 4.1 指标：备份成功/失败计数、最近成功备份时间、RPO 达标率、备份时长
- [ ] 4.2 告警：备份失败、RPO 超限（>24h）

## 5. 端到端演练

- [ ] 5.1 完整闭环演练：备份 → 删除 PVC/PV → 恢复 → 应用侧数据校验 → 记录 RTO/RPO

## 验证回路

- [ ] V.1 build/vet/test 全绿；端到端演练通过且 RTO/RPO 达标
- [ ] V.2 commit + push（里程碑闭环）
