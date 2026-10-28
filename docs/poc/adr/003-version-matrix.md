# ADR-003：TopoLVM 目标版本与版本矩阵（设计 §2.1 / §10 / add-poc-decision-gate spec §3）

- **状态**：待 POC 实测填充（框架）
- **日期**：2026-10-28
- **决策人**：平台团队

## 背景

设计【待核实】第 1、3 项要求明确 TopoLVM 目标版本、provisioner 参数键（`topolvm.io/device-class`）、
lvmd 配置热加载能力、scheduler-extender 与 CSIStorageCapacity 现状、K8s 对
matchConditions/ValidatingAdmissionPolicy/Scheduling Gate 的支持。本 ADR 是版本矩阵的**权威维护点**，
持续与 `control-plane/config/hardening/version-matrix.md` 对齐。

## 版本矩阵（POC 实测后填充）

| 组件 | 目标/验证版本 | provisioner 参数键 | 备注 |
| --- | --- | --- | --- |
| Kubernetes | ___ | — | 需 ≥1.30 以启用 ValidatingAdmissionPolicy/matchConditions |
| 内核 | ___ | — | thin-pool / dmeventd 行为依赖 |
| lvm2 | ___ | — | `thin_pool_autoextend_*`、thin_check |
| TopoLVM | ___ | `topolvm.io/device-class` | 官方 Helm 版本；确认 lvmd 热加载能力 |
| controller-runtime | 0.20.4 | — | 本控制面依赖（已固定） |

## TopoLVM 集成核实项（§1.2–1.3）

- [ ] `topolvm.io/device-class` 键与 thick/thin 映射确认
- [ ] lvmd 配置热加载能力（SIGHUP/file watch/需滚动重启）—— 决定 lvmd-config-ctrl 灰度策略
- [ ] scheduler-extender 与 CSIStorageCapacity 现状（external-provisioner 上报）
- [ ] thin 快照/克隆限制（与 `functional-test.sh` §2.1 交叉验证）

## 影响

- 版本矩阵任一变更须回归 `control-plane/config/hardening/version-matrix.md`；
- TopoLVM 升级演练与回滚见 hardening `version-matrix.md` §2。
