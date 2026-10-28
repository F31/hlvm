# storage-control-plane 规格 Delta

## ADDED Requirements

### Requirement: 控制面部署形态
storage-controller SHALL 以 Deployment ×2 + leader election 部署；storage-webhook SHALL 独立 Deployment ×3（active-active，无 leader），配置 PDB 与反亲和。

#### Scenario: 控制面整体宕机
- **WHEN** storage-controller 两副本均不可用
- **THEN** 已有卷的 IO、挂载不受影响（数据面独立原则）

### Requirement: disk-ctrl 失联判定
disk-ctrl SHALL 在节点失联超过可配阈值（默认 30min）时标记 stale 并触发节点隔离流程入口。

#### Scenario: 节点失联
- **WHEN** 节点 NotReady 持续超过阈值
- **THEN** 创建 StorageNodeOps(isolate) 并打存储故障标签

### Requirement: vg-ctrl 删盘保护
vg-ctrl SHALL 在移除盘之前校验无 LV 占用、移除不会导致冗余丧失；校验失败 SHALL 拒绝并将原因写入 `status.pendingOps`。

#### Scenario: 有 LV 占用拒绝移除
- **WHEN** `operations.removeDisks` 包含仍被 LV 占用的盘
- **THEN** 不下发 vgreduce 任务，pendingOps 记录阻塞原因

### Requirement: etcd 写放大控制
NodeDisk 的 SMART 全量采样 SHALL 只进 Prometheus；CRD status SHALL 仅在 health/phase 变化或每 10 分钟低频刷新。

#### Scenario: SMART 高频采样不写 CRD
- **WHEN** agent 每分钟采集 SMART
- **THEN** NodeDisk status 不随每次采样更新
