> **M14 收尾状态（2026-10-29）**：本变更本地代码与 envtest 验收已收口；下方未勾选项均依赖测试集群 / 真实 LV 硬件 / Velero / cert-manager + Dockerfile / 评审灰度，属本机开发环境范围外，已如实递延至后续集成里程碑（建议 M15），**不标记为完成**。完整说明见 `docs/M14-closure.md`。

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
- [x] 3.1 CRD 版本化**框架** → `config/hardening/03-crd-conversion.yaml`（v1alpha1+v1beta1 stub + conversion webhook 骨架）
  - 诚实边界（2026-10-30 审计）：交付的仅骨架。`control-plane/cmd` 下无 `crd-conversion` 入口，
    CI 不构建 `ghcr.io/f31/hlvm/crd-conversion` 镜像，v1beta1 未 `served`，主 CRD 无 conversion 配置。
    清单顶部已加「请勿 apply」警告：apply 会覆盖主 CRD 并把 conversion 指向不存在的 webhook，
    导致 NodeDisk 读写失败。此前描述只写「框架」但未点明镜像不存在，易被当成可部署清单。
- [x] 3.1b conversion webhook 服务**实现**（spec「升级与回滚能力」要求的能力本体，2026-10-30 完成）：
  - 服务端：`cmd/crd-conversion`（独立 HTTPS 转换服务，不用 manager——不 watch 集群、无 client，
    故障面更小）。启动即 `conversion.IsConvertible` 自检，hub/spoke 缺失直接退出，
    避免部署出「Ready 但转换全失败」的 webhook。证书用 certwatcher 热加载，支持 cert-manager 轮换。
  - API：新增 `api/v1beta1`（NodeDisk 试点）。**v1alpha1 仍是存储版本，v1beta1 为 served 非存储**，
    把爆炸半径压到「只用 v1beta1 的客户端」——webhook 挂了 v1alpha1 读路径不经过它，控制器不受影响。
  - 字段映射：v1alpha1 `spec.deviceRef`（string）⇄ v1beta1 `spec.device.path`（object），
    空串映射为 nil（往返 JSON 等价）。列表同样实现 hub/spoke（apiserver 对 List 是整体下发）。
  - 清单：`config/hardening/03-crd-conversion.yaml`（工作负载/证书）+ `03b-nodedisk-dual-version.yaml`
    （双版本 CRD + conversion 接线，`cert-manager.io/inject-ca-from` 注入 caBundle）。
    骨架期的「请勿 apply」警告已移除——现在可部署，但**必须按顺序**（先服务就绪，再开转换）。
  - CI：`images` job 增加 `CMD_NAME=crd-conversion` 构建推送；`go build ./...` 覆盖新入口。
  - 验证：单测 4 条（转换往返无损 + JSON 视角全字段等价 + 空设备 + 列表）；
    `verify-conversion` **10 断言**（2026-10-30，WSL kind 1.36 实测全 PASS）：服务就绪 / 证书签发 /
    caBundle 注入 / `strategy=Webhook` / **preferredVersion=v1beta1** / 正向映射 / v1beta1 视图不含
    deviceRef / 反向写入回读 / 列表条目一致 / **webhook 下线后 v1beta1 失败而 v1alpha1 仍可读** /
    恢复后自愈。
  - 仍未覆盖（诚实边界）：**storedVersions 切换未做**（需迁移方案：先确保所有写方都已迁移、
    再切 storage=true、最后从 storedVersions 移除 v1alpha1；切换后回滚要能做反向转换）。
    其余 4 个 Kind 仍只有 v1alpha1，按同一模式推广时要把 `03b` 的 schema 与 hub/spoke 复制过去。
    轮换只验证了「cert-manager 会续签 + 进程会热加载」，没有做真实过期演练。
- [x] 3.2 agent 滚动升级 + 排空 → `config/hardening/02-agent-rollout.yaml`（maxUnavailable=1 + 排空约定）
- [x] 3.3 TopoLVM 升级回滚 + 兼容矩阵 → `config/hardening/version-matrix.md`
- [x] 3.4 任一组件可回滚验证 → `version-matrix.md` §3

### 4. 安全基线
- [x] 4.1 agent 特权最小化 + PSA + seccomp + 命令白名单 → `config/hardening/00-namespace-psa.yaml` + 改进 `agent/config/daemonset-agent.yaml`（privileged→false，精确 capability + drop ALL + seccomp；命令白名单 ConfigMap 声明）
  - **已回退（2026-10-30 集群实测）**：`privileged: false` + drop ALL + add
    `SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO` 时，容器内 **uid=0 仍无法读写块设备**
    （`dd`/`blkid`/`wipefs` 全部 `Operation not permitted`）。根因是 runc 的 **device cgroup**
    过滤器而非 capability——非特权 Pod 的 device allowlist 为空，加 capability 绕不过。
    该 Agent 是平台唯一 PV/VG 写路径，读不到设备等于 wipe/pvcreate 与签名预检全部失效
    （更糟的是把「读失败」当成「干净盘」）。现按 `openspec/specs/node-agent`「agent 特权、读写」
    回退为 `privileged: true`（`readOnlyRootFilesystem: false`，因 LVM 需写 `/etc/lvm`、`/run/lvm`），
    由 `internal/controller/deploy_manifests_test.go::TestAgentDaemonSetIsPrivileged` 防回归。
  - **补充（2026-10-30，同日）**：非特权的替代路径已落地——磁盘设备插件
    `hlvm.io/disk`（`--mode=device-plugin`，见 `openspec/changes/add-disk-device-plugin/`），
    非特权 Pod 可按盘获得访问权并已在 kind 验证（分配后可读、未分配仍 EPERM）。
    但**本项仍为「已回退」状态**：agent 需要本节点**全部**盘做 wipe/pvcreate，而扩展资源只能表达
    「申请 N 块」。要真正满足本项，还需把 agent 的盘访问改为「有界集合」模型（未做）。
  - **同类冲突（已收敛，采集侧非特权）**：exporter 按 spec 必须非特权，但同一 device cgroup 限制使其
    无法 `smartctl`/`nvme` 打开设备 → SMART 类指标在真实环境缺失。已选 ① 并落地：改为「每盘一个
    collector Pod」（`disk_collector_controller.go` + `HLVM_EXPORTER_DEVICE=auto`，只保留 uid0 +
    `SYS_RAWIO`，`privileged:false`、不挂宿主 `/dev`），`verify-collector` 7 断言在 kind 实测通过。
    边界：kind 盘不支持 SMART，健康值走回退 `0`；真实盘数值待复验。旧 `config/exporter/daemonset.yaml`
    未删除，也不在自动化路径里（部署它会与 collector 重复采集）。
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
