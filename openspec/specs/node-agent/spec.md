# node-agent Specification

## Purpose
节点 Agent（hlvm 自研本地存储平台的节点侧执行者）是磁盘纳管与 PV/VG/thinpool 的唯一写路径（单写者原则，§1.5）。它负责发现磁盘、采集 SMART 健康、预检可纳管性、消费控制面下发的 StorageTask 执行写操作，并将观测结果低频写回 NodeDisk.status。本 capability 定义 Agent 的行为契约：单一写路径、宿主机统一 LVM 入口、命令执行安全、预检规则引擎、SMART 健康抽象、StorageTask 幂等执行、节点级权限隔离、读写分离部署、NodeDisk 低频状态写回、预检状态机落盘、预检规则全覆盖、阈值热加载与 media_errors 增量、宿主机 lvm.conf 限定扫描、dmeventd 与 thin_pool_autoextend 管理、心跳指标、exporter 全量指标采集。其 CRD 契约与指标不受实现语言（Rust）影响。需求来源：设计文档 §5 与 add-node-agent 提案。

## Requirements

### Requirement: 单一写路径
节点上对 PV/VG/thinpool 的写操作 SHALL 仅来自 StorageTask 消费（executor 模块），SHALL NOT 接受任何外部直接调用；LV 级写者唯一为 lvmd。

#### Scenario: 无任务不写
- **WHEN** agent 运行中且无 StorageTask
- **THEN** agent 不对 VG/thinpool 执行任何写操作，仅发现与采集

### Requirement: 宿主机统一 LVM 入口
Agent SHALL 通过 `chroot /host`（或 nsenter）调用宿主机 lvm，与 lvmd 共享同一套工具与 `/run/lock/lvm` 锁；输出 SHALL 统一以 `--reportformat json` 解析，解析失败一律视为"未知"。

#### Scenario: 解析失败不推断
- **WHEN** lvm 命令输出无法按 JSON 解析
- **THEN** 状态上报为未知并告警，不得基于文本猜测推断状态

#### Scenario: 与 lvmd 并发不冲突
- **WHEN** agent 与 lvmd 同时操作同一 VG
- **THEN** 通过共享锁目录串行化，无锁冲突或状态损坏

### Requirement: 命令执行安全
Agent SHALL 以 argv 数组执行命令并禁止 shell 拼接；设备路径 SHALL 只接受 `/dev/disk/by-id/...` 且做格式校验；每个破坏性动作执行前 SHALL 二次读取实际状态（serial 匹配、无签名/无持有者、非系统盘）；SHALL 支持 dryRun。

#### Scenario: 注入拒绝
- **WHEN** 参数中出现 shell 元字符或非 by-id 设备路径
- **THEN** 任务拒绝执行并记录审计

#### Scenario: 二次校验拦截
- **WHEN** wipe 执行前发现目标盘 serial 与任务不一致
- **THEN** 中止执行并上报 Failed

### Requirement: 预检规则引擎
Agent 预检 SHALL 覆盖：系统盘（根/boot/swap/kubelet 数据目录所在盘及其 holders）、存在 fs/LVM/md 签名、被 multipath 或 device-mapper 持有、已是 PV、SMART failed、容量/介质不符 tier；任一命中 SHALL 阻止进入 PreChecked。

#### Scenario: 系统盘保护
- **WHEN** 发现的盘包含根文件系统
- **THEN** 标记 isSystemDisk=true，occupiedBy=filesystem，预检拒绝纳管

### Requirement: SMART 健康抽象
Agent SHALL 将 NVMe 与 SATA/SAS 的 SMART 数据统一抽象为 Health{Healthy,Warning,Critical,Failed}；阈值表放 ConfigMap 并支持热加载；NVMe media_errors SHALL 按增量判定。

#### Scenario: media_errors 增量告警
- **WHEN** media_errors 累计值非 0 但两次采样间无增长
- **THEN** 不触发新的 Critical 告警

### Requirement: StorageTask 幂等执行
Agent SHALL 以 taskID 去重；崩溃恢复后对"已执行未回执"的任务 SHALL 重新探测实际状态后补回执，SHALL NOT 重复执行。

#### Scenario: 崩溃恢复
- **WHEN** agent 在执行 pvcreate 后崩溃重启
- **THEN** 重启后探测该盘已是 PV，补回执 Succeeded 而不重复执行

### Requirement: 节点级权限隔离
Agent 的 ServiceAccount SHALL 只能读写 `spec.nodeName` 等于自身节点的 Task/Disk（通过 ValidatingAdmissionPolicy + 节点绑定 token 实现），确保单节点被攻破不能操作其他节点的盘。

#### Scenario: 越权拒绝
- **WHEN** node37 上的 agent 尝试更新 nodeName=node38 的 StorageTask
- **THEN** APIServer 拒绝该写请求

### Requirement: 读写分离靠部署
storage-agent 与 storage-exporter SHALL 为不同 DaemonSet：agent 特权、读写；exporter 非特权、只读挂载、独立 ServiceAccount、无 privileged。

#### Scenario: exporter 最小权限
- **WHEN** exporter DaemonSet 部署
- **THEN** Pod 无 privileged capability，挂载为只读

### Requirement: NodeDisk 低频状态写回
Agent SHALL 将发现/健康/预检结果写回对应节点的 `NodeDisk.status`；写回 SHALL 遵守 etcd 写放大约束：仅当 health/phase 较上次变化，或距上次写回已超过 10 分钟（低频刷新）时才发起 patch；SMART 原始指标 SHALL 全量只进 Prometheus（exporter），SHALL NOT 全量塞入 CRD status。

#### Scenario: 低频刷新节流
- **WHEN** 某磁盘 health 连续 5 分钟保持 Warning 且无变化
- **THEN** 期间不重复写回 status（仅在首个变化与每 10 分钟心跳点写回）

#### Scenario: 变化即时写回
- **WHEN** 磁盘 health 由 Healthy 变为 Critical
- **THEN** 立即写回 status，不受 10 分钟节流限制

### Requirement: 预检状态机落盘
预检通过（无任何不合规命中）的磁盘 SHALL 由 Agent 将其 `NodeDisk.status.phase` 由 `Candidate` 推进到 `PreChecked`；预检命中则不推进并持续暴露不合规原因（通过 StorageTask/Event 或 status.conditions）。

#### Scenario: 候选到预检通过
- **WHEN** 一块洁净数据盘完成预检且全部规则通过
- **THEN** 其 phase 落为 PreChecked，控制面据此开放纳管

#### Scenario: 预检失败不推进
- **WHEN** 磁盘存在 fs 签名或属系统盘
- **THEN** phase 保持 Candidate，并暴露不合规原因供运维

### Requirement: 预检规则全覆盖
除既有的系统盘/PV 占用/SMART failed 外，预检 SHALL 额外检测：块设备上的 fs/LVM/md 签名（blkid 解析）、被 multipath 或 device-mapper 持有（holders）、与 tier 期望的容量/介质不符；任一命中 SHALL 阻止进入 PreChecked。

#### Scenario: fs 签名拦截
- **WHEN** 目标盘存在 ext4/xfs 等文件系统签名
- **THEN** 预检拒绝纳管并标注 fs 签名

#### Scenario: tier 介质不符
- **WHEN** 期望 tier 介质为 nvme 但实际盘为 sata
- **THEN** 预检拒绝并标注介质不符

### Requirement: 阈值热加载与 media_errors 增量
健康映射阈值 SHALL 来自 ConfigMap 并可热加载（变更后无需重启 Agent 生效）；NVMe `media_errors` SHALL 按两次采样间增量判定（累计非 0 但无新增不重复告警）。

#### Scenario: 热加载生效
- **WHEN** ConfigMap 中 used_warn 阈值由 80 调整为 70
- **THEN** 下一次映射使用新阈值，Agent 不重启

### Requirement: 宿主机 lvm.conf 限定扫描范围
Agent SHALL 生成并管理宿主机 lvm.conf 的 `devices{}` / devices file，将扫描范围限定为已纳管盘（by-id 白名单），避免误扫系统盘/非纳管盘；配置变更 SHALL 可校验且可回滚。

#### Scenario: 限定扫描
- **WHEN** Agent 纳管 nvme-1/nvme-2 并写入 devices file
- **THEN** lvm 仅扫描这两块盘，系统盘不进入 VG 扫描

### Requirement: dmeventd 与 thin_pool_autoextend 管理
Agent SHALL 启用 dmeventd 并管理 `thin_pool_autoextend_threshold` / `thin_pool_autoextend_percent`（thin-pool 接近满时自动扩容）；配置 SHALL 可被 Agent 生成、校验并回写宿主机配置。

#### Scenario: 自动扩容触发
- **WHEN** thin-pool 使用率超过 threshold
- **THEN** dmeventd 触发 lvextend 扩容（percent 比例），避免 out-of-data-space

### Requirement: Agent 心跳指标
Agent SHALL 暴露 `storage_agent_heartbeat`（节点级 gauge 或 Prometheus 指标），供控制面/监控判定 agent 存活；心跳缺失 SHALL 触发组件类告警（见 add-observability）。

#### Scenario: 心跳缺失
- **WHEN** agent 进程退出且心跳停止上报超过阈值
- **THEN** 监控产生 AgentHeartbeatLost 告警（数据面不受影响，仅通知）

### Requirement: exporter 全量指标采集
exporter 模式 SHALL 真实采集并暴露 Prometheus 指标（SMART 健康、VG 容量、thin-pool 使用率等），SMART 原始值全量进入 exporter 指标而非 CRD status；指标命名 SHALL 与 add-observability 的 `storage_*` 单一真相源对齐。

#### Scenario: 指标暴露
- **WHEN** exporter DaemonSet 部署并采集
- **THEN** `/metrics` 暴露 storage_disk_smart_health / storage_vg_* / storage_thinpool_* 等指标
