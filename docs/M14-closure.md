# M14 收尾说明（2026-10-29）

## 1. 里程碑结论

**本地代码与 envtest 验收已收口；19 项集成类需求如实递延，不标记为完成。**

M14 在本机开发环境（Windows Go 1.27 + envtest 1.33、WSL2 kind 1.36）内能真实验证的代码与测试工作已全部完成并合入 `origin/main`。剩余 19 项 `[ ]` 全部依赖测试集群、真实 LV 硬件、Velero、cert-manager + Dockerfile 或评审灰度，超出本机范围。

**里程碑记账决策（用户授权）**：`add-lifecycle-ops`（18/18 全完成）与 `add-observability` / `add-capacity-governance`（仅剩集群类递延项）已 `openspec archive` 归档——代码实现记入基线 spec，但其 tasks.md 中的 `[ ]` 递延项随归档保留，**未做任何虚假 tick**。其余 4 个变更（admission-scheduling / backup-restore / hardening-rollout / poc-decision-gate）仍处 `changes/`，含 13 项 open，继续作为 M15 集成跟踪来源。

纪律原则：UI/状态必须诚实反映真实行为。归档不 tick——所有 19 项 `[ ]` 与"移交集成/依赖测试集群"注记全程保留，仅归属位置从 `changes/` 变为 `changes/archive/`。

## 2. 本机已真实验收的 M14 交付物

| 提交 | 内容 | 验收方式 |
|------|------|----------|
| `045f091` | add-crd-controller-skeleton V.2：envtest 真实 kube-apiserver+etcd 安装 5 个手写 CRD，启动 Disk/VG 控制器断言真实对账（Stale 条件 + 删盘保护 pendingOps）；Makefile `test-envtest` 目标 | envtest 1.33 真实集群 e2e，KUBEBUILDER_ASSETS 缺失自动 skip |
| `82264a9` | add-observability 3.2/3.3：只读大盘（`GET /` HTML）+ 纳管入口（`POST /api/v1/adopt`，仅 Candidate 可纳管、双确认、生成待审批 StorageTask） | `go build/vet/test` 全绿 + server_test |
| `78a3acf` | add-capacity-governance 4.2：data%≥85→Locked、metadata%≥75→Locked、节点打 `<tier>-locked=true`、降压滞回解锁摘除标签 | envtest 1.33 真实控制平面 |
| `a260f60` | add-lifecycle-ops 5.1/5.2：Node NotReady 超阈值→自动创建 `auto-isolate-<node>`(isolate) + Stale=True；注入假 LVReporter 模拟手工 lvcreate→StorageDrift 告警事件 | envtest 1.33 真实控制平面 |
| `5a2b452` | 修复 VAP 在 K8s 1.34+ 的 2 个真实缺陷（强制 `validationActions`；CEL 加 `has()` 防御 null），并在 kind 1.36 真实集群验收 add-admission-scheduling 4.2/4.3 静态层 | WSL2 kind 1.36 真实集群 |
| `c37ed67` | archive add-node-agent（M14 节点 Agent 里程碑，本地 kind 1.36 全链路 + kill -9 混沌 + Linux CI 87 passed） | 已归档 |
| `26d740b` / `f3e0161` | Agent（Rust）M14 真实集群暴露的 5 个 bug 修复 + WSL 原生构建统一 + CI 编译错误修复 | Linux CI cargo test 绿 |

> 注：envtest 用 1.33、kind 用 1.36，二者存在版本差。VAP 兼容性缺陷正是 kind 1.36 才暴露，说明动态层/集群项更易在版本差下漏检——这是 19 项递延而非伪造完成的另一客观理由。

## 3. 已归档变更（M14）

- `add-node-agent`（c37ed67）→ `openspec/changes/archive/2026-10-29-add-node-agent`（全完成）
- `add-crd-controller-skeleton`（045f091）→ `openspec/changes/archive/2026-10-29-add-crd-controller-skeleton`（全完成）
- `add-lifecycle-ops`（fa4439e）→ `openspec/changes/archive/2026-10-29-add-lifecycle-ops`（18/18 全完成，§5.1/5.2 经 envtest 验收）
- `add-observability`（本次归档）→ `openspec/changes/archive/2026-10-29-add-observability`（代码完成；**2 项 `[ ]` 递延**：4.1 告警延迟演练、4.2 指标口径核对，均依赖真实 LV 硬件）
- `add-capacity-governance`（本次归档）→ `openspec/changes/archive/2026-10-29-add-capacity-governance`（代码完成；**4 项 `[ ]` 递延**：2.2 灰度重载、3.1 dmeventd 验证、4.3 thinpool 打满演练、V.2 打满演练，均依赖测试集群）

## 4. 递延的 19 项集成需求（全部 `[ ]`，移交 M15 集成里程碑）

> 其中 **6 项**已随 `add-observability` / `add-capacity-governance` 归档，存于 `openspec/changes/archive/` 的 tasks.md；**13 项**仍存于 4 个活跃变更的 tasks.md。无论归属位置，均为未在本机验证的集成依赖项，**未 tick**。

### 4A. 已归档-递延（6 项）

#### add-observability（2 项，已归档）
| 项 | 依赖 |
|----|------|
| 4.1 告警延迟演练（thinpool 打满/拔盘/kill agent，Critical≤1min/Warning≤5min） | 真实 LV 硬件 |
| 4.2 指标口径核对（与 lvs/vgs 实测对账） | 真实 LV 硬件 |

#### add-capacity-governance（4 项，已归档）
| 项 | 依赖 |
|----|------|
| 2.2 变更灰度 + 滚动重载机制 | 测试集群 |
| 3.1 dmeventd 第一防线验证（autoextend ≤30s 扩容） | 测试集群 |
| 4.3 thinpool 打满演练验证锁与告警链路 | 测试集群 |
| V.2 打满演练通过 | 测试集群 |

### 4B. 仍活跃-递延（13 项）

#### add-admission-scheduling（1 项）
| 项 | 依赖 | 门禁 |
|----|------|------|
| 4.3 动态层 mutating webhook（节点 locked 调度排除已存在 Pod 不受影响） | mutating webhook server 部署 + cert-manager + 真实节点 locked 标签；control-plane 暂无 Dockerfile/证书机制 | 待测试集群 |

#### add-backup-restore（2 项）
| 项 | 依赖 |
|----|------|
| 2.2 块/文件系统一致性验证用例（pre-hook 对比） | 移交集成验证 |
| 5.1 完整闭环演练（备份→删 PVC/PV→恢复→数据校验→RTO/RPO） | 测试集群 + Velero |

#### add-hardening-rollout（5 项）
| 项 | 依赖 |
|----|------|
| 1.4 演练报告与问题闭环 | 移交集成（需测试集群执行并归档报告） |
| 2.2 报告评审通过（fio 实测 + 评审） | 移交集成 |
| 5.2 灰度期问题闭环与放量决策 | 需真实灰度执行 |
| 5.3 上线评审门禁 | 需全部门禁逐项通过 |
| V.1-b 全部演练与评审通过形成上线报告 | 移交集成 |

#### add-poc-decision-gate（5 项）
| 项 | 依赖 |
|----|------|
| 实测执行 ×2、实测与结论、实测与评审 | 移交集成 |
| V.1-b 决策门评审通过（POC 报告 + ADR 评审） | 移交集成 |

**合计：6（已归档）+ 13（活跃）= 19 项，全部为集成环境依赖项，本机无法真实验收。**

## 5. 风险登记

1. **版本差漏检**：envtest 1.33 vs 目标 1.36 差异已导致 VAP 漏检；动态调度层（4.3）与集群演练项在 1.33 下无法证明，生产 1.36+ 行为未被验证。
2. **真实 LV 路径未证**：capacity 4.3、observability 4.1/4.2 涉及 thinpool 打满、拔盘、指标口径，若不在集成环境验证，生产故障链路（锁/告警）未被证明。
3. **上线门禁未过**：hardening-rollout 5.3 / V.1-b 未通过，系统**不能视为 production-ready**。
4. **孤儿回收/漂移检测依赖 agent LV 上报**：orphan-gc、drift-detector 的 lvs 三方对账需 agent 实际运行后启用，目前仅纯函数与 CR/PV 侧路径验过。
5. **归档升基线但验证未毕**：`add-observability` / `add-capacity-governance` 已 `openspec archive`，其 spec 需求已合并进 `openspec/specs/` 基线（分别 +5 / +6 条 ADDED），反映"已实现"；但对应的集群验证项（observability 4.1/4.2、capacity 2.2/3.1/4.3/V.2）仍未在真实环境证明。读基线 spec 时需对照本文 §4A 的 `[ ]` 递延项，避免误读为已交付验收。

## 6. 后续集成里程碑（建议 M15）前置条件

要闭合上述 19 项，需具备：
- 测试集群（K8s ≥ 1.36，与 envtest 版本对齐以消版本差）；
- 真实 LV 硬件或可控仿真（thinpool 打满、拔盘、SMART）；
- Velero 部署（backup-restore 5.1）；
- cert-manager + control-plane Dockerfile（admission 4.3 动态层）；
- 评审/灰度流程（hardening、poc-decision-gate）。

建议将 13 项活跃 open 项（及归档变更中 6 项递延 open）整体纳入一个 `m15-integration` 变更跟踪，闭合后统一回填各归档 tasks.md 的 `[ ]` 项，避免状态歧义。
