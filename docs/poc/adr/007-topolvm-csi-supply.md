# ADR-007：B 链路 PVC 供给（TopoLVM CSI）部署形态

- 状态：已采纳（POC，2026-11-11 真机验证通过）
- 关联：ADR-005（lvmd ConfigMap 聚合）、ADR-006（lvmd 部署与共享锁）
- 环境：真实集群 k8s v1.36.6 / containerd 2.2.1，CP `10-60-131-187` + worker
  `10-60-153-100` / `10-60-166-202`

## 1. 背景与目标

B 链路的目标是「按 VG 剩余容量动态供给 PVC」。ADR-006 落地后 lvmd 已经在真机上线，
`hlmd-lvmd-<node>` ConfigMap 也真的被消费了，但**仍然不提供 PVC 供给**：没有 CSI
controller / node 插件、没有 StorageClass，PV 无从创建。

本 ADR 记录把 TopoLVM CSI 真正跑起来时做的取舍，以及实测判据。

## 2. 决策

### 2.1 用上游 chart 渲染，不手写清单（可追溯）

`control-plane/config/csi/` 下的清单由 TopoLVM **v0.42.0** 的 chart（chart 版本
17.2.0）`helm template` 渲染后再做**最小元数据归一化**（去掉 `helm.sh/chart`、
`managed-by` 改成 `hlvm-poc`、`app.kubernetes.io/version` 对齐实际镜像 tag）。
渲染命令与 values 覆盖点写在同目录 `README.md`。

理由：手写 CSI 部署最容易漏的是 RBAC（controller 需要 PV/PVC/StorageClass/CSINode
/CSIStorageCapacity 的一组权限，node 需要 `nodes` patch 与 LogicalVolume 全权）。
漏一条的表现是「Pod 起来了但 PVC 一直 Pending」，排查成本远高于渲染。

### 2.2 单镜像承载全部容器（弱网下的关键取舍）

上游 chart 的 `image.csi.*` 默认值就是 `topolvm-with-sidecar`，即 csi-provisioner /
csi-node-driver-registrar / livenessprobe（以及 resizer / snapshotter）的二进制**都在
同一个镜像里**，各容器用 `command` 覆盖入口即可。这与「每个 sidecar 一个
`registry.k8s.io/sig-storage/*` 镜像」的常规做法不同，但在弱网下差异极大：

| 方案 | 需要从外网拉的镜像 | amd64 总量 |
| --- | --- | --- |
| 常规多镜像 | topolvm + 5 个 sig-storage 镜像 | ≈ 300 MiB 起 |
| 单镜像（本决策） | 仅 `topolvm-with-sidecar` | 210.1 MiB |

ADR-006 已经踩过一遍弱网：直连 ghcr 单连接 90–500 KiB/s 且抖动。这次该镜像的
**5 层中有 5 层与已导入的 plain 镜像完全相同**（210.1 → 只需补 36 MiB 新层），
剩下靠 `docs/poc/scripts/fetch-oci-parallel.py` 补拉后组装 OCI layout 导入。

### 2.3 `lvmd.managed=false`：lvmd 只由本项目管理

chart 默认会再起一个 lvmd DaemonSet。POC 关掉它，复用 `config/lvmd/daemonset.yaml`
部署的那一个，通过宿主 `/run/topolvm/lvmd.sock` 通信。

理由：同一节点两个 lvmd 会各自持有 device-class 配置并对同一 VG 下发 LVM 命令，
既违背「单一 lvmd」原则，也让 ADR-006 §5.3 的共享锁结论失去意义。

### 2.4 用 capacity tracking，不用 scheduler extender

chart 的 `scheduler.enabled` 默认 `false`，`controller.storageCapacityTracking.enabled`
默认 `true`：csi-provisioner 带 `--enable-capacity` 生成 `CSIStorageCapacity`，
默认调度器的 VolumeBinding 插件据此选节点。

决策：**保持默认**。部署 scheduler extender 需要改 kube-scheduler 的
`KubeSchedulerConfiguration` 并重启控制面，POC 收益为零；而 capacity 路径只需要
node 上报容量注解 + provisioner 生成对象，已经被本次实测验证可行。

### 2.5 StorageClass：`WaitForFirstConsumer` + device-class 绑定

```yaml
name: hlvm-b
provisioner: topolvm.io
parameters:
  csi.storage.k8s.io/fstype: ext4
  topolvm.io/device-class: hlvm-lvmd
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
```

`hlvm-lvmd` 必须等于 lvmd 配置里的 device-class 名（也就是 `hlmd-lvmd-<node>`
ConfigMap 里的 `name`）。`WaitForFirstConsumer` 是 TopoLVM 官方建议：容量型供给
在 Pod 未确定节点前无法可靠选盘。

### 2.6 其它收敛项

| 项 | 取值 | 原因 |
| --- | --- | --- |
| `node.nodeSelector` | `kubernetes.io/hostname=10-60-153-100` | 只有这台有专用 VG；与 lvmd DS 的 selector 一致 |
| `snapshot.enabled` | `false` | 集群无 `snapshot.storage.k8s.io` CRD，开着 csi-snapshotter 起不来 |
| `controller.replicaCount` | `1` | POC 单节点存储，无 HA 诉求 |
| `controller.podDisruptionBudget` | `false` | 单副本下 PDB 只会挡节点维护 |
| `webhook.podMutatingWebhook` | `false`（上游默认） | 关闭后 controller 不需要证书，因此**不需要 cert-manager**；渲染时摘掉了 chart 的 cert-manager 依赖 |
| `priorityClass.enabled` | `false` | 少一个集群级对象 |

## 3. 实测结果（2026-11-11，真机）

部署（`kubectl apply -f control-plane/config/csi/`）后：

| 判据 | 结果 |
| --- | --- |
| `CSIDriver/topolvm.io` | 存在，`attachRequired: false`、`storageCapacity: true` |
| `CSINode/10-60-153-100` | 已注册 `topolvm.io` |
| 节点拓扑标签 | `topology.topolvm.io/node=10-60-153-100` |
| 节点容量注解 | `capacity.topolvm.io/hlvm-lvmd=2143289344`（2044 MiB） |
| `topolvm-node` DS | 3/3 Ready（仅目标节点一个 Pod） |
| `topolvm-controller` Deploy | 4/4 Running（lead election 已拿到 lease） |
| `CSIStorageCapacity` | `hlvm-system/csisc-4qsxs` 已生成 |

端到端（`docs/poc/scripts/pvc-supply-e2e.sh`，PVC 1Gi → Pod 挂载写 16 MiB → 删除）：

| 判据 | 证据 |
| --- | --- |
| PVC Bound | `pvc-poc` phase=Bound，PV `pvc-6acbb1c3-…` 容量 1Gi |
| PV 拓扑亲和 | `topology.topolvm.io/node=10-60-153-100` |
| PV 驱动 | `csi.driver=topolvm.io` |
| Pod 可用 | Running，`/data` 挂成 ext4，写入 16 MiB 且校验和取回 |
| LV 落地 | VG 内新增 1 颗 `a3d67498-…`，`1073741824B` = 1Gi |
| LV 回收 | 删除 Pod+PVC 后该 LV 消失、PV 删除 |
| LogicalVolume CR | `pvc-6acbb1c3-…` 由控制器创建，`nodeName=10-60-153-100`、`deviceClass=hlvm-lvmd` |

## 4. 判据实现上的两个坑（都写进了脚本注释）

1. **LV 名不能靠前缀猜**。TopoLVM 在 VG 里创建的 LV 名是另一个独立 UUID
   （实测 `a3d67498-…`），与 PV 名 `pvc-<uid>`、CR 的 `spec.name` 都不相同。
   脚本改成「创建前基线 → 创建后集合差 + 尺寸核对」。
2. **宿主视角别走 SSH**。WSL 到云主机 22 端口会被 Clash TUN 的 fake-ip 间歇劫持
   （`Connection closed by 198.18.x.x port 22`），导致「读不到 lvs」被误判成
   「LV 不存在」假绿。脚本改走 `kubectl exec ds/hlvm-lvmd -- nsenter -t 1 … lvs`，
   既避开网络抖动，又正好是 lvmd 自己的视角。

## 5. 诚实边界

- **容量上报曾错误地按 VG 剩余而非 thin-pool（已修复，见 ADR-006 §14）**：原节点注解
  `capacity.topolvm.io/hlvm-lvmd=2 GiB`、两条 `CSIStorageCapacity` 各 2044Mi，
  而 thin-pool 数据区是 36G。根因不是容量规划，而是渲染出的 device-class 缺
  `type: thin`，TopoLVM 把 class 当 thick 处理、连供给也走 thick LV。
  2026-11-12 真机 A/B 实证：补上 `type: thin` 后两节点注解变为
  38654705664 B（36 GiB）、CSIStorageCapacity 两条 36Gi、新建 LV 的
  `pool_lv=thinpool` / `Attr=Vwi-aotz--`。修复随 `v0.1.0-preview.3` 的控制器镜像上线
  （控制器会覆盖手工改的 ConfigMap，故必须发版）。本节的「2044Mi」是修复前的历史实测值。
- **多节点已扩到 2 个 worker（2026-11-12 更正，见 ADR-006 §13）**：`hlvm-b` 现可供给到
  `10-60-153-100` 与 `10-60-166-202`，两个节点各跑通一次 PVC→LV→写入→回收 E2E。
  每台 worker 仍需各自 `pvcreate`/`vgcreate` + 各自 `NodeVG`，但 lvmd **仍是一个**
  DaemonSet（聚合 ConfigMap + initContainer 按 `NODE_NAME` 投影各自的 `lvmd.yaml`）；
  三个 DS 改用 `hlvm.io/lvmd=true` 标签选择器。`CSIStorageCapacity` 两条分别以
  `nodeTopology.matchLabels` 指向两个节点、各 2044Mi。
  仍未覆盖 CP；A 链路设备插件仍只在 153，若扩到 166 必须排除承载 B 链路 PV 的 `vdb`。
- **NodeVG 仍是手工 seed**（ADR-006 路线 A），生产闭环需要 agent 的 VG-reporter。
- **agent 未参与本次验证**：本 ADR 的部署与 E2E 只覆盖 lvmd/CSI 侧，没有让 agent 的
  lvm 调用栈参与，因此「agent 与 lvmd 进程级互斥」在本 ADR 范围内未实测。
  > 更正（2026-11-11 续）：此处原写「设计 §5.3 的 `chroot /host` 改造未落地」与代码不符
  > （wrapper 改造已落地，见 ADR-006 §1 前置）；进程级互斥已由 ADR-006 §11 的
  > `agent-lvmd-lock-verify.sh` 补测，当时仍不是 agent 主循环（边界见 §11.4）。
  > 再更正（2026-11-12）：**agent 主循环与常驻 DS 已由 ADR-006 §12 补齐**——
  > 完整 `verify-agent` 灰度相位 rc=0 全 PASS、`MODE=pod` 门禁 PASS，且在 agent
  > 常驻状态下本 ADR 的 `pvc-supply-e2e.sh` 复跑仍 PASS。本 ADR 其余边界仍成立。
- **镜像预热**：`topolvm-with-sidecar:0.42.0` 原先只导入了 CP 与 153；扩容 166 时
  直接从 GHCR 匿名拉取成功（`ctr -n k8s.io images pull`，5.1s / 136.9MiB），
  另补拉 `topolvm:0.42.0`（5.5s）与 `storage-agent:sha-52bda85`（8.8s）。
  新增节点不再必须手工导入镜像，但弱网环境下仍建议先预拉再 apply 清单。
- **CSI 组件与 A 链路并存但不互斥**：`hlvm.io/disk` 是整盘直通资源，
  `topolvm.io/capacity` 是容量资源，两者不是同一维度的调度依据。
