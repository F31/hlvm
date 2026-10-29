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
3. **`spec.TTL` 的语义边界（2026-10-29 落地）**：定义为**执行窗口**（对齐 K8s Job 的
   `activeDeadlineSeconds`），自 `creationTimestamp` 起算；只拦截**尚未开始**的任务
   （`phase` 为空或 `Pending`），到期标记 `Failed`（`Result` 以 `DeadlineExceeded:` 开头）并保留对象，
   **不自动重试**；TTL 无法解析或 `<=0` 时**失败关闭**（拒绝执行）。详见下方补遗。

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
  （UID 一致）；删除 NodeVG 后任务在数秒内被 GC 回收。`pvcreate` 任务对 `NodeDisk` 同样生效（同一脚本内验证）。
- **已实测（kind，`verify-ttl`）**：`ttl: 2s` 的任务在到期后被标记 `Failed`（`DeadlineExceeded: ...`）且对象保留；
  `ttl: 1h` 的任务在 8s 内未被改写；`ttl: nonsense` 失败关闭。
- **验证副作用（已修复）**：真机验收暴露两个 envtest 覆盖不到的部署缺陷——
  ① ClusterRole 缺 `storagetasks/status` 更新（403，任务永远 Pending）；
  ② StorageTask CRD 缺 `subresources.status`（404，**agent patch_status 回执链路实际不可用**）。
  两者已修复，并新增 `internal/controller/deploy_manifests_test.go` 做清单级防回归。
- ~~未覆盖：`spec.TTL` 的 **agent 侧复核**~~ → **已补齐**（同日，`agent/src/common/ttl.rs` +
  `reporter::kube_rw::expired_reason`，见补遗「残余竞态」）；仍未覆盖的是两侧时钟偏差。

---

## 补遗（2026-10-29）：`spec.TTL` 落地为「执行窗口」

### 决策

1. **控制面为执行窗口的唯一执行者**：`StorageTaskReconciler` 在非终态路径先评估
   `EvaluateTaskTTL(task, now)`：
   - `TaskTTLNone`（未设 TTL）：不限制；
   - `TaskTTLWaiting`：返回 `RequeueAfter=剩余时间`，到点精确复查（不轮询）；
   - `TaskTTLExpired`：若任务**尚未开始**（phase 为空或 `Pending`），标记 `Failed` 并写 Event；
     若已 `Running`/`Unknown`，**不改写**（单写者原则：执行已发生，结果由 agent 收敛）。
2. **不自动删除任务**：与 Job 的 `activeDeadlineSeconds` 一致——对象保留供排查，
   重试须人工删除任务后由 desired-state 控制器重新下发。
3. **失败关闭**：`spec.ttl` 非法（不可解析 / `<=0`）时视为已过期并拒绝执行。
   理由：TTL 是破坏性任务的安全窗口约束，无法评估窗口时执行风险高于不执行。
4. **语义边界写进 API 注释与 CRD 注释**：TTL 是「执行窗口」，不是「保留期」；
   保留期由拥有者生命周期（ADR-006 决策 1）决定，两者不可混用。

### 与 Job 的对照

| 维度 | K8s Job `activeDeadlineSeconds` | hlvm `spec.ttl` |
| --- | --- | --- |
| 起算点 | Pod 启动（Job 开始） | `creationTimestamp`（"存活时长"语义） |
| 到期动作 | 终止执行，Job 标 Failed（`DeadlineExceeded`） | 未开始时标 Failed；执行中不改写 |
| 对象保留 | 保留 | 保留 |
| 自动重试 | 无（需重建 Job） | 无（需删除任务由控制器重建） |

### 残余竞态（已由 agent 侧复核关闭）

- **竞态描述**：agent 采用**轮询 list**，若它在控制面标记 `Failed` 的同一瞬间已取走任务，仍可能执行一次
  过期任务。窗口 ≈ 一轮轮询间隔（10s），且 TTL 是安全窗口而非硬实时边界。
- **已实现第二道闸**：`agent/src/common/ttl.rs` 提供 `parse_go_duration` / `evaluate_task_window`，
  `reporter::kube_rw::expired_reason` 在**执行前**复核 `creationTimestamp + spec.ttl`，命中则直接
  回写 `Failed`（`message` 带 `DeadlineExceeded: ` 前缀、`completedAt` 为当前 RFC3339）并跳过 executor。
- **语义与控制面逐条对齐**：只拦截尚未开始的任务（phase 空 / `Pending`）；`Running`/`Unknown` 不覆盖；
  TTL 非法或 `<= 0` 失败关闭；**缺 `creationTimestamp` 同样失败关闭**（无法评估窗口时不执行破坏性任务）。
- **验证**：`cargo test` 新增 11 个用例（Go 风格时长解析 8 例 + 窗口评估/原因前缀/边界/失败关闭），
  全量 99 项通过；`cargo fmt --check` 通过；`cargo clippy --all-targets` **无新增告警**
  （仓库既有 39 条历史告警未在本轮处理，CI 中 clippy 为非阻塞反馈）。
  时长解析刻意不引第三方 crate，以与 Go `time.ParseDuration` 语义逐项对齐（含小数、组合单位、`0` 特例）。
- **仍未覆盖**：控制面与 agent 的**时钟偏差**（同节点 NTP 正常时误差可忽略；若偏差超过 TTL 量级，
  两侧判定可能不一致——属部署前提，非代码缺陷）。

