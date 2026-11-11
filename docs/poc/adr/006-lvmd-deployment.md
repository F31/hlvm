# 006：lvmd 部署立项（B 链路供给落地 —— 重新立项）

- **状态**：重新立项（2026-11-11）。原 `openspec/changes/add-topolvm-csi-supply/` 已被用户网页提交删除（`5b54463 Delete openspec directory`，含 39 个 task，用户确认"接受现状"）。本文档替代该 openspec 变更提案，作为 B 链路"实际部署 lvmd"的立项与执行计划。
- **决策人**：平台团队
- **关联**：ADR-005（lvmd ConfigMap 聚合语义，已接受并实现）、设计 §5.3（宿主 lvm 共享锁硬门禁，已灰度验证）

---

## 1. 背景与动机

B 链路目标：让 hlvm 通过 **TopoLVM `lvmd`** 按 VG 剩余 GiB 供给 PVC（而非 A 链路的设备插件按块直通裸设备）。

本轮已完成的前置：
- **§5.3 门禁已真机验证**（2026-11-11，`87d9160`+`c633cfc`）：`HLVM_HOST_WRAPPER=chroot /host` 使 agent 经宿主 lvm 二进制 + 宿主 `/run/lock/lvm` 锁读写，与 lvmd 同源同锁。真机 PASS：`chroot /host lvm version → LVM version: 2.03.16(2)`。
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

```yaml
# 草稿（待落地为 control-plane/config/lvmd/daemonset.yaml）
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
