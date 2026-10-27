# poc-validation 规格 Delta

## ADDED Requirements

### Requirement: POC 决策门
项目在阶段 0 POC 全部通过标准达标并产出决策记录之前，SHALL NOT 开始任何自研模块（控制面/Agent/Webhook/exporter）的开发。

#### Scenario: 决策门通过
- **WHEN** POC 报告中 §10 全部验证项达标，且语言/RAID/版本矩阵三份决策记录通过评审
- **THEN** 项目进入阶段 1 模块开发
- **AND** 设计文档【待核实清单】中可由 POC 关闭的条目状态被更新

#### Scenario: 决策门未通过
- **WHEN** 任一 POC 验证项未达标
- **THEN** 不进入模块开发，未达标项形成整改结论或项目终止结论

### Requirement: 性能基线以实测为准
所有性能与可靠性结论 SHALL 基于 POC fio 实测数据（裸盘 / thick LV / thin LV 含首写、覆盖写、有快照场景 / XFS，多种 bs 与队列深度，关注 p99 延迟），不得预设"接近裸盘""零开销"结论。

#### Scenario: 覆盖写损耗定标
- **WHEN** fio 对比测试完成
- **THEN** 输出实测损耗数据报告，并与假设目标（覆盖写损耗 ≤10%）对照给出结论

### Requirement: TopoLVM 版本矩阵
项目 SHALL 在 POC 阶段明确 TopoLVM 目标版本及版本矩阵，包括 provisioner 参数键（`topolvm.io/device-class`）、lvmd 配置热加载能力、scheduler-extender 与 CSIStorageCapacity 的版本现状。

#### Scenario: 版本矩阵产出
- **WHEN** TopoLVM 集成验证完成
- **THEN** 产出包含 K8s / 内核 / lvm2 / TopoLVM 兼容矩阵的版本矩阵文档

### Requirement: 故障剧本 POC 验证
thinpool 打满（§9.1）、坏盘热拔（§9.3，pooled 与 per-disk 各验证一块）、节点断电恢复（§9.2）三类故障场景 SHALL 在 POC 阶段完成注入验证，确认剧本可执行、告警准确。

#### Scenario: thinpool 打满
- **WHEN** 突发写入打满 thinpool
- **THEN** 记录前兆、dmeventd 扩容时延与成功率、IO hang/报错行为、文件系统可恢复性

#### Scenario: webhook 全宕机
- **WHEN** 全部 webhook 副本宕机
- **THEN** 非本平台 PVC 的创建不受阻塞（验证 §4 分级 FailurePolicy 前提）
