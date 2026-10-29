# Proposal: add-capacity-governance

## Why

设计方案 v1.1 §3.3 与 §7：thinpool 防爆是平台的一等能力（风险登记 #1 高危项）。容量保护必须以"分级超分 + dmeventd 第一防线 + 锁 + 预测告警"为主，控制面自动扩容只是有限缓冲（v1.0 数学矛盾已在 v1.1 修正为 80%/95%）。本 change 交付 MVP 的容量管控闭环（§10 阶段 1 第 1 项的 capacity/lvmd-config 部分）。

## What Changes

- capacity-ctrl：消费 NodeVG status + ThinPoolPolicy，评估 `capacityStatus`（available/pressure/locked，含滞回 unlockPercent）、渲染 lvm.conf 的 autoextend 配置、告警、锁与审计；不承担秒级动作。
- lvmd-config-ctrl：由 NodeVG CRD 渲染各节点 lvmd ConfigMap（device-class、thin-pool、overprovision-ratio），变更经灰度 + 滚动重载（热加载能力以 POC 结论为准）。
- dmeventd 第一防线：`thin_pool_autoextend_threshold/percent` 由 agent 下发、capacity-ctrl 校验生效；控制面 60s 周期采集只做状态评估与兜底告警。
- 锁机制：locked 节点打 `storage.example.io/<tier>-locked=true` 标签，供调度约束注入消费（add-admission-scheduling）；锁同时拦新 PVC 与存量扩容。
- 预测告警：按增长速率计算 timeToFull，Warning(<24h)/Critical(<4h) 早于阈值告警。
- metadata 治理：metadataSize 按 chunkSize 与池大小定标（POC 数据），独立阈值 metadataWarning(50%)/metadataCritical(75%)。

## 前置核实清单

1. POC 结论：`thin_pool_autoextend_*` 实际行为、dmeventd 扩容时延与成功率（add-poc-decision-gate 任务 4.1/4.4）。
2. lvmd 配置是否支持热加载（POC 任务 1.3）。

## Out of Scope

- 调度约束注入与 PVC 准入拦截的执行方（add-admission-scheduling）；本 change 只产出锁标签与 capacityStatus 数据。
- StorageClass 与使用规范文档（随上线材料交付）。
- 告警通道对接细节（add-observability）。

## Impact

- **Affected specs**: `capacity-governance`（新增）
- **Affected code**: `internal/controller/capacity.go`、`internal/controller/lvmdconfig.go`、lvm.conf 渲染模板、锁标签逻辑。
- **验证回路**：单测（状态映射、滞回、预测算法）+ envtest（locked 状态流转）+ 测试集群打满演练复测。
