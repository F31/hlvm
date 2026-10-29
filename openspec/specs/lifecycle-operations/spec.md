# lifecycle-operations Specification

## Purpose
TBD - created by archiving change add-lifecycle-ops. Update Purpose after archive.

## Requirements

### Requirement: 节点退役状态机
StorageNodeOps(retire) SHALL 按 validate → drain → wait-pvc-cleanup → wipe(可选) → done 状态机推进，阻塞点 SHALL 写入 `status.blockingPVCs`；同一节点 SHALL 允许存在多个 StorageNodeOps 对象。

#### Scenario: 阻塞于在用 PVC
- **WHEN** retire 进行中且节点存在在用 PV
- **THEN** 状态机停在 wait-pvc-cleanup，blockingPVCs 列出全部阻塞项

### Requirement: 恢复节点残留数据保护
旧故障节点恢复后，平台 SHALL NOT 自动删除残留 LV；SHALL 进入隔离期（默认 7 天可配），由人工确认数据不再需要后经 StorageTask 清理。

#### Scenario: 隔离期不清理
- **WHEN** 故障节点恢复且隔离期未满、未获人工确认
- **THEN** 残留 LV 保持原样，UI/告警提示待人工处理

### Requirement: recover-disk 全程人工确认
recover-disk SHALL 识别 foreign VG 后等待人工确认，再执行 vgimport 并校验 LV 与 PV 对应关系；SHALL NOT 自动迁移数据。

#### Scenario: 未确认不导入
- **WHEN** 新节点发现 foreign VG 但无人工确认
- **THEN** 不执行 vgimport，等待确认

### Requirement: orphan-gc 只提醒不删除
orphan-gc SHALL 检测 Retain 后 Released 的 PV 与孤儿 LV（三方对账：LogicalVolume CR / PV / lvs），统计占用并提醒人工回收；SHALL NOT 自动删除。

#### Scenario: 孤儿 LV 提醒
- **WHEN** lvs 存在无 PV/CR 对应的 LV
- **THEN** 记录孤儿清单与占用统计，告警提醒人工回收

### Requirement: drift 检测与 break-glass
drift-detector SHALL 通过 CR/PV/lvs 对账发现人工绕过平台的 LVM 变更，告警并给出"补录/回滚"建议；SHALL 提供 break-glass 授权窗口（窗口内允许手工操作，事后强制补录）。

#### Scenario: 手工变更被发现
- **WHEN** 运维手工 lvremove 删除了一个平台未记录的 LV
- **THEN** 下次对账触发 drift 告警，报告差异与补录/回滚建议

### Requirement: 审计完整性
所有平台写操作 SHALL 记录操作人、对象、前后值、时间、来源，并与 K8s audit log 交叉校验。

#### Scenario: 审计可交叉校验
- **WHEN** 平台执行一次 vgreduce 任务
- **THEN** 平台审计与 K8s audit log 均有对应记录且字段一致

### Requirement: 坏盘差异化处置
磁盘损坏处置 SHALL 区分：无 RAID pooled（明确告知该 VG 全部 LV 不可恢复）、无 RAID per-disk（影响限于单盘）、有 RAID（换盘重建并监控进度）；vgreduce --removemissing SHALL 经审批执行。

#### Scenario: 无 RAID pooled 坏盘
- **WHEN** pooled 布局 VG 内一块盘损坏且无冗余
- **THEN** Critical 告警文案明确数据不可恢复，业务从其他副本重建后经审批 vgreduce
