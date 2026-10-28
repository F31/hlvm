# Tasks: add-hardening-rollout

> 进度说明（M12 / 控制面硬化代码）：接上审计缺口——`RecordAuditEvent` 此前已定义但从未接线。
> 本里程碑给 `StorageTaskReconciler` 加 `EventRecorder`，在**破坏性任务（wipe/secure-erase、vgreduce）完成**时写审计事件
> （操作人取自 `hlvm.storage/operator` 标签，缺省 system；方法含 `wipe:<policy>`/`vgreduce:<disks>`），落实设计 §4.1/§4.3
> 「磁盘擦除/退役须记录入审计」。新增 3 个 fake-client 单测覆盖擦除/退役审计与「非破坏性不审计」。build/vet/test 全绿。
> 安全基线其余项（agent 特权最小化/PSA/seccomp/命令白名单/镜像签名 SBOM/LUKS 评估）、升级回滚、灰度、混沌/Runbook、性能报告
> 移交 M12b（部署与策略清单）。

## 1. 混沌演练（上线门禁）

- [ ] 1.1 演练方案：随机拔盘、断网、kill agent/controller/webhook、etcd 抖动的注入工具与观察指标
- [ ] 1.2 数据面独立性验证：控制面/Agent/Webhook 各自整体宕机 → 已有卷 IO/挂载零影响
- [ ] 1.3 剧本回放：§9.1–9.4 四个标准剧本按演练脚本走通，告警与动作符合 §8 矩阵
- [ ] 1.4 演练报告与问题闭环（回归验证）

## 2. 性能基线报告

- [ ] 2.1 汇总 POC 与硬化期实测数据，形成正式性能基线报告（覆盖写损耗、p99 延迟、dmeventd 扩容时延等）
- [ ] 2.2 报告评审通过，作为后续版本回归的基线

## 3. 升级与回滚

- [ ] 3.1 CRD 版本化方案：v1alpha1→v1beta1 带 conversion webhook 的框架与演练
- [ ] 3.2 agent 滚动升级：maxUnavailable 受控、升级期间任务排空与恢复
- [ ] 3.3 TopoLVM 升级演练与回滚；版本兼容矩阵（K8s/内核/lvm2/TopoLVM）声明与文档化
- [ ] 3.4 任一组件可回滚验证（含 webhook、controller、agent）

## 4. 安全基线

- [ ] 4.1 agent 特权最小化复核：仅必需 capability 与 hostPath、PSA 标签、seccomp、命令白名单
- [ ] 4.2 镜像签名与 SBOM 流程
- [ ] 4.3 磁盘退役安全擦除记录入审计验证；LUKS 可选项评估结论
  - [x] 4.3.1 控制面：破坏性擦除/wipe/secure-erase 与 vgreduce 完成时写审计事件（M12；`StorageTaskReconciler` + `RecordAuditEvent`，含 operator/method 字段）
  - [ ] 4.3.2 LUKS 可选项评估结论（设计 §11 数据安全；移交 M12b/决策）

## 5. 灰度上线

- [ ] 5.1 灰度计划：内部中间件 → 多副本业务；观察指标（告警量、容量水位、drift、任务失败率）
- [ ] 5.2 灰度期问题闭环与放量决策记录
- [ ] 5.3 上线评审：全部门禁（混沌、性能、升级回滚、备份演练、安全基线）逐项通过

## 验证回路

- [ ] V.1 全部演练与评审通过，形成上线报告
- [ ] V.2 commit + push（里程碑闭环）
