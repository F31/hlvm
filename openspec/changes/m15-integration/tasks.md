# Tasks: m15-integration

> M15 集成里程碑跟踪变更。汇总 M14 收口时递延的 **19 项集成验证需求**（原分布于 6 个 M14 变更；observability / capacity-governance 已归档，其余 4 个仍活跃）。本变更不引入新 spec 能力，仅作跨能力集成验证的协调与跟踪载体。前置条件与诚实边界见 `proposal.md` 与 `docs/M14-closure.md`。
>
> 验收通过后，各 `[ ]` 项需回填至源变更 `tasks.md`：活跃变更（admission-scheduling / backup-restore / hardening-rollout / poc-decision-gate）原地 tick；已归档变更在其 `openspec/changes/archive/2026-10-29-*/tasks.md` 中 tick。
>
> 集成工具：`scripts/m15-integration.sh`（`check` / `bootstrap` / `build` / `verify-admission` /
> `verify-controller` / `verify-lvmd` / `verify-taskgc` / `verify-ttl` / `verify-agent` / `all`）；诚实分流见 `docs/m15-integration-runbook.md`（§A kind 可自动化 vs §B 必须真实 LV / Velero / 评审灰度）。

## 1. 前置条件（M15 启动门槛）

- [ ] 1.1 测试集群就绪（K8s ≥ 1.36，与 envtest 版本对齐消版本差）
  - 进展（2026-10-29）：**envtest 版本差已消除**——`ENVTEST_K8S_VERSION` 由 1.33.0 升到 1.36.2
    （与 kind `kindest/node:v1.36.1` 同 minor），三个 envtest 全 PASS，并接入 CI 门禁
    （`make test-envtest`，此前 CI 完全不跑 envtest）。升级过程暴露并修复 2 类测试缺陷：
    ① controller 名称唯一性检查是**进程级全局集合**，多 envtest 同进程注册同名 controller 必失败
    （测试侧 `newEnvtestManager` 关闭该校验）；② 测试用缓存 client 写 status 触发 `not found` /
    `the object has been modified`（改直连 client + `RetryOnConflict`）。
  - 仍待：M15 要求的**目标测试集群**（真实硬件环境）尚未提供；本地 kind 仅为自动化验证载体。
- [ ] 1.2 真实 LV 硬件或可控仿真（thinpool 打满、拔盘、SMART 上报）
- [ ] 1.3 Velero 部署可用（backup-restore 5.1 闭环依赖）
- [x] 1.4 cert-manager + control-plane Dockerfile（admission 4.3 动态层 mutating webhook 的证书机制）
  - 已完成（2026-10-29 kind 实测）：Dockerfile 在 WSL docker 构建并 `kind load`；cert-manager v1.17.2
    三组件 Ready；Certificate 签发与 caBundle 注入正常；webhook（3/3）与 controller（2/2）均 Running；
    admission 4.3 注入链路验证 PASS（详见 §4.1）。
  - **生产默认运行态镜像已验证**：`gcr.io/distroless/static:nonroot`（sha256:18f4cc26…）经代理拉取成功，
    两个镜像均以 distroless 构建（`User=65532:65532`、`Entrypoint=/app`、14.3MB，对比 golang 基础镜像 1.31GB，
    镜像内无 shell）；`kind load` 后滚动更新成功，distroless 运行态下 `verify-ttl`(5) / `verify-controller`(4) /
    `verify-lvmd`(10) / `verify-taskgc`(6) / `verify-admission` **全部 PASS**。
  - **CI 已确认（2026-10-30）**：run `40888920900`（HEAD `1ffb629`）4 个 job 全 `success` ——
    `Go (control-plane)` / `Rust (agent)` / `Container images` / `Ready`。其中 Rust job
    即 `cargo test --all-targets` 的 CI 证据（agent 侧 TTL 复核 11 例单测），images job 在 main push 上
    `push: true`，两镜像已推送 GHCR。此前「本机无 `gh` 无法确认」的记录作废：仓库 Actions 可匿名只读
    （`curl api.github.com`，Windows 侧需 `--ssl-no-revoke`，否则代理下 schannel 报
    `CRYPT_E_REVOCATION_OFFLINE` 易被误判为代理不通）。
  - **补齐 agent 镜像构建（2026-10-30）**：核对发现 CI images job 此前**只**构建 controller/webhook，
    而 `agent/config/daemonset-agent.yaml` 与 exporter 清单都引用 agent 镜像 —— 该镜像从未被构建/推送，
    真实集群部署必然 `ImagePullBackOff`（本机无 Rust 链接器也无法本地补建）。现已：rust job 上传
    `hlvm-agent-bin` artifact（`if-no-files-found: error`），images job `needs: [go, rust]` 后下载并
    用 `agent/Dockerfile` 构建推送 `ghcr.io/f31/hlvm/storage-agent:latest`；同时统一 exporter 清单里
    的旧名 `ghcr.io/f31/hlvm/agent:latest`（原标注「占位」）为 `storage-agent`。
  - **CI 实测通过（2026-10-30，run `40970587925` / `45b7ea4`）**：4 job 全 success；`Rust (agent)` 的
    `Upload agent binary`、`Container images` 的 `Download agent binary` 与三个 `Build & push`
    （`storage-controller` / `storage-webhook` / **`storage-agent`**）均 success，即 agent 镜像已实际推送。
    因包为私有，无法用匿名 token 二次复核包内容，此处以 push step 成功为准。
  - 余项（不阻塞本项）：GHCR 包为**私有**（匿名 token 端点 401），真实集群部署须注入 `imagePullSecret`
    （见 runbook §6）；目标测试集群仍需自行安装 cert-manager 并注入 CA。
- [ ] 1.5 评审 / 灰度流程就位（hardening-rollout、poc-decision-gate）
- [x] 1.6 节点 Agent 真机部署验证（本轮补充，不在原 19 项内）
  - 背景：Agent **此前从未在集群中运行过**（镜像未构建、SA 错配、节点名未注入），三类缺陷因此长期不可见。
    `verify-agent` 首次真跑逐条暴露并修复（2026-10-30）：
    ① `hlvm-agent` SA 在 `kube-system`、DaemonSet 在 `hlvm-system` → Pod 因
       `serviceaccount "hlvm-agent" not found` 无法创建；已统一到 `hlvm-system`
       （`v2-chaos-kind.yaml` 同步）；
    ② 未读 Downward API 注入的 `HLVM_NODE_NAME`/`NODE_NAME`，缺省回退 `"unknown"`；而任务过滤是
       `spec.nodeName == node` → Agent 表面健康却**永不执行任何任务**。现按 命令行 > `HLVM_NODE_NAME`
       > `NODE_NAME` 解析，缺失即失败关闭；
    ③ `lsblk -J -b` 的 `size` 为 JSON 数字，模型却是 `Option<String>` → discovery 整体解析失败。
       现兼容数字/字符串（附 3 例单测）。
  - 实测（`verify-agent`，6 断言全 PASS）：Pod 就绪 / 节点名注入正确 / kube 客户端与两条回写循环建立 /
    discovery 无错 / agent 自主回写 StorageTask 状态（`phase=Failed`，`message=No such file or directory
    (os error 2)`，证明 `storagetasks/status` 写权限可用）/ NodeDisk 观测写回（`health=healthy`，21s）。
  - **第二批缺陷（2026-10-30 同日暴露，均为「静态看起来对、真机跑不通」）**：
    ④ **「特权最小化」实际废掉了数据面**：按 hardening 4.1 改为 `privileged: false` + drop ALL +
      add `SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO` 后，容器内 uid=0 **仍读不了块设备**（`dd if=/dev/loop77`、
      `blkid`、`wipefs` 全部 `Operation not permitted`）。根因是 runc 的 **device cgroup** 过滤器，与
      capability 无关：非特权 Pod 的 device allowlist 为空。结论是 wipe/pvcreate（唯一写路径）与签名预检
      在生产环境必然失败。已按 spec（agent 特权、读写）回退 `privileged: true`，并加清单级防回归
      `deploy_manifests_test.go::TestAgentDaemonSetIsPrivileged`（负向验证：改回 false 即报错）。
      非特权的替代路径只有 device plugin 按盘分配（未实现）。
    ⑤ **`occupiedBy` 恒 `none`，签名规则从未生效**：观测路径硬编码 `occupied_by: None` / `is_pv: false` /
      `holders: []`；同时签名探测调 `blkid --json`——**blkid 没有 `--json` 选项**（那是 lsblk 的），
      命令必然失败 ⇒「存在 fs/LVM/md 签名即拦截纳管」在真实路径上从未执行（单测只喂解析函数，掩盖了它）。
      现改为 `blkid -o export` 取签名、lsblk `TYPE/FSTYPE` 辅助、`pvs` 确认 PV，按 CRD 枚举写
      `filesystem|lvm-pv|md|mpath|holder|none`；探测失败写 `unknown` 并失败关闭（关键坑：blkid 的
      EPERM 与「无签名」**同为退出码 2**，故「2 且 stderr 非空」判为失败）。跨语言枚举漂移由
      `occupiedby_enum_test.go` 直接比对 Go 枚举与 Rust 常量（负向验证有效）。
  - 断言增至 **7** 条（新增：节点内建 ext4 loop 设备 → 要求 `occupiedBy=filesystem` 且 phase 不推进到
    `PreChecked`）。全链 `all` 复跑：8 阶段 **32 PASS / 0 FAIL**；`cargo test --all-targets` 116 passed、
    `go vet/test` 全绿。
  - 未解决（开放决策，已记录不擅改）：exporter 按 spec 必须非特权，而同一 device cgroup 限制使其读不到
    SMART（`smartctl`/`nvme` 需打开设备）→ 真实环境 SMART 指标缺失。三条路：接受缺失 / 允许 exporter 特权 /
    引入 device plugin，需在 M15 评审时定。
  - 顺带修复：`agent/config/daemonset-agent.yaml` 中重复的 exporter DaemonSet 已删除（唯一来源为
    `control-plane/config/exporter/daemonset.yaml`），避免每节点跑两个 exporter。
  - 诚实边界：kind 无真实 LV，本项只验证「连 API / 按节点过滤 / 写回状态」，不覆盖 wipe、pvcreate 真实执行
    （需 1.2 硬件）；阶段结束会撤掉 DaemonSet（`verify-ttl` 依赖「无 agent」前提），不留常驻 Agent。

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
    失败关闭。**残余竞态已关闭（同日）**：agent 在执行前复核 `creationTimestamp + spec.ttl`
    （`agent/src/common/ttl.rs` + `reporter::kube_rw::expired_reason`），命中即回写 `Failed` 并跳过执行器；
    语义与控制面逐条对齐（仅拦未开始任务、非法 TTL/缺时间戳失败关闭）。`cargo test` 99 项通过（新增 11 例），
    `cargo fmt --check` 通过；CI `rust` job 以 `cargo test --all-targets` 作为门禁。仍未覆盖两侧时钟偏差。
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
