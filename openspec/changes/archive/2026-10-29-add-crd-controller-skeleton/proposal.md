# Proposal: add-crd-controller-skeleton

## Why

设计方案 v1.1 §3 定义了平台的 API 基础（Disk / VG / ThinPoolPolicy / StorageTask / StorageNodeOps 五个 CRD），§7 定义了控制面控制器清单。CRD 与控制面骨架是 MVP（§10 阶段 1 第 1 项）的地基：所有旁路组件（Agent、webhook、exporter、UI）都以这些 CRD 为契约协作。本 change 建立可编译、可部署、可对账的最小控制面。

## What Changes

- 定义 API Group `storage.<api-domain>/v1alpha1`（上线前替换占位域名）下 5 个 cluster-scoped CRD，Kind 命名采纳 §附录 B#30 建议（`NodeDisk` / `NodeVG` 等，避免与 OpenEBS `BlockDevice` 冲突）。
- NodeDisk CRD：身份以 serial/WWN（§3.1），`phase`（Discovered→Candidate→PreChecked→Wiped→InVG→Draining→Removed）与 `health` 两维度分离，`adopt` + `confirmSerial` 意图驱动推进。
- NodeVG CRD：tier ↔ device-class 解耦 StorageClass（§附录 B#10），layout `pooled|per-disk`（无 RAID 默认 per-disk），thinPool 初始 80% / 上限 95%（修正 v1.0 数学矛盾），spec 不可被控制器回写。
- ThinPoolPolicy 集群级单例（可按 tier 覆盖）：阈值、滞回 `unlockPercent`、锁策略（拦新 PVC + 拦存量扩容）、预测参数。
- StorageTask / StorageNodeOps CRD：稳定 taskID、type 白名单、`approvedBy` 审批字段、TTL、幂等语义（§3.4/§3.5）。
- storage-controller 骨架（Deployment ×2 + leader election）：disk-ctrl（含节点失联 stale 判定）、vg-ctrl（声明式 reconcile → 下发 StorageTask、删盘保护锁、冗余降级检测）先行；capacity/lvmd-config 控制器骨架占位由 add-capacity-governance 填充。
- etcd 写放大控制：NodeDisk status 仅在 `health/phase` 变化或 10 分钟低频刷新（§3.1）。

## 前置核实清单

1. POC 决策门已通过（依赖 add-poc-decision-gate）。
2. K8s 版本对 CRD v1、CEL（用于后续 VAP）的支持。

## Out of Scope

- capacity-ctrl / lvmd-config-ctrl 的完整逻辑（add-capacity-governance）。
- webhook 与调度约束（add-admission-scheduling）。
- agent 实现（add-node-agent）；本 change 只保证 CRD 契约完整。
- orphan-gc / drift-detector / lifecycle-ctrl / backup-ctrl / audit（add-lifecycle-ops）。

## Impact

- **Affected specs**: `crd-api`、`storage-control-plane`（新增）
- **Affected code**: `api/v1alpha1/`（Go 类型 + deepcopy）、`config/crd/`（kubebuilder manifests）、`internal/controller/disk.go`、`internal/controller/vg.go`、部署 manifests（Deployment ×2、RBAC、leader election）。
- **验证回路**：go build / go vet / go test（envtest 对账单测）+ CRD apply 到测试集群。
