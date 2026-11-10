# 变更日志

本文件记录 hlvm 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **0.x 阶段说明**：1.0 之前 CRD schema 与可选字段仍可能不兼容变更；每次升级前先读对应版本的
> 「升级注意」。`preview` 后缀表示**未通过真实硬件与生产环境验证**，不得用于生产。

## [Unreleased]

### 集成验证 / 修复

- `verify-conversion` / `verify-cert-rotation` / `verify-storage-migration` 现在统一 apply
  `03b~03f` 五份双版本清单，并在收尾恢复 **5 份** `bases` 单版本 CRD（此前只 apply/恢复 `03b`，
  另外 4 个 Kind 的 conversion 链路从未在集群里验证过）
- `verify-conversion` 新增 4 个 Kind 的双向转换往返 + 列表转换断言，以及 5 个 CRD 的
  `conversion.strategy` / caBundle 接线断言；NodeDisk 原有 12 条结构映射深度断言保持不变
- `verify-cert-rotation` / `verify-storage-migration` 各补一轮 4 Kind 的 conversion smoke
  （v1alpha1 写 → v1beta1 读回，前置先等齐 5 个 CRD 的 caBundle），并在两个相位的清理路径
  按 label 兜底删探针对象；避免「只验 NodeDisk 就宣布 5 份清单全绿」
- 修复 delete-protector 准入规则仍监听 `v1alpha1` DELETE 的问题：消费者已全迁 v1beta1、
  裸资源名解析到 v1beta1，旧规则会让 `NodeVG` / `StorageNodeOps` 的删除保护被静默绕过。
  **已知边界**：规则只列 `v1beta1`；双版本叠加期间老客户端显式用 `v1alpha1` 发起 DELETE
  不受保护——解码侧 `nodeNameOf` 只识别 v1beta1 类型，把 v1alpha1 列进规则反而会静默跳过

## [0.1.0-preview.2] - 2026-11-10

第二个技术预览版：把 `main` 上自 preview.1 以来的 7 个提交收敛为**可复现的显式版本标签**，
重点是 CRD 版本化覆盖与集成脚手架的可信度。**仍未在真实 LV 硬件与生产集群验证，禁止用于生产。**
定位与完整风险清单见 `docs/release-notes/v0.1.0-preview.2.md`。

### 新增 / 变更

**CRD 版本化（5 个 Kind 全部双版本）**
- `NodeVG` 升级为 v1beta1(storage) + v1alpha1(served)，补 hub/spoke 双向转换与往返测试
- `StorageTask` / `StorageNodeOps` / `ThinPoolPolicy` 同样双版本化；新增 `03d/03e/03f` 三份
  hardening 叠加清单（必须在 conversion webhook 就绪后 apply）
- 全部 Go 消费者（控制器 / webhook / dashboard）与 Rust agent 迁到 **v1beta1**，
  conversion 不再位于控制面关键路径；`AddToScheme` 仍双版本注册
- `crd-conversion` 启动自检覆盖全部 5 个双版本 Kind；新增 9 个 conversion 往返测试

**集成脚手架可信度**
- 新增 `preflight` 相位：ssh 可达性 / 私有镜像凭据 / 云盘 / udev / 造盘钩子的只读体检；
  **结构性缺失判 FAIL、能力缺失只 WARN**；`real` 模式 `IMG_TAG=latest` 判 FAIL
- 新增单节点模式 `M15_SINGLE_NODE=1`（显式开关，禁止因「少一台机器」静默降级）；
  修 `all` 在全新集群上 `check → preflight → bootstrap` 必挂的顺序缺陷
- `verify-topology-scale` 跨节点拓扑 / 容量账；修正 8 类脚手架静默失败（见 runbook §10.12）
- **修复版本化遗留的集成回归**：7 处普通相位仍以 `v1alpha1` 创建 `NodeVG` / `StorageTask`、
  1 处 `ownerReference.apiVersion` 断言仍期望 `v1alpha1`；在 `bases` 单版本 v1beta1 下会让
  `all` 在 `verify-admission` 直接失败（conversion 相位里刻意使用 v1alpha1 的断言保持不变）

**Agent 与调度**
- `/dev/disk/by-id` 多别名按前缀优先级择优（`virtio- > scsi- > nvme- > wwn- > ata-`），
  消除同一块盘两次枚举得到不同设备 ID 导致的身份漂移
- 控制面三组件改用 `topologySpreadConstraints` 软约束；PDB 改为 `maxUnavailable: 1`，
  随副本数缩放，避免 R=2 时 `minAvailable: 2` 让 `kubectl drain` 永久阻塞

### 已知限制（相对 preview.1 的变化）

- preview.1「已知限制」第 3 条「4 个 Kind 仍为 v1alpha1」**本版已消除**；其余各条仍未闭合
- 5 个 Kind 的 v1alpha1 兼容层与 conversion webhook **仅在 NodeDisk 上做过集群验收**：
  集成脚本的 `verify-conversion` 只 apply `03b`，`03c~03f` 尚未被任何相位消费
- Go 侧 K8s 客户端版本错配：`api`/`apimachinery` v0.33.0 但 `client-go`/
  `apiextensions-apiserver` v0.32.1；Rust 侧 `k8s-openapi 0.28 / v1_36`；实测集群 1.36

### 升级注意

- 从 preview.1 升级时，先确认 `config/hardening/03-crd-conversion.yaml` 的 webhook 就绪，
  再 apply `03b~03f`；顺序反了会出现「CRD 要求转换、webhook 还不存在」的不可用窗口
- 消费者已全迁 v1beta1；显式使用 v1alpha1 的老客户端现在依赖 conversion webhook 的可用性
- 镜像请使用显式版本标签 `ghcr.io/f31/hlvm/<component>:v0.1.0-preview.2`，不要引用 `:latest`

## [0.1.0-preview.1] - 2026-11-02

首个技术预览版：控制面 + 节点 Agent 的可部署形态已经闭环，可在 kind 1.36 上完整复现，
**未在真实 LV 硬件与生产集群验证**。定位与限制见 `docs/release-notes/v0.1.0-preview.1.md`。

### 新增

**CRD 与控制面**
- 5 个 CRD：`NodeDisk` / `NodeVG` / `StorageTask` / `StorageNodeOps` / `ThinPoolPolicy`
- 磁盘/VG 控制器对账：纳管状态机、Stale 条件、删盘保护（pendingOps）、孤儿 GC
- `NodeDisk` 收敛到 **v1beta1 存储版本**；v1alpha1 作为 served 版本经 conversion webhook 转换
- 容量治理：data% ≥85 或 metadata% ≥75 → `Locked` + 节点 `<tier>-locked=true` 标签，降压滞回自动解锁
- 生命周期运维：Node NotReady 超阈值自动创建 `auto-isolate-<node>`（isolate）+ Stale=True
- 只读大盘（`GET /`）与纳管入口（`POST /api/v1/adopt`，仅 Candidate、双确认、生成待审批 StorageTask）
- 准入控制：VAP 静态层（K8s 1.34+ 修正 `validationActions` 与 CEL null 防御）+ mutating webhook 动态层
- StorageTask 执行窗口 `spec.ttl`；归属交 K8s GC；lvmd ConfigMap 按节点聚合渲染

**节点 Agent（Rust，单二进制）**
- 4 种模式：`agent` / `exporter` / `device-plugin` / `doctor`
- 磁盘发现、SMART/NVMe 健康、预检规则引擎、LVM 写路径（唯一写者）、低频状态写回
- 读写分离部署：exporter 独立非特权 DaemonSet；每盘一个 collector Pod 承担 SMART 采集
- **device plugin**：按盘暴露 `hlvm.io/disk`，非特权 Pod 可按盘授权（kubelet 重启后自愈重注册）
- 版本可追溯：启动日志打印 Cargo 版本与构建提交号

**可观测性**
- Prometheus 指标（容量/告警/心跳）+ 告警评估；指标口径与阈值见 `openspec/specs/observability`
- CRD conversion / 证书轮换 / storedVersions 切换与回滚的演练脚本

**交付与验证**
- 集成脚手架 `scripts/m15-integration.sh`：23 个相位、约 120 条断言，覆盖 bootstrap → 构建 →
  准入 → 控制器 → agent → 热插拔 → 拓扑容量账 → 备份
- `scripts/real-cluster/`：真实集群（kubeadm + 云主机）部署脚本与只读云盘预检
- 适配层 `M15_TARGET=kind|real`：节点执行、镜像加载、设备注入、测试节点选择等 7 个抽象
- CI：Go（build/vet/test/envtest）、Rust（test/release build）、4 个容器镜像、tag 发布流水线

### 已知限制

- 真实 LV / thinpool / `/dev/disk/by-id`（udev）路径**未验证**；kind 无 udev，只覆盖 `dev-<name>` 回退分支
- Velero 灾备闭环**未验证**（本地 kind 无法拉取所需镜像，相位 SKIP）
- `NodeVG` / `StorageTask` / `StorageNodeOps` / `ThinPoolPolicy` 仍为 **v1alpha1**，尚未版本化
- 节点扩缩容与调度器重平衡（原 6.5b-2）未验证
- 灰度放量与上线评审门禁未执行（hardening 5.2/5.3、poc V.1-b）

### 升级注意

首个版本，无升级路径。镜像请使用显式版本标签（`ghcr.io/f31/hlvm/<component>:v0.1.0-preview.1`），
不要在生产链路上引用 `:latest`。
