# Proposal: add-lifecycle-ops

## Why

设计方案 v1.1 §3.5、§7、§9：MVP 只覆盖纳管与容量管控，磁盘/节点全生命周期（退役、隔离、恢复）、Retain 后孤儿回收、人工绕过平台操作（drift）的治理属于阶段 2（§10 阶段 2 第 1 项）。这些能力对应风险登记中的"Retain 隐形容量成本""人工误操作"等长期运行痛点，且 StorageNodeOps 状态机是 §9.2/§9.4 剧本的自动化载体。

## What Changes

- lifecycle-ctrl：StorageNodeOps 状态机（validate → drain → wait-pvc-cleanup → wipe → done）；retire / isolate / recover-disk 三种操作；阻塞点写 `status.blockingPVCs`。
- 节点故障剧本自动化（§9.2）：失联 → isolate + 存储故障标签（非 NoSchedule 污点，§7 修正）；旧节点恢复后进入隔离期（默认 7 天可配），不自动删除残留 LV，人工确认后经 StorageTask 清理；recover-disk 的 foreign VG 识别 → 人工确认 → vgimport 全程人工确认。
- 磁盘损坏剧本（§9.3）：无 RAID pooled/per-disk 差异化文案与流程（vgreduce --removemissing 需审批）；有 RAID 换盘重建流程与进度监控。
- 节点退役剧本（§9.4）：validate 列 PVC → drain 等业务确认 → wait-pvc-cleanup → 可选 wipe → done。
- orphan-gc：检测 Retain 后 Released 的 PV 与孤儿 LV（对账 LogicalVolume CR / PV / lvs 三方），统计占用，提醒人工回收（不自动删除）。
- drift-detector：CR/PV/lvs 对账，发现人工 lvcreate/lvremove 等绕过平台变更，告警并给出"补录/回滚"建议；提供 break-glass 流程（授权窗口内允许手工操作并事后补录）。
- audit：所有写操作记录操作人、对象、前后值、时间、来源；与 K8s audit log 交叉校验。
- RBAC 与 doctor 诊断打包（§10 阶段 2 第 3 项）。

## 前置核实清单

1. add-crd-controller-skeleton 与 add-node-agent 已交付（StorageNodeOps CRD、StorageTask 执行路径）。

## Out of Scope

- 备份编排（add-backup-restore）。
- 混沌演练与灰度上线（add-hardening-rollout）。

## Impact

- **Affected specs**: `lifecycle-operations`（新增）
- **Affected code**: `internal/controller/lifecycle.go`、`internal/controller/orphangc.go`、`internal/controller/drift.go`、audit 模块、agent doctor 模式。
- **验证回路**：单测（状态机、对账）+ envtest + 测试集群演练（模拟节点故障/恢复、手工 lvcreate 触发 drift）。
