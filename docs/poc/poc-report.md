# POC 报告（add-poc-decision-gate §5.5 汇总模板）

> 本模板由 POC 实测阶段回填。结构化脚本与决策记录见同目录 `README.md`。
> 决策门评审：POC 报告 + 4 份 ADR（001 语言 / 002 RAID / 003 版本矩阵 / 004 备份 RTO-RPO）全部通过评审后，项目进入阶段 1 模块开发（注：本仓库模块已先行，见 README 执行顺序说明）。

## 1. 环境与版本（§1）
- K8s 版本：___
- TopoLVM 版本：___；provisioner 参数键：___
- 节点数/本地盘：___
- matchConditions / ValidatingAdmissionPolicy / Scheduling Gate 支持：___
- lvmd 热加载能力：___；scheduler-extender / CSIStorageCapacity 现状：___

## 2. 基础功能（§2）
- PVC 创建（thick/thin）：___
- 在线扩容：___
- 快照/克隆：___
- 节点重启恢复：___

## 3. 性能基线（§3，详见 fio-baseline.sh → fio-results.csv）
- 覆盖写损耗（thin vs 裸盘）：___（目标 ≤10%）
- p99 写延迟（4k 随机写）：___
- 有快照下写损耗增量：___
- 结论：□ 达标  □ 不达标（缓解措施 ___）

## 4. 故障注入（§4）
- 4.1 thinpool 打满：dmeventd 扩容时延 ___、成功率 ___、IO 行为 ___、可恢复性 ___
- 4.2 坏盘热拔：告警准确性 ___、剧本可执行性 ___
- 4.3 节点断电恢复：失联判定 ___、重建流程 ___、隔离期行为 ___
- 4.4 lvextend/out-of-data-space 恢复：参数核实 ___、恢复步骤 ___

## 5. 决策门产出
- 5.1 agent 语言决策：见 ADR-001（结论 ___）
- 5.2 RAID 选型：见 ADR-002（结论 ___）
- 5.3 备份 RTO/RPO：见 ADR-004（RTO ___ / RPO ___）
- 5.4 webhook 可用性预演：全 webhook 宕机时非平台 PVC ___ 阻塞（预期不阻塞）
- 5.5 设计【待核实清单】关闭状态：见 README.md（1/2/3 移交集成，4 不需 POC，5 见 ADR-002）

## 6. 决策门结论
- □ 通过（进入阶段 1 / 作为回归基线与版本门控输入）
- □ 未通过（整改项 ___ / 终止结论 ___）

评审签字：___  日期：___
