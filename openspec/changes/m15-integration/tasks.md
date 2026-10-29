# Tasks: m15-integration

> M15 集成里程碑跟踪变更。汇总 M14 收口时递延的 **19 项集成验证需求**（原分布于 6 个 M14 变更；observability / capacity-governance 已归档，其余 4 个仍活跃）。本变更不引入新 spec 能力，仅作跨能力集成验证的协调与跟踪载体。前置条件与诚实边界见 `proposal.md` 与 `docs/M14-closure.md`。
>
> 验收通过后，各 `[ ]` 项需回填至源变更 `tasks.md`：活跃变更（admission-scheduling / backup-restore / hardening-rollout / poc-decision-gate）原地 tick；已归档变更在其 `openspec/changes/archive/2026-10-29-*/tasks.md` 中 tick。
>
> 集成工具：`scripts/m15-integration.sh`（`check` / `bootstrap` / `build` / `verify-admission` / `all`）；诚实分流见 `docs/m15-integration-runbook.md`（§A kind 可自动化 vs §B 必须真实 LV / Velero / 评审灰度）。

## 1. 前置条件（M15 启动门槛）

- [ ] 1.1 测试集群就绪（K8s ≥ 1.36，与 envtest 版本对齐消版本差）
- [ ] 1.2 真实 LV 硬件或可控仿真（thinpool 打满、拔盘、SMART 上报）
- [ ] 1.3 Velero 部署可用（backup-restore 5.1 闭环依赖）
- [ ] 1.4 cert-manager + control-plane Dockerfile（admission 4.3 动态层 mutating webhook 的证书机制）
  - 进展（2026-10-29 kind 实测通过）：Dockerfile 已在 WSL docker 构建并 `kind load`（本地用
    `RUNTIME_IMAGE=golang:1.24-bookworm` 覆盖运行态基础镜像，规避 distroless 拉取）；cert-manager v1.17.2
    三组件 Ready；Certificate 签发与 caBundle 注入正常；webhook（3/3）与 controller（2/2）均 Running；
    admission 4.3 注入链路验证 PASS（详见 §4.1）。
  - 仍待：生产默认 `gcr.io/distroless/static:nonroot` 运行态未在本机拉取验证；CI `images` job 的实际构建/推送
    结果待确认；目标测试集群仍需自行安装 cert-manager 并注入 CA。
- [ ] 1.5 评审 / 灰度流程就位（hardening-rollout、poc-decision-gate）

## 2. add-observability（已归档，2 项）

- [ ] 2.1 4.1 告警延迟演练：触发 thinpool 打满、拔盘、kill agent，核对 Critical ≤1min / Warning ≤5min（依赖真实 LV 硬件）
- [ ] 2.2 4.2 指标口径核对：与 lvs/vgs 实测值对账（口径冲突以实测为准；依赖真实 LV 硬件）

## 3. add-capacity-governance（已归档，4 项）

- [ ] 3.1 2.2 变更灰度 + 滚动重载机制（热加载与否按 POC 结论；依赖测试集群）
- [ ] 3.2 3.1 dmeventd 第一防线验证：autoextend 配置在测试节点生效，越线后 ≤30s 完成扩容（对照非功能指标；依赖测试集群）
- [ ] 3.3 4.3 测试集群复测 thinpool 打满演练，验证锁与告警链路（依赖测试集群）
- [ ] 3.4 V.2 打满演练通过（依赖测试集群；见 §4.3）

## 4. add-admission-scheduling（活跃，1 项）

- [ ] 4.1 4.3 动态层：单节点 locked → 新 Pod 调度排除该节点、已有 Pod 不受影响（依赖 mutating webhook server 部署 + 真实节点 locked 标签 + cert-manager）
  - 进展（2026-10-29 kind 实测）：cert-manager caBundle 注入正常；mutator 已对引用平台 PVC 的新建 Pod 注入
    `storage.example.io/data-locked NotIn ["true"]` 的 nodeAffinity（PASS）；PVC 校验 webhook 亦被真实调用
    （返回 replicas 提示）。kind 无 TopoLVM CSI，Pod 未真正调度；「新 Pod 排除 locked 节点、已有 Pod 不受影响」
    的**调度级**结论仍需真 CSI/LV 复验，故保留 `[ ]`。
  - 本次实测发现并修复 3 个真实缺陷：①VG/Capacity/Drift/LvmdConfig 四个 controller 同名（controller-runtime
    v0.20 唯一性校验致启动崩溃）→ 各加 `.Named()`；②webhook manifests 缺 `rules`（API Server 从不调用）
    → 四个 webhook 补 `rules` 并加单测 `TestManifestsWebhooksHaveRules` 防回归；③controller ClusterRole 缺
    PV/PVC/ConfigMap/Pod/Namespace 读取与 Node patch → 补齐。（后续 TTL 验证又发现 2 个：
    `storagetasks/status` RBAC 与 StorageTask CRD 的 `subresources.status`，见本节末尾。）
  - 进展（2026-10-29 kind 复验修复有效性）：`scripts/m15-integration.sh verify-controller` 在真实集群端到端 PASS——
    创建 `pooled + md-raid1 + 2 盘` 的 NodeVG 并请求移除 1 盘 → controller 写入
    `status.pendingOps=["移除候选盘将导致 VG 冗余丧失，整体拒绝下发 vgreduce"]`、下发 `vgcreate` StorageTask、
    **不**下发 `vgreduce`；解除 `removeDisks` 后 `pendingOps` 清空。该结果同时反证 ①注册名修复（controller 正常启动并
    reconcile）与 ③RBAC 修复（`nodedisks` list 权限缺失会使 Reconcile 直接失败、pendingOps 不会写入）均已生效。
    仍**不含**真实 `vgcreate/vgreduce` 执行（需 agent + 真实 LV），故本条整体仍保留 `[ ]`。
  - 追加取证（2026-10-29，lvmd ConfigMap 链路）：`hlmd-lvmd-<node>` 在真实集群正确渲染（device-class=tier、
    volume-group=NodeVG 名、thin-pool 正确）；人工篡改内容后，**由 NodeVG 事件触发**可在 1×2s 内纠正并输出
    "漂移已纠正"日志，证明 `configmaps` create/update RBAC 有效。
  - **已决策并修复（ADR-005，2026-10-29）**：原实现存在 ① 未设 `ownerReference` → `.Owns()` 永不触发、篡改不自愈、
    VG 删除后 CM 残留；② CM 按 node 唯一却由单 VG 渲染 → 同节点多 VG 互相覆盖；③ device-class 名取 tier →
    per-disk 同 tier 重名。现改为**一节点一份聚合渲染**（TopoLVM 原生形态）：`device-classes` 数组按名稳定升序、
    仅含 `vgExists=true`、新增 `spec.deviceClassName` 显式命名、重名返回 error 不写非法配置；CM 持有每个同节点
    VG 的**非 controller** ownerRef，控制器改用 `Owns(&ConfigMap{}, builder.MatchEveryOwner)`
    （v0.20 默认 `OnlyControllerOwner()`，不传则多 owner 不触发），GC 自然回收孤儿。
    决策与业界参考见 `docs/poc/adr/005-lvmd-config-aggregation.md`；单测
    `TestAggregateLVMDConfig_*` / `TestLvmdConfigReconciler_*` 覆盖排序、过滤、重名、聚合、收敛、漂移。
  - **kind 真实集群验证（`scripts/m15-integration.sh verify-lvmd`，全 PASS）**：同节点两 VG 聚合为两个
    device-class 且 data<metadata 升序、两个非 controller ownerRef；篡改后 **1s** 自愈（owner watch 生效）；
    `deviceClassName=cold` 生效；删一个 VG **2s** 内收敛；删最后一个 VG 后 **2s** CM 被 GC。
    仍待真实 lvmd 环境验证：`device-classes: []`（节点尚无 VG）与缺失 class 的热加载行为。
  - **已决策并修复（ADR-006，2026-10-29）**：原实现 `StorageTask` 无 ownerReference、无 TTL 清理，删除 NodeVG 后
    残留（实测 4 条孤儿），且存在对已删除对象继续执行 wipe/vgcreate 的误执行风险。现改为任务持有拥有者的
    **非 controller** ownerReference（`controller=false`、`blockOwnerDeletion=false`），由 K8s GC 回收；
    未采用 TTL-after-finished（稳定任务名 + desired-state 重建会抖动，且审计走 Event + audit log 而非任务对象）。
    决策与备选方案见 `docs/poc/adr/006-storagetask-lifecycle.md`；单测 `TestEnsureStorageTask_*` 覆盖
    NodeVG/NodeDisk 归属、非 controller、无 UID 不写引用、幂等。kind 实测（`verify-taskgc`）：
    ownerReference UID 与 NodeVG 一致，删除 NodeVG 后任务数秒内被 GC。
    遗留（未实现，不假装完成）：`StorageTaskSpec.TTL`（"过期不执行"）在 Go/Rust 两侧均未被消费，属执行窗口
    控制而非保留期，需 agent 侧实现。
  - **已定案并修复（ADR-005 补遗，2026-10-29，源码证据）**：上游 TopoLVM `ValidateDeviceClasses` 对空列表
    直接返回错误 `should have at least one device-class`，且在 lvmd 启动路径上 `return err`；lvmd 自身无配置
    热加载（仅 SIGTERM/Interrupt，`loadConfFile` 只在启动时调用）。原实现「无可用 VG 时写
    `device-classes: []`」等于下发 lvmd 无法启动的配置。现改为：聚合无可用 class 时返回 `ok=false`，控制器
    **删除托管 ConfigMap**（仅限带 `hlvm.dev/managed` 注解），使「CM 存在」等价于「该节点可服务」。
    `verify-lvmd` 新增断言：`vgExists=false` 窗口期不写空列表、已有 CM 被撤销、恢复后重建。
    **kind 内以真实 lvmd 0.42.0 运行验证**：配置 `device-classes: []` → 加载后立即
    `Error: should have at least one device-class`，exitCode=1（运行态确认，非仅源码推断）。
    仍待真实环境验证：删除 CM 后 agent/lvmd 的实际表现、「class 指向不存在 VG」的运行态行为
    （kind 内 lvmd 因 nsenter 权限在 ListVolumeGroups 阶段即退出）、配置热加载。
  - **TTL 已落地（ADR-006 补遗，2026-10-29）**：`spec.ttl` 对齐 K8s Job `activeDeadlineSeconds`——自
    `creationTimestamp` 起算，仅拦截尚未开始（phase 空/Pending）的任务；到期标 `Failed`
    （`DeadlineExceeded:` 前缀）并保留对象、不自动重试；非法/`<=0` 失败关闭；`Running`/`Unknown` 不改写
    （单写者）。kind 实测（`verify-ttl`）：`ttl=2s` 3s 内标 Failed、`ttl=1h` 8s 内未改写、`ttl=nonsense`
    失败关闭。**残余竞态**：agent 轮询 list 可能在控制面标记前取走任务；彻底关闭需 agent 执行前复核
    `creationTimestamp + ttl`，当前环境无 Rust 工具链，未写入 agent 代码（不假装完成）。
  - **本轮验证暴露并修复 2 个部署期缺陷**（envtest 与单测均不覆盖，仅真实集群可暴露）：
    ① ClusterRole 缺 `storagetasks/status` 更新 → TTL 标记与结果回写持续 403，任务永远 Pending；
    ② StorageTask CRD 缺 `subresources.status` → `/status` 404，**agent 的 patch_status 回执链路实际不可用**
    （此前无 agent、无状态写入故未暴露）。均已在 `config/rbac/role.yaml` 与 CRD 修复，并新增
    `internal/controller/deploy_manifests_test.go` 做清单级防回归。

## 5. add-backup-restore（活跃，2 项）

- [ ] 5.1 2.2 块/文件系统一致性验证用例（有 pre-hook vs 无 pre-hook 的恢复结果对比）—— 移交集成验证
- [ ] 5.2 5.1 完整闭环演练：备份 → 删除 PVC/PV → 恢复 → 应用侧数据校验 → 记录 RTO/RPO —— 移交集成验证（需测试集群 + Velero）

## 6. add-hardening-rollout（活跃，5 项）

- [ ] 6.1 1.4 演练报告与问题闭环（**移交集成**：需测试集群执行并归档报告）
- [ ] 6.2 2.2 报告评审通过（**移交集成**：需测试集群 fio 实测 + 评审）
- [ ] 6.3 5.2 灰度期问题闭环与放量决策（**移交集成**：需真实灰度执行）
- [ ] 6.4 5.3 上线评审门禁（**移交集成**：需全部门禁逐项通过）
- [ ] 6.5 V.1-b 全部演练与评审通过形成上线报告（**移交集成**）

## 7. add-poc-decision-gate（活跃，5 项）

- [ ] 7.1 实测执行（POC 项一）—— 移交集成
- [ ] 7.2 实测执行（POC 项二）—— 移交集成
- [ ] 7.3 实测与结论 —— 移交集成
- [ ] 7.4 实测与评审 —— 移交集成
- [ ] 7.5 V.1-b 决策门评审通过（POC 报告 + ADR 评审）—— 移交集成

## 验证回路

- [ ] V.1 前置条件 1.1–1.5 全部就绪
- [ ] V.2 19 项集成验证在测试集群逐项通过，并回填各源变更 `tasks.md` 的对应 `[ ]` 项（活跃变更 + 已归档变更 archive tasks.md）
- [ ] V.3 本变更 `tasks.md` 全绿后 `openspec archive m15-integration` 收口
