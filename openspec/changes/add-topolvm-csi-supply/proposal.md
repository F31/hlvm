# Proposal: add-topolvm-csi-supply

> 状态：**立项待评审**。本 change 只登记范围、决策门与验收判据，**不含任何实现**；
> 代码与清单的实施须在本 proposal 获批后按 `tasks.md` 顺序单独推进。

## Why

设计 §1 把「CSI 复用上游 TopoLVM、差异化全部在旁路」定为核心决策，`docs/自研本地存储平台设计方案_v1.1_评审优化版.md`
§2.1 也逐条列了衔接点。但截至 `v0.1.0-preview.2`，仓库里**只有 A 链路**（设备插件
`hlvm.io/disk` 按块直通裸设备）通过 M15 验收，**B 链路**（PVC → LV 的容量供给）从未部署：
M15 里的 `topolvm-${LOCK_TIER}` 是验证 mutating webhook 的假 SC，脚本注释明写
「kind 内无 TopoLVM CSI，PVC 不会绑定」。这也是发布说明标注「禁止生产使用」的主因之一，
以及 hlvm → hnb 端到端供给（hnb 侧已用 TopoLVM 0.42.0 + `hnb-topolvm`）的真实前置。

2026-11-10 一次外部评审把「规划中的底座」误读成「已部署的底座」，据此提出
「生产直接走标准 TopoLVM 容量模式（配置即可）／真机降到 1 块盘／系统盘划分区复用」。
该误读的直接代价已由 `scripts/real-cluster/README.md` §7 与 CHANGELOG 修正，但它同时暴露了
**必须正式立项**的事实：这不是配置切换，而是补一条完整链路。

### 现状不是「从零起步」，而是「半接线」

| 已有（已验收） | 缺口（本 change 要补） |
|---|---|
| `internal/controller/lvmd_config_controller.go` + `lvmd_config.go`：由 NodeVG 渲染一节点一份 `hlmd-lvmd-<node>` ConfigMap 的 `lvmd.yaml`（device-class / volume-group / thin-pool / overprovision-ratio）；`verify-lvmd` 已验收聚合、排序、自愈、GC 语义 | **没有任何 lvmd 进程挂载或读取这份 ConfigMap**（全仓 yaml/agent 代码 0 命中）；`verify-lvmd` 用手工 patch `vgExists=true` 模拟 VG 建成，不验真实 lvmd |
| `admission_logic.go` 已按 `provisioner=topolvm.io` 识别平台 SC、`topolvm.io/device-class` 取 tier；`pod_mutator.go` 注入 locked nodeAffinity；`validatingadmissionpolicy.yaml` 已校验参数键 | 平台 SC 从未真实存在，PVC 不绑定，准入链路只在假对象上验过 |
| `lv_model.go` 定义 `ManagedLV` / `ActualLV` / 三方对账键，`drift.go` 有文本侧漂移检测 | `LVReporter` 默认 nil（lvs 一侧被跳过），且**没有**读 TopoLVM `LogicalVolume` CR 的客户端与 RBAC；无 `CSIStorageCapacity` 消费者 |
| `NodeVG.spec.deviceClassName > tier > "default"` 的映射、`ThinPoolPolicy`、StorageTask 写路径 | agent `lvm/mod.rs` 实际仍 `Command::new("lvm")` 调**容器内** lvm（镜像 `FROM kindest/node:v1.36.1`），§5.3 要求的 `chroot /host` + 共享 `/run/lock/lvm` 只留在注释与 `HLVM_HOST_WRAPPER` 预留 |

**结论**：`lvmd-config-ctrl` 的渲染侧已存在（`README.md` §7 早先写「无 lvmd-config-ctrl」不准确，
本轮已更正），真正缺的是上游 CSI 部署、**消费侧接线**、容量/对账观测，以及与 lvmd 共存的
宿主机 LVM 入口。立项范围必须据此收敛，否则会重复造已有能力。

### 可复用的已验证基线（hnb，不是猜测）

hnb 已跑通 TopoLVM 供给，物料在 `deploy/storage/topolvm/values-minimal.yaml`：

- 上游 Helm chart **17.3.0 / TopoLVM 0.42.0**，镜像 `ghcr.io/topolvm/topolvm-with-sidecar`
  固定 digest；仓库内**没有** vendor 化 chart/CRD/清单，全靠外部 chart 渲染。
- `lvmd.managed: false`、`node.lvmdEmbedded: true`，device-class `hnb` / VG `hnb-vg` / `spare-gb: 1`，
  **无 thin-pool 配置**；VG 由主机侧脚本 `scripts/lab/prepare-loop-storage.sh` 预建，
  不是 ConfigMap 下发。
- `controller.storageCapacityTracking.enabled: true`、`scheduler.enabled: false`
  —— 容量调度走 **CSIStorageCapacity / StorageCapacity tracking**，
  **不是** `topolvm-scheduler` extender，也没有 `capacity.topolvm.io/*` 注解（hnb 全仓 0 命中）。
  外部评审里「标准 TopoLVM 按 `capacity.topolvm.io/xxx` 调度」这个假设不成立，本 change 不引入它。
- SC `hnb-topolvm`：`provisioner=topolvm.io`、`fsType=ext4`、`Retain`、
  `WaitForFirstConsumer`、`allowVolumeExpansion=true`、`topolvm.io/device-class: hnb`。
- 组件：`topolvm-system` 下 controller Deployment + node DaemonSet、`CSIDriver topolvm.io`、
  CRD `logicalvolumes.topolvm.io`；snapshot / webhook / cert-manager **全部关闭**。
- 实测结论在 `docs/acceptance/reports/20261015-full-minimal-topolvm.md`（PVC 1Gi→Bound、
  LV 创建、patch 4Gi 在线扩容不重建 Pod、marker 保留）与
  `20261018-s2-s3-lab-infrastructure.md`（重建 Pod / worker 重启后同一 PVC 保留）。

## 前置核实清单（设计文档 `【待核实】`，阶段 0 门控，未核实不得进阶段 1）

1. chart 17.3.0 的 `lvmd.managed=true` 是否支持从我们渲染的 `hlmd-lvmd-<node>` ConfigMap
   读 `lvmd.yaml`；配置变更是热加载还是必须滚动重启 node Pod（设计 §2.1 标 `【待核实】`）。
2. `topolvm.io/device-class` 在 0.42.0 渲染后确实落在 `StorageClass.parameters`
   （hnb values 用 `additionalParameters`），与 hlvm VAP 的 CEL 校验一致。
3. TopoLVM 0.42.0 的 `LogicalVolume` CR group/version、字段与 `CSIDriver` 的
   `storageCapacityTracking` 在 K8s 1.36 下的实际行为；`WaitForFirstConsumer` 与
   webhook 注入的 locked nodeAffinity 是否冲突（设计 §2.1、附录 B 待核实清单）。
4. **宿主机 LVM 入口**：agent 与 lvmd 同机操作同一 VG 时，`nsenter/chroot /host` +
   `/run/lock/lvm` 共享锁的实测；复用 `docs/poc/scripts/concurrency-lvmd-test.sh`（设计 §5.3、
   §12「Agent 与 lvmd 并发改 LVM」高风险项）。
5. 上游镜像拉取：GHCR 私有包与 `ghcr.io/topolvm` 的可达性、digest 固定策略、real 模式
   `IMG_TAG` 纪律（不得 `:latest`，见 runbook §11.3）。
6. 备份清单的 SC 名对齐：`config/backup/03-drill-job.yaml` 写 `topolvm-provisioner`、
   `00-velero-install.yaml` 写 `config.driver: topolvm.io`，真实 SC 名确定后要同步，
   否则 `verify-velero` 会从「SKIP」变成「假绿」。
7. thinpool 取舍：hnb 基线是 thick（无 thin-pool）；hlvm `AggregateLVMDConfig` 会渲染
   thin-pool + 超分比，二者如何对齐（第一阶段建议跟随 hnb 用 thick，thinpool 治理留阶段 3）。

## What Changes（分阶段，每阶段独立验证，不得一把梭）

- **阶段 0 决策门**：完成上表 7 项核实，产出「lvmd 形态」与「thinpool 取舍」两项书面决策，
  不写实现代码。
- **阶段 1 上游 CSI 部署相位**：在 `scripts/m15-integration.sh` 增加 `bootstrap-csi` 与
  `verify-csi-supply`；固定 chart 版本 + digest，部署 controller / node / CSIDriver /
  StorageClass；kind 用 loop 盘模拟 VG，real 用裸数据盘。**验收以 PVC 真正 Bound 为准**，
  不以「Deployment Available」或「SC 存在」为准。
- **阶段 2 接线与观测**：把 `hlmd-lvmd-<node>` ConfigMap 接到真实 lvmd（或按阶段 0 决策改用
  values 渲染）；接入 `LogicalVolume` CR / PV / lvs 三方对账（激活 `LVReporter`）与
  `CSIStorageCapacity` 观测；保留 §1「每一层只有一个写者」与「数据面独立于控制面」的断言。
- **阶段 3 端到端与治理**：hlvm × hnb 错峰联调（hnb 用 hlvm 的 SC 交付带 PVC 应用）、
  thinpool/autoextend 治理接线、Velero 快照闭环。**必须等阶段 1/2 全绿后启动**。

### 验收判据（`verify-csi-supply` 分层，禁止只数 PASS 条数）

1. 上游组件就绪：`CSIDriver topolvm.io`、`LogicalVolume` CRD、controller / node Pod；
   SC 的 `provisioner` 与 `topolvm.io/device-class` 与 hlvm VAP 一致。
2. **PVC 1Gi → Bound**，且 Pod 内可读写；扩容到 4Gi 后 `FileSystemResizeSuccessful`、
   **不重建 Pod**、marker 保留（复刻 hnb 已验证口径）。
3. 容量账：`CSIStorageCapacity` 对象存在且数值随 LV 分配变化；与 `NodeVG.status.freeBytes`
   对账，口径冲突时以实测 `lvs/vgs` 为准（设计 §2.1）。
4. 三方对账：`LogicalVolume` CR / PV / 节点实际 LV 一致；人工 `lvcreate` 能被 drift 检测发现。
5. **数据面独立**：把 hlvm 控制面 Deployment 缩到 0，已挂载卷的 IO 与存量业务不受影响
   （设计 §1 底线，M15 现有相位没有覆盖，必须新增）。
6. 破坏性路径：VG 变更走 `confirmSerial` + `dryRun` + 人工审批，不自动 wipe/pvcreate。
7. 收尾恢复：相位结束后 CRD / SC / 命名空间 / 设备插件状态与 `m15-joint.sh` 的收尾断言一致，
   不污染后续 `all` 链。

## 关键设计决定

1. **不动 A 链路**。设备插件解决的是 devices cgroup 授权（proposal `add-disk-device-plugin`
   的 Out of Scope 明确「不做纳管决策」），与 PVC 容量调度并存；删掉它会让 agent 特权收不回、
   SMART 采不到两个实测缺陷回归。真机「每 worker 2 块」维持现状。
2. **不引入 scheduler extender 与 `capacity.topolvm.io` 注解**：跟随 hnb 已验证的
   `storageCapacityTracking`，减少一套调度器配置与静态挂载。
3. **LVM 并发是硬门禁，不是普通任务**。在阶段 0 第 4 项未通过前，禁止在真机上让 agent 与
   lvmd 同时写同一 VG；容器内 lvm 与宿主内核 device-mapper 不匹配有元数据损坏风险
   （设计 §5.3、§12）。
4. **错峰纪律**：本 change 的相位纳入 `m15 all` 后，与 hnb 测试仍禁止并行
   （`scripts/m15-joint.sh` flock 串行、runbook §7.2 / §10.19）。
5. **不改已发布 tag 的发布说明**：`v0.1.0-preview.2` 未单列 CSI 缺口，下一版发布时纳入
   「未验证清单」；本 change 期间只在 `CHANGELOG.md` 的 Unreleased 登记。

## Out of Scope

- 不实现自研 CSI controller / node / lvmd（设计 §1：CSI 不出自研代码，私有 patch ≤2 处）。
- 不删、不重构设备插件与 `hlvm.io/disk`；不把真机降配到 1 块盘；不把「2 块」改成硬断言。
- 不支持系统盘剩余分区复用（与「自动发现 + 自动 wipe」安全模型冲突，属长期 backlog，
  若将来做必须 opt-in 显式设备路径 + 人工审批 + 禁止自动擦除）。
- 不做生产灰度门禁、不做多 CP 高可用验收、不升级 Go k8s 依赖基线（各有独立立项）。
- 不在本 change 内解决 `verify-cert-rotation` 遗留 `port-forward` 孤儿进程、Velero 本地镜像
  拉取受限等既有环境问题。
- **本 proposal 不含任何代码/清单实现**，实施须另行批准。

## Impact

- 新增文件：`openspec/changes/add-topolvm-csi-supply/{proposal,tasks}.md`、
  `.openspec.yaml`（`skip_specs: true`，与 `m15-integration` 一致）。
- 文档：`scripts/real-cluster/README.md` §7 更正「无 lvmd-config-ctrl」的不准确表述并指向本 change；
  `CHANGELOG.md` Unreleased 登记立项；`docs/m15-integration-runbook.md` 增加相位索引（阶段 1 落地时）。
- 预期后续改动面（**均不在本轮**）：`scripts/m15-integration.sh`（新相位 + `all` 链接线）、
  `control-plane/config/csi/`（上游部署入口/values）、`control-plane/internal/controller/`
  （LVReporter 实现、LogicalVolume scheme + RBAC）、`agent/src/lvm/mod.rs` 与
  `agent/src/executor/mod.rs`（宿主机 LVM 入口 + 锁）、`control-plane/config/backup/`（SC 名对齐）、
  CI 镜像预载策略。
- 依赖前提：M17 真机资源与凭据（GHCR 只读、SSH 免密、kubeconfig、裸盘）；
  kind 阶段可先于真机完成，但**真机阶段不得与 hnb 测试并行**。
