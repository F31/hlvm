# 变更日志

本文件记录 hlvm 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **0.x 阶段说明**：1.0 之前 CRD schema 与可选字段仍可能不兼容变更；每次升级前先读对应版本的
> 「升级注意」。`preview` 后缀表示**未通过真实硬件与生产环境验证**，不得用于生产。

## [Unreleased]

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
