# 真实测试集群（云主机）部署

目标：把 M15 里「kind 覆盖不到」的项在真实环境闭合——真实 LV / `dm_thin_pool`、
`/dev/disk/by-id`（udev 存在）、多节点真实调度、Velero 端到端、节点扩缩容。

> 状态：2026-11-11 已在 3 节点云主机集群跑通 `preflight`（PASS=10 / WARN=2 / FAIL=0；
> 4 个 GHCR 包已公开、控制面实测匿名拉取可用）。**全相位 `all` 的结论不在本 README 预写**，
> 以实际验收记录为准。语法（`bash -n`）与 kind 侧适配层回归已通过。首次执行请按 §4 的
> 检查点逐步确认，不要直接 `for f in *.sh` 全跑。

## 1. 拓扑与规格

| 角色 | 台数 | vCPU | 内存 | 系统盘 | 数据盘 |
|---|---|---|---|---|---|
| control-plane | 1 | 4 | 8 GiB | 50 GiB | — |
| worker | 2~3 | 4 | 8 GiB | 50 GiB | 2 × 20~50 GiB 裸数据盘（virtio-blk 优先，见 §1/§2） |

- 3 台（1 CP + 2 worker）是**下限**：能闭合拓扑/容量账（`verify-topology-scale`）与真实 LV。
- 4 台（+1 worker）可额外演练 **6.5b-2 节点扩缩容**：把第 4 台 join/remove 即可。
- **副本分布看上的是可调度域 D，不是节点总数**：CP 带 `NoSchedule` taint 且控制面
  Deployment 未容忍，故 3 台时 D=2 —— webhook 3 副本必然 2:1（`maxSkew: 1` 下的理论最优），
  想看到 1:1:1 需要 3 个 worker（即 4 台方案）。详见 runbook §10.15。
- **数据盘必须是未格式化的裸整盘，且不能是系统盘**。这既不是容量要求，也不是调度器的限制，
  而是「整盘纳管 + 自动擦盘」的安全边界（两条链路的完整说明见 §7）：设备插件 `hlvm.io/disk`
  的计量单位是**可纳管整盘的块数**（K8s 扩展资源天生是整数）；agent 的 `select_disks` 只认
  `lsblk TYPE=disk` 并排除挂载了 `/`、`/boot`、`/var`、`/home` 等的系统盘，观测侧见到
  `FSTYPE` 签名还会写 `occupiedBy=filesystem` 拒绝纳管；而 `StorageTask` 写路径确实会
  `wipefs` → `pvcreate` → `vgcreate`。所以「系统盘划个分区」「同一块盘分两区」「loop 文件当盘」
  都既不识别、也不允许——把系统盘纳入等于允许自动擦掉 `/`。
- **每 worker 2 块是「device plugin 模式」的推荐配置，不是代码硬断言**。`preflight` 不检查盘数，
  唯一的尺寸门槛是 `disk-precheck.sh` 的 `MIN_GIB=20`。要 2 块是为了让断言保持判别力：
  `verify-topology-scale` 第 6 步删掉 `m15-topo-hold-${n}-1` 后第二块仍被占用，节点处于
  **部分占用**状态，才能证明「释放的那一块回到 kubelet、另一块没被误回收、调度器在部分占用下
  仍能跨节点重平衡」；1 块/节点时删完即全空，Pending Pod 落回来只是一次普通重调度，且 0/1 两态下
  「每节点独立记账 vs 集群共享记账」几乎无法区分，真实 LV / 多盘 VG 场景同样需要 ≥2 块。
  **降到 1 块仍能跑完、且大概率仍打 PASS，但必须在验收记录里注明「部分占用下的设备回收、
  多盘 VG 未覆盖」，不能算完整 M17 真机验收**。该相位另有保护：某节点盘位 `>4` 会被排除出
  填充/耗尽断言（属环境特异性），故 2~4 块为合适区间。

**表格取 20~50 GiB 是「验证目的」的值，100 GiB 只是压测余量**。代码里没有任何对数据盘尺寸的约束；`disk-precheck.sh` 的
`MIN_GIB=20` 只是「候选盘」下限（防把小分区当数据盘）。功能断言完全不依赖容量——kind 上跑绿
126 条断言用的盘只有 **64MB**（`scsi_debug dev_size_mb=64`）。100GiB 买的是真实 LV 阶段的
余量（thinpool 元数据 + 若干瘦卷 + 快照 + autoextend 演练不中途 ENOSPC）。按目的取值：

| 目的 | 建议 |
|---|---|
| 只跑拓扑/账本/调度类断言 | 2 × 20 GiB |
| 真实 thinpool + LV + 快照 | 2 × 30~50 GiB |
| 大卷 / 多次快照压测 | 2 × 100 GiB |

盘越大，autoextend 演练越慢（要写到 75% 才触发扩容），**压测目的选大盘，验证目的反而选小盘**。

**只有 1 台机器也能测，但必须显式声明。** 单机（1 CP，无 worker）下
`M15_SINGLE_NODE=1` 才允许继续：`preflight` 的 worker 不变量改为「声明与实测节点数一致」，
`verify-topology-scale` 显式 SKIP（跨节点断言无对象可验），其余相位照跑。不设开关时
`preflight` 仍判 FAIL——脚本不会因为「少一台机器」自动替你降低覆盖。详见 runbook §10.16。

## 2. 前置

1. 所有节点**内网互通**，安全组放通：22、6443、以及 kubeadm 要求的节点间全端口
   （或直接同安全组互通）。
2. **数据盘形态**：镜像选 Linux（Ubuntu 24.04，勿选 Windows）。云厂商新建的数据盘默认就是
   未格式化的裸盘，**保持原样即可**——不要勾选控制台的「自动初始化 / 格式化 / 挂载」向导，
   不要 `mkfs`、分区、mount 或写 `/etc/fstab`；一旦有 `FSTYPE` 签名或挂载点，会被判为
   `occupiedBy=filesystem` 或系统盘而拒绝纳管，`hlvm.io/disk` 归 0、被测节点被静默排除。
   不要用从快照创建的盘 / 共享盘 / 加密盘 / 本地 NVMe 临时盘，不要预建 LVM/RAID，并留意镜像
   cloud-init 是否把数据盘自动挂到 `/mnt`、`/data`（`disk-precheck.sh` 第 4 段专查此项）。
   **硬性条件是节点内存在 `/dev/disk/by-id` 条目（udev 生成）；`virtio` 只是最常见的驱动类型，
   不是要求**：virtio-blk → `virtio-*`、virtio-scsi → `scsi-*` / `wwn-*`、NVMe → `nvme-*`
   都可纳管。agent 用 `common::by_id_alias_rank` 固定优先级
   （`virtio-` > `scsi-` > `nvme-` > `wwn-` > `ata-` > 其它，同级字典序）择优，避免同一块盘的
   多别名造成 NodeDisk 身份漂移；完全没有 by-id 时设备 ID 回退 `dev-<name>`，6.2 断言不成立。
3. 出网：能拉 `pkgs.k8s.io`、`registry.k8s.io`、`ghcr.io`、`docker.io`、`quay.io`。
   国内环境建议给 containerd 配 registry mirror（见 `cloud-init.yaml` 注释）。
4. **GHCR 镜像供给二选一**（2026-11-11 起 `ghcr.io/f31/hlvm/` 下 4 个包
   `storage-controller` / `storage-webhook` / `storage-agent` / `crd-conversion` 已设为 **public**）：
   - **公开包（当前默认）**：节点匿名拉取，不需要 `imagePullSecret`，也**不要跑
     `post-install.sh`**（它强制要求 `GHCR_USER/GHCR_TOKEN`，且只 patch `default` SA，见 §6）。
     跑 M15 时显式 `M15_GHCR_PUBLIC=1`；`preflight` 会从控制面逐个实测 4 个包的匿名
     pull token = 200 才放行，任一失败会列出具体包名。**不做静默检测**：不设开关而缺 secret 一律 FAIL。
   - **私有包**：需 `read:packages` PAT + `hlvm-system/ghcr-pull`，且必须先修
     `post-install.sh` 的具名 SA 缺陷（§6），否则节点仍 `ImagePullBackOff` 而 preflight 假绿。
   - GitHub 组织账号改包可见性需包 admin（组织 owner）权限，**设为 public 后不可逆**。
     判据细节（为什么用 token 端点而不是 manifest）见 runbook §7。

## 3. 执行顺序

```bash
# 0) 每台节点：cloud-init 已装好 containerd/kubelet/kubeadm（见 cloud-init.yaml）
#    若云厂商不支持 cloud-init，把 cloud-init.yaml 的 runcmd 当脚本手工执行一遍。

# 1) 控制面（只在 CP 上执行）
sudo K8S_MINOR=1.36 POD_CIDR=10.244.0.0/16 ./setup-control-plane.sh
#    产出 /etc/kubernetes/admin.conf；脚本会把它拷到执行用户的 ~/.kube/config

# 2) worker（每台执行，token 从 CP 上取）
#    CP: sudo kubeadm token create --print-join-command
sudo ./join-worker.sh "<kubeadm join 输出的完整命令>"

# 3) 回到 CP（或任何能访问集群的机器）：只做逐节点数据盘预检
export KUBECONFIG=~/.kube/config
export KCTX=$(kubectl config current-context)
#   公开包模式**不要跑 post-install.sh**（强制要 PAT，且只 patch default SA）。
#   数据盘预检逐节点单独跑 scripts/real-cluster/disk-precheck.sh。

# 4) 跑集成（在能 ssh 到所有节点的机器上；kubeconfig / 密钥路径按实际环境改）
cd ..
# 镜像标签用版本号，不要用 latest：latest 会被下一次 main 构建覆盖，
# 用它跑出来的结论无法对应到具体版本（见 runbook §11.3）。
export M15_TARGET=real \
       KCTX=kubernetes-admin@kubernetes \
       KUBECONFIG=~/.kube/hlvm-real.conf \
       M15_SSH_USER=root M15_SSH_PORT=22 \
       M15_SSH_KEY=~/.ssh/hlvm-real \
       IMG_REGISTRY=ghcr.io/f31/hlvm IMG_TAG=v0.1.0-preview.2 \
       M15_GHCR_PUBLIC=1

./m15-integration.sh check       # 只读：context / 版本 / CRD 现状
./m15-integration.sh preflight   # 环境体检（runbook §10.14）：ssh 可达性、节点能力、镜像供给、镜像标签
./m15-integration.sh all         # 首跑建议先单个跑，见下
```

**先 `preflight` 再 `all`**。`preflight` 的结构性缺失（ssh 不通 / 无独立 worker /
镜像供给声明不匹配（缺 `ghcr-pull`，或声明 public 但 4 个 token 未全 200）/
用 `:latest` 验收 / 造盘钩子路径写错）会直接非 0 退出，
不用等到第 5~15 个相位才以「产品缺陷」的样子爆出来。它列出的 WARN 是能力缺口，
对应相位会 SKIP——先知道哪些相位会跳过，再去读 `all` 的结论。

首跑建议顺序：`preflight` → `bootstrap` → `verify-nodedisk-convergence` →
`verify-admission` → 其余单个 verify → 全绿后再 `all`。一把梭 `all` 失败时，
日志里 20 多个相位的输出混在一起，归因成本远高于逐个跑。

## 4. 首次执行必须确认的检查点

| 检查点 | 命令 | 期望 |
|---|---|---|
| 版本 | `kubectl version` | server ≥ 1.36 |
| cgroup | `stat -fc %T /sys/fs/cgroup` | `cgroup2fs` |
| by-id | `ls -l /dev/disk/by-id/`（不限前缀，virtio-/scsi-/nvme- 均可） | 每块数据盘至少一条稳定条目 |
| 盘干净 | `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT` | 数据盘 `TYPE=disk`，`FSTYPE` 与 `MOUNTPOINT` 均空 |
| 无签名 | `sudo blkid /dev/vdb` | **无输出**（无文件系统签名） |
| 无自动挂载 | `findmnt -Rno TARGET,SOURCE,FSTYPE` | 输出中不含 `/dev/vd[b-z]`（出现 `/data`、`/mnt` 即已被 cloud-init 接管） |
| thin pool | `lsmod \| grep dm_thin_pool` | 有输出 |
| 节点数 | `kubectl get nodes` | 全部 Ready |
| 拉镜像 | `kubectl -n hlvm-system get events` | 无 `Failed to pull` |

## 5. 与 kind 的差异（`M15_TARGET=real` 已经处理的部分）

| 环节 | kind | real |
|---|---|---|
| 节点执行 | `docker exec <容器>` | `ssh <user>@<InternalIP>` |
| 镜像 | `kind load docker-image` | 节点从 `IMG_REGISTRY` 拉：公开包匿名（`M15_GHCR_PUBLIC=1`）；私有包需 `imagePullSecret` 注入**所有具名 SA** |
| 建集群 | `kind create cluster` | 跳过（脚本只做 bootstrap 的平台组件） |
| 造盘/拔盘 | `modprobe scsi_debug` | 必须提供 `M15_DISK_ATTACH_CMD` / `M15_DISK_DETACH_CMD`；否则该相位 SKIP |
| 被测节点 | `items[0]`（CP） | 自动选 worker（避开控制面） |
| etcd 直读 / kubelet 重启 | `docker exec <CP>` | `ssh <CP>`（仍打控制面，不是被测 worker） |

## 6. 尚未闭合

- **私有包路径的 `post-install.sh` 具名 SA 缺陷（2026-11-11 发现，未修）**：该脚本只把
  `ghcr-pull` patch 到 `hlvm-system/default` SA，但所有工作负载都用具名 SA
  （`hlvm-storage-controller` / `hlvm-storage-webhook` / `hlvm-agent` / `hlvm-device-plugin` /
  `hlvm-crd-conversion` / `hlvm-storage-exporter` / `hlvm-backup-drill`）。即使 secret 存在，
  kubelet 仍拉不到私有镜像；而 M15 `preflight` 只断言 secret 存在 ⇒ **结构性假绿**。
  本轮 4 个包已 public，走匿名拉取，不跑该脚本、也不覆盖该路径；若将来回退私有包，
  须先给所有具名 SA 注入并读回校验后再验收。
- **by-id 多别名在真机 udev 下的稳定性（kind 永远覆盖不到）**：一块盘在 `/dev/disk/by-id` 下
  常有多个别名（virtio-blk 常见 `virtio-<serial>` + `wwn-0x...`，virtio-scsi 还会多一条
  `scsi-...`）。「遍历目录取第一个匹配项导致 NodeDisk 身份漂移」是**已修复的历史缺陷**，
  不是待办：现在 `common::by_id_alias_rank` 按 `virtio-(0) > scsi-(1) > nvme-(2) >
  wwn-(3) > ata-(4) > 其它(5)` 定序、同级按字典序，未知前缀排最后而非丢弃；
  `agent::resolve_by_id_under` 是唯一实现，设备插件侧委托它。但 kind 无 udev、无别名，
  **择优分支从未在真实多别名设备上跑过**：真机首跑请对同一块盘连续扫两次，确认 `NodeDisk`
  名字稳定、且择优结果符合上述优先级。
- **TopoLVM CSI 供给链路尚未部署（当前不提供 PVC 供给）**：设计文档把 TopoLVM 写成底座，
  但仓库里没有上游部署清单；M15 里的 `topolvm-${LOCK_TIER}` 只是验证 mutating webhook 的假 SC，
  PVC 不会绑定。当前 M15 / 本 README 的相位覆盖的是设备插件链路，**不含 PVC→LV 端到端**；
  两条链路的关系与边界见 §7。
- **6.5b-2 节点扩缩容**：脚本给了 join/remove 的入口，但「调度器重平衡是否达标」仍需人工判读。
- Velero 的 BSL 用内置 minio；生产形态应换成对象存储（云 OSS/S3），此时可删掉 minio 相关步骤。
- 真实证书**自然到期**续签（`verify-cert-rotation` 只验证轮换机制，不验证到期时间）。

## 7. 架构边界：两条独立的消费链路

> 本节回应一次外部评审的误读：把「设计文档里规划的 TopoLVM 底座」当成了「已经部署的底座」，
> 并把 `hlvm.io/disk` 当成 TopoLVM 容量调度的替代品。设计文档
> （`docs/自研本地存储平台设计方案_v1.1_评审优化版.md` 开头、§2.1、§13）写的
> 「CSI 复用 TopoLVM」是**决策与目标**，不是当前代码状态；§2.1 的 device-class 参数与
> lvmd 热加载至今仍标 `【待核实】`。

| | A：设备直通链路（已实现） | B：CSI 容量供给链路（规划中，未部署） |
|---|---|---|
| 对外接口 | 扩展资源 `hlvm.io/disk: N`，整数**块数** | `StorageClass provisioner=topolvm.io` + `capacity.topolvm.io/<class>`，按 VG 剩余 **GiB** |
| 调度对象 | Pod 申请后拿到裸设备节点（devices cgroup 授权） | PVC `storage: 50Gi` → TopoLVM 创建 LV |
| 主要用途 | 「每盘一个 collector Pod」按盘采 SMART，让 agent / exporter 不必特权化 | 给有状态应用供给本地卷 |
| 代码 / 清单 | `agent/src/plugin/`、`agent/config/daemonset-device-plugin.yaml`、M15 `verify-device-plugin` / `verify-collector` | **上游 CSI 组件（lvmd / controller / node / CSIDriver / 真实 SC）部署清单全部缺失**；控制面已有 `LvmdConfigReconciler` 渲染 `hlmd-lvmd-<node>` ConfigMap（M15 `verify-lvmd` 只验聚合语义，**无 lvmd 进程消费**），`lv_model.go` 的 `LVReporter` 默认 nil、未接 TopoLVM `LogicalVolume` CR，无 `CSIStorageCapacity` 消费者 |
| 当前状态 | 已验收（M15 全相位 PASS） | 未部署；M15 注释明写「kind 内无 TopoLVM CSI，PVC 不会绑定」，`topolvm-${LOCK_TIER}` 是**假 SC**，webhook 只按 `provisioner=topolvm.io` 识别 SC 并注入 nodeAffinity |

**两条链路并存、不互斥，也不是上下层的替代关系**：A 给容器的是裸块设备节点，B 给 Pod 的是
格式化后的逻辑卷；一个解决「非特权 Pod 打不开 `/dev/sdX`（devices cgroup BPF 过滤，
`uid=0` 加 `SYS_ADMIN` 也绕不过）」的权限问题，一个解决「按容量切卷」的供给问题。K8s Device
Plugin 的扩展资源天生是整数个数，因此「块数」是设备直通的正确语义，不是设计缺陷。删掉 A，
`openspec/changes/add-disk-device-plugin/proposal.md` 里两个实测缺陷（agent 特权收不回、
exporter 采不到 SMART）会直接回归。

**因此以下几点不要据此改动**：

- 「生产直接走标准 TopoLVM 容量模式，配置即可」不成立。device-class ↔ VG 的**映射渲染侧**
  已有（`lvmd_config.go`），但要补的仍是完整链路：上游部署、**把已渲染的 ConfigMap 接到真实
  lvmd**、容量上报、`LogicalVolume` / PV 三方对账、agent 与 lvmd 共享宿主机 LVM 锁。
  设计 §2.1 已把这些列为衔接点，**应独立立项，不是配置切换**；它也是 hlvm → hnb
  端到端供给（hnb 侧已用 TopoLVM 0.42.0 + `hnb-topolvm`）的真实前置。
  立项方案见 `openspec/changes/add-topolvm-csi-supply/proposal.md`（待评审，不含实现）。
- M15 的拓扑 / 设备类断言全部围绕 A 链路，且当前 PVC 根本不绑定。将来即使部署了 B 链路，
  用同一 VG 上不同大小的 LV 覆盖「部分占用 / 多盘 VG」也**需要新写一套断言**；现在把真机
  降到 1 块盘，只会让 §1 所述第 6 步失去判别力。
- 标准 TopoLVM 允许人工在系统盘剩余空间划分区建 PV，但 hlvm 是「自动发现 + 自动
  `wipefs` / `pvcreate`」。系统盘复用若要支持，必须是 **opt-in 显式设备路径 + 人工审批 +
  禁止自动擦除**，并登记共享失败域、根分区 I/O 竞争与云盘扩容 / 分区表风险；属长期 backlog。

**版本定位**：`v0.1.0-preview.2` 明确标注「禁止生产使用」「真实 LV / thinpool 未验证」，
本 README 补充说明「CSI 供给链路未部署、当前不提供 PVC 供给」。上述「必须独立数据盘 /
必须整盘 / 按块数计资源」在预览版阶段是**诚实的安全边界**，不是待优化的技术债；让容量调度
成为生产主路径是方向，但需要新里程碑用代码和验收去兑现，而不是先改文档措辞。
