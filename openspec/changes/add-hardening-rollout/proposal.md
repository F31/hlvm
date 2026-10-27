# Proposal: add-hardening-rollout

## Why

设计方案 v1.1 §10 阶段 3 与 §11：自研差异化组件无社区背书（附录 A.3 承认的短板），混沌演练是上线门禁；升级/回滚能力、兼容矩阵、性能基线报告是平台长期可维护的必要条件。这是上线前的最后一道门控。

## What Changes

- 混沌演练：随机拔盘、断网、kill agent/controller/webhook、etcd 抖动；验证数据面独立原则（控制面/Agent/Webhook 整体宕机不影响已有卷 IO/挂载）。
- 性能基线报告：汇总 POC 与硬化期实测，形成正式性能报告（不预设结论）。
- 升级演练（§11）：CRD 版本化方案（v1alpha1→v1beta1 带 conversion）、agent 滚动 maxUnavailable 受控、TopoLVM 升级与回滚、K8s/内核/lvm2/TopoLVM 版本兼容矩阵声明。
- 灰度上线：内部中间件 → 多副本业务，按 §10 阶段 3 第 3 项节奏。
- 安全基线落实（§11）：agent 特权最小化、PSA 标签、seccomp、命令白名单、节点级 RBAC、镜像签名与 SBOM、数据安全（安全擦除记录入审计、可选 LUKS）。
- Runbook 演练验证（§9）：故障标准剧本经混沌演练验证，剧本即代码随版本维护。

## 前置核实清单

1. 阶段 1、2 全部 change 已交付并通过各自验证回路。

## Out of Scope

- 新功能开发；本 change 只做硬化、验证与上线。
- 精简路径（§13）场景下的范围裁剪（由立项评审另行决策）。

## Impact

- **Affected specs**: `hardening-release`（新增）
- **Affected code**: 演练脚本与故障注入工具、升级 manifests（conversion webhook、滚动策略）、发布清单、安全加固配置。
- **验证回路**：混沌演练全项通过 + 升级/回滚演练通过 + 性能报告评审 + 灰度指标观察达标 → 正式上线。
