# Proposal: m15-integration

## Why

M14 收口时，本机开发环境（envtest 1.33 + kind 1.36）能真实验证的代码与测试工作已全部完成并合入 `origin/main`，但 **19 项集成验证需求**因依赖测试集群、真实 LV 硬件、Velero、cert-manager + Dockerfile、评审/灰度流程而递延（完整明细与诚实边界见 `docs/M14-closure.md`）。这些项横跨 6 个能力域（admission-scheduling、backup-restore、capacity-governance、hardening-rollout、observability、poc-decision-gate），散落在活跃与已归档变更中，状态易歧义。本变更作为 **M15 集成里程碑**的协调与跟踪载体，统一承载这 19 项，闭合后回填各源变更 `tasks.md` 的 `[ ]` 项。

## What Changes

- **不引入新的产品能力 spec**；本变更仅协调跨能力的集成验证，属里程碑跟踪，非功能开发。
- 汇总并跟踪 19 项递延需求：observability 2 项 + capacity-governance 4 项已随源变更归档；admission-scheduling 1 项 + backup-restore 2 项 + hardening-rollout 5 项 + poc-decision-gate 5 项仍属活跃变更。
- 定义 M15 启动门槛（前置条件）：测试集群 ≥1.36、真实 LV 或可控仿真、Velero、cert-manager + control-plane Dockerfile、评审/灰度流程。
- 验收通过后，将各 `[ ]` 项回填至源变更 `tasks.md`（活跃变更原地 tick；已归档变更在其 `changes/archive/*/tasks.md` 中 tick）。

## 前置核实清单（M15 启动门槛）

1. 测试集群 K8s ≥ 1.36（与 envtest 版本对齐，消版本差——M14 中 VAP 兼容性缺陷即因 1.33 vs 1.36 差暴露）。
2. 真实 LV 硬件或可控仿真（thinpool 打满、拔盘、SMART 上报）。
3. Velero 部署可用（backup-restore 5.1 闭环）。
4. cert-manager + control-plane Dockerfile（admission 4.3 动态 mutating webhook 部署所需的证书机制；control-plane 当前无 Dockerfile，需先补）。
5. 评审/灰度流程就位（hardening-rollout、poc-decision-gate）。

## Out of Scope

- M14 已完成的本地代码与 envtest/kind 验证（不重复）。
- 新功能开发；本变更只做既有实现的集成验收与回填。

## Impact

- **Affected specs**: 无新增；验收后回填 admission-scheduling / backup-restore / capacity-governance / hardening-rollout / observability / poc-decision-gate 基线关联项。
- **Affected code**: 无（仅验证与文档回填）。
- **验证回路**：M15 集成环境逐项验收 → 回填源 `tasks.md` → 本变更 `tasks.md` 全绿后归档。
