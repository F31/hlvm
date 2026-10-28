# crd-api Specification

## Purpose
TBD - created by archiving change add-crd-controller-skeleton. Update Purpose after archive.

## Requirements

### Requirement: NodeDisk 身份与命名
NodeDisk 对象 SHALL 以磁盘 WWN/serial 作为稳定身份（对象名 `{node}-{serial/wwn 短名}`），不使用设备名；所有破坏性操作 SHALL 通过 `/dev/disk/by-id/...` 引用设备并要求 `spec.confirmSerial` 与 `status.identity.serial` 一致。

#### Scenario: 设备名漂移不影响对象
- **WHEN** 节点重启导致 `/dev/nvme0n1` 变为 `/dev/nvme1n1`
- **THEN** NodeDisk 对象不变，`status.currentDevice` 更新为新的设备名且仅作展示

#### Scenario: 换盘不复用对象
- **WHEN** 同一槽位更换为新盘（serial 不同）
- **THEN** 创建新的 NodeDisk 对象，旧对象不复活

### Requirement: phase 与 health 维度分离
NodeDisk SHALL 将生命周期 `phase`（Discovered→Candidate→PreChecked→Wiped→InVG→Draining→Removed）与健康度 `health`（healthy|warning|critical|failed）作为两个独立字段，互不覆盖。

#### Scenario: 健康劣化不改生命周期
- **WHEN** 一块 InVG 状态盘的 SMART 判定为 critical
- **THEN** `status.health` 更新为 critical，`status.phase` 保持 InVG

### Requirement: 意图驱动推进
NodeDisk 的 `Candidate→PreChecked` SHALL 由 agent 预检自动完成；`PreChecked→Wiped→InVG` SHALL 要求 `spec.adopt=true` 且被 VG 引用；wipe SHALL 额外要求 `confirmSerial` 匹配。

#### Scenario: 未采纳不推进
- **WHEN** agent 预检通过但 `spec.adopt=false`
- **THEN** phase 停留在 Candidate，不执行 wipe

#### Scenario: serial 不匹配拒绝 wipe
- **WHEN** wipe 请求的 `confirmSerial` 与 `status.identity.serial` 不一致
- **THEN** 拒绝执行并记录原因

### Requirement: NodeVG spec 不可回写
控制器 SHALL NOT 回写 NodeVG 的 `spec` 字段；自动扩容等运行时结果 SHALL 只写 `status`。

#### Scenario: 自动扩容写 status
- **WHEN** thinpool 自动扩容完成
- **THEN** `status.thinPool.currentSizeBytes` 更新，`spec.thinPool` 不变

### Requirement: NodeVG layout 策略
NodeVG SHALL 支持 `pooled` 与 `per-disk` 两种 layout；无 RAID 冗余的 tier SHALL 默认 `per-disk`，`pooled` 仅在 RAID 之下允许。

#### Scenario: 无 RAID 拒绝 pooled
- **WHEN** 创建 `redundancy: none` 且 `layout: pooled` 的 NodeVG
- **THEN** 校验拒绝并说明爆炸半径原因

### Requirement: thinpool 比例参数
NodeVG thinPool SHALL 使用 `initialSizePercent=80` 与 `maxSizePercent=95` 的默认语义：自动扩容为有限缓冲，保留 5% 给 metadata 增长与救急。

#### Scenario: 扩容上限约束
- **WHEN** thinpool 触发自动扩容
- **THEN** 扩容目标不超过 VG 的 95%，超限部分转人工工单

### Requirement: ThinPoolPolicy 锁与滞回
ThinPoolPolicy SHALL 定义 `capacityStatus` 映射（<75% available → 75–85% pressure → ≥85% 或 metadata≥75% 或 outOfSpace 为 locked）与滞回解锁（回落到 `unlockPercent` 以下才解锁）；锁 SHALL 同时拦截新 PVC 与存量 PVC 扩容。

#### Scenario: 边界不抖动
- **WHEN** data% 在 85% 与 80% 之间波动
- **THEN** capacityStatus 保持 locked，直到低于 unlockPercent

### Requirement: StorageTask 幂等与审批
StorageTask SHALL 以稳定 taskID 去重；破坏性 type（wipe 等）SHALL 要求 `approvedBy`；任务带 TTL，过期不执行。

#### Scenario: 重复投递去重
- **WHEN** 同一 taskID 的 StorageTask 被二次投递到节点
- **THEN** agent 不重复执行，按已执行状态补回执

### Requirement: StorageNodeOps 可多次操作
StorageNodeOps SHALL 允许同一节点存在多个对象（按操作命名，如 `retire-node37-20261015`），状态机为 validate→drain→wait-pvc-cleanup→wipe→done，阻塞点写入 `status.blockingPVCs`。

#### Scenario: 阻塞于在用 PVC
- **WHEN** retire 时节点仍有在用 PV/PVC
- **THEN** 状态机停在 wait-pvc-cleanup，blockingPVCs 列出阻塞项
