# Tasks: add-poc-decision-gate

## 1. POC 环境搭建

- [ ] 1.1 搭建 ≥3 节点测试集群，确认 K8s 版本并核实 `matchConditions` / ValidatingAdmissionPolicy / Scheduling Gate 支持情况
- [ ] 1.2 通过上游官方 Helm 安装 TopoLVM，核实 provisioner 参数键（`topolvm.io/device-class`）与目标版本，记录版本矩阵
- [ ] 1.3 核实 lvmd 配置热加载能力与 scheduler-extender / CSIStorageCapacity 的版本现状

## 2. 基础功能验证

- [ ] 2.1 验证 PVC 创建、在线扩容、快照、克隆（含 thick 与 thin 两种 device-class）
- [ ] 2.2 验证节点重启后的卷恢复（重启恢复场景）

## 3. 性能基线（fio 实测）

- [ ] 3.1 裸盘基线：多种 bs（4k/8k/64k/1M）× 队列深度，记录 IOPS / 带宽 / p99 延迟
- [ ] 3.2 thick LV、thin LV（首写、覆盖写、有快照）对比测试，XFS 文件系统层损耗
- [ ] 3.3 输出损耗数据报告，与假设目标（覆盖写损耗 ≤10%）对照，给出可接受目标结论

## 4. 故障注入验证

- [ ] 4.1 thinpool 打满：突发写入打满 pool，记录前兆、dmeventd 扩容时延与成功率、IO 是否 hang/报错、文件系统可恢复性
- [ ] 4.2 坏盘热拔：pooled 与 per-disk 各一块，验证 §9.3 剧本可执行、告警准确
- [ ] 4.3 节点强制断电与恢复：验证失联判定、重建流程、隔离期行为（§9.2）
- [ ] 4.4 核实 `lvextend` 参数、`thin_pool_autoextend_*` 行为与 out-of-data-space 恢复步骤（Runbook 依据）

## 5. 决策门产出

- [ ] 5.1 agent 语言决策记录（ADR）：Rust vs Go 原型对比（内存、CPU、解析稳定性、团队能力），按 §5.5 标准出结论
- [ ] 5.2 RAID 选型决策记录：硬件 RAID / mdadm / LVM RAID1（含 LVM RAID 对 thin-pool 元数据冗余的验证结论）
- [ ] 5.3 备份演练：Velero/Kopia 恢复演练，实测 RTO/RPO
- [ ] 5.4 webhook 可用性预演：模拟全部 webhook 副本宕机，验证不阻塞非本平台 PVC 的方案前提
- [ ] 5.5 汇总 POC 报告，对照 §10 通过标准逐项打勾；更新设计文档【待核实清单】关闭状态

## 验证回路

- [ ] V.1 决策门评审：POC 报告 + 3 份 ADR 全部通过评审，未达标项形成整改或终止结论
