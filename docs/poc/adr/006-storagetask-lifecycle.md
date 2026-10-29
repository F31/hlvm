# ADR-006：StorageTask 的归属与回收（ownerReference + K8s GC，不做 TTL 清理）

- **状态**：已接受（2026-10-29，M15 集成验证中发现并决策）
- **日期**：2026-10-29
- **决策人**：平台团队
- **触发**：M15 kind 实测发现删除 NodeVG 后 `vg-<vg>-vgcreate|vgreduce-*` 任务残留（4 条孤儿），
  既无 `ownerReference` 也无清理机制。

## 背景

`StorageTask` 是**一次性执行体**：控制器按 desired state 计算任务（稳定命名，如
`vg-<vg>-vgcreate`、`disk-<disk>-wipe`），agent 消费执行并写 `status`，控制器读终态回写
`NodeVG` / `NodeDisk.status`。任务对象本身有两个与生命周期相关的问题：

1. **孤儿堆积**：任务无 `ownerReference`，拥有者删除后仍留在集群（无 agent 时尤甚）。
2. **误执行风险**（比堆积更严重）：指向已删除 `NodeDisk` 的 `wipe` 任务、或指向已删除
   `NodeVG` 的 `vgcreate` 任务，仍可能被 agent 拉取执行——对已脱离平台管理的对象做破坏性操作。

与此同时，`StorageTaskSpec.TTL`（"任务存活时长，过期不执行"）已在 Go/Rust 两侧定义但**未被任何代码消费**，
不能充当清理机制。

## 业界参考

| 实现 | 生命周期模型 | 对本决策的意义 |
| --- | --- | --- |
| **K8s Job** | `ttlSecondsAfterFinished` + 可选 ownerReference；Job 非 owned 时长期保留作历史 | 一次性执行体的标准做法：**保留策略是显式选项**，默认不自动删除 |
| **K8s GC** | dependent 在**所有** owner 删除后才删除；`blockOwnerDeletion` 可阻止前台级联 | 无需 finalizer 即可表达「归属随拥有者消亡」 |
| **Velero** | `Backup.spec.ttl` 到期删除 Backup 对象及其存储 | TTL 语义是「保留窗口」，不是「执行窗口」；与本处 `spec.TTL` 语义相反，需避免混淆 |
| **Cluster API / Crossplane** | 子资源持有 ownerReference；删除父对象即级联清理运行时对象 | 运行时产物不承担审计职责，审计另走事件/日志 |

## 决策

1. **任务持有拥有者的非 controller `ownerReference`**（`NodeVG` 或 `NodeDisk`）：
   - `controller: false`、`blockOwnerDeletion: false`——任务只借 GC 归属，不参与 `Owns` 级联，
     也不阻塞拥有者删除（一个对象只能有一个 controller owner，任务不应抢占）；
   - 拥有者删除 → K8s GC 回收任务，同时天然阻断「对已删除对象继续执行破坏性任务」；
   - 无 UID 的对象（未持久化 / fake client 构造）不写 ownerReference，避免非法引用。
2. **不引入 `ttlSecondsAfterFinished` 式清理**。理由：
   - 任务名**稳定**，desired-state 控制器在任务缺失时会立即重建同名任务 →
     「删除 → 重建 → 再删除」抖动，且失败任务会被无限重试并以删除掩盖失败；
   - 终态任务的自然保留期等于拥有者生命周期，数量上界是「该对象的操作次数」（通常个位数），
     不构成容量问题；
   - 审计不依赖任务对象：写操作审计经 `Event`（`audit.go`）+ K8s audit log 交叉校验（设计 §4.1），
     `StorageTask` 只是执行记录。
3. **`spec.TTL` 的语义边界**：定义保持不变（"过期不执行"），但当前**未实现**——属执行窗口控制，
   与清理无关。落地需 agent 侧消费（校验 `creationTimestamp + ttl`），且要在
   `StorageTaskSpec` 文档中与「保留期」明确区分。列为后续变更，不在本 ADR 范围内假装完成。

## 备选方案（未采纳）

- **TTL-after-finished 自动删除终态任务**：如上，与稳定命名的 desired-state 重建机制冲突；
  若未来改为「每次操作的唯一任务名（含随机后缀）」，该方案才成立。
- **保留任务永久作为审计台账**：审计要求「操作人 / 对象 / 前后值 / 时间 / 来源」，
  应以独立审计记录承载（`Event` + audit log 已覆盖），让执行体承担台账职责会同时牺牲可清理性。
- **finalizer 手工清理**：GC 已覆盖同一语义，finalizer 只会增加删除阻塞与故障面。

## 影响与风险

- `verify-lvmd` / `verify-controller` 的显式清理仍保留（兼容旧镜像与 GC 延迟），但不再是唯一保障。
- 任务级 RBAC 不变；GC 由 kube-controller-manager 执行，无需控制面额外权限。
- **已实测（kind，`verify-taskgc`）**：`vgcreate` 任务带 `NodeVG` 非 controller ownerReference
  （UID 一致）；删除 NodeVG 后任务在数秒内被 GC 回收。
- 未覆盖：`NodeDisk` 路径的 GC 未单独做集群实测（仅单测覆盖），但其 ownerReference 构造与 NodeVG 同源。
- `spec.TTL` 仍未实现，已登记为遗留项，不得视为已交付能力。
