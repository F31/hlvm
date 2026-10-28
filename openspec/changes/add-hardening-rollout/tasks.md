# Tasks: add-hardening-rollout

## M12（控制面硬化代码，已交付）

> 接上审计缺口：`RecordAuditEvent` 此前已定义但从未接线。给 `StorageTaskReconciler` 加
> `EventRecorder`，在**破坏性任务（wipe/secure-erase、vgreduce）完成**时写审计事件
> （operator 取自 `hlvm.storage/operator` 标签，缺省 system；method=`wipe:<policy>`/`vgreduce:<disks>`）。
> 3 个 fake-client 单测覆盖擦除/退役审计与「非破坏性不审计」。build/vet/test 全绿（提交 b193259）。

## M12b（部署与策略清单，已交付）

> 安全基线/升级/灰度/混沌/性能/数据安全策略全部**结构化 + 文档化交付**；需测试集群执行的演练、
> 实测、放量标注「移交集成」，不阻塞本里程碑。

### 1. 混沌演练（上线门禁）
- [x] 1.1 注入工具与观察指标 → `config/hardening/runbook-chaos.md`（拔盘/断网/kill/etcd 抖动 + 观察指标表）
- [x] 1.2 数据面独立性验证脚本 → `runbook-chaos.md` §2（断言 + 验证步骤）
- [x] 1.3 剧本回放（§9.1–9.4）→ `runbook-chaos.md` §3
- [ ] 1.4 演练报告与问题闭环（**移交集成**：需测试集群执行并归档报告）

### 2. 性能基线报告
- [x] 2.1 报告模板 → `config/hardening/perf-baseline-report.md`（fio 矩阵 / p99 / 写损耗 / dmeventd 时延）
- [ ] 2.2 报告评审通过（**移交集成**：需测试集群 fio 实测 + 评审）

### 3. 升级与回滚
- [x] 3.1 CRD 版本化框架 → `config/hardening/03-crd-conversion.yaml`（v1alpha1+v1beta1 stub + conversion webhook 骨架）
- [x] 3.2 agent 滚动升级 + 排空 → `config/hardening/02-agent-rollout.yaml`（maxUnavailable=1 + 排空约定）
- [x] 3.3 TopoLVM 升级回滚 + 兼容矩阵 → `config/hardening/version-matrix.md`
- [x] 3.4 任一组件可回滚验证 → `version-matrix.md` §3

### 4. 安全基线
- [x] 4.1 agent 特权最小化 + PSA + seccomp + 命令白名单 → `config/hardening/00-namespace-psa.yaml` + 改进 `agent/config/daemonset-agent.yaml`（privileged→false，精确 capability + drop ALL + seccomp；命令白名单 ConfigMap 声明）
- [x] 4.2 镜像签名与 SBOM → `config/hardening/04-image-signing.yaml`（cosign sign/attest 流程 + ImagePolicyWebhook 骨架）
- [x] 4.3.1 控制面审计（M12 已落地）
- [x] 4.3.2 LUKS 评估结论 → `config/hardening/luks-evaluation.md`（POC/MVP 不默认，合规要求 + 密钥管理落地后启用）

### 5. 灰度上线
- [x] 5.1 灰度计划 → `config/hardening/canary-plan.md`（内部中间件→多副本→有状态，观察指标）
- [ ] 5.2 灰度期问题闭环与放量决策（**移交集成**：需真实灰度执行）
- [ ] 5.3 上线评审门禁（**移交集成**：需全部门禁逐项通过）

## 验证回路
- [x] V.1-a 全部结构化清单/文档产出；5 个 YAML 经 yaml.v3 解析校验全绿
- [ ] V.1-b 全部演练与评审通过形成上线报告（**移交集成**）
- [x] V.2 commit + push（里程碑闭环）
