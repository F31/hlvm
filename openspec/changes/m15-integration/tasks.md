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
    PV/PVC/ConfigMap/Pod/Namespace 读取与 Node patch → 补齐。

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
