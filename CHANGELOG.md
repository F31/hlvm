# 变更日志

本文件记录 hlvm 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **0.x 阶段说明**：1.0 之前 CRD schema 与可选字段仍可能不兼容变更；每次升级前先读对应版本的
> 「升级注意」。`preview` 后缀表示**未通过真实硬件与生产环境验证**，不得用于生产。

## [Unreleased]

### 集成脚本 / 真机前置（2026-11-11）

- **新增 `M15_GHCR_PUBLIC=1` 显式开关**（默认 0，不做静默检测）：4 个 GHCR 包改为 public 后，
  `preflight` 跳过 `hlvm-system/ghcr-pull` 检查，改为从控制面节点**逐个**实测 4 个包的匿名
  `ghcr.io/token?scope=repository:f31/hlvm/<pkg>:pull` = 200 才 PASS，任一失败列出具体包名并
  FAIL；汇总 WARN「不覆盖 registry 鉴权链路」。不设开关且缺 secret 一律 FAIL。
  `phase_check` 的提示同步条件化，避免公开模式下输出误导性的「私有包会 ImagePullBackOff」。
  **判据选 token 而非 manifest**：公开包匿名 GET manifest 同样 401（OCI Bearer challenge），
  已用已知公开包 `topolvm/topolvm` 对照实测；上一版「manifest 期望 200」会在包公开后误判 FAIL。
- **文档同步**：`scripts/real-cluster/README.md` §2/§3/§5/§6 改为公开包默认路径（不再要求
  `GHCR_USER/GHCR_TOKEN`、不跑 `post-install.sh`），`docs/m15-integration-runbook.md` §7 更正
  「`storage-agent` 从未推送」的过时记录并写明两条路径与结论边界。
- **真机 `preflight` 首次跑通**：3 节点集群（v1.36.6，1 CP + 2 worker）上
  PASS=10 / WARN=2 / FAIL=0 / RC=0；WARN 为「不覆盖 registry 鉴权链路」与
  「未提供 `M15_DISK_ATTACH_CMD` → `verify-device-hotplug` SKIP」。`all` 结论另行记录。
- **已知风险（登记，未修 `post-install.sh`）**：私有包路径下该脚本只把 `ghcr-pull` 挂到
  `hlvm-system/default` SA，而全部工作负载用具名 SA ⇒ 节点仍 ImagePullBackOff，
  但 `preflight` 只断言 secret 存在 ⇒ 结构性假绿。本轮走公开包路径，未实跑也未修复该路径。
- **仓库结构（2026-11-11 远端提交 `5b54463`）**：整个 `openspec/` 目录（46 文件、2790 行）
  已从 `main` 删除，含 `add-topolvm-csi-supply` 立项与全部归档 spec/tasks。下方历史版本条目里
  出现的 `openspec/...` 路径是**当时的记录**，当前文件已不存在；验收回填改以本文件与
  `docs/m15-integration-runbook.md` 为准，不再 tick 已删除的任务清单。
- **修 real 模式「声明精确版本、实跑 latest」假绿（真机首跑发现）**：静态清单把
  controller/webhook 写成 `:latest`（kind 靠 `cp_build` + `image_load` 命中本地镜像），但 real
  不构建不 load，`IMG_TAG` 只作用于动态创建的 agent/conversion 镜像 ⇒ preflight 打印
  「精确版本引用，结论可复现」而集群实际拉 `latest`（会被下一次 main 推送覆盖）。现
  `phase_bootstrap` 在 real 模式把两个静态 Deployment 的 `containers/0/image` 显式 patch 为
  `${IMG_REGISTRY}/...:${IMG_TAG}`；`phase_preflight` 在已部署时核对实际镜像引用，不一致即 FAIL
  并要求重跑 bootstrap。`all` 里的 `phase_build` 只改 `imagePullPolicy`，不会覆盖 tag。
  **验证闭环**：修复前 preflight FAIL（列出 `controller/webhook=:latest`）→ bootstrap 对齐 RC=0
  → preflight PASS=11 / WARN=2 / FAIL=0 / RC=0；实际镜像为
  `storage-controller:v0.1.0-preview.2` / `storage-webhook:v0.1.0-preview.2`。

### 已知风险 / 评估

- **`verify-cert-rotation` 遗留 `kubectl port-forward` 孤儿进程（本轮发现，未修 m15 脚本）**：
  TLS 探针起的 `port-forward ... 19443:9444` 在相位结束后仍存活（PPID=1）。它本身不阻塞测试，
  但会继承 joint 脚本 `exec 9>` 的锁 fd；本轮已通过 `flock -n -o` 重构规避，并在验收前
  kill 该进程释放 19443。m15 脚本自身的探针进程清理待单独立项。
- **Go 侧 k8s 依赖代差（登记，不在本版修复）**：`k8s.io/api` / `apimachinery` 为 v0.33.0，
  `client-go` / `apiextensions-apiserver` 为 v0.32.1，`controller-runtime` 为 v0.20.4
  （官方绑定 k8s v0.32.x）；MVS 会让 client-go 0.32.1 链接到 apimachinery 0.33.0，
  属上游未验证搭配。Rust 侧 `k8s-openapi 0.28 / v1_36` 与 kind 1.36.x 实测集群对齐。
  当前 `go build/vet/test`、envtest 1.36.2 与 kind 1.36.4 集成全通过，**没有实际失败证据**，
  但升到 k8s 0.36 需 controller-runtime 0.22+，牵连 webhook decoder / cache /
  CRD conversion 接线，须单独立项并在真实集群回归后评估——不借「顺手统一版本」夹带。
  已新增 `internal/version/deps_test.go` 基线锁定 + CI 显式 `Verify k8s dependency baseline`
  步骤，防止 `go get -u` 之类的无意识漂移；详细理由见该测试文件顶部注释与 runbook §10.18。

### 文档 / 架构澄清

- 修 `scripts/real-cluster/README.md` 的文档漂移：① 新增 §7「两条消费链路」，明确
  A（设备插件 `hlvm.io/disk` 按块直通裸设备）与 B（TopoLVM CSI 按 VG 剩余 GiB 供给 PVC）
  **并存不互斥**，且 **B 链路尚未部署、当前不提供 PVC 供给**（M15 的 `topolvm-${LOCK_TIER}`
  是验证 mutating webhook 的假 SC，PVC 不绑定）；② §1 把「每 worker 2 块」从硬性要求改为
  **device plugin 模式的推荐配置**，补上 `verify-topology-scale` 第 6 步「部分占用」判据与
  降配到 1 块时的诚实边界，并说明「系统盘 / 分区 / loop 文件不可用」是
  「自动发现 + 自动 `wipefs`/`pvcreate`」的安全边界；③ §2 把 `virtio` 由硬性前置改为
  「最常见驱动类型」，硬性条件改为存在 `/dev/disk/by-id` 条目，补云盘默认裸状态、
  「不要初始化 / 勾选自动挂载」与 `common::by_id_alias_rank` 前缀优先级；④ §6 的 by-id
  描述由「取目录第一项」更正为已实现的择优规则（真机首跑目的改为验证择优在真实 udev
  多别名下稳定）。§4 检查点不再限定 `grep virtio`，并补「无自动挂载」断言；拓扑表数据盘
  由 `2 × 100 GiB（virtio 云盘）` 改为 `2 × 20~50 GiB 裸数据盘`。
- **登记架构风险**：设计文档把「规划中的 TopoLVM 底座」写成既成事实、把两条链路写成一层，
  已导致外部评审误判为「底层已是标准 TopoLVM，配置切换即可走容量模式」。
  让容量调度成为生产主路径是方向，但需独立里程碑（上游部署 / device-class 映射 /
  容量上报 / `LogicalVolume` 对账 / 与 agent 共享 LVM 锁），不是配置优化。
  **本轮不改代码**：不删设备插件、不把真机降配到 1 块盘、不按「直接走标准 TopoLVM」重构；
  `v0.1.0-preview.2` 的发布说明已写明「禁止生产使用」，**但未单列 CSI 缺口**——该缺口由
  `real-cluster/README.md` §7 与本节补充说明，已发布 tag 对应的发布说明不追溯改写，
  下一个版本发布时应纳入「未验证清单」。
- **同轮复核更正**：上一节把 `lvmd-config-ctrl` 列为「完全不存在」不准确。
  `control-plane/internal/controller/lvmd_config_controller.go` 已由 NodeVG 渲染一节点一份
  `hlmd-lvmd-<node>` ConfigMap 的 `lvmd.yaml`，`lvmd_config.go` 已实现 device-class ↔ VG /
  thin-pool / 超分比映射，M15 `verify-lvmd` 已验收聚合、排序、自愈、GC 语义；缺的是
  **消费侧**（无任何 lvmd 进程挂载该 ConfigMap）与上游 CSI 部署。`lv_model.go` 的
  `LVReporter` 默认 nil，三方对账的 lvs 一侧跳过，且没有读 TopoLVM `LogicalVolume` CR
  的客户端。README §7 表格与措辞已同步更正。
- **独立立项（仅方案，不含实现）**：新增
  `openspec/changes/add-topolvm-csi-supply/{proposal,tasks}.md`，按设计 §1 / §2.1 /
  §5.3 / §12 / §13 定义阶段 0 决策门（7 项 `【待核实】`）、阶段 1 上游 CSI 部署、
  阶段 2 接线与观测、阶段 3 hlvm × hnb 端到端；核对 hnb 已验证基线后明确
  **容量调度走 `CSIStorageCapacity`（`scheduler.enabled=false`），不引入
  `topolvm-scheduler` extender 或 `capacity.topolvm.io/*` 注解**（后者在 hnb 全仓 0 命中，
  外部评审的该假设不成立）。硬门禁：真机 agent 与 lvmd 同机写同一 VG 前必须完成
  `chroot /host` + `/run/lock/lvm` 共享锁实测。所有任务保持 `[ ]`，实施须另行批准。

### 集成验证 / 修复

- 修 `scripts/m15-joint.sh` 互斥锁：原 `exec 9> /mnt/e/.../.joint.lock` 的 fd 会被子进程继承，
  `verify-cert-rotation` 遗留的 `kubectl port-forward` 孤儿进程在脚本退出后仍持锁，导致
  hnb 相位误报「另一个实例正在运行」；9p 挂载上的 flock 也不可靠。改为
  `flock -n -o "$HOME/.hlvm-joint.lock" bash <script>` 命令模式（子进程不继承 fd、锁在 ext4），
  外层保留以明确报错；新增 `HLVM_JOINT_LOCK_FILE` 可配置
- 完成首轮 hlvm × hnb 错峰验收：hlvm `m15 all` exit 0（单节点，Velero 按环境 SKIP）+
  内置收尾断言 PASS，随后 hnb 相位 17 个 Deployment 全部 Available、exit 0；轻量联调探针
  验证 5 个 CRD 单版本 v1beta1 / 外部标准客户端可发现 NodeDisk / hnb 侧无命名冲突 /
  hnb 节点容器内访问 hlvm API 返回 200。证据在 `joint-logs/`（已忽略），
  结论边界见 runbook §10.19
- 修 `scripts/m15-joint.sh` 基线快照的跨侧 git 误判：Windows git 设 `core.autocrlf=true`
  而 WSL git 未设时，同一 `/mnt/e` 工作树在 WSL 会把 8 个文件的行尾差异报成改动；
  改用 `--ignore-space-at-eol` 判真实改动，并对真实未提交改动直接 FAIL（结论须对应 HEAD）
- 新增 `scripts/m15-joint.sh`：hlvm × hnb 联合测试的错峰编排（`flock` 互斥、环境基线快照、
  hlvm 收尾断言、hnb 相位显式配置或显式 SKIP、分文件日志），把「两套测试不能并行」
  固化为机制而不是靠人记；runbook 新增 §10.19 记录产品分层、冲突面与环境实测
- 修正 runbook 章节编号重复：Go / Rust 依赖代差一节由 §10.17 改为 §10.18（by-id 一节保留 §10.17）
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
