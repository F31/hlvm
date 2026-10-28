# POC 决策门（add-poc-decision-gate）

> 设计 v1.1 §10 阶段 0 规定：**POC 决策门未达标前，不进入任何自研模块开发**。
> 本 change 在 OpenSpec 顺序中为**收尾项**——结构化交付 POC 脚本框架与决策记录模板；
> 真实集群实测（环境搭建、fio、故障注入、备份演练、灰度）标注「移交集成」，不阻塞本仓库代码收口。

## 目录

| 文件 | 内容 | 对应任务 |
| --- | --- | --- |
| `env-setup.md` | ≥3 节点集群 + TopoLVM Helm 安装 + 版本/特性核实命令 | §1.1–1.3 |
| `scripts/functional-test.sh` | PVC 创建/扩容/快照/克隆/重启恢复 | §2.1–2.2 |
| `scripts/fio-baseline.sh` | 裸盘/thick/thin 性能矩阵 + p99 | §3.1–3.3 |
| `scripts/fault-injection.sh` | thinpool 打满/坏盘热拔/节点断电/lvextend 核实 | §4.1–4.4 |
| `scripts/webhook-availability.sh` | 全 webhook 宕机不阻塞非平台 PVC | §5.4 |
| `adr/001-agent-language.md` | agent 语言决策（Rust vs Go，§5.5） | §5.1 |
| `adr/002-raid-selection.md` | RAID 选型（硬件/mdadm/LVM RAID1） | §5.2 |
| `adr/003-version-matrix.md` | TopoLVM 目标版本矩阵 | spec §3 |
| `adr/004-backup-rto-rpo.md` | 备份演练 RTO/RPO（Velero/Kopia） | §5.3 |
| `poc-report.md` | POC 汇总报告模板（实测填入） | §5.5 |

## §10 阶段 0 通过标准清单

| 项 | 验证内容 | 通过标准 | 状态 |
| --- | --- | --- | --- |
| 基础 | PVC 创建、在线扩容、快照、克隆、重启恢复 | 全通过 | ☐ 移交集成 |
| 性能基线 | fio 裸盘/thick/thin（首写/覆盖写/有快照）/XFS，p99 | 输出损耗数据与目标（覆盖写 ≤10% 假设） | ☐ 移交集成 |
| thinpool 打满 | 突发写入打满 pool | 前兆/dmeventd 时延成功率/IO 行为/可恢复 | ☐ 移交集成 |
| 坏盘 | 热拔 pooled 与 per-disk 各一块 | §9.3 可执行、告警准确 | ☐ 移交集成 |
| 节点宕机 | 强制断电与恢复 | 失联判定/重建/隔离期 | ☐ 移交集成 |
| webhook 可用性 | 全部 webhook 副本宕机 | 不阻塞非本平台 PVC（§4 分级） | ☐ 移交集成 |
| TopoLVM 集成 | lvmd 下发/重载、scheduler/CSIStorageCapacity | 明确上游版本矩阵 | ☐ 移交集成 |
| RAID 选型 | 硬件 RAID/mdadm/LVM RAID1 | 结论写入规范 | ☐ 见 ADR-002 |
| 语言决策 | Rust vs Go 原型 | 决策记录（§5.5） | ☐ 见 ADR-001 |
| 备份 | Velero/Kopia 恢复演练 | 实测 RTO/RPO | ☐ 见 ADR-004 |

## 设计【待核实清单】关闭状态

| # | 待核实项 | POC 关闭方式 | 状态 |
| --- | --- | --- | --- |
| 1 | TopoLVM 目标版本 / device-class 键 / lvmd 热加载 / 调度现状 / thin 快照克隆限制 / RAID 配置 | `env-setup.md` §2–3 + `adr/003` | ☐ 移交集成 |
| 2 | `lvextend` 参数 / `thin_pool_autoextend_*` / out-of-data-space 恢复 | `fault-injection.sh` §4.4 + `poc-report.md` | ☐ 移交集成 |
| 3 | K8s 对 matchConditions / ValidatingAdmissionPolicy / Scheduling Gate 支持 | `env-setup.md` §1.1 | ☐ 移交集成 |
| 4 | Carina 等对比对象当前能力 | 立项时评估，非 POC 阻塞 | ☐ 不需 POC |
| 5 | LUKS 与 TopoLVM 组合 / LVM RAID 对 thin-pool 元数据冗余 | `adr/002` + `luks-evaluation.md`(hardening) | ☐ 见 ADR-002 |

## 执行顺序说明（重要）

本仓库的 OpenSpec 执行顺序中，`add-poc-decision-gate` 排在最后，但设计上它是**第一道门控**。
在用户驱动的"按 change 顺序推进"执行中，自研模块（M0–M12b，控制面/Agent/Webhook/exporter + 备份/硬化）
已先行完成。因此本 change 的产出定位为：
- **结构化交付** POC 脚本与决策记录模板（本次提交）；
- **真实实测** 移交集成环境执行，结果回填 `poc-report.md`；
- POC 实测结论将作为后续**回归基线与版本门控输入**（性能基线、版本矩阵、故障剧本可重复性），而非"是否开发"的门控。
