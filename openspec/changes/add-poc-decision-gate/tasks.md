# Tasks: add-poc-decision-gate

> 收尾 change（不阻塞）。仅结构化交付 POC 脚本框架与决策记录文档（docs/poc/），无产品代码。
> 真实集群实测（环境搭建/fio/故障注入/备份演练/灰度/webhook 预演）标注「移交集成」，回填 poc-report.md。

## 1. POC 环境搭建
- [x] 1.1 集群与 K8s 特性核实命令 → `docs/poc/env-setup.md` §1.1
- [x] 1.2 TopoLVM 官方 Helm 安装 + provisioner 键/版本核实 → `env-setup.md` §2
- [x] 1.3 lvmd 热加载 / 调度现状核实 → `env-setup.md` §3

## 2. 基础功能验证
- [x] 2.1 PVC 创建/扩容/快照/克隆脚本 → `docs/poc/scripts/functional-test.sh`
- [x] 2.2 节点重启恢复脚本 → `functional-test.sh` §2.2
- [ ] 实测执行（**移交集成**）

## 3. 性能基线（fio 实测）
- [x] 3.1 裸盘基线脚本 → `scripts/fio-baseline.sh`
- [x] 3.2 thick/thin 对比脚本
- [x] 3.3 损耗报告输出（CSV + 模板）
- [ ] 实测与结论（**移交集成**）

## 4. 故障注入验证
- [x] 4.1 thinpool 打满脚本 → `scripts/fault-injection.sh`
- [x] 4.2 坏盘热拔脚本
- [x] 4.3 节点断电脚本
- [x] 4.4 lvextend/out-of-data-space 核实脚本
- [ ] 实测执行（**移交集成**）

## 5. 决策门产出
- [x] 5.1 agent 语言 ADR → `docs/poc/adr/001-agent-language.md`
- [x] 5.2 RAID 选型 ADR → `adr/002-raid-selection.md`
- [x] 5.3 备份 RTO/RPO ADR → `adr/004-backup-rto-rpo.md`
- [x] 5.4 webhook 可用性预演脚本 → `scripts/webhook-availability.sh`
- [x] 5.5 POC 报告模板 + 待核实清单关闭状态 → `poc-report.md` + `README.md`
- [ ] 实测与评审（**移交集成**）

## 验证回路
- [x] V.1-a 脚本 bash -n 语法校验全绿；4 份 ADR + 环境/报告文档产出
- [ ] V.1-b 决策门评审通过（**移交集成**：POC 报告 + ADR 评审）
