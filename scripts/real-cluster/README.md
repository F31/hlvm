# 真实测试集群（云主机）部署

目标：把 M15 里「kind 覆盖不到」的项在真实环境闭合——真实 LV / `dm_thin_pool`、
`/dev/disk/by-id`（udev 存在）、多节点真实调度、Velero 端到端、节点扩缩容。

> 状态：脚本为**首版**，尚未在真实云主机上端到端跑过。已在本地校验的只有语法（`bash -n`）
> 与 kind 侧的适配层回归。首次执行请按 §4 的检查点逐步确认，不要直接 `for f in *.sh` 全跑。

## 1. 拓扑与规格

| 角色 | 台数 | vCPU | 内存 | 系统盘 | 数据盘 |
|---|---|---|---|---|---|
| control-plane | 1 | 4 | 8 GiB | 50 GiB | — |
| worker | 2~3 | 4 | 8 GiB | 50 GiB | 2 × 100 GiB（virtio 云盘） |

- 3 台（1 CP + 2 worker）是**下限**：能闭合拓扑/容量账（`verify-topology-scale`）与真实 LV。
- 4 台（+1 worker）可额外演练 **6.5b-2 节点扩缩容**：把第 4 台 join/remove 即可。
- **副本分布看上的是可调度域 D，不是节点总数**：CP 带 `NoSchedule` taint 且控制面
  Deployment 未容忍，故 3 台时 D=2 —— webhook 3 副本必然 2:1（`maxSkew: 1` 下的理论最优），
  想看到 1:1:1 需要 3 个 worker（即 4 台方案）。详见 runbook §10.15。
- 数据盘**必须是裸块设备**（不要预格式化、不要让 CSI 接管）。容量账按**块数**计（
  `hlvm.io/disk` = 可纳管整盘数），每台 worker 给 2 块是为了让「每节点独立记账」这个断言
  不退化：`verify-topology-scale` 要分别断言「各 worker 按自身容量填满」与「集群耗尽后
  跨节点申请被拒」，1 块/节点时每节点容量只有 0/1 两态，独立记账与集群记账无法区分。
  该相位还有保护：某节点盘位 `>4` 会被排除出填充/耗尽断言（属环境特异性），故 2~4 块为合适区间。

**100 GiB 不是要求，是余量值**。代码里没有任何对数据盘尺寸的约束；`disk-precheck.sh` 的
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
2. 云盘使用 **virtio** 挂载，节点内应能看到 `/dev/disk/by-id/virtio-*`。
3. 出网：能拉 `pkgs.k8s.io`、`registry.k8s.io`、`ghcr.io`、`docker.io`、`quay.io`。
   国内环境建议给 containerd 配 registry mirror（见 `cloud-init.yaml` 注释）。
4. 一个 GHCR 只读凭据（`GHCR_USER` + `GHCR_TOKEN`），用于 `imagePullSecret`——
   仓库当前是**私有包**，缺了必然 `ImagePullBackOff`。

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

# 3) 回到 CP（或任何能访问集群的机器）
export KUBECONFIG=~/.kube/config
export KCTX=$(kubectl config current-context)
export GHCR_USER=... GHCR_TOKEN=...
./post-install.sh          # imagePullSecret + 各节点数据盘预检

# 4) 跑集成（在能 ssh 到所有节点的机器上）
cd ..
# 镜像标签用版本号，不要用 latest：latest 会被下一次 main 构建覆盖，
# 用它跑出来的结论无法对应到具体版本（见 runbook §11.3）。
export M15_TARGET=real \
       KCTX=kubernetes-admin@kubernetes \
       M15_SSH_USER=root \
       M15_SSH_KEY=~/.ssh/id_ed25519 \
       IMG_REGISTRY=ghcr.io/f31/hlvm IMG_TAG=v0.1.0-preview.1

./m15-integration.sh check       # 只读：context / 版本 / CRD 现状
./m15-integration.sh preflight   # 环境体检（runbook §10.14）：ssh 可达性、节点能力、凭据、镜像标签
./m15-integration.sh all         # 首跑建议先单个跑，见下
```

**先 `preflight` 再 `all`**。`preflight` 的结构性缺失（ssh 不通 / 无独立 worker /
缺 imagePullSecret / 用 `:latest` 验收 / 造盘钩子路径写错）会直接非 0 退出，
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
| by-id | `ls -l /dev/disk/by-id/ \| grep virtio` | 每块数据盘一条 |
| 盘干净 | `sudo blkid /dev/vdb` | **无输出**（无文件系统签名） |
| thin pool | `lsmod \| grep dm_thin_pool` | 有输出 |
| 节点数 | `kubectl get nodes` | 全部 Ready |
| 拉镜像 | `kubectl -n hlvm-system get events` | 无 `Failed to pull` |

## 5. 与 kind 的差异（`M15_TARGET=real` 已经处理的部分）

| 环节 | kind | real |
|---|---|---|
| 节点执行 | `docker exec <容器>` | `ssh <user>@<InternalIP>` |
| 镜像 | `kind load docker-image` | 节点从 `IMG_REGISTRY` 拉（需 imagePullSecret） |
| 建集群 | `kind create cluster` | 跳过（脚本只做 bootstrap 的平台组件） |
| 造盘/拔盘 | `modprobe scsi_debug` | 必须提供 `M15_DISK_ATTACH_CMD` / `M15_DISK_DETACH_CMD`；否则该相位 SKIP |
| 被测节点 | `items[0]`（CP） | 自动选 worker（避开控制面） |
| etcd 直读 / kubelet 重启 | `docker exec <CP>` | `ssh <CP>`（仍打控制面，不是被测 worker） |

## 6. 尚未闭合

- **by-id 别名歧义（真机大概率露头，kind 永远看不到）**：一块盘在 `/dev/disk/by-id` 下常有多个
  别名（`virtio-<serial>` + `wwn-0x...`，SCSI 盘还会多一条 `scsi-...`）。`agent::resolve_by_id`
  遍历目录取**第一个**匹配项，没有前缀优先级；该别名又被当作 NodeDisk 的标识使用。若两次扫描
  选到不同别名（udev 补链有先后），同一块盘会被识别成两个设备。kind 上无 udev、无别名，故
  本地回归不可能覆盖。真机首跑时请对同一块盘连续扫两次，确认 `NodeDisk` 名字不漂移。
- **6.5b-2 节点扩缩容**：脚本给了 join/remove 的入口，但「调度器重平衡是否达标」仍需人工判读。
- Velero 的 BSL 用内置 minio；生产形态应换成对象存储（云 OSS/S3），此时可删掉 minio 相关步骤。
- 真实证书**自然到期**续签（`verify-cert-rotation` 只验证轮换机制，不验证到期时间）。
