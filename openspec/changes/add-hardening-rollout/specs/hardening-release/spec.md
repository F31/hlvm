# hardening-release 规格 Delta

## ADDED Requirements

### Requirement: 混沌演练为上线门禁
上线前 SHALL 完成混沌演练（随机拔盘、断网、kill agent/controller/webhook、etcd 抖动），并验证数据面独立原则：控制面、Agent、Webhook 任一整体宕机，已有卷的 IO 与挂载 SHALL 零影响。

#### Scenario: 控制面宕机数据面无感
- **WHEN** 混沌演练中 storage-controller 全副本被 kill
- **THEN** 已有卷的 IO 与挂载不受影响，恢复后控制面自动接管对账

### Requirement: 性能结论以实测报告为准
正式性能基线报告 SHALL 基于 POC 与硬化期实测数据形成并经评审，作为后续版本回归基线；任何发布材料 SHALL NOT 使用"接近裸盘""零开销"等未实测表述。

#### Scenario: 性能报告评审
- **WHEN** 性能基线报告完成
- **THEN** 覆盖写损耗、p99 延迟、dmeventd 扩容时延等关键指标均有实测数据与结论

### Requirement: 升级与回滚能力
平台 SHALL 支持：CRD 版本化（v1alpha1→v1beta1 带 conversion）、agent 滚动升级（maxUnavailable 受控）、TopoLVM 升级与回滚；SHALL 声明 K8s/内核/lvm2/TopoLVM 版本兼容矩阵；任一组件 SHALL 可回滚。

#### Scenario: agent 滚动升级
- **WHEN** agent 新版本滚动发布
- **THEN** maxUnavailable 受控，执行中任务排空后升级，失败可回滚

### Requirement: 灰度上线节奏
上线 SHALL 按内部中间件 → 多副本业务的灰度节奏推进，灰度观察指标（告警量、容量水位、drift、任务失败率）达标后方可放量。

#### Scenario: 灰度放量决策
- **WHEN** 内部中间件灰度期观察指标达标
- **THEN** 记录放量决策后扩大灰度范围

### Requirement: 安全基线
上线前 SHALL 落实：agent 特权最小化（仅必需 capability 与 hostPath）、PSA 标签、seccomp、命令白名单、节点级 RBAC、镜像签名与 SBOM；磁盘退役安全擦除 SHALL 记录入审计。

#### Scenario: 退役擦除可审计
- **WHEN** 一块盘经审批完成 secure-erase
- **THEN** 审计记录含操作人、盘身份、擦除方式与时间
