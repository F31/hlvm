# Proposal: add-admission-scheduling

## Why

设计方案 v1.1 §4 重写了 v1.0 的 webhook 设计：`WaitForFirstConsumer` 下 PVC 创建时无节点、"Fail 全量 PVC 阻塞全集群"（风险登记高危项）两个 P0 缺陷必须靠三层方案（tier 级准入 + 调度层节点约束 + 静态 VAP）与 FailurePolicy 分级解决。这是 MVP（§10 阶段 1 第 1 项的独立 webhook 部分）。

## What Changes

- storage-webhook 独立 Deployment ×3（active-active、无 leader、PDB + 反亲和、超时 ≤3s），不含任何业务计算——只读 NodeVG status。
- 第 1 层 PVC 准入（tier 级）：`matchConditions` CEL 过滤仅对使用本平台 StorageClass 的 PVC 生效，覆盖 CREATE 与扩容 UPDATE；判定"该 tier 是否存在至少一个可用节点"，拒绝信息面向租户不暴露内部细节。
- 第 2 层 节点级约束：Pod 变更 webhook（或 Scheduling Gate，POC 已验证二选一）为引用本平台 PVC 的新 Pod 注入 nodeAffinity 排除 locked 节点；该方案在 POC 已验证，备选为 CSIStorageCapacity 过滤 + 告警。
- 第 3 层 静态规则 ValidatingAdmissionPolicy：SC 白名单、reclaimPolicy、`storage.example.io/replicas` 声明标签等，不需要自研 webhook。
- FailurePolicy 分级：安全类（删除保护）= Fail 仅作用于本平台对象；容量类拦截 = Ignore，异常时 capacity-ctrl 告警兜底。
- 删除保护：节点退役（StorageNodeOps retire）存在在用 PV 时拒绝删除相关存储对象（含 finalizer）。

## 前置核实清单

1. K8s 版本支持 `matchConditions`（≥1.28）/ VAP / Scheduling Gate（POC 任务 1.1 已核实，此处落实版本约束到部署清单）。

## Out of Scope

- locked 标签与 capacityStatus 的生产方（add-capacity-governance）。
- UI / OpenAPI。

## Impact

- **Affected specs**: `admission-scheduling`（新增）
- **Affected code**: webhook 服务代码、`config/webhook/`（manifests、matchConditions、FailurePolicy 配置）、VAP 清单、Pod 调度约束注入逻辑。
- **验证回路**：单测 + envtest（准入决策）+ 全 webhook 副本宕机演练（不阻塞非本平台 PVC）。
