# node-agent 规格 Delta

## ADDED Requirements

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
