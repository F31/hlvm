# capacity-governance Specification

## Purpose
TBD - created by archiving change add-capacity-governance. Update Purpose after archive.

## Requirements

### Requirement: 扩容第一防线为 dmeventd
thinpool 自动扩容 SHALL 以 LVM 原生 dmeventd（`thin_pool_autoextend_threshold/percent`）为第一防线，由内核事件驱动秒级响应；控制面 SHALL 只负责策略下发、状态评估、告警、锁与审计，SHALL NOT 被依赖做秒级动作。

#### Scenario: 突发写入扩容
- **WHEN** thinpool 数据区在数秒内越过 autoextend 阈值
- **THEN** dmeventd 在越线后 ≤30s 内完成扩容（非功能指标目标，POC 后定标）

### Requirement: capacityStatus 映射与滞回
capacityStatus SHALL 按 `<75% available → 75–85% pressure → ≥85% 或 metadata≥75% 或 outOfSpace 为 locked` 映射；解锁 SHALL 要求回落到 `unlockPercent` 以下，避免边界抖动。

#### Scenario: 锁定
- **WHEN** thinpool data% 达到 85%
- **THEN** capacityStatus=locked 并打 tier 锁标签

#### Scenario: 滞回解锁
- **WHEN** data% 从 85% 回落到 83%（仍在 unlockPercent=80 之上）
- **THEN** 保持 locked，不解锁

### Requirement: 锁拦截范围
锁 SHALL 同时拦截新 PVC 创建与存量 PVC 扩容（`blockNewPVC` 与 `blockPVCExpansion` 均可配）；locked 节点 SHALL 打 `storage.example.io/<tier>-locked=true` 标签供调度层消费。

#### Scenario: 锁定期扩容被拦
- **WHEN** 节点 locked 期间租户对已有 PVC 发起扩容
- **THEN** 请求被拒绝，拒绝信息不暴露内部节点/VG 名

### Requirement: 预测告警
capacity-ctrl SHALL 按增长速率预测 timeToFull，并在 <24h 发 Warning、<4h 发 Critical，早于阈值告警。

#### Scenario: 快速增长预警
- **WHEN** data% 当前 60% 但按速率 3h 后将写满
- **THEN** 触发 Critical 预测告警（即使未达 85% 阈值）

### Requirement: metadata 独立治理
thinpool metadata SHALL 有独立阈值（warning 50% / critical 75%）；metadataSize SHALL 依据 POC 定标（池大小、chunkSize、快照数量）。

#### Scenario: metadata 打满预警
- **WHEN** metadataPercent 越过 75%
- **THEN** 置 locked 并提示元数据扩容预案（thin_check Runbook）

### Requirement: lvmd 配置渲染与灰度
lvmd-config-ctrl SHALL 由 NodeVG CRD 渲染各节点 lvmd ConfigMap，变更 SHALL 经灰度 + 滚动重载下发；热加载支持与否以 POC 结论为准。

#### Scenario: 配置灰度下发
- **WHEN** NodeVG 的 overprovisionRatio 变更
- **THEN** 对应节点 lvmd ConfigMap 按灰度批次更新并滚动重载，全程不影响已有卷 IO
