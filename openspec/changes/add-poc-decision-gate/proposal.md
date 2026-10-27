# Proposal: add-poc-decision-gate

## Why

设计方案 v1.1 §10 明确：**阶段 0 POC 决策门未达标前，不进入任何模块开发**。阶段 0 需在 ≥3 节点集群上完成 TopoLVM 集成验证、性能基线实测、故障剧本可执行性验证，并产出语言决策（§5.5）、RAID 选型、上游版本矩阵三项决策记录。这是整个项目的第一道里程碑门控，也是后续所有 change 的前置依赖。

## What Changes

- 搭建 ≥3 节点 POC 集群，安装上游 TopoLVM（官方 Helm），完成基础功能验证（PVC 创建、在线扩容、快照、克隆、重启恢复）。
- fio 性能基线实测：裸盘 / thick LV / thin LV（首写、覆盖写、有快照）/ XFS，多种 bs 与队列深度，关注 p99 延迟；输出损耗数据与可接受目标（假设值：覆盖写损耗 ≤10%，以实测为准）。
- 故障注入验证：thinpool 打满（§9.1）、坏盘热拔（§9.3，pooled 与 per-disk 各一块）、节点断电恢复（§9.2）、全部 webhook 副本宕机（§4）。
- TopoLVM 集成验证：lvmd 配置下发与重载、scheduler/CSIStorageCapacity 行为，明确上游版本矩阵（§2.1）。
- 决策产出：agent 语言决策记录（Rust vs Go，§5.5）、RAID 选型结论（硬件 RAID / mdadm / LVM RAID1）、备份方案 RTO/RPO 实测（Velero/Kopia）。
- 核实并关闭设计文档【待核实清单】（附录 B）中可由 POC 关闭的条目。

## 前置核实清单（【待核实】项）

1. TopoLVM 目标版本：provisioner/参数键（`topolvm.io/device-class`）、lvmd 配置热加载、scheduler-extender 与 CSIStorageCapacity 现状、thin 快照/克隆限制。
2. `lvextend` 扩池/扩元数据准确参数、`thin_pool_autoextend_*` 行为、out-of-data-space 内核行为与恢复步骤。
3. 集群 K8s 版本对 `matchConditions` / ValidatingAdmissionPolicy / Scheduling Gate 的支持。

## Out of Scope

- 任何自研组件（storage-controller / storage-agent / storage-webhook / exporter）的模块开发。
- 生产环境灰度与上线。

## Impact

- **Affected specs**: `poc-validation`（新增）
- **Affected code**: 无产品代码；仅 POC 环境、测试脚本与决策记录文档（`docs/poc/`）。
- **门控产出**：POC 报告 + 3 份决策记录（ADR：语言、RAID、版本矩阵）。未达标则不创建后续 change 的实施任务。
