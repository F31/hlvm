# observability Specification

## Purpose
TBD - created by archiving change add-observability. Update Purpose after archive.

## Requirements

### Requirement: exporter 部署与指标
storage-exporter SHALL 以独立非特权 DaemonSet（独立 ServiceAccount、只读挂载、无 privileged）运行，采集并暴露设计 §5.4 全部平台指标。

#### Scenario: 最小权限采集
- **WHEN** exporter DaemonSet 运行
- **THEN** 仅读采集，无写权限，指标含 smart/vg/thinpool/raid/agent 心跳与任务失败

### Requirement: 告警口径统一
仪表盘与告警 SHALL 统一使用本方案指标；与 TopoLVM 自带 `topolvm_*` 指标并存时 SHALL NOT 出现双口径；口径冲突时以实测 `lvs/vgs` 为准。

#### Scenario: 容量对账
- **WHEN** exporter 报告的 vg_free_bytes 与节点 vgs 实测不一致
- **THEN** 以 vgs 实测为准修正指标或修复采集缺陷

### Requirement: 告警矩阵与延迟
告警 SHALL 覆盖设计 §8 全表（容量、磁盘、结构、组件四类），Critical 告警延迟 ≤1min、Warning ≤5min；media_errors SHALL 按增量判定不误报。

#### Scenario: 打满即时告警
- **WHEN** thinpool data% 达到 85%
- **THEN** Critical 告警在 1min 内触发，联动 locked

#### Scenario: media_errors 不误报
- **WHEN** media_errors 累计非 0 但无增量
- **THEN** 不重复 Critical 告警

### Requirement: agent 心跳分级
agent 心跳丢失告警 SHALL 与存储不可用分级：agent 异常 ≠ 存储不可用（数据面独立原则），心跳丢失 >3min 仅 Warning。

#### Scenario: agent 挂掉业务不受影响
- **WHEN** agent 进程被 kill
- **THEN** 已有卷 IO 正常，仅触发心跳 Warning 告警

### Requirement: UI 只读大盘与纳管入口
UI SHALL 提供只读大盘（Disk/VG/容量/健康/预检报告）与纳管入口；纳管 adopt SHALL 有确认交互，破坏性操作 SHALL 仅生成待审批任务而非直接执行。

#### Scenario: 纳管双确认
- **WHEN** 运维在 UI 对 Candidate 盘发起纳管并选择 wipe
- **THEN** 要求输入 confirmSerial 匹配后才创建待审批 StorageTask
