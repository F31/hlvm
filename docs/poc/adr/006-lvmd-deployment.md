# 006：lvmd 部署立项（B 链路供给落地 —— 重新立项）

- **状态**：重新立项（2026-11-11）。原 `openspec/changes/add-topolvm-csi-supply/` 已被用户网页提交删除（`5b54463 Delete openspec directory`，含 39 个 task，用户确认"接受现状"）。本文档替代该 openspec 变更提案，作为 B 链路"实际部署 lvmd"的立项与执行计划。
- **决策人**：平台团队
- **关联**：ADR-005（lvmd ConfigMap 聚合语义，已接受并实现）、设计 §5.3（宿主 lvm 共享锁硬门禁，已灰度验证）

---

## 1. 背景与动机

B 链路目标：让 hlvm 通过 **TopoLVM `lvmd`** 按 VG 剩余 GiB 供给 PVC（而非 A 链路的设备插件按块直通裸设备）。

本轮已完成的前置：
- ~~**§5.3 门禁已真机验证**（2026-11-11，`87d9160`+`c633cfc`）：`HLVM_HOST_WRAPPER=chroot /host` 使 agent 经宿主 lvm 二进制 + 宿主 `/run/lock/lvm` 锁读写，与 lvmd 同源同锁。真机 PASS：`chroot /host lvm version → LVM version: 2.03.16(2)`。~~
  > ⚠ **该结论已被 §11 推翻（2026-11-11 续）**：`lvm version` 只读不取锁，是假绿；
  > `chroot /host` 不切 IPC NS，任何真实写都会挂死。正确配置与落地记录见 **§11.6**。
- **`LvmdConfigReconciler` + `AggregateLVMDConfig` 已实现并通过单测**（ADR-005）：由同节点全部 `NodeVG`（`status.vgExists=true`）聚合渲染 `hlmd-lvmd-<node>` ConfigMap（一节点一份，`device-classes` 数组，稳定排序）。

尚缺的"最后一公里"（即本文档要立的）：
1. **NodeVG 真相源**：控制面/agent 从不创建 NodeVG（仅消费/更新）。真机 0 实例 → 0 ConfigMap → lvmd 无配置可消费。
2. **lvmd 进程消费者**：无 lvmd DaemonSet 落地，ConfigMap 仅被渲染而无人挂载消费。
3. **并发互斥真实验证**：§5.3 门禁只验证了"agent 经 chroot /host 调通宿主 lvm"，尚未验证"agent 与 lvmd 并发写同一 VG 时锁互斥"这一门禁的**最终目的**。

---

## 2. 真机现状盘点（2026-11-11 实测）

| 项 | 结论 | 来源 |
| --- | --- | --- |
| 集群规模 | CP `10-60-131-187` + worker `10-60-153-100`/`10-60-166-202`，全部 Ready，containerd 2.2.1，k8s v1.36.6 | `kubectl get nodes` |
| NodeVG 实例 | **0**（`No resources found`） | `kubectl get nodevgs` |
| `hlmd-lvmd-*` ConfigMap | 0（仅 `hlvm-agent-command-allowlist`） | 推理：无 NodeVG → 无渲染输入 |
| CP 宿主 LVM | LVM 2.03.16，**无 VG**（`vgs` 空） | CP `lvm version` / `vgs` |
| worker LVM | 每台有 **2×40GiB 数据盘已被 cloud-init 清除**（`wipefs -a`，disk-precheck 报「可纳管 2 块」），可在其上 `vgcreate` 造专用 VG；**须排除出设备插件(hlvm.io/disk)分配池**避免 A/B 链路抢盘 | `disk-precheck.sh` / 日记载 10:16 |
| lvmd 镜像 | `ghcr.io/topolvm/topolvm:0.42.0`（**无 `v` 前缀**，ADR-005 kind 实测用过）；`v0.42.0` 曾误报 not found。Windows/CP 出网受限，worker 节点拉取待确认 | ADR-005 L116；本机 curl 受限 |
| agent 镜像 | `ghcr.io/f31/hlvm/storage-agent`，已 public，worker 已缓存 | 真机验证 |

---

## 3. 部署架构（lvmd DaemonSet）

lvmd 必须与 agent **共用宿主 lvm 二进制与 `/run/lock/lvm` 锁**，因此 DaemonSet 须与 `daemonset-agent.yaml` **完全对齐挂载与特权基线**（§5.3）：

> **落地修正（2026-11-11 实测）**：以下为立项草稿。真实清单已落地于
> `control-plane/config/lvmd/daemonset.yaml`，与草稿有两点关键差异：
> 1. **不需要 `HLVM_HOST_WRAPPER=chroot /host`**：TopoLVM v0.42.0 的 lvmd 在
>    `internal/lvmd/command/lvm_command.go` 中把 lvm 默认封装为
>    `nsenter -m -u -i -n -p -t 1 /sbin/lvm`，直接进入宿主 PID 1 命名空间执行宿主 lvm，
>    **天然使用宿主 `/run/lock/lvm`**，与 agent 的 `chroot /host` 同源同锁（§5.3 目的达成）。
>    `HLVM_HOST_WRAPPER` 是 hlvm agent 私有 env，lvmd 不识别。
> 2. 命令为 `/lvmd --config=/etc/topolvm/lvmd.yaml`（v0.42.0 中 lvmd 是独立二进制，非
>    `topolvm lvmd` 子命令）；镜像用 `ghcr.io/topolvm/topolvm-with-sidecar:0.42.0`（与 hnb 同 digest）。

```yaml
# 草稿（已落地为 control-plane/config/lvmd/daemonset.yaml）
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: hlvm-lvmd, namespace: hlvm-system }
spec:
  selector:
    matchLabels: { app.kubernetes.io/component: lvmd }
  template:
    spec:
      serviceAccountName: hlvm-lvmd        # 新增 RBAC：读 hlmd-lvmd-* ConfigMap
      hostPID: true
      nodeSelector: { kubernetes.io/hostname: "<有 VG 的 worker>" }   # 仅落目标节点
      tolerations:
        - { key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }
      containers:
        - name: lvmd
          image: ghcr.io/topolvm/topolvm:0.42.0
          args: ["lvmd", "--config=/etc/topolvm/lvmd.yaml"]
          securityContext:
            privileged: true                # 同 agent：设备 cgroup 要求（§11）
            readOnlyRootFilesystem: false
            allowPrivilegeEscalation: true
            seccompProfile: { type: Unconfined }
          env:
            - name: HLVM_HOST_WRAPPER      # 与 agent 完全一致：chroot /host 调宿主 lvm
              value: "chroot /host"
          volumeMounts:
            - { name: host, mountPath: /host }
            - { name: dev,  mountPath: /dev }
            - { name: run-lock-lvm, mountPath: /run/lock/lvm }
            - { name: lvmd-config, mountPath: /etc/topolvm }   # 来自 hlmd-lvmd-<node>
      volumes:
        - { name: host, hostPath: { path: / } }
        - { name: dev,  hostPath: { path: /dev } }
        - { name: run-lock-lvm, hostPath: { path: /run/lock/lvm } }
        - name: lvmd-config
          configMap: { name: hlmd-lvmd-<node>, items: [{ key: lvmd.yaml, path: lvmd.yaml }] }
```

要点：
- **`HLVM_HOST_WRAPPER=chroot /host` 同样注入 lvmd 容器**：使 lvmd 调宿主 lvm（kindest 镜像无 lvm 二进制，容器自带 lvm 也须指向宿主锁目录），与 agent **同源同锁**。
- **configMap 按节点名投影** `hlmd-lvmd-<node>` → 控制面渲染即灰度下发载体（ADR-005 的"变更灰度 + 滚动重载"语义成立）。
- lvmd 无配置热加载（ADR-005 补遗：仅启动时读一次），所以 ConfigMap 变更须**滚动重启 lvmd DS**（部署层负责）。
- **互斥约束**：agent 与 lvmd 不得同时运行于"同一 VG 的写路径"且未走共享锁 —— §5.3 + 本门禁即为此。A 链路（设备插件直通）与 B 链路（lvmd）在"同一块盘/同一 VG"上**互斥**，须靠 tier/盘分配避免重叠。
- **设备插件排除**：device-plugin DaemonSet（`hlvm-disk-plugin`）须加 env `HLVM_PLUGIN_EXCLUDE_BY_ID_PREFIXES=<目标盘 by-id 前缀>`（#153 已实现），把 lvmd 专用盘排除出 `hlvm.io/disk`，否则 A 链路会与 lvmd 抢盘（见 §5 GATE-1 / §8）。

---

## 4. NodeVG 真相源策略（关键决策点）

`LvmdConfigReconciler` 需要 NodeVG 输入。两条路线，范围与风险不同：

### 路线 A —— 手工 seed（POC，快，推荐先走）
- 在目标 worker 上**先造一个 VG**（见 §5 gate1）。
- `kubectl apply` 一个 NodeVG（`spec`: nodeName/tier/thinPool）+ `kubectl patch status` 写入 `vgExists=true`、`vgUUID`、`totalBytes`/`freeBytes`。
- 立刻验证 `LvmdConfigReconciler` 渲染 `hlmd-lvmd-<node>`（控制面半边无需 agent 参与即可验证）。
- **局限**：非生产形态（真实 B 链路应由 agent 上报 VG 自动建 NodeVG）。但足以验证"渲染 + lvmd 部署 + 锁互斥"三件事。

### 路线 B —— 补全 agent VG-reporter（LVReporter，生产形态）
- agent 周期扫描宿主 VG，创建/更新 NodeVG CR（`status` 写 `vgExists`/容量）。这是 B 链路"真正"的闭环，但范围大：需 agent 新增 k8s 写客户端、NodeVG 类型客户端、扫描与对账逻辑、单写者协调（避免与控制面 `CapacityReconciler` 抢 `status`）。
- 与现有"Agent 仅写 StorageTask.status，控制面回写 NodeVG/NodeDisk"的单写者纪律（见 `reporter/kube_rw.rs:3`）需重新界定边界。

**建议**：先 A 后 B。A 用于在本迭代真机坐实"lvmd 可部署 + 锁互斥"，B 作为后续独立立项补全自动闭环。

---

## 5. 可行性门禁（执行前须先过）

- **GATE-1（worker 有 VG）✅ 已可解**：每台 worker 已有 2×40GiB 数据盘被 cloud-init 清除（`wipefs -a`，disk-precheck 报「可纳管 2 块」），属已授权范围。可在其上 `vgcreate` 造一个**专供 lvmd** 的 VG（含 free 空间）。**关键约束**：该盘须**排除出设备插件(hlvm.io/disk)的分配池**（A/B 链路重叠风险，见 §8），否则直通链路会与 lvmd 抢同一块盘。建议选其中一块、显式不纳入设备插件 tier。

  **排除机制（#153 已实现）**：device-plugin 新增 env `HLVM_PLUGIN_EXCLUDE_BY_ID_PREFIXES`（逗号分隔的 by-id 名前缀），命中前缀的盘不纳入 `hlvm.io/disk` 分配池。该前缀匹配 `/dev/disk/by-id/` 之后的**名**（末段），故可在 device-plugin DaemonSet 上设置一个**只命中目标 worker 那块 lvmd 盘**的前缀（如该盘 by-id 的唯一序列号/型号前缀），实现「全局设置却仅排除目标盘」——无需 per-node 模板。
- **GATE-2（lvmd 镜像可拉取）✅ 已可解**：节点出网 `docker.io`/`quay.io` 不可达、ghcr 是否托管 topolvm 待核，但 **WSL relay 模式已验证可行**（WSL Docker daemon `docker pull` → `docker save` → scp → 节点 `ctr -n k8s.io import`，HdCdTc/jcoOj0 实证）。lvmd 镜像无论来自 docker.io/quay/ghcr，均可经此分发到三节点。

---

## 6. 分阶段执行

| 阶段 | 动作 | 退出判据 |
| --- | --- | --- |
| P0 立项 | 本文档获批；过 GATE-1/2 | 用户确认路线 A；worker VG + 镜像可达 |
| P1 真相源 | 目标 worker 造 VG（如需）；`kubectl apply` + `patch status` 建 NodeVG | `kubectl get nodevgs` 见 1 实例且 `vgExists=true` |
| P2 渲染验证 | 确认 `hlmd-lvmd-<node>` 由控制面渲染且内容正确 | ConfigMap 存在，`device-classes` 含该 VG、device-class 名稳定 |
| P3 lvmd 部署 | 落 `control-plane/config/lvmd/daemonset.yaml` + RBAC；目标节点滚动起 lvmd | Pod Running；lvmd 日志 `configuration file loaded` 且 device_classes 非空 |
| P4 锁互斥验证 | agent（wrapper 开）与 lvmd 并发对同 VG 做 lvm 操作；观察 `/run/lock/lvm` 串行 | 无 `device-mapper`/LVM 并发损坏；两侧操作均成功且日志无竞争报错 |
| P5 清理/回滚 | lvmd DS 下线（保留 NodeVG/ConfigMap 供回归）；更新 CHANGELOG/记忆 | 集群回归基线（无残留 Pod） |

**执行状态（2026-11-11 真机）**：
P0 ✅（路线 A 获批）→ P1 ✅（`hlvm-lvmd-vg-153` + NodeVG seed `vgExists=true`，§10.3）
→ P2 ✅（`hlmd-lvmd-10-60-153-100` 渲染一致，§10.3）→ P3 ✅（lvmd DS 1/1 Ready，§10.6）
→ P4 ✅（锁同源静态身份 + 10 路并发 lvcreate 全绿，§10.6，**agent 侧 §5.3 改造未落地，边界见 §10.6 末**）
→ P5 ⏳（本轮**保留** lvmd 在线以支撑后续联调，未回滚）。


---

## 7. 验证判据（PASS 定义）

- **渲染正确**：`hlmd-lvmd-<node>` 的 `lvmd.yaml` 含 `device-classes:` + 目标 VG 条目，`device-class` 名符合 ADR-005（tier/deviceClassName 回退）。
- **lvmd 起得来**：Pod `Running`，lvmd 进程不以 "should have at least one device-class" 退出（ADR-005 已证明空列表会退出）。
- **锁互斥**：agent 与 lvmd 同时跑 lvm 写（如 agent `vgcreate`/lvmd 持续 `lvcreate`），`/run/lock/lvm` 保证串行，无 LVM 元数据损坏、无 "Device or resource busy" 类竞争失败。
- **诚实边界**：若 GATE-1 要求"造 VG"而用户不允许真实盘变更，则 P3/P4 降级为 **kind 内 loop-VG 验证**（ADR-005 已在 kind 跑过 lvmd 0.42.0，但 loop-VG 需补），不做真机承诺。

---

## 8. 风险与诚实边界

- **NodeVG 非自动**：路线 A 是 POC 捷径；生产闭环必须路线 B。本文档不掩盖此缺口。
- **真实 VG 变更风险**：GATE-1 若需 `vgcreate`，须用户明确授权（真实基础设施写入）。
- **镜像可达性**：受 Clash TUN / 节点出网策略影响，GATE-2 可能需中转，增加部署时长。
- **A/B 链路重叠**：同一 VG 同时被设备插件直通与 lvmd 供给会冲突；须靠 tier/盘分配隔离，本计划默认 lvmd 只落"专用于 B 链路"的 VG。隔离手段已落地为 device-plugin 的 `HLVM_PLUGIN_EXCLUDE_BY_ID_PREFIXES` 排除旋钮（#153）：lvmd 专用盘在设备插件侧被排除，A 链路不会把它当可分配盘。生产化时建议改为按节点 label 选择排除集（避免全局 env 依赖 by-id 唯一性）。

---

## 9. 本次待决策

1. **NodeVG 路线**：先走路线 A（手工 seed + 真机验证），还是直接路线 B（补全 agent VG-reporter）？→ 建议 A。
2. **worker VG**：是否允许在目标 worker 上 `vgcreate` 造一个专用 VG（真实盘或 loop）？若不允许，P3/P4 转 kind 验证。
3. **落地位置**：lvmd 清单放 `control-plane/config/lvmd/`（纳入控制面 config 树与 CI 校验）？

---

## 10. 实施记录（POC，2026-11-11）

本節记录执行 P0–P5 过程中发现并修正的真实问题，避免后续重蹈。

### 10.1 device-plugin by-id 解析 bug（已修复）

部署 device-plugin 到真实 worker 后，日志报 `无 by-id 链接，设备 ID 回退为 dev-<name>`，导致
排除旋钮（`HLVM_PLUGIN_EXCLUDE_BY_ID_PREFIXES`，按 by-id 名前缀）**完全失效**（回退态 `by_id=None`，
`is_excluded` 恒 false），节点 `hlvm.io/disk` 把两块盘都报了出去。

根因：`plugin::rescan()` 调的是 `crate::agent::resolve_by_id(p)`，它**硬编码解析宿主 `/dev`**，而 device-plugin
容器把宿主 `/dev` 挂在 `/host/dev`（env `HLVM_DEVICE_ROOT=/host/dev`）。容器内真实 `/dev` 是 runc 的 tmpfs，
`/dev/disk/by-id` 不存在 ⇒ 解析失败 ⇒ 回退 dev-<name>。

修复：`rescan()` 改用插件自己的 `resolve_by_id_in(device_root(), p)`（已含多别名择优、走 `HLVM_DEVICE_ROOT`），
真实节点即可解析出 `virtio-UCLOUD_DISK_VDx` 稳定 by-id，排除旋钮生效，且设备 ID 从易漂移的 `dev-<name>`
升级为稳定 by-id（对 StorageTask 安全约束更友好）。kind 等无 udev 环境仍走回退（行为不变）。

> 教训：设备插件与 agent 共用 `resolve_by_id_under`，但**谁提供 dev_root 必须各自正确**；插件侧曾误用
> agent 的默认 `/dev`，是个隐蔽的「两套挂载、同一函数」陷阱。

### 10.2 真实节点 by-id 跨 worker 同序列号（设计影响）

目标 worker `10-60-153-100` 与 `10-60-166-202` 的数据盘 by-id 均为 `virtio-UCLOUD_DISK_VDB`/`VDC`
（UCloud 云盘序列号跨主机相同）。因此**按 by-id 前缀排除无法在全局 DaemonSet 上区分 worker**——
若全局设置前缀 `virtio-UCLOUD_DISK_VDB`，会把三台 worker 的 vdb 全排除，破坏其它 worker 的 A 链路分配池。

POC 对策：device-plugin DaemonSet 加 `nodeSelector: kubernetes.io/hostname: 10-60-153-100`，**仅落目标
worker**并带排除 env，验证旋钮本身即可，不波及其它节点。生产化须改 per-node 排除（节点 label 或
Node-local DevicePluginConfiguration），而非依赖 by-id 唯一性。

### 10.3 结论

- 排除旋钮 + by-id 解析修复均已落地（commit 见 §11）。真实 worker 验证：vdb 被排除、`hlvm.io/disk` 仅剩 vdc。
- lvmd 部署（P2–P5）继续按路线 A（手工 seed NodeVG + 节点级 lvmd DS + §5.3 共享锁互斥验证）。

### 10.4 lvmd 清单落地与宿主锁同源确认（#159）

- **锁同源机制（关键）**：TopoLVM v0.42.0 `internal/lvmd/command/lvm_command.go` 默认前缀为
  `["/usr/bin/nsenter","-m","-u","-i","-n","-p","-t","1","/sbin/lvm"]`，即 lvmd **不跑容器内 lvm**，
  而是进入宿主 PID 1 命名空间执行宿主 `/sbin/lvm`。因此 lvmd 与 agent（`chroot /host lvm`）
  **共用同一份宿主 lvm 二进制与同一个宿主 `/run/lock/lvm`**，§5.3 门禁目的在机制层成立；
  清单只需 `hostPID: true` + `privileged` + 宿主 `/dev`，**无需** `HLVM_HOST_WRAPPER`（那是 agent 私有 env）。
- **清单**：`control-plane/config/lvmd/daemonset.yaml`（独立 SA `hlvm-lvmd`、无 RBAC —— lvmd 不访问 API；
  配置经 ConfigMap `hlmd-lvmd-10-60-153-100` 挂到 `/etc/topolvm/lvmd.yaml`；socket `/run/topolvm`）。
- **镜像（GATE-2）**：节点直连 `ghcr.io` 极慢（37 KiB/s 起步），单层 210 MiB 需十几分钟；
  加 `--platform linux/amd64` 避免多架构 index 的额外 manifest/层是关键提速手段（实测 2.2 MiB/s 起）。
  WSL 侧无该镜像缓存，relay 不可用，最终以节点后台 `ctr images pull` 完成预拉。

### 10.5 镜像选型修正：POC 只需 plain `topolvm`（210 MiB → 73 MiB）

`topolvm-with-sidecar` 与 plain `topolvm` **前 5 层完全相同**，差异只在追加的 CSI sidecar 层
（`802f1e22` 37.8 + `285dff0c` 36.0 + `7bc7b4fe` 36.3 + `722d0d45` 13.3 + `d62a3f27` 13.4 ≈ 137 MiB），
而 lvmd 只需要 `/lvmd`。故清单改用 `ghcr.io/topolvm/topolvm:0.42.0`（amd64 层共 73.3 MiB），
真机弱网下拉取代价降到约 1/3。生产若需同镜像复用 CSI 侧车再换回，不影响本 ADR 的机制结论。

**真机弱网旁路（可复用做法）**：单连接被限速到 90–500 KiB/s 且抖动剧烈，串行 `ctr pull` 在 210 MiB 上
跑 8 分钟只到 66 MiB。改用「HTTP Range 分块 + 多连接并行」后实测吞吐提升到约 1 MiB/s 量级：
按 2 MiB 切块、8 并发、经本机代理拉 blob，本地按序拼装并校验 sha256，组装成 OCI layout
（`oci-layout` + `index.json` + `blobs/sha256/*`）后打 tar，`scp` 到节点 `ctr -n k8s.io images import`。
脚本：`docs/poc/scripts/fetch-oci-parallel.py`（分块并行下载 + 组装 OCI layout，通用化）；
`scp` 到节点后 `ctr -n k8s.io images import`（实测 73 MiB 上传 17.7 s、import 2.7 s）。
**关键点**：`index.json` 的 `manifests[0].size` 必须等于 manifest blob 的真实字节数，
且 `annotations["io.containerd.image.name"]` 决定 `ctr import` 后镜像的本地名字。

### 10.6 lvmd 部署与门禁实测结论（#159–#161，2026-11-11）

**部署结果**：`hlvm-system/hlvm-lvmd` DS `1/1 Ready`、`RESTARTS=0`，仅落 `10-60-153-100`；
启动日志一次性加载成功：

```
configuration file loaded
  device_classes=[{name: hlvm-lvmd, volume-group: hlvm-lvmd-vg-153,
                   spare-gb: 0, thin-pool: {name: thinpool, overprovision-ratio: 1}}]
  socket_name=/run/topolvm/lvmd.sock  file_name=/etc/topolvm/lvmd.yaml
```

**#160 启动判据（PASS）**
| 判据 | 结果 |
| --- | --- |
| Pod Ready / 无重启 | 1/1，RESTARTS=0 |
| ConfigMap 渲染值被 lvmd 接受 | device-class / VG / thin-pool 三项与真机 VG、LV 完全一致 |
| 宿主 socket 生成 | `/run/topolvm/lvmd.sock`（srwxr-xr-x root:root） |
| livenessProbe `/lvmd health` | 通过（否则 Pod 不会 Ready） |
| 与宿主共享 PID 命名空间 | lvmd PID 291624 与宿主 PID 1 同为 `pid:[4026531836]` |

**#161 锁同源判据（PASS，机制 + 实测双证）**
1. **静态身份一致**——宿主视图 vs 容器内经 `nsenter -m -u -i -n -p -t 1` 视图：

   | 对象 | 宿主 | 容器内 nsenter |
   | --- | --- | --- |
   | `/run/lock/lvm` | dev 27 inode 2 | dev 27 inode 2（同一目录项） |
   | `/sbin/lvm` sha256 前 32 | `7e2299bed497407342a72d00099598e3` | 同 |
   | `lvm version` | 2.03.16(2) | 2.03.16(2) |
   | `vgs` | `hlvm-lvmd-vg-153 42945478656B / free 2143289344B` | 同 |

   即 lvmd 的 lvm 子进程与 agent 的 `chroot /host lvm` 落在**同一份宿主二进制 + 同一把宿主锁目录**上。
2. **并发争用**——宿主侧 5 个 + 容器内 nsenter 5 个 `lvcreate -L 64M` 同时打同一 VG：
   10/10 全部 `rc=0`，LV 尺寸均 64.00m，无任何 `lock`/`fail` 日志，`lvs` 一致，清场后残留 0。
   容器内命令耗时系统性偏长（0.47–0.72 s vs 宿主 0.14–0.43 s），含 `ctr exec` 开销，
   方向上与「排队等同一次全局锁」一致，但**不足以单独作为等待证据**，故以第 1 项为判据。

**诚实边界**
- 本验证证明「同一把锁」与「并发不出错」，**未**证明锁等待的精确时序（无 instrumentation）。
- 本次并发场景是同一 VG 上的 LV 创建；agent 实际写的是 `hlvm.io/disk` 直通盘、lvmd 写本 VG，
  两者虽落在不同 VG，但**共用同一全局锁目录**，故互斥结论同样适用。
- 本节的互斥结论针对「宿主 lvm 视图」，**未**覆盖 agent 的 lvm 调用栈。
  > 更正（2026-11-11 续，见 §11）：此处原写「agent 侧 `chroot /host` 改造尚未落地、仍
  > `Command::new("lvm")` 调镜像内 lvm」，与代码不符。§5.3 的读写路径 wrapper 改造
  > （`agent/src/lvm/mod.rs::lvm_argv_with` + `executor::execute`）及灰度门禁均已落地，
  > 且 kindest/node 基础镜像内无 lvm 二进制。真正常驻缺失的是真机上没有常驻
  > `hlvm-storage-agent` DaemonSet；进程级并发已由 §11 的判据补齐。

**可复跑脚本**：`docs/poc/scripts/lvmd-lock-verify.sh <node-ip> [task-id] [vg]`
（1/2/3 三步与本表一一对应；不需要 agent 在位）。需要 agent + lvmd 同时在位的业务级压测仍用
`docs/poc/scripts/concurrency-lvmd-test.sh`。

---

## 11. 进程级锁同源复验：§5.3 默认 wrapper 的真实缺陷与修法（2026-11-11 续）

> **阅读提示（2026-11-12）**：§1、§2、§3、§10 中把 `chroot /host` 作为有效方案、
> 或写成「同源同锁已达成」的描述，都是**当时的历史记录**，已被 §11.4 的真机写路径
> 实测推翻。当前正确配置、落地范围与判据一律以 **§11.6** 为准；尤其不要照抄
> §3 历史 YAML 示例里的 `HLVM_HOST_WRAPPER`（lvmd 本身也不识别该 env，见 §6）。

### 11.1 补的是哪一条

§1 第 3 项把「agent 与 lvmd 并发写同一 VG 时锁互斥」列为 §5.3 门禁的**最终目的**；
§10.6 只证到「宿主 lvm 视图」。本节补 agent 调用栈这一层。

**同时更正历史表述**：§10.6、ADR-007 §5、CHANGELOG 曾写「§5.3 的 `chroot /host`
改造尚未落地、agent 仍 `Command::new("lvm")` 调镜像内 lvm」——与代码不符。
`agent/src/lvm/mod.rs::lvm_argv_with` + `executor::execute` 的 wrapper 改造早已落地且有单测，
`agent/config/daemonset-agent.yaml` 的 `/host`、`/dev`、`/run/lock/lvm` 挂载齐备；
且 agent 镜像（kindest/node）内**本就没有 lvm 二进制**（裸调用 rc=127）。
真正缺的是「真机上没有常驻 `hlvm-storage-agent` DS」与「进程级并发实测」。

### 11.2 判据设计

新增 `docs/poc/scripts/agent-lvmd-lock-verify.sh`：一次性 probe Pod 复用
`storage-agent:sha-7e76f95` 镜像 + `HLVM_HOST_WRAPPER` + `/host`,`/dev`,`/run/lock/lvm`
挂载（与 agent DS 清单约定一致）；**不部署常驻 agent**——agent 是唯一 PV/VG 写路径，
起主循环会触发 reconcile，对本判据是无关变量且有副作用。不硬编码 wrapper：从 Pod 内
读 env，按 `lvm_argv_with` 的 `split_whitespace` 语义现场拼命令。

全流程走 `kubectl exec`（agent Pod 的 wrapper / lvmd Pod 的 `nsenter -t 1`），不用 SSH：
WSL→云主机 22 会被 Clash TUN 的 fake-ip 劫持，判据不能架在那条链路上。

### 11.3 静态身份判据：PASS

| 判据 | 原始证据 |
| --- | --- |
| env 注入 | `WRAPPER=chroot /host`（或 nsenter 变体，逐字一致） |
| 容器内无裸 lvm | `BARE_LVM=absent`，`BARE_LVM_RC=127` |
| wrapper 语义调到宿主 lvm | `WRAPPED_RC=0`，`LVM version: 2.03.16(2) (2022-05-18)` |
| 读到宿主 VG 视图 | `WRAPPED_VGS=hlvm-lvmd-vg-153` |
| 同一把锁目录 | `/run/lock/lvm` dev+inode = `27 2`（agent / lvmd 双侧一致） |
| 同一份二进制 | `/sbin/lvm` sha256[0:32] = `7e2299bed497407342a72d00099598e3`（双侧一致） |

### 11.4 动态判据：默认 wrapper FAIL —— 这是 §5.3 的真实缺陷

10 路并发（agent 5 × lvmd 5）全部无输出挂起，连 `lvs` 都被堵住。诊断：

- `lslocks`：agent 侧锁路径 `/host/run/lock/lvm/V_hlvm-lvmd-vg-153`，lvmd 侧
  `/run/lock/lvm/V_hlvm-lvmd-vg-153`；一个进程持 `WRITE` 锁、其余 `WRITE*` 等待。
- 持锁进程 `wchan=__do_semtimedop`（SysV 信号量等待）。
- **单路对照实验（排除并发竞态）**，同一个 agent 镜像 Pod 内：

  | 调用栈 | 单路 `lvcreate -y -L 64M` |
  | --- | --- |
  | `chroot /host lvm ...`（旧 M15 灰度默认，2026-11-12 已废弃） | **rc=124**（30s 超时）、无输出，持锁卡死 |
  | `nsenter -t 1 -m -u -i -n -p -- lvm ...` | **rc=0**，`probe-nsenter 67108864B`，清场成功 |

**根因**：`chroot` 只替换文件系统根，**不切 IPC / mount / PID 命名空间**。
lvm/libdm 的 udev 同步依赖 SysV 信号量：宿主 udev 在宿主 IPC NS 里 post，
而 chroot 后的 lvm 仍在容器 IPC NS 里等 ⇒ 持着 VG flock 永久等待，堵死所有 lvm 操作。
因此「同一份二进制 + 同一把锁目录」是**必要但不充分**条件，§5.3 门禁此前只验了
`lvm version`（只读、不取锁），漏掉了写路径。

**修法（已验证并于 2026-11-12 落地，见 §11.6）**：`HLVM_HOST_WRAPPER` 改为
`nsenter -t 1 -m -u -i -n -p --`（`lvm_argv_with` 会在其后追加 `lvm`，命令行合法）。
该变体下完整判据 **PASS**：单路预检 rc=0，10/10 路 `lvcreate` rc=0，
无 lock/fail/error 日志，宿主 lvs 可见 `ckagent1..5` + `cklvmd1..5`，
清场后 `REMAIN=0 / LV_TOTAL=1`（只剩 thinpool），VG 回到基线。

> 落地范围（原「本轮未改产品代码与默认配置」的记录已失效）：m15 注入值、
> agent DS 注释、Rust 模块注释与单测、设计 §5.3、POC 并发判据脚本，
> 以及把 §5.3 门禁断言从只读 `lvm version` 升级为一次真实写。详见 **§11.6**。

### 11.5 判据脚本自身的三处坑（已修，写进脚本注释）

1. `kubectl exec -i ... sh -s` + 容器内后台子进程：后台进程只要还持有 exec 的 stdout
   管道，kubectl 就等不到 EOF ⇒ 判据无限挂起。改为 WSL 侧 10 路**独立短** `kubectl exec`。
2. 未加引号的 heredoc 里注释写了反引号 ⇒ 触发命令替换，把注释文字当命令执行，
   还污染了 ERR trap 的 fails 计数。heredoc 一律 `<<'EOS'`，注释禁用反引号。
3. 增加 **4.0 单路写能力预检**：wrapper 不具备写能力时立刻 FAIL + 打印诊断 +
   `pkill -9 -x lvm` 清理孤儿，绝不让 10 路并发把 VG 锁死。能力缺失 SKIP 不计 PASS，
   读不到宿主 lvs 一律 FAIL 不做无据判定。

### 11.6 修法落地（2026-11-12）

把 §11.4 的修法从「判据脚本里的可行方向」变成产品侧默认配置与硬门禁。

**改动面**

| 文件 | 改动 |
| --- | --- |
| `docs/poc/scripts/host-wrapper-gate.sh`（新增） | §5.3 真实写门禁：从 Pod 内读 `HLVM_HOST_WRAPPER`，按 `lvm_argv_with` 的 split_whitespace 语义现场拼命令，执行 lvcreate → lvs 核对 → lvremove → 残留 0；timeout 置于 wrapper **之后**（宿主 NS 侧）并带 `-k`；输出 `GATE_RESULT=PASS/FAIL/SKIP`，能力缺失 SKIP 不计 PASS。支持 `MODE=probe`（自起一次性 Pod）与 `MODE=pod`（指向已部署 agent Pod）。 |
| `scripts/m15-integration.sh` | `M15_HOST_WRAPPER=1` 注入值改为 `nsenter -t 1 -m -u -i -n -p --`；删除只读 `lvm version` 断言，改为调用 `host-wrapper-gate.sh` 并按 `GATE_RESULT` 判 PASS/FAIL/SKIP；新增可选 `M15_GATE_VG`。默认仍不注入，kind 集成不受影响。 |
| `agent/config/daemonset-agent.yaml` | 注释改为 nsenter 推荐值，写明依赖 `hostPID: true` + `privileged`，禁止 `chroot /host`。 |
| `agent/src/lvm/mod.rs` / `agent/src/executor/mod.rs` | 模块与函数注释改为推荐值 + IPC NS 根因；新增 `lvm_argv_matches_recommended_nsenter_wrapper` 单测钉死 argv 形态。 |
| `control-plane/internal/controller/deploy_manifests_test.go` | 新增 `TestHostWrapperGateConfigConsistent` 防注入值 / 门禁调用 / 脚本默认值回退。 |
| 设计 §5.3、`control-plane/config/lvmd/daemonset.yaml`、`concurrency-lvmd-test.sh`、`lvmd-lock-verify.sh` | 同步更正把 `chroot /host` 当有效示例的描述。 |
| `agent-lvmd-lock-verify.sh` | 默认 `WRAPPER` 改为 nsenter；`WRAPPER='chroot /host'` 变为显式负向对照。 |

**真机复验（2026-11-12，worker `10-60-153-100`，VG `hlvm-lvmd-vg-153`）**

| 场景 | 结论 | 原始证据 |
| --- | --- | --- |
| 默认 nsenter | **GATE_RESULT=PASS / rc=0** | `INFO_VERSION=LVM 2.03.16(2)`、`CREATE_RC=0`、`Logical volume "hlvm-gate-266615" created.`、`LVS_LIST=hlvm-gate-266615 thinpool`、`REMAIN=0` |
| `WRAPPER='chroot /host'` 负向对照 | **GATE_RESULT=FAIL / rc=1** | `CREATE_RC=137`（宿主 `timeout -k` 截断挂死的 lvcreate）、`CLEANUP_REMAIN=0`、宿主 lvs 仍可读、`orphan_lvm=0`、probe Pod 已清 |
| 清场终态 | 回到基线 | VG 只剩 `thinpool`，`hlvm-pvc-poc` 无 Pod，3 节点 Ready |

**脚本自身缺陷（已修）**：负向对照第一轮暴露 timeout 在 LV 落盘之后才杀进程，
FAIL 分支直接退出，把 `hlvm-gate-264175` 留在业务 VG 上。现加 `run_host()` 统一
wrapper 前缀、`trap cleanup_lv EXIT` 兜底、各失败分支打印 `CLEANUP_REMAIN`，
重跑验证 `CLEANUP_REMAIN=0`。

本轮当时的诚实边界见 **§11.7**；其中「未部署常驻 agent DS」与
「`MODE=pod` 未跑完整相位」两条已由 **§12**（2026-11-12 续）补齐，
其余边界仍成立。

### 11.7 诚实边界

- **依旧不是 agent 主循环**：probe Pod 复用同镜像/同 env/同挂载并复现 lvm 调用栈，
  但没有跑 `--mode=agent` 的 reconcile；§1 第 3 项在「修法落地后的真实 agent 进程」上仍未验。
  > **2026-11-12 更正**：本条已由 **§12** 补齐（真机完整 `verify-agent` 灰度相位
  > + 常驻 agent DS）。以下边界在本 ADR 记录时点成立，不再代表当前状态。
- 修法 `nsenter` 要求 agent Pod 具备 `hostPID: true` + `privileged`（现有清单已满足），
  但**kind 节点无 lvm2**，kind 集成依旧无法覆盖该路径。
- 只覆盖单 worker、单 VG；NodeVG 仍是手工 seed；容量上报仍按 VG free 2 GiB 而非
  thin-pool 36G（ADR-007 §5）。
- 真机重启后的 B 链路自愈已复验：三节点 Ready，lvmd DS、topolvm controller/node
  在 kubelet 恢复后 ~40s 全部 Running，`pvc-supply-e2e.sh` 重跑
  **PASS**（PVC Bound → 1Gi thin LV → 写 16 MiB → PV/LV 全回收）；
  VG 与 36G thin-pool 随宿主重启存活，`thin_count` 回到 0。

**可复跑脚本**：
```bash
# 默认（当前 M15 灰度配置）预期 FAIL，验证门禁缺陷
bash docs/poc/scripts/agent-lvmd-lock-verify.sh
# 修法变体，预期 PASS
WRAPPER='nsenter -t 1 -m -u -i -n -p --' bash docs/poc/scripts/agent-lvmd-lock-verify.sh
```

---

## 12. 常驻 agent DS 上线：主循环与 MODE=pod 闭环（2026-11-12 续）

§11.7 记下的最大空白是「验的是调用栈，不是 agent 主循环」。本节把这条补上：
真机跑通完整 `M15_HOST_WRAPPER=1` 的 `verify-agent` 相位，并保留一个常驻
`hlvm-storage-agent` DaemonSet，再在 agent 常驻状态下复跑 B 链路 E2E。

### 12.1 上线前发现：手工 seed 遗留的孤儿 StorageTask

真机上有一条 9 小时前创建、从未被消费的
`StorageTask/vg-hlvm-lvmd-vg-153-vgcreate`（`spec.disks` 指向
`/dev/disk/by-id/virtio-UCLOUD_DISK_VDB`，正是当前 B 链路 VG 的 PV）：

- `status` 子资源**整个缺失**，`spec.ttl` 为空，无 `approvedBy`；
- `run_task_reconciler` 每 10s 轮询，`is_terminal` 只认 `Succeeded`/`Failed`；
  `expired_reason` 在 `ttl` 为空时直接返回 `None` ⇒ agent 上线瞬间就会取走它；
- 本例 `executor::plan_execution` 因「破坏性行为缺 approvedBy」判 `Rejected`，
  **不会真写盘**，但会回写 `Failed` 并污染 NodeVG 状态；换成带审批或
  `pvcreate` 类型的任务就可能直接对承载 B 链路的盘执行写操作。

处理方式是先证明「删了不会被重建」，再删：
`NodeVG.status.vgExists=true`，而 `DesiredStorageTasksForVG` 只在
`!vg.Status.VGExists` 时下发 ⇒ 删除该 Task 后观察 35s，
`storagetasks` 恒为 0；`vgExists=true / freeBytes=2143289344 /
capacityStatus=available` 与宿主 VG（只剩 `thinpool`）全部不变。

> 这是**静态代码分析 + 状态核查得出的风险判断**，不是「实测 agent 把它执行坏了」：
> 我们主动避开了这次消费。不能写成破坏性实测结论。

### 12.2 完整 m15 灰度相位（real，rc=0 / 全 PASS 无 SKIP）

```bash
KUBECONFIG=~/.kube/hlvm-real.conf \
M15_TARGET=real KCTX=kubernetes-admin@kubernetes \
IMG_TAG=sha-87d9160 M15_HOST_WRAPPER=1 \
M15_GATE_VG=hlvm-lvmd-vg-153 \
M15_SSH_USER=root M15_SSH_KEY=/home/jinfeng105/.ssh/hlvm-real \
  bash scripts/m15-integration.sh verify-agent
```

`sha-87d9160` 是含 wrapper 改造、且**三台节点都已缓存**的镜像 tag，用来避开
弱网拉镜像；`pick_test_node` 选中 `10-60-153-100`（有 VG 的 worker）。

| 判据 | 结论与原始证据 |
| --- | --- |
| agent 就绪 | 被测节点上确有 Ready 的 agent Pod（非 rollout 假绿） |
| `MODE=pod` 门禁 | **GATE_RESULT=PASS**：从真实 Pod 读到 `WRAPPER=nsenter -t 1 -m -u -i -n -p --`，`CREATE_RC=0`、`Logical volume "hlvm-gate-279785" created.`、`REMAIN=0` |
| 节点名 / kube 客户端 | 日志含 `node="10-60-153-100"` 与「进入 StorageTask 回写协调循环」 |
| 任务状态回写 | `message=命令执行失败: No device found for /dev/disk/by-id/m15-agent-nonexistent.` —— 这条同时证明 agent 的 `execute()` 经 wrapper 走到了**宿主 lvm**，否则会是容器内 `lvm: not found` |
| NodeDisk 观测写回 | `health=healthy`（21s） |
| 占用判定 | ext4 loop 盘 `occupiedBy=filesystem`、`phase=Discovered`（未通过预检，27s） |

相位自动清场：DS 撤销、`m15-*` CR 清零、`/dev/loop77` 与
`/tmp/m15-occ.img` 释放、VG 只剩 `thinpool`。

### 12.3 常驻 DS 与 B 链路回归

新增 `docs/poc/scripts/deploy-agent-real.sh`，把 12.1 的安全前置固化为硬判据：
扫描本节点所有非终态 StorageTask，默认 **FAIL 并拒绝部署**（不静默删），
只有 `PURGE_ORPHAN_TASKS=1` 才显式删除 + 观察不重建；随后 apply 单节点常驻
DS、按「目标节点存在 Ready Pod」判就绪、校验 env/hostPID、调用
`host-wrapper-gate.sh MODE=pod`、采集主循环日志与 `RESTARTS`。

真机一次跑通：`SUMMARY: PASS=16 FAIL=0 SKIP=0 RESULT=PASS`，
常驻 Pod `hlvm-storage-agent-2k6qx`。

**agent 常驻状态下**复跑 `pvc-supply-e2e.sh`：**PASS**
（PVC 1Gi Bound → PV 拓扑亲和 → Pod ext4 写 16 MiB → VG 新增
`1073741824B` thin LV → 删除后 PV/LV 全回收）。终态：3 节点 Ready、
4 个 DS（disk-plugin / lvmd / storage-agent / topolvm-node）、
`RESTARTS=0`、VG 只剩 `thinpool`、`orphan_lvm=0`、PVC/PV/StorageTask/NodeDisk
全为 0、容量注解回到 `capacity.topolvm.io/hlvm-lvmd=2143289344`。

### 12.4 诚实边界

- 常驻 DS 用 `nodeSelector` 限定单个 worker（POC 边界），**不是三节点全量部署**；
  `verify-agent` 相位的临时 DS 也已在结束时撤销，当前在位的只有这一个。
- 镜像用节点缓存的 `sha-87d9160`，不是当前 HEAD 的 CI 产物；验的是 wrapper
  配置与主循环行为，不构成「当前 HEAD 二进制已上线」的结论。
- NodeVG 仍手工 seed、`LVReporter` 未接；容量上报仍按 VG free 2 GiB 而非
  thin-pool 36G；只覆盖单 VG。
- 孤儿 Task 的风险是静态分析 + 状态核查推断，未让它真的被消费（见 12.1）。
- 本轮**没有新增产品代码改动**，改动面是 POC 脚本与文档；`m15-integration.sh`
  沿用 §11.6 已落地的 nsenter 注入与新门禁，未再修改。

**可复跑命令**：

```bash
# 部署 / 复验常驻 agent（含孤儿 Task 前置扫描 + MODE=pod 门禁）
KUBECONFIG=~/.kube/hlvm-real.conf bash docs/poc/scripts/deploy-agent-real.sh
# 撤掉常驻 DS
KUBECONFIG=~/.kube/hlvm-real.conf bash docs/poc/scripts/deploy-agent-real.sh --cleanup
# agent 常驻状态下复验 B 链路
KUBECONFIG=~/.kube/hlvm-real.conf bash docs/poc/scripts/pvc-supply-e2e.sh
```

## 13. 多节点扩容：双 worker + CI 镜像上线（2026-11-12 续）

### 13.1 起点与本轮目标

真机复查发现 **三台节点各有两块 40G 空白盘**（153 的 `vdb` 已建 VG、`vdc` 空闲；
CP 与 166 的 `vdb`/`vdc` 全空），所以 §12.4 的「单 worker」是**软件限制而非资源限制**。
卡点有三个，逐一对应本轮的改动：

| 卡点 | 原因 | 改动 |
| --- | --- | --- |
| lvmd DS 写死 `hlmd-lvmd-10-60-153-100` | 两节点 VG 名不同 ⇒ 配置内容不同，而 K8s 的 ConfigMap 卷名是静态的 | 聚合 CM + initContainer 按 `NODE_NAME` 投影 |
| 三个 DS 写死 `kubernetes.io/hostname` | 无法随节点扩缩 | 统一 `hlvm.io/lvmd=true` 标签选择器 |
| `kubectl exec ds/...` 任取 Pod | 双节点下有一半概率读到另一节点的 VG，得出「LV 不存在」的假结论 | 全部改为按 `spec.nodeName` 定点取 Ready Pod |

同时把 §12.4 的「镜像是节点缓存旧产物」边界收窄：改用 **GHCR 上的 CI 产物
`ghcr.io/f31/hlvm/storage-agent:sha-52bda85`**（两节点均实测可匿名拉取）。

### 13.2 关键结构：按节点投影 lvmd.yaml

- 真相源不变：`LvmdConfigReconciler` 仍按 `LvmdConfigName(node)` 渲染 per-node
  ConfigMap `hlmd-lvmd-<node>`（§2.1 / ADR-005）。新建 166 的 NodeVG 后，
  **控制器自动渲染出了 `hlmd-lvmd-10-60-166-202`**，无需改控制器代码。
- 新增聚合 CM `hlvm-lvmd-all`，`data` 的 key 是节点名、value 是该节点的
  `lvmd.yaml`。lvmd DS 挂它到 `/etc/topolvm-all`，initContainer 用 Downward API
  的 `spec.nodeName` 取对应 key 拷进 emptyDir `/etc/topolvm/lvmd.yaml`，
  主容器再以原路径消费。于是 **一个 DS 可服务任意节点**，扩缩节点 = 打标签 + 同步聚合 CM。
- initContainer 复用 CSI node 同款 `topolvm-with-sidecar:0.42.0`（内含 `sh`），
  不引入第三种镜像；拷贝前校验文件存在、拷贝后 `grep volume-group`，
  取不到 key 会明确报错而不是静默用空配置启动 lvmd。
- `expand-lvmd-nodes.sh` 从集群里的 per-node CM **重新生成**聚合 CM 并逐字节核对，
  避免仓库快照与控制器渲染结果脱节；`TestLvmdPOCArtifactsConsistent` 把
  seed ↔ per-node CM ↔ 聚合 CM ↔ DS 投影 ↔ 判据定点取 Pod 全部钉死。

### 13.3 顺序纪律与窗口期 Task

顺序必须是 **建 VG → seed NodeVG + patch status → 清窗口期 Task → 生成聚合 CM →
打标签 → apply 清单 → 判就绪**。先打标签会让 lvmd/agent 立刻调到还没配置的节点：
initContainer 取不到 key 而 CrashLoop，agent 还会消费刚下发的 `vgcreate` Task。

实测再次复现 §12.1 的孤儿 Task：seed `hlvm-lvmd-vg-202` 的窗口期产生
`vg-hlvm-lvmd-vg-202-vgcreate`（`type=vgcreate`、目标盘正是刚建 VG 的 `vdb`、
无 `approvedBy`、无 `ttl`、无 `status.phase`）。脚本默认 **FAIL 且不静默删除**；
在确认 `NodeVG.vgExists=true`（控制器只在 `!vgExists` 下发，删后不重建）后，
显式 `PURGE_WINDOW_TASKS=1` 才清理，并观察 35s 恒为 0。清理条件收紧为
「目标节点 + `vgcreate` + 无审批」，任一不符即拒绝自动清理。

### 13.4 真机实测（逐相位 → all）

| 相位 | 首跑 | 修复后 |
| --- | --- | --- |
| `DRY_RUN=1` 只读前置 | PASS=4 / SKIP=1（预期） | 抓到 VG 名不能从节点名推导的 bug，改显式映射 |
| `prepare` | FAIL=1（窗口 Task 闸门，符合设计） | **PASS=8 / FAIL=0 / SKIP=0** |
| `deploy` | FAIL=1（153 旧 Pod 滚动竞态） | **PASS=12 / FAIL=0 / SKIP=0** |
| `verify` | — | **PASS=21 / FAIL=0 / SKIP=0** |
| `all` 全量回归 | — | **PASS=35 / FAIL=0 / SKIP=0** |

关键证据：

- 166 建出 `hlvm-lvmd-vg-202`（`vg_size=42945478656B`、`vg_free=2143289344B`、
  `thinpool=38654705664B`）；重跑走幂等分支 `VG_EXISTS=1`，**不重复 `pvcreate`**。
- 三个 DS（lvmd / topolvm-node / storage-agent）`desired=2`，两节点各有 Ready Pod；
  常驻 agent 镜像两节点一致为 `sha-52bda85`。
- 两个 agent Pod 的 `MODE=pod` 真实写门禁各自 PASS
  （`CREATE_RC=0` / `LVS_RC=0` / `REMAIN=0`），宿主无残留 LV。
- 容量注解两节点各 `capacity.topolvm.io/hlvm-lvmd=2143289344`（2044 MiB），
  CSIStorageCapacity 两条分别以 `nodeTopology.matchLabels` 指向 153 / 166、各 2044Mi。
- **逐节点 PVC E2E 各 PASS**：1Gi PVC Bound → PV 拓扑亲和落到对应节点 →
  ext4 写 16 MiB → 该节点 VG 新增 1 颗 `1073741824B` LV → 删除后 PV/LV 全回收。
- 终态：`storagetasks=0`、非 velero PVC=0，两个 VG 都只剩 `thinpool`。

**两次首跑 FAIL 都是判据脚本自身的缺陷，不是产品缺陷**，且都是「前提不成立就停下来」：
① `prepare` 重跑时把待清理的窗口 Task 当成硬阻塞，永远走不到清理分支；
② DS 从 hostname 改成标签选择器触发滚动更新，`deploy-agent-real.sh` 拿旧 Pod 名
去 exec，报 `cannot exec into a completed pod`。修法分别是「显式批准 + 阶段 2 逐条核验
特征」与「等 DS generation/updated/ready 收敛 + 门禁前重新定点取 Pod」。

### 13.5 诚实边界

- **只扩到 2 个 worker**，CP 未扩（taint 且无 VG 需求）；A 链路 `hlvm-disk-plugin`
  仍只在 153。若把设备插件扩到 166，必须同时设
  `HLVM_PLUGIN_EXCLUDE_BY_ID_PREFIXES=virtio-UCLOUD_DISK_VDB`，否则会把承载
  B 链路 PV 的整块盘分出去。
- **聚合 CM 由脚本同步，不是控制器直接渲染**：真相源仍是 per-node CM，但若
  `LvmdConfigReconciler` 后续纠正了 per-node CM 的内容漂移，需重跑
  `expand-lvmd-nodes.sh` 才会同步到 `hlvm-lvmd-all`。生产化应由控制器直接渲染聚合 CM。
- **NodeVG 仍是路线 A 手工 seed**，`LVReporter` 未接；容量仍按 VG free 2 GiB
  上报，而非 thin-pool 36G；窗口期 Task 需显式批准清理。
- **镜像边界**：`sha-52bda85` 是上一轮 CI 产物，不是「节点缓存的旧 tag」，
  但不等于本轮最终 HEAD 的 tag。本轮未改 `agent/src` / `Cargo.toml` / `Cargo.lock`
  （`git diff 52bda85 -- agent/src agent/Cargo.toml agent/Cargo.lock` 为空），
  agent 二进制与当前 HEAD 等价；**「当前 HEAD 的 tag 已上线」这一字面结论仍不成立**，
  要彻底闭合需在最终 commit 的 CI 产物出来后再切一次 tag。
- **未跑 `m15 all`**：`verify-agent` 相位会 `delete ds hlvm-storage-agent` 并起自己的
  临时单节点 DS，会撤销本轮常驻 DS；且 m15 若干相位仍假设单节点 DS。本轮验证面为
  Go `vet`/`test ./...`、Rust `cargo test --all-targets`（155 passed）、全部脚本
  `bash -n`、`git diff --check`，以及真机三相位 + `all` 回归。
- 早期 `concurrency-lvmd-test.sh` 仍用 `ds/` 任取 Pod，未适配多节点，
  **不在本轮验收范围**（已在脚本头部标注）；多节点锁同源请用
  `agent-lvmd-lock-verify.sh`（已定点）与 `host-wrapper-gate.sh`。

### 13.6 可复跑命令（WSL 内、仓库根）

```bash
# 只读前置（不写不改）
DRY_RUN=1 bash docs/poc/scripts/expand-lvmd-nodes.sh
# 逐相位：写盘需显式确认；首次 seed 会有窗口期 Task 闸门
CONFIRM_WRITE=1 STEP=prepare bash docs/poc/scripts/expand-lvmd-nodes.sh
CONFIRM_WRITE=1 PURGE_WINDOW_TASKS=1 STEP=prepare bash docs/poc/scripts/expand-lvmd-nodes.sh
STEP=deploy bash docs/poc/scripts/expand-lvmd-nodes.sh
STEP=verify bash docs/poc/scripts/expand-lvmd-nodes.sh
# 全绿后全量回归
CONFIRM_WRITE=1 STEP=all bash docs/poc/scripts/expand-lvmd-nodes.sh
```

## 14. device-class 缺 `type: thin`：B 链路供给的假绿修复（2026-11-12 续）

### 14.1 起点：§13 的「thin LV」结论不成立

`pvc-supply-e2e.sh` 原判据是「VG 内新增 1 颗 LV + 尺寸 = PVC 请求」。这个判据
**无法区分 thick LV 与 thin LV**：只要 lvmd 在 VG 里建出一颗 1Gi 的 LV，无论它
是否取自 thin-pool，都会 PASS。§13.5 把「容量按 VG free 2 GiB 上报而非
thin-pool 36G」登记为容量规划问题，实际是同一个配置缺陷的两个症状。

### 14.2 根因（TopoLVM v0.42.0 源码 + 真机日志）

`AggregateLVMDConfig` 渲染的 device-class 只有 `thin-pool:` 段，缺 `type: thin`：

```yaml
device-classes:
  - name: hlvm-lvmd
    volume-group: hlvm-lvmd-vg-153
    spare-gb: 0
    thin-pool:                        # ← 没有 type: thin，整段被忽略
      name: thinpool
      overprovision-ratio: 1.00
```

TopoLVM `NewDeviceClassManager` 仅在 `dc.Type == TypeThin` 时把 class 注册进
`deviceClassByThinPoolName`；`dc.Type` 为空会被归一为 `TypeThick`，thin-pool
配置整段不生效。真机 lvmd 启动日志实证 `"type":""`，且 `ValidateDeviceClasses`
的 thin 分支校验根本没被触发。

后果链：`vgService.Watch` 的 `WatchItem.FreeBytes` 取 `vgFree`（VG 40G −
thinpool 36G − metadata ≈ 2 GiB），故 `capacity.topolvm.io/hlvm-lvmd=2143289344`；
`CreateVolume` 走 thick 路径直接从 VG free 切 LV，`pool_lv` 为空。
**36G thin-pool 建好了却完全不参与供给**。

### 14.3 可逆 A/B 实证（真机，2026-11-12）

实验前完整备份 3 份 ConfigMap 到 `/tmp/hlvm-thin-ab-*`；临时把
`hlvm-storage-controller` scale 到 0（否则 `Owns(ConfigMap, MatchEveryOwner)`
会立刻用旧渲染结果覆盖），在聚合 CM 与两份 per-node CM 插入 `type: thin`，
`rollout restart ds/hlvm-lvmd`，再建 1Gi PVC 观察。

| 判据 | A（修复前） | B（加 `type: thin`） |
|---|---|---|
| lvmd 启动日志 | `"type":""` | `"type":"thin"` |
| 节点容量注解（两节点） | 2143289344 B（2 GiB） | 38654705664 B（36 GiB） |
| CSIStorageCapacity（两条） | 2044Mi / 2044Mi | 36Gi / 36Gi |
| 新增 LV `pool_lv` | 空（thick） | `thinpool` |
| 新增 LV `lv_attr` | thick（`-wi-a-----`） | thin volume（`Vwi-aotz--`） |
| 回收后残留 LV | 0 | 0 |

实验结束用备份（带新鲜 `resourceVersion` 做 `kubectl replace`）恢复 3 份 CM、
重启 lvmd、控制器 scale 回 2，真机回到 2 GiB 基线、无残留 PVC/PV —— 实验完全可逆。

### 14.4 修复落地

- `AggregateLVMDConfig` 每个 device-class 显式渲染 `type: thin`，注释钉死上游行为
  与实测数字；`TestAggregateLVMDConfig_SortedAndComplete` 期望串同步。
- 三份 ConfigMap 快照（`configmap-lvmd-all.yaml` / `-153` / `-202`）同步，由
  `TestLvmdPOCArtifactsConsistent` 逐字节锁定「快照 == 渲染结果」。
- `pvc-supply-e2e.sh` 新增 `lv_pool_of()`：用 `--separator '|'` 单独取新增 LV 的
  `pool_lv`，必须等于 `THINPOOL`（默认 `thinpool`），否则 FAIL 并提示
  「device-class 缺 type: thin 会退化成 thick LV」。这堵住 §13 的假绿。
- **部署约束**：控制器 `Owns(ConfigMap, MatchEveryOwner)` 会覆盖任何手工 CM 修改，
  修复必须随控制器二进制上线。按项目「集成/生产一律 `:vX.Y.Z`」纪律，本轮发
  `v0.1.0-preview.3`，真机部署 `storage-controller:v0.1.0-preview.3` 后由控制器
  重渲染 per-node CM，再由 `expand-lvmd-nodes.sh` 同步聚合 CM 并复验。

### 14.5 诚实边界

- 切换后**新建** LV 走 thin-pool；切换前已存在的 thick LV（若有）不自动迁移。
  真机切换前 PVC/PV 全 0，无迁移对象。
- `overprovision-ratio: 1.00` 表示不超供给，容量上限仍是 thin-pool 36G；
  要超供需显式调大 `NodeVG.spec.thinPool.overprovisionRatio`。
- **`LVReporter` 仍未接**。接线前必须先解决 `DriftDetectorReconciler` 把
  `pv.Name` 当作 managed LV 名、而 TopoLVM 实际 LV 名是另一个 UUID 的问题；
  否则接上 lvs 上报会同时产生 `unmanaged-lv` 与 `missing-lv` 两类误报。
- 聚合 CM 仍由 `expand-lvmd-nodes.sh` 同步，控制器只渲染 per-node CM（§13.5）。

## 15. 判据收尾与三方对账前置修复（2026-11-12 续）

### 15.1 起点：§14 复验后登记的三处待办

1. `pvc-supply-e2e.sh` 用「单次 jsonpath + `2>/dev/null || true`」读节点拓扑标签，
   kubectl 偶发非零就把「读不到」判成「标签不存在」。§14 的 `verify` 第二轮因此假红，
   而同一轮里 PVC 仍 Bound、PV 亲和仍落在 `topology.topolvm.io/node`。
2. 4 个 POC 脚本把默认 `AGENT_IMAGE` 写死为 `sha-52bda85`，发版后立刻过时；
   §14 复验首跑未显式传参，脚本拿旧默认值与 DS 的 `sha-def842b` 比对而报 FAIL。
3. §14.5 登记的 `LVReporter` 接线前置：`DriftDetectorReconciler` 把 `pv.Name` 当
   managed LV 名，而 TopoLVM 实际 LV 名是另一个 UUID。

### 15.2 真机实证：TopoLVM PV 到底把 LV 名放在哪

不靠猜源码：在 `hlvm-b` 上建 1Gi PVC（**必须带 Pod**，SC 是 WFFC，无消费者时
PVC 恒 Pending），读 PV / LogicalVolume CR / 宿主 `lvs` 三方对照：

```
pv.name                     = pvc-cf9b6816-3cb3-477f-b139-fc408de3cf4a
pv.metadata.annotations     = 只有 pv.kubernetes.io/provisioned-by 等，**无** hlvm.dev/*
pv.spec.csi.driver          = topolvm.io
pv.spec.csi.volumeHandle    = 9e639840-23de-403e-aebe-2335b9505816
pv.spec.nodeAffinity        = topology.topolvm.io/node In [10-60-153-100]
LogicalVolume.status.volumeID = 9e639840-23de-403e-aebe-2335b9505816
宿主 lvs                    = 9e639840-... | pool_lv=thinpool | Vwi-aotz-- | 1073741824B
NodeVG                      = hlvm-lvmd-vg-153 (spec.nodeName=10-60-153-100)
```

由此坐实旧实现是**两层**缺陷，而不只是「名字写错」：

- 旧代码只认 `hlvm.dev/node` 注解 ⇒ 真机所有 TopoLVM PV 都被 `continue` 跳过，
  `managed` 恒空，`DetectDrift` 按设计直接返回 nil —— **三方对账从来没生效过**；
- 即便补上注解，`Name: pv.Name`（`pvc-<uid>`）与宿主 LV 名（UUID）不同，
  会同时产生 `unmanaged-lv` + `missing-lv` 双向误报。`VG` 注解同样不存在。

### 15.3 修复：`ManagedLVsFromPVs` 纯函数

- CSI 路径（`driver=topolvm.io` 且有 `volumeHandle`）：`Name=volumeHandle`；
  `Node` 取注解优先、回退 `nodeAffinity` 的 `topology.topolvm.io/node`；
  `VG` 取注解优先、回退按 `NodeVG.spec.nodeName` 反查 `metadata.name`；
  `Bytes` 取 `spec.capacity.storage`。字段不全**宁可跳过**，绝不拿错名字构造账面项。
- 兼容路径：非 TopoLVM CSI 但带 `hlvm.dev/node` 注解的 PV（hlvm 自研供给 / envtest）
  保持历史语义（账面 LV 名 = `pv.Name`），因此既有 envtest 与单测零回归。
- `Reconcile` 额外 `List(NodeVG)` 并交给纯函数；`nodes` 集合由 managed 派生。
- 单测 `drift_pv_test.go` 用§15.2 的真实值钉死三元组，并给出反例：把账面名改成
  `pv.Name` 时 `DetectDrift` 必然返回 2 条双向误报；另固定 thin-pool 过滤前置行为。

### 15.4 判据收尾

- `pvc-supply-e2e.sh` 新增 `kc_get`：3 次重试，成功返回 0（值允许为空，由调用方判
  「确实缺失」），3 次全失败返回 1，调用方必须报「读取失败、判据未覆盖」。覆盖
  CSINode 驱动、节点拓扑标签、节点容量注解、PVC `volumeName`、PV 容量/亲和/driver。
- 4 个 POC 脚本（`expand-lvmd-nodes.sh` / `deploy-agent-real.sh` /
  `host-wrapper-gate.sh` / `agent-lvmd-lock-verify.sh`）默认镜像改为从仓库根
  `VERSION` 推导 `:v<VERSION>`；`expand-lvmd-nodes.sh` 门禁同时接受发布版
  `:v<VERSION>`（校验与 VERSION 一致）与 CI 产物 `:sha-<commit>`（保留 git
  commit 存在性与 agent 产品代码等价校验、排除旧缓存 tag）。
- `host-wrapper-gate.sh` 在 m15 里只以 `MODE=pod` 调用，不使用 probe 镜像，
  故默认 tag 变化不影响 kind 集成链路。

### 15.5 真机复验（2026-11-12）

- 两节点预拉 `storage-agent:v0.1.0-preview.3` 各 3.6s：与 `sha-def842b` 同 digest，
  layer 全部命中 content store。
- `DRY_RUN=1` 只读前置：默认镜像自动解析为 `:v0.1.0-preview.3`，门禁 PASS=4 /
  FAIL=0 / SKIP=1（SKIP 是 DRY_RUN 本身，不计 PASS）。
- `STEP=deploy`：**PASS=12 / FAIL=0 / SKIP=0**，两节点常驻 agent DS 切到发布版 tag，
  各自 `MODE=pod` 真实写门禁 17 项全 PASS。
- `STEP=verify`：连续 **4 次**均 **PASS=23 / FAIL=0 / SKIP=0**；两节点各跑通
  1Gi PVC → thin LV（`pool_lv=thinpool`）→ ext4 写 16 MiB → PV/LV 回收，
  拓扑标签判据不再偶发假红，镜像断言不再需要显式传参。
- 终态：三节点 Ready；控制器与 agent 均 `:v0.1.0-preview.3`；两节点容量注解
  `38654705664`、两条 CSIStorageCapacity `36Gi`；StorageTask / PVC / PV /
  LogicalVolume CR 全 0；VG 只剩 thinpool。

### 15.6 诚实边界

- **`LVReporter` 仍为 nil，不得声称「三方对账已上线」**。本轮 Go 修复在 `main`，
  但真机控制器仍是 `storage-controller:v0.1.0-preview.3`（不含本轮代码）。因为
  Reporter=nil 时 `actual` 恒空、`DetectDrift` 直接返回 nil，该修复在真机**没有可观测
  行为**，故本轮未发 preview.4；接线时应随下一版控制器二进制一并发布并做真机对账验收。
- LVReporter 接线剩余前置（本轮只清掉第 1 项）：
  1. PV → LV 名 / 节点 / VG 映射（§15.3，**已修**）；
  2. agent 上报侧必须过滤 thin-pool 自身及内部 LV：实测宿主 `lvs` 除业务 LV 外还有
     `thinpool | twi-aotz-- | 38654705664B`，全量上报会让每个节点稳定多一条
     `unmanaged-lv` 误报（`TestDetectDrift_ThinPoolLVNeedsReporterFiltering` 钉死该行为）；
  3. `DriftDetectorReconciler.SetupWithManager` 目前只 `For(NodeVG{})`，PV 增删改
     不触发对账，需补 PV watch；
  4. agent 侧 lvs 采集与回写通道尚未实现。
- 其余边界沿用 §13.5 / §14.5：聚合 CM 仍由脚本同步、CP 未扩、A 链路设备插件仍
  单节点、`NodeVG.status.freeBytes`（VG 物理 free 2 GiB）与 CSI 调度的 36 Gi
  thin-pool 容量是不同维度、**未跑 `m15 all`**（`verify-agent` 会删除常驻 DS）。

### 15.7 可复跑命令（WSL 内、仓库根）

```bash
export KUBECONFIG=$HOME/.kube/hlvm-real.conf SSH_KEY=/home/jinfeng105/.ssh/hlvm-real
DRY_RUN=1 bash docs/poc/scripts/expand-lvmd-nodes.sh          # 只读前置
STEP=deploy bash docs/poc/scripts/expand-lvmd-nodes.sh         # 默认 :v<VERSION>
STEP=verify bash docs/poc/scripts/expand-lvmd-nodes.sh         # 双节点 E2E
```

---

## 16. LVReporter 接线：三方对账的 lvs 一侧（2026-11-12）

### 16.1 背景与范围

§15.6 登记了 4 项接线前置：① PV→LV 名/节点/VG 映射（§15.3 已修）；
② agent 上报侧过滤 thin-pool；③ 补 PV watch；④ agent 侧 lvs 采集与回写通道。
本轮清掉 ②③④，落地 ADR §4「路线 B」的**上报侧最小闭环**：agent 采集宿主
`lvs` → 写 CR status → 控制面读 status 做三方对账。

**明确不在本轮范围**：NodeVG 仍由脚本手工 seed（路线 B 的「自动创建 CR」部分）、
`freeBytes` 语义统一、控制面自动修复漂移（设计明令 SHALL NOT）、空集群对账。

### 16.2 承载对象与字段级单写者（关键决策）

选择 `NodeVG.status` 新增两个字段，而非新建 `NodeLVReport` CR：

```go
LogicalVolumes    []LVReport  `json:"logicalVolumes,omitempty"`   // name + bytes
LastLVReportTime  *metav1.Time `json:"lastLVReportTime,omitempty"` // RFC3339
```

- 一个节点一个 `NodeVG`，`node` / `vg` 由 CR 自身给出，载荷只需 LV 名与字节数；
- CRD `status` 是 `x-kubernetes-preserve-unknown-fields: true`，无需改 schema；
- 不引入新 Kind，避开 conversion webhook / RBAC / 部署清单的连锁改动。

**字段级单写者边界**（本轮最关键的隐性坑）：`logicalVolumes` 与
`lastLVReportTime` 的**唯一写者是节点 agent**（`patch_status`，JSON Merge Patch
只替换这两个 key）；控制面只读。因此 Go 侧 `VGStatus` **必须声明这两个字段**并同步
`zz_generated.deepcopy.go`——`VGReconciler` 用 `Status().Update` 全量写回，若 Go
类型里没有字段，client-go 解码时会丢弃未知字段，下一次 Update 就把 agent 上报静默抹掉。
`CapacityReconciler` 用 `Status().Patch(MergeFrom)`，只下发差异字段，不会覆盖。
`TestVGStatusDeepCopyPreservesLVReport` 与 `TestLVReporterWiringDiscipline` 钉死该纪律。

权限：`control-plane/config/rbac/agent_role.yaml` 增加 `nodevgs/status` 的
`get;update;patch`。不改则 agent `patch_status` 返回 403，且日志只有一行报错。

### 16.3 采集与过滤（真机字段实证）

`lvs` 显式 `-o lv_name,vg_name,lv_size,lv_attr,pool_lv --units b --reportformat json`。
2026-11-12 在 `10-60-153-100` 实读（当时 VG 只有 thin-pool）：

```
{"lv_name":"thinpool","vg_name":"hlvm-lvmd-vg-153","lv_size":"38654705664B",
 "lv_attr":"twi-aotz--","pool_lv":""}
```

`report_lv()` 经 `HLVM_HOST_WRAPPER`（真机常驻 DS 注入
`nsenter -t 1 -m -u -i -n -p --`）进入宿主 mount+IPC NS，与写路径共用宿主 lvm
二进制和 `/run/lock/lvm` 锁（§5.3），不另开 SSH。

`is_reportable_lv` 过滤规则（**只排除内部对象，绝不排除手工普通 LV**）：

| 形状 | `lv_attr` | 处理 |
|---|---|---|
| thin-pool 自身 `thinpool` | `twi-aotz--` | 排除（首位 `t`） |
| 内部数据区 `[thinpool_tdata]` | `Twi-aotz--` | 排除（`[` 前缀 + 首位 `T`） |
| TopoLVM 业务 thin LV | `Vwi-aotz--` / `pool_lv=thinpool` | 保留 |
| 手工 `lvcreate` 普通 LV | `-wi-a-----` | **保留**（漂移检测的目标） |
| `lv_attr` 缺失/为空 | — | **失败关闭跳过**（类型未知，不推断） |

控制面 `NodeVGLVReporter` 再做一层兜底：过滤与 `spec.thinPool.name` 同名及 `[` 开头的
项，兼容「新控制器 + 旧 agent」的滚动升级窗口。

### 16.4 新鲜度与失败关闭

- agent：30s 采样；清单变化立即写，否则 **60s 保活写**（刷新时间戳）。采集失败时
  **不写**，让时间戳自然老化，绝不拿旧清单冒充当前实测。空清单必须显式下发 `[]`
  （JSON Merge Patch 对数组整体替换），否则 `lvremove` 后陈旧清单会一直留在 CR 里。
- 控制面：`DefaultLVReportMaxAge = 3min`；`lastLVReportTime` 缺失/过期/无对应 NodeVG
  都返回 error。
- **`DriftDetectorReconciler` 整轮放弃对账**：旧实现在采集失败时 `continue`，结果是
  「部分节点有 actual、部分没有」→ 缺数据节点的所有 managed 全部变成 `missing-lv`
  误报。改为任一节点失败即 return（不返回 error 以免无限重试刷日志），靠 PV / NodeVG
  事件再次触发。`TestDriftDetector_FailClosedWhenAnyNodeReportMissing` 钉死。

既有契约保留：`DetectDrift` 在 `managed` 或 `actual` 为空时返回空。因此
**平台账面为空（无任何 PV）时，人工 lvcreate 不会被检出**；真机漂移注入必须在
PVC/PV 存在期间进行，脚本已按此设计，不得声称覆盖空集群场景。

### 16.5 触发链路

```
宿主 lvs ──(agent, 30s, wrapper)──> NodeVG.status.logicalVolumes / lastLVReportTime
                                          │
                For(NodeVG{}) ◄───────────┤ status 更新事件
                Watches(PV{}) ◄───────────┘ PV 增删改（映射到全部 NodeVG）
                                          ▼
              NodeVGLVReporter.ListActualLVs(node)  [freshness gate]
                                          ▼
              ManagedLVsFromPVs(PV, NodeVG)  vs  actual → DetectDrift
                                          ▼
              Warning Event reason=StorageDrift（仅告警 + 补录/回滚建议，不自动修复）
```

`SetupWithManager` 补 `Watches(&corev1.PersistentVolume{}, ...)`；`main.go` 装配
`&NodeVGLVReporter{Client: mgr.GetClient()}`，Reporter 不再为 nil。

### 16.6 真机验收（v0.1.0-preview.4 镜像产出后执行）

新增 `docs/poc/scripts/drift-reconcile-e2e.sh`：能力缺失 SKIP（不计 PASS）、
所有 kubectl 字段读取走 `kc_get` 三次重试、多节点定点取 Pod、结论行
`DRIFT_E2E_RESULT=PASS|FAIL|SKIP`。四阶段判据：

1. 前置镜像门禁（控制器/agent 均 `:v<VERSION>`）+ wrapper + 上报新鲜且不含 thin-pool；
2. 正常态：PVC+Pod（SC 为 WFFC）→ Bound → agent 上报 `volumeHandle` → 基线后零告警；
3. 注入：宿主手工 `lvcreate` → 必须命中 `unmanaged-lv` 事件与控制器日志，且不得出现
   `missing-lv` 双向误报；
4. 清理：`lvremove` → 上报移除 → 告警计数在 90s 窗口内不再增长；回收 Pod/PVC →
   PV/LV 消失、终态无残留。

部署顺序（WSL 内，仓库根）：

```bash
export KUBECONFIG=$HOME/.kube/hlvm-real.conf
kubectl apply -f control-plane/config/rbac/agent_role.yaml       # 必须先放权
kubectl -n hlvm-system set image deploy/hlvm-storage-controller \
  manager=ghcr.io/f31/hlvm/storage-controller:v0.1.0-preview.4
STEP=deploy bash docs/poc/scripts/expand-lvmd-nodes.sh          # agent 切发布版
bash docs/poc/scripts/drift-reconcile-e2e.sh
NODE=10-60-166-202 VG=hlvm-lvmd-vg-202 bash docs/poc/scripts/drift-reconcile-e2e.sh
```

**验收结果于镜像发布后补记，不在打 tag 前宣称通过。**

### 16.7 诚实边界

- 未改 `DetectDrift` 的「任一侧为空即返回」契约：空集群手工 `lvcreate` 检不出。
- NodeVG 仍手工 seed；agent **只 patch 既有 CR 的 status**，不创建 NodeVG。
- `NodeVG.status.freeBytes` 仍是 VG 物理 free 2 GiB，与 CSI 36 Gi thin-pool 容量不同维度。
- 聚合 CM 仍由脚本同步；CP 未扩、A 链路设备插件仍单节点；未跑 `m15 all`。
- `cargo fmt -- --check` 仍对 `agent/src/common/mod.rs` / `plugin/mod.rs` 报差异
  （rustfmt 1.10 新规则、既有基线，非本轮引入）；CI 该步为 `continue-on-error`，
  本轮 4 个改动文件已单独格式化。
