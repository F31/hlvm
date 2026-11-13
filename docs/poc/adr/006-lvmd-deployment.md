# 006：lvmd 部署立项（B 链路供给落地 —— 重新立项）

- **状态**：重新立项（2026-11-11）。原 `openspec/changes/add-topolvm-csi-supply/` 已被用户网页提交删除（`5b54463 Delete openspec directory`，含 39 个 task，用户确认"接受现状"）。本文档替代该 openspec 变更提案，作为 B 链路"实际部署 lvmd"的立项与执行计划。
- **决策人**：平台团队
- **关联**：ADR-005（lvmd ConfigMap 聚合语义，已接受并实现）、设计 §5.3（宿主 lvm 共享锁硬门禁，已灰度验证）

> **项目状态声明（2026-11-13，详见 §23）**：本文档 §1–§22 记录的是**代码实现与自动化判据**
> 的落地，不是设计方案的验收结论。设计 v1.1 §10 的**阶段 0 POC 决策门整体未过**
> （`docs/poc/poc-report.md` 仍为空模板、ADR-001~004 仍为提议/框架），
> `runbook §4` 的 **§B 19 项递延无一项达到验收通过**。因此「真机 `m15 all` 零 FAIL /
> CI 全绿 / 已发 `v0.1.0-preview.6`」只证明 §A 自动化覆盖，**不等于设计已验收**，
> 也不等于 production-ready（`docs/M14-closure.md` 风险 #3）。这是「模块先行、
> 决策门后补」的客观状态，不是漏记；闭合顺序见 §23.3。

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

`lvs` 显式 `-o lv_name,vg_name,lv_size,lv_attr,pool_lv --units b`，报表 flag 由
`lvm_json` 统一注入一次。2026-11-12 在 `10-60-153-100` 实读（当时 VG 只有 thin-pool）：

```
{"lv_name":"thinpool","vg_name":"hlvm-lvmd-vg-153","lv_size":"38654705664B",
 "lv_attr":"twi-aotz--","pool_lv":""}
```

`report_lv()` 经 `HLVM_HOST_WRAPPER`（真机常驻 DS 注入
`nsenter -t 1 -m -u -i -n -p --`）进入宿主 mount+IPC NS，与写路径共用宿主 lvm
二进制和 `/run/lock/lvm` 锁（§5.3），不另开 SSH。

**真机只读验证抓到的既有缺陷（本轮一并修）**：在旧 agent Pod 内按 wrapper 现场拼
`lvm lvs ... --reportformat json --reportformat json`，宿主 lvm 直接返回
`Option --reportformat may not be repeated.` / `Error during parsing of command line.`
（exit 3）。根因是 `report_vg/lv/pv` 各自带了一次 `--reportformat json`，而
`lvm_argv_with` 又无条件追加一次 —— **所有 LVM 读路径一直都是失败的**，只是
`build_host_state` 里 `report_pv()` 的失败被静默忽略，长期未暴露。若带着这个缺陷
发版，新上报循环会永远采集失败、`NodeVG.status` 永远没有上报，控制面因新鲜度门禁
整轮放弃对账，表现为「升级后依然零告警」的假绿。修法：`lvm_argv_with` 改为幂等
（仅当 args 未自带该 flag 才追加），`report_*` 去掉显式 flag；新增
`lvm_argv_never_repeats_reportformat` / `lv_report_argv_matches_real_host_command`
两个单测钉死，并在真机用旧 Pod 复跑单 flag 命令确认输出正常。

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
# agent 按节点逐个升级并做真实写门禁（DS 全局生效，两次调用对同一 DS 幂等）
NODE=10-60-153-100 VG=hlvm-lvmd-vg-153 bash docs/poc/scripts/deploy-agent-real.sh
NODE=10-60-166-202 VG=hlvm-lvmd-vg-202 bash docs/poc/scripts/deploy-agent-real.sh
bash docs/poc/scripts/drift-reconcile-e2e.sh
NODE=10-60-166-202 VG=hlvm-lvmd-vg-202 bash docs/poc/scripts/drift-reconcile-e2e.sh
```

镜像拉取见上文的 mirror 方式；云主机直连 GHCR 慢到不可用。

**验收结果（2026-11-12，镜像 `v0.1.0-preview.4` 产出后执行）：双节点各 `PASS=19 FAIL=0
SKIP=0`，`DRIFT_E2E_RESULT=PASS`。**

两次运行的关键证据一致：

| 判据 | 153（`hlvm-lvmd-vg-153`） | 166（`hlvm-lvmd-vg-202`） |
|---|---|---|
| 上报新鲜度 | 滞后 47s | 滞后 9s |
| 基线 `logicalVolumes` | 空（thinpool 已过滤） | 空 |
| 业务 LV 上报 | `volumeHandle=441b7f40-…` 已出现在 status | `volumeHandle=1558e3ce-…` 已出现 |
| 正常态告警 | 0 | 0 |
| 注入告警 | `unmanaged-lv` + `lv=hlvm-drift-753212` | `unmanaged-lv` + `lv=hlvm-drift-758454` |
| `missing-lv` 双向误报 | 无 | 无 |
| 清理后 90s 计数 | 3 → 3 | 4 → 4 |
| 终态 | 无 PVC/PV/LV 残留，仍在上报 | 同 |

Agent 侧日志同时坐实三条常驻循环并存：`进入 StorageTask 回写协调循环`、`进入 NodeVG LV
上报协调循环（ADR-006 §16）`、`进入 NodeDisk 观测状态写回协调循环`，且 VG 只有 thin-pool 时
上报为 `count=0`。

**首跑抓到一处判据假红（不是产品误报）**：`NEW_COUNT="$(awk ... <<< "$EVENTS")"` 在
`EVENTS` 为空时，here-string 会喂进一行空行，被 `n=($2==""?1:$2)` 计成 1 条告警 ⇒
「正常态出现 1 条漂移告警」但证据串为空。`event_count_sum` 同源。两处均加
`length($0)==0 { next }`。这类缺陷与 §15 的 `kc_get` 同族：**判据自身的空值语义必须显式**。

**部署运维事实（非产品缺陷，但会拖住验收）**：云主机直连 `ghcr.io` 仅约 27 KB/s，
controller（13.6 MiB）实测拉了 8m43s / 10m13s，agent（压缩 376 MiB）按此速率不可行。
本集群 `certs.d` 只配了 `docker.io` / `registry.k8s.io`，未配 `ghcr.io`。用
**不改全局配置**的方式解决：

```bash
mkdir -p /tmp/ghcr-mirror/ghcr.io
printf 'server = "https://ghcr.io"\n[host."https://ghcr.nju.edu.cn"]\n  capabilities = ["pull", "resolve"]\n' \
  > /tmp/ghcr-mirror/ghcr.io/hosts.toml
ctr -n k8s.io images pull --hosts-dir /tmp/ghcr-mirror \
  ghcr.io/f31/hlvm/storage-agent:v0.1.0-preview.4
```

复用 preview.3 共享层后仅需拉 10.6 MiB（1.9–4.6s）。注意：`ctr images pull` 与 kubelet 的
拉取会争 containerd content store 锁，若发现 Pod 长时间 `ContainerCreating` 而镜像已在
节点上，先确认没有手工 `ctr` 进程在跑（本次 166 上手工 pull 挂住，`kill` 后 kubelet 立即完成）。

### 16.7 诚实边界

- 未改 `DetectDrift` 的「任一侧为空即返回」契约：空集群手工 `lvcreate` 检不出。因此验收
  必须在 PVC/PV 存活期间注入，本脚本已按此排序，不能声称「空集群也覆盖」。
- 只覆盖了 2 个 worker（CP 未扩、A 链路设备插件仍单节点）；165/131 未参与本轮对账。
- 告警只发 `Warning` 事件 + 日志，**不自动修复**；事件随 TTL 过期，长期留档需外部采集。
- 新鲜度门禁 3min 是「宁可不对账也不误报」的取舍：agent 长时间写失败时对账会**静默停摆**，
  只有 `lastLVReportTime` 停滞可观测（本轮未做该指标告警；已在 §17 补齐四族指标与告警规则）。
- NodeVG 仍手工 seed；agent **只 patch 既有 CR 的 status**，不创建 NodeVG。
- `NodeVG.status.freeBytes` 仍是 VG 物理 free 2 GiB，与 CSI 36 Gi thin-pool 容量不同维度。
- 聚合 CM 仍由脚本同步；未跑 `m15 all`（`verify-agent` 会删常驻 DS）。
- 真机 CRD 的 `status` 是 `x-kubernetes-preserve-unknown-fields: true`，新字段才写得进去；
  仓库 `config/crd/bases` 里是 `status: {}`（空 schema 会 prune 未知字段）。**本轮刻意未
  重新 apply CRD**，换干净集群时必须先确认这一点，否则 agent 上报会被静默丢弃。
- `cargo fmt -- --check` 仍对 `agent/src/common/mod.rs` / `plugin/mod.rs` 报差异
  （rustfmt 1.10 新规则、既有基线，非本轮引入）；CI 该步为 `continue-on-error`，
  本轮 4 个改动文件已单独格式化。

## 17. 对账可观测性：把「静默停摆」变成可告警（2026-11-12）

### 17.1 问题：§16 留下的唯一「不可观测失败」

§16 的失败关闭语义是刻意的取舍：任一节点上报缺失/过期即**整轮放弃对账**，否则 stale 清单
会把该节点全部 managed LV 判成 `missing-lv` 误报。代价是：`ListActualLVs` 返回 error 时
控制器只打一条 `Info` 日志就 `return`，平台在 Agent 长挂期间看起来「一切正常」——
这是最危险的一类失败（无告警、无事件、指标全绿）。

更隐蔽的是：控制面只在 NodeVG/PV 变化时触发对账，而 Agent 挂掉后 NodeVG 不再更新，
**连这条 Info 日志都不会再产生**。若只观测「滞后秒数」这类由 reconcile 计算的值，
它会冻结在 Agent 挂掉前的瞬间，永远不越过阈值。

### 17.2 指标口径（4 族，`internal/metrics`）

| 指标 | 类型 | 标签 | 语义 |
| --- | --- | --- | --- |
| `storage_controller_lv_report_timestamp_seconds` | Gauge | `node,vg` | Agent 最近一次上报的 **Unix 时间戳** |
| `storage_controller_lv_report_present` | Gauge | `node,vg` | 1=有上报；0=Agent 从未上报 |
| `storage_controller_drift_reconcile_skipped_total` | Counter | `reason` | 放弃对账的轮次（reason 闭集） |
| `storage_controller_drift_items` | Gauge | `kind` | 当前一轮漂移条目数（`unmanaged-lv` / `missing-lv`） |

`reason` 是**闭集常量**（`no_reporter` / `report_missing` / `report_stale` / `no_nodevg` /
`list_failed` / `unknown`），由 `LVReportUnavailableError.Reason` 携带。禁止把错误串直接做
标签：既会把 node/vg 等内部拓扑拼进去打爆基数，也会让 /metrics 泄漏拓扑信息。

指标名同时登记进 `internal/metrics` 的规范名常量块，供告警规则与仪表盘统一引用。

### 17.3 三个刻意的语义选择

1. **时间戳而非滞后秒数**。滞后秒数由 reconcile 计算，Agent 停止上报后不再有触发，
   该值会冻结在挂掉前的瞬间（永不告警）。时间戳冻结后 `time() - ts` 仍随墙钟增长，
   是唯一在「无任何事件」时仍能暴露停摆的形态。
2. **全量替换而非只写**。`ReplaceLVReportFreshness` 对上一轮存在、本轮消失的 `(node,vg)`
   显式 `DeleteLabelValues`。只写不删会让已删 NodeVG 的时间戳永远冻结在 /metrics 上，
   `time() - ts` 持续增长 → 永久误告警。
3. **跳过轮次不清零漂移条目**。`ReplaceDriftItems` 只在真正完成对账的轮次调用；跳过时
   保留上次结论。否则 Agent 抖动一次就把「有漂移」瞬间改写成 0，伪装成已恢复。
   消失的 kind 置 0 而非删除序列：序列消失会让 `drift_items{kind=...} > 0` 变成 no data，
   被告警系统当成恢复。

另外，新鲜度指标覆盖**全部 NodeVG**（直接读 `NodeVG.status`），不限于「有 PV 的节点」：
空集群（无 PVC）时 managed 为空，一次 reporter 调用都不会发生，若指标跟随对账走，
Agent 挂掉将完全不可观测。

### 17.4 告警规则（`control-plane/config/prometheus/alert-rules-drift.yaml`）

| 告警 | 表达式 | for | 级别 |
| --- | --- | --- | --- |
| `DriftLVReportStalled` | `time() - lv_report_timestamp_seconds > 180` | 2m | warning |
| `DriftLVReportMissing` | `lv_report_present == 0` | 15m | warning |
| `DriftReconcileSkipped` | `increase(drift_reconcile_skipped_total[15m]) > 0` | 0m | warning |
| `StorageDriftDetected` | `drift_items > 0` | 5m | warning |

- 180s 与 `DefaultLVReportMaxAge` 对齐：超过它就等于对账未覆盖，不需要另一个阈值。
  `for: 2m` 抑制 NTP 抖动与一次性写失败（Agent 30s 采样 / 60s 保活，允许连续两轮失败）。
- `present == 0` 单列一条：没有上报时**不存在时间戳序列**，`Stalled` 对它是 no data，
  永远不触发。
- 全部为 `warning`：本链路缺失只意味着「对账未覆盖」，不直接造成数据损坏；真正的
  容量/可用性告警由 §8 既有规则负责。
- 已知边界：控制器自身挂掉时 /metrics 端点消失、序列转 stale，本组规则不触发，
  由组件存活类告警覆盖。

### 17.5 守卫测试

告警规则引用不存在的指标名时 Prometheus 不报错，只会让该告警**永远不触发**——与
「一切正常」不可区分。`TestAlertRulesReferenceKnownMetrics` 从各 collector 的 `Describe`
取真实 fqName（外加 exporter 侧规范名常量），扫描 `config/prometheus/*.yaml` 非注释行，
任何未知 `storage_*` 名字即失败；并显式要求 `alert-rules-drift.yaml` 在位（防止改名后
守卫静默少扫）。已用「注入 `storage_controller_drift_itemz`」验证该测试会红。

控制器侧判据：`drift_observability_test.go` 钉死过期上报必须**不产生任何告警事件**且计入
`skipped{report_stale}`；无 PV 的 NodeVG 必须有新鲜度指标；NodeVG 删除后序列必须消失；
跳过轮次漂移条目必须保持 1（已用变异「跳过时清零」验证会红）。

### 17.6 真机验收（v0.1.0-preview.5，2026-11-12 执行）

镜像上线后执行，判据脚本 `docs/poc/scripts/drift-metrics-verify.sh`。
**PASS=13 / FAIL=0 / SKIP=0（rc=0）**，只读复跑（`SKIP_STALL=1`）**PASS=4 / SKIP=1**。
环境：controller `v0.1.0-preview.5`（leader `c76fdf4f7-9xmx4`），agent 仍 `.preview.4`。

关键证据：

| 判据 | 证据 |
| --- | --- |
| 正向新鲜度 | `10-60-153-100/hlvm-lvmd-vg-153` age=32s、`10-60-166-202/hlvm-lvmd-vg-202` age=31s，`present=1` |
| 停摆可观测 | 停写后时间戳冻结，age 自然增长到 203s（> 180s 阈值），**未伪造 status** |
| 放弃对账被计数 | `skipped_total{reason="report_stale"}` **0 → 5** |
| 不给假告警 | 停摆期间 `StorageDrift` 事件数 3 → 3（stale 清单未被当成漂移） |
| 恢复 | 移除 taint 后 Pod 重建，age=0s ≤ 90s |

复跑命令（WSL 内、仓库根）：

```bash
export KUBECONFIG=$HOME/.kube/hlvm-real.conf
bash docs/poc/scripts/drift-metrics-verify.sh              # 全量（会临时停一个 worker 的 agent）
SKIP_STALL=1 bash docs/poc/scripts/drift-metrics-verify.sh # 只读正向
```

**方法修正（首跑两处红，都是判据自身缺陷，不是产品缺陷）：**

1. `kubectl scale ds ... --replicas=0` 在这个集群不可用：`DaemonSet` **没有** `spec.replicas`
   字段（`patch` 报 `unknown field "spec.replicas"`），`daemonsets/<name>/scale` 子资源
   也返回 NotFound。改为「给目标节点加 DS 不支持的 taint + 删该节点 Pod」：
   DS 只容忍 `node-role.kubernetes.io/control-plane`，故 taint 后不会重建，
   且只影响**一个** worker（另一个继续上报，集群仍可用）。移除 taint 即恢复。
2. 首跑报「present=1 但无时间戳」：Prometheus 文本格式对大数用科学计数法
   （`1.794463357e+09`），判据用 `^[0-9]+$` 判数值 ⇒ 误判缺失。改为 awk `printf "%.0f"`。

**另一处必须写进判据设计的事实**：控制面只对「有 PV 的节点」调用 reporter
（`nodes` 由 `managed` 推导），**空集群里 `report_stale` 分支根本不可达**。脚本因此在
停摆确认后创建一颗 fixture PV（`hlvm.dev/node` 注解兼容路径）让该分支可达，并在恢复
上报**之前**删除它 —— 否则新鲜清单会把不存在的 LV 判成 `missing-lv`。
fixture 只用于让代码路径可达，PV→LV 的真实映射由 `drift-reconcile-e2e.sh` 用
真实 PVC/Pod 覆盖，二者不可互相替代。

### 17.7 诚实边界

- 只覆盖 2 个 worker；CP 未扩、A 链路设备插件仍单节点。
- 指标只在 leader 副本上有数据（controller-runtime leader election）：多副本部署下须
  抓取 leader 的 /metrics，或让 Prometheus 抓全部 Pod 后按 `max by` 聚合。
- 平台仍**不自动修复**漂移（设计原则），`StorageDriftDetected` 必须由人跟进。
- 未做仪表盘面板；未接真实 Prometheus 做规则求值（仓库内只有规则清单与静态守卫测试）。
- 事件仍是主要证据载体（含 LV 名等细节），指标只提供「有没有/多旧」这类聚合信号。

## 18. 用真实 PromQL 引擎求值告警规则（2026-11-12 续）

### 18.1 起点：§17.7 登记的第一条边界

§17 交付了四族指标与四条告警规则，并留了一条诚实的边界：

> 未做仪表盘面板；**未接真实 Prometheus 做规则求值**（仓库内只有规则清单与静态守卫测试）。

静态守卫（`TestAlertRulesReferenceKnownMetrics`）只能证明「被引用的指标名存在」。它证明不了：

1. 表达式能被 PromQL **解析**（括号、聚合、区间写法、函数签名）；
2. `for:` 时长真的会在预期时刻把 pending 转成 firing；
3. 改写后的语义仍是反假绿的（`time() - ts` 而不是「滞后秒数」）。

这三点恰好是「规则静默不触发」的主要成因，而规则不触发与「一切正常」在监控上不可区分
——和 §17 要解决的失败模式是同一个。

### 18.2 落地：`scripts/prometheus-rules-check.sh`

PrometheusRule 是 CRD（`spec.groups`），promtool 只认顶层 `groups:`，所以脚本先做**结构转换**
再校验：

| 步骤 | 做什么 | 判据 |
| --- | --- | --- |
| 提取 | 各 `config/prometheus/*.yaml` 的 `spec.groups` 去 2 空格缩进 → 纯规则文件 | 首行必须是 `groups:`，且非空 |
| `check rules` | 对**全部**规则文件（含未写单测的 backup/alerting/recording） | promtool 解析通过 |
| `test rules` | 对 `config/prometheus/tests/*.yml` 逐个求值 | 全部用例断言一致 |
| 覆盖守卫 | 强制覆盖文件（默认 `alert-rules-drift.yaml`）里每条告警都必须在用例中出现 | 缺一条即 FAIL |

promtool 的获取方式：本机有 `PROMTOOL` 就用；否则走 docker（`PROM_IMAGE`，默认
`prom/prometheus:v3.1.0`）；两者都没有则 **SKIP 并写明未覆盖**，绝不计 PASS（沿用
`docs/poc/scripts` 的同一纪律）。但 `CI` 环境变量存在时**不允许 SKIP**：CI 里 SKIP 等于门禁开洞
（yml 写着有这个 job、日志一片绿，规则其实一条都没求值过），此时判 FAIL、exit 1。
实测三条路径：`CI=1` 且无镜像 → `FAIL=1 / rc=1`；本地无镜像 → `SKIP=1 / rc=0`；
`CI=1` 且有镜像 → `PASS=13 / rc=0`。

踩坑：`prom/prometheus` 镜像以 `nobody` 运行，而 `mktemp -d` 是 0700 ⇒ promtool 报
`stat ...: permission denied`，看起来像规则文件坏了。显式带 `--user "$(id -u):$(id -g)"`。

### 18.3 用例设计：每条告警都要有正例 + 反例

`config/prometheus/tests/drift_rules_test.yml` 五组用例，关键在**同一组的正反两面**：

- **Stalled**：`w1` 的 `lv_report_timestamp_seconds` 恒为 100（模拟 Agent 停写后 status 不再更新）；
  `w2` 的序列用 `0+60x…` 跟着 `time()` 走（健康上报）。断言 `4m` 静默（240-100=140<180）、
  `5m` 仍静默（表达式刚为真、`for: 2m` 未满）、`7m` 只对 `w1` 触发。
  `w2` 在同一条表达式下静默 = 「健康节点不误报」被钉住。
- **Missing**：`present=0` 的 14m 静默 / 15m 触发（`for: 15m` 边界）。
- **Missing 反例**：`present=1` 恒不触发 —— 挡住把 `== 0` 写成 `>= 0` 这类改动（静态检查完全看不出来）。
- **Skipped**：计数器 `0x3 1x27`，`increase(...[15m])` 在窗口内无增量时静默、有增量当刻触发（`for: 0m`）。
- **StorageDriftDetected**：`drift_items=2` 的 4m 静默 / 5m 触发，并在注解里验证 `{{ $value }}` 渲染为 `2`。

注解文本也逐字断言：模板写错（`$labels.node` 拼错）会让 summary 空掉，而空 summary 的告警
在通知渠道里只剩一个 alertname。

### 18.4 变异校验（证明用例有鉴别力）

一次就绿的用例必须怀疑。三处注入，全部如期转红：

| 注入 | 结果 |
| --- | --- |
| `for: 2m` → `for: 0m`（Stalled） | `5m` 断言 FAILED，got 里出现该告警 |
| `> 180` → `> 30`（Stalled） | 同上（提前越界） |
| `present == 0` → `present >= 0`（Missing） | `20m` 反例 FAILED |

### 18.5 不依赖 docker 的结构守卫

`internal/metrics/promtool_tests_test.go` 跑在普通 `go test ./...` 里，守四件事：

- 用例还在（目录/文件为空即 FAIL），且每个用例都声明了 `rule_files` 指向真实存在的规则文件
  —— 否则 promtool 会用空规则集跑，用例全部空转；
- 每个 `eval_time` 形如 `5m`/`90s`、每组都有 `input_series` 与 `alert_rule_test`；
- **每条告警同时具备「应触发」与「应静默」两类断言**，且断言里的 alertname 必须在规则文件里存在
  （改名后用例成了空转是最隐蔽的退化）；
- `scripts/prometheus-rules-check.sh` 存在、有可执行位、**且 ci.yml 真的调用它**，并进了 `ready.needs`
  —— 「脚本写了但没人跑」是标准的假门禁。

注入验证：删掉 `StorageDriftDetected` 的反例 → 报「缺少应静默反例」；规则侧告警改名 → 报
「没有 promtool 求值用例」+「用例断言了不存在的告警」；从 `ready.needs` 移除 job → 报「未拦住 Ready」。

### 18.6 CI 接线

新增 `prometheus-rules` job（`ubuntu-latest` + docker，直接跑脚本），并纳入 `ready.needs`。
GHCR/镜像无关，不占用构建时间；promtool 求值是纯 CPU、秒级。

**首跑即红，两处都是真缺陷**（值得记，因为都属「本地怎么跑都绿」那一类）：

1. **脚本在 git 里没有可执行位**：Windows 上 `core.fileMode=false`，`chmod +x` 不进索引，
   提交后是 `100644`。CI 里 `run: scripts/prometheus-rules-check.sh` 直接 permission denied；
   go job 里 `TestPrometheusRulesCheckIsWiredIntoCI` 也按「没有可执行位」报红 ——
   本轮的守卫第一次运行就抓到了自己交付物的缺陷。修法：
   `git update-index --chmod=+x scripts/prometheus-rules-check.sh`（不能靠本地 chmod）。
2. **`ready` 是假门禁**：它只有 `if: always()` + 一句 echo，于是 go/rust/prometheus-rules
   三个 job 同时 failure 时 Ready 仍然 success。分支保护看的是 Ready ⇒ 整条门禁被废掉。
   改为读取 `toJSON(needs)`、逐项打印结果、非 success（`images` 的 skipped 例外）即
   `exit 1`。守卫 `TestCIFinalGateAssertsResults` 钉住 `toJSON(needs)` / `::error::` / `exit 1`
   与 needs 覆盖；删掉 `exit 1` 的注入已如期转红。

### 18.7 顺带修掉的 go.mod 陈旧标记

引入 `sigs.k8s.io/yaml` 直接依赖后跑 `go mod tidy`，它同时纠正了几处长期过期的 `// indirect`
（`k8s.io/utils`、`github.com/go-logr/logr`、`github.com/prometheus/client_golang` 其实都是直接
import）。`TestK8sDependencyBaseline` 因此报「未登记基线的 k8s 直接依赖 k8s.io/utils」。
**版本一个都没变**，登记进基线并注明原因即可；此后升版仍会被门禁拦住。

### 18.8 诚实边界

- 仍是**离线求值**，没有连真实 Prometheus server：抓取间隔、序列 staleness、
  `external_labels`、多副本 leader 抓取都未覆盖（promtool 只有 `evaluation_interval`）。
- promtool 3.1.0 与生产 Prometheus 版本未必一致；重大语义变更需按生产版本复跑。
- 覆盖守卫目前只对 `alert-rules-drift.yaml` 强制（已由 §19 补齐到全部告警）。
- 求值的是单条规则，不含「recording rule → alert 依赖链」的联合语义。
- 无 Grafana 仪表盘；无 Alertmanager 路由/抑制规则验证。
- 未跑 `m15 all`（与 §17 同一原因），本轮无 agent/控制器二进制变更。

## 19. 求值覆盖扩到全部 22 条告警 + 4 条记录规则（2026-11-12 续）

### 19.1 起点

§18.8 的第一条边界：覆盖守卫只强制 `alert-rules-drift.yaml`（4 条），
`alert-rules.yaml`（14 条）与 `alert-rules-backup.yaml`（4 条）只做 `check rules`
（能解析），记录规则连解析都没试过。而没有求值断言就等于「从来没被触发过」——
和 §17/§18 要治的是同一个病。

### 19.2 结果

新增 3 个案例文件，与规则文件一一对应：

| 用例文件 | 覆盖 | 关键语义 |
| --- | --- | --- |
| `tests/alert-rules_test.yml` | 14 条告警 | 阈值 `>=`/`<`/`>` 的边界、`for: 5m` 边界、`increase` 的「累计非 0 不重复告警」、心跳的时间戳语义 |
| `tests/alert-rules-backup_test.yml` | 4 条告警 | 24h `increase`、RPO 的 `for: 5m`、90 天窗口、`> 0` 守卫 |
| `tests/recording-rules_test.yml` | 4 条记录规则 | 过滤型聚合（`count(... >= 2)` / `count(... > 0)`）、`rate` 数值 |

覆盖守卫改为默认扫 **全部** `alert-rules*.yaml`（`COVERAGE_FILE` 仍可指定单个文件），
Go 侧 `TestPromtoolDriftRuleTestsAreIntact` 同步扩到全部告警文件，并新增两条约束：
告警名必须全局唯一、每个含告警的规则文件都必须被某个用例 `rule_files` 引用。
脚本本地 **PASS=34 / FAIL=0 / SKIP=0**（22 条告警 + 4 条记录规则 + 8 项结构检查）。

### 19.3 三个 promtool 行为陷阱（本轮实测踩到）

1. **`values: '1x5'` 产生 6 个样本，不是 5 个**：`x` 是「再重复几步」，即 `a×n` = n+1 个样本。
   按「n 个样本」推算区间会让所有断言时刻整体错位（`49x5 50x10 …` 本以为是 5 段，
   实际第一段占了 6 个点），表现为「阈值早/晚一个求值点」。
2. **`increase()` 在增量首次出现的那次求值读到 0**：区间内的最后一个样本要到下一个求值点
   才被计入。所以 `expr: increase(...) > 0` 的规则，其 firing 时刻比「手算的增量时刻 + for」
   再晚 1 个 interval。`ControlPlaneReconcileErrors` 因此是 5m 而不是 4m 触发。
3. **`max(...) by ()` 会丢掉全部标签**：`BackupDrillNever` 在「记录存在但为 0」这条分支上
   只有 `severity`，没有 `pvc` —— 与 `absent` 分支形态一致。这是「全局门禁」语义的代价，
   已写进用例注释，避免以后有人以为漏了标签是缺陷。

### 19.4 顺带修掉的一个假红

覆盖守卫用 awk 从规则文件取告警名，而工作区里的 `*.yaml` 是 **CRLF**（Windows `autocrlf=true`），
取出来的名字带尾随 `\r`，`grep "alertname:\s*Foo\b"` 永远不匹配 ⇒ 报「告警没有用例」。
这属于判据自身的缺陷（不是规则的问题），修法是 awk 里 `sub(/\r$/, "")` + `tr -d '\r'`。
**教训**：脚本读仓库文件时不能假设 LF，尤其是 Windows 工作区。

### 19.5 变异校验

| 注入 | 结果 |
| --- | --- |
| `ThinPoolDataWarning` 阈值 `>= 75` → `>= 95` | `alert-rules_test.yml` rc=1 |
| 记录规则 `max by` → `min by` | `recording-rules_test.yml` rc=1 |
| 去掉 `BackupDrillOverdue` 的 `> 0` 守卫 | `alert-rules-backup_test.yml` rc=1（新增的 ts=0 + 2161h 用例捕获） |
| 删掉 `alert-rules-backup_test.yml` | Go 守卫报「没有任何用例声明 rule_files」+ 4 条告警无覆盖 |

恢复后四个用例全部 rc=0。

### 19.6 诚实边界

- 仍是离线求值：没有抓取间隔抖动、staleness、`external_labels`、多副本 leader 抓取。
- `for:` 的判定精度受求值间隔限制（本轮统一 `interval: 1m`），秒级 `for` 未覆盖。
- 90 天窗口用 `interval: 1h` + 2161 步把时钟推过去；真实 Prometheus 按 1m 求值时行为一致，
  但「跨 DST / 时钟回拨」未覆盖。
- 未验证 Alertmanager 路由、抑制、静默；未做 Grafana 面板。
- 记录规则只验数值，不验「被 alert 规则引用」的联合语义。

## 20. 告警的落点：Alertmanager 路由/抑制与 Grafana 面板（2026-11-12 续）

### 20.1 起点：§18.8 / §19.6 连续两轮登记的同一条边界

> 无 Grafana 仪表盘；无 Alertmanager 路由/抑制规则验证。

前两轮把「什么时候算告警」做到了可求值（22 条告警 + 4 条记录规则全部有正例/反例），
但**告警算出来之后去哪儿**这件事在仓库里是空的。这留下三个静默失败：

| 缺陷 | 表现 | 为什么危险 |
| --- | --- | --- |
| 没有路由 | 告警落到默认接收器或被丢弃 | 值班人什么都收不到，而 Prometheus 一切正常 |
| 没有抑制 | thin-pool out-of-space 时同时响 4–5 条同源告警 | 值班人要先做故障分类才能开始处置 |
| 抑制/路由写错 | alertname 拼错、severity 拼错 | **不报错**，只是安静地不再生效；表现为「告警变少了」 |

三者的共同点还是那一条：**出错与「一切正常」在监控上不可区分。**

### 20.2 落地物

| 文件 | 作用 |
| --- | --- |
| `config/alertmanager/alertmanager.yaml` | 路由树（critical→pager / warning→ticket，默认黑洞）+ 3 条抑制规则 |
| `config/grafana/dashboards/hlvm-storage-drift.json` | §17 四族指标的面板（8 panel / 8 query） |
| `scripts/observability-config-check.sh` | `amtool check-config` + 仪表盘结构 + 每条 expr 的 PromQL 解析 |
| `scripts/dashboard_lint.py` | 仪表盘结构检查 / 由 `expr` 生成 promtool 探针规则 |
| `internal/metrics/observability_config_test.go` | 解析器查不出来的语义守卫（下面 20.4） |

### 20.3 抑制规则的设计判据

**抑制只用于「同一根因的派生信号」，绝不跨子系统压制。** 三条规则：

1. `ThinPoolDataCritical|ThinPoolMetadataCritical` ⇒ 压同 `node`/`vg` 的对应 Warning
   （同一表达式族、更高阈值，Critical 已包含 Warning 的全部信息）；
2. `ThinPoolOutOfSpace` ⇒ 压同 `node`/`vg` 的全部 thin-pool 容量告警（此时「使用率 85%」
   已无操作意义，处置动作变成 Runbook §9.1）；
3. `DiskSmartCritical` ⇒ 压同 `node`/`device` 的温度/寿命/spare/media 增量
   （同一块盘的派生信号，处置统一为「标记盘并换盘」）。

**刻意不加**的三条（写进配置注释防后人顺手补上）：

- 「任意 critical ⇒ 同节点所有 warning」：会压掉 `StorageDriftDetected` 与
  `DriftLVReportStalled` —— 这两条恰恰是「平台看起来一切正常」时唯一能暴露问题的信号。
- `DriftLVReportStalled ⇒ DriftReconcileSkipped`：后者的 `reason` 是闭集，
  `no_reporter`（lvs 一侧从未接入，配置缺失）与 `list_failed`（RBAC/API 故障）不能被
  `report_stale` 掩掉，否则同节点上两个独立故障只剩一个可见。
- `AgentHeartbeatLost ⇒ 任意存储告警`：心跳丢失时数据面不受影响，容量与磁盘告警仍然有效。

路由侧的两条硬约束：**critical 必须排在 warning 之前**（Alertmanager 只走第一条匹配的叶子
路由，除非 `continue: true`）；**每条 severity 必须有路由**，且该路由的接收器必须真的配有
投递通道——默认接收器是「只记录不投递」的黑洞，severity 拼错就等于全量静默。

> **§21.3 修正**：上面这条「顺序错了 critical 会被降级成工单」在本配置下**并不成立**——
> 两条 severity 路由的 matcher 互斥（`severity="critical"` / `="warning"`），一条告警只会
> 命中其中一条，顺序因而没有行为差异（实测：对调后判据仍全绿）。顺序要求保留为**防御性
> 约束**：一旦有人把 matcher 写成 `severity=~"warning|critical"`，它才真的决定投递。

### 20.4 两段式校验：外部解析器 + 语义守卫

`amtool check-config` 与 `promtool check rules` 能证明「结构合法、PromQL 可解析」，但
**证明不了语义**——抑制规则里写一个不存在的 alertname，amtool 照样 SUCCESS。所以补一层
不需要 docker 的 Go 守卫（进普通 `go test ./...`）：

| 守卫 | 抓什么 |
| --- | --- |
| `TestAlertmanagerInhibitRulesReferenceKnownAlerts` | 抑制两侧的 alertname 必须在规则文件里存在；两侧都必须由 alertname 限定（否则抑制范围不可预测）；`equal` 非空且 ∈ 闭集 {node,vg,device,kind,pvc}；拒绝已废弃的 `source_match` |
| `TestAlertmanagerRoutesCoverEverySeverity` | 每条 severity 都有路由且该接收器**真的配有 `*_configs`**；路由里的 severity 值必须是规则里出现过的；critical 必须排在 warning 之前；critical 不得用默认接收器 |
| `TestDashboardQueriesReferenceKnownMetrics` | 面板 `expr` 里的 `storage_*` 必须在真实指标集合里（与告警规则守卫**共用同一份** `knownMetricNames`）；对账面板必须覆盖 §17 四族指标 |
| `TestObservabilityConfigCheckIsWiredIntoCI` | 脚本 + linter 在位、可执行位、ci.yml 真的调用、`ready.needs` 覆盖 |

**一条写法约束**（由守卫强制）：抑制规则里的 alertname 只能是字面量或字面量的 `|` 分支，
不能写 `ThinPool(Data|Metadata)Critical` 这类分组正则。不是洁癖——正则里的名字没法静态展开，
于是「抑制规则引用了已改名的告警」只能靠人眼发现。第一版配置正是这么写的，守卫当场拒绝，
改成显式枚举后才有上面的检查能力。

### 20.5 仪表盘：Grafana 变量怎么静态校验

面板里出现 `${datasource}`、`$node` 这类 Grafana 模板变量，promtool 会把 `$` 当语法错误。
做法：**内建变量**（`$__rate_interval`/`$__interval`/`$__range`）按固定字面量替换（5m/5m/1h），
**仪表盘自己声明的变量**（`templating.list[].name`）替换成 `.*`——正则通配，任何 matcher
形态都能解析；替换完仍出现 `$` 即报「未登记模板变量」并指出位置。

为什么要这么绕：若直接把 `$` 丢给 promtool，报错指向 promtool 的解析器而不指向真正的笔误；
若默默放行，面板在 Grafana 里就是一张空图（"No data" 看起来像没有异常）。

`hlvm-overview.json`（既有，2026-10-28）用 `node=~"$node"`，正是这条规则覆盖到的情形。

### 20.6 变异校验（7 处注入，全部如期转红）

| 注入 | 判据反应 |
| --- | --- |
| 抑制规则 alertname 拼成 `ThinPoolDataCriticalX` | 守卫报「引用了不存在的告警 —— 该条抑制永远不会生效」 |
| 路由 `severity="critical"` → `"crit"` | 守卫同时报「没有任何告警用这个 severity」+「severity=critical 没有任何路由接收」 |
| 路由顺序对调（warning 在前） | 守卫报「warning(0) 排在 critical(1) 前面 —— critical 会被降级成工单」（**注**：该判据只在 matcher 可重叠时才有行为意义，见 §21.3） |
| critical 的 receiver 改成未定义的 `pagerx` | `amtool check-config` 失败（rc=1），脚本 FAIL |
| 面板 expr 改成 `storage_thinpool_data_percent >=` | promtool `unexpected end of input`，脚本 FAIL |
| 从 `ready.needs` 摘掉 observability | 两个 Go 守卫同时报「未包含 observability」 |
| 抑制规则 `equal: [node, vg]` → `[]` | 守卫报「等于全局抑制」 |

恢复后 `go test` 两项 ok、脚本 `PASS=5/FAIL=0/SKIP=0`。

### 20.7 CI：job 从 `prometheus-rules` 改名 `observability`

该 job 现在同时管规则求值、Alertmanager 配置、仪表盘查询，名字必须对得上（否则下一个人会
以为「改 Alertmanager 不用跑 CI」）。两个 step 分别调两个脚本，仍整体进 `ready.needs`。

风险：**若分支保护里把 `Prometheus rules (promtool)` 配成了必需检查，改名会静默失效。**
本仓库的分支保护看的是 `Ready`（§18.6 的教训就是它），所以改名安全；换成别的仓库需要复核。
守卫 `TestCIFinalGateAssertsResults` 现在断言 `observability` 并在题注里记了这个改名。

### 20.8 诚实边界

- **没有真实 Alertmanager / Grafana 实例**：amtool 是离线校验，报警延迟（Critical ≤1min）、
  分组行为、`repeat_interval` 的实际手感、模板渲染结果都未验证。
- **`equal` 标签在真实序列上是否存在未验证**：抑制不生效的头号原因是 `equal` 里的标签
  某一侧没有（例如未来给 `DiskSmartCritical` 加了 `device` 之外的维度）。这只能在真机上看
  「同源告警是否真被压掉」。
- 接收器地址是**形状示例**（`hlvm-alert-sink...`），部署时必须替换；本仓库不含适配器实现。
- 仪表盘只做**语法与指标名**校验：不校验数据源可达、单位/阈值是否与规则文件一致
  （同一阈值在规则与面板各写一遍，目前靠人；未做跨文件一致性断言）、不校验面板是否真的好看。
- `$__rate_interval` 按 5m 代入：区间长度不影响语法解析，但**不代表** Grafana 实际取值。
- 面板 `hlvm-overview.json` 里 `storage_disk_*` 系列依赖 exporter 实际暴露，控制面无法验证。
- 抑制规则只覆盖 thin-pool 与磁盘两族；备份/对账告警没有抑制（见 20.3 的「刻意不加」）。
- 未跑 `m15 all`，本轮无 agent/控制器二进制变更。
  - **2026-11-13 状态更正**：「未跑 `m15 all`」已由 §22 闭合（第五遍 16 个 verify 相位零 FAIL）。
    本条保留为 §21 交付时刻的历史快照，不改写。

## 21. 用真实 Alertmanager 实例验抑制与路由（2026-11-12 续）

### 21.1 起点：§20.8 的第一条边界

§20 交付了路由树与 3 条抑制规则，并连写两轮留下同一条边界：

> **没有真实 Alertmanager / Grafana 实例**：amtool 是离线校验，报警延迟、分组行为、
> `repeat_interval` 的实际手感、模板渲染结果都未验证。

这条边界的要害在于：**配置合法 ≠ 运行时真的按预期抑制**。三种错法都不会报错 ——

| 错法 | 后果 | 谁能发现 |
| --- | --- | --- |
| `equal` 里的标签在某一侧告警上不存在 | 该条抑制永不匹配 | 谁都不能，配置看着完全正常 |
| 抑制写得过宽 | 把「必须由人处理」的告警压掉 | 表现为「告警变少了」 |
| receiver 名字写错 / 路由没接上 | 值班人收不到 | 表现为「最近很安静」 |

第一条尤其隐蔽：它是**语义**错误，`amtool check-config` 与 `alertmanager_config_test.go`
都只能检查「标签名在我们的闭集里」，检查不了「这条告警真的带这个标签」。

### 21.2 落地物

`docs/poc/scripts/alertmanager-inhibit-e2e.sh`：用 `AM_IMAGE`（默认 `prom/alertmanager:v0.28.1`）
起一个容器，挂**仓库里那份** `alertmanager.yaml`，然后用 `amtool alert add` 注入告警、
读 `/api/v2/alerts` 与 `/api/v2/alerts/groups` 断言。8 组、27 条断言，全部「正例 + 反例」成对：

| 组 | 正例 | 反例（缺了它这组等于没测） |
| --- | --- | --- |
| 1 | 同 node+vg 的 Critical 压掉 Warning | DataCritical 自身 active（不自我抑制） |
| 2 | — | 同 node 不同 vg、同 vg 不同 node **都不得**被压 |
| 3 | OutOfSpace 压同 pool 的 DataWarning 与 MetadataCritical | OutOfSpace 自身 active |
| 4 | — | OutOfSpace **不得**压 StorageDriftDetected / DriftLVReportStalled / AgentHeartbeatLost |
| 5 | DiskSmartCritical 压同盘温度告警 | **不得**压另一块盘（`equal: [node, device]`） |
| 6 | critical→pager、warning→ticket | 未知 severity→blackhole 且仍 `active`（不丢弃） |
| 7 | 解析 OutOfSpace 后 MetadataCritical 回 active | 同一时刻 DataWarning 仍被 Critical 压着 |
| 8 | 同 alertname+node 的两块盘告警合成 1 组 | （分组数/组内条数都断言） |

工程细节三条：

- 断言**重试到收敛**（`SETTLE_SECS`，默认 20s）而不是 `sleep` 固定时长：抑制由通知流水线
  异步重算，固定 sleep 要么慢要么抖。
- 分组断言必须等 `group_wait`（ticket 是 1m）过后才在 `/api/v2/alerts/groups` 出现，
  所以轮询上限 `GROUP_WAIT_SECS=150`，且**断言「恰好 1 组、组内恰好 2 条」**而不是「有分组」。
- `amtool` 走 `docker exec` 进同一个容器，省一次 `docker run`，也不需要 `--network host`
  （§20 的教训：镜像里 `/bin/amtool` 与 `/bin/alertmanager` 都存在）。

配套 `TestInhibitRulesHaveRuntimeE2ECase`（普通 `go test ./...`，不需要 docker）守：
每条抑制规则的 source 告警必须真的出现在脚本的 `am_add alertname=<name>` 行里
（只在注释里提到不算），脚本有 `SUMMARY` 汇总行与 `VERDICT="FAIL"` 分支。
**新加一条抑制规则却不补实测用例时这里会红** —— 否则判据会安静地覆盖不到新规则。

### 21.3 实测发现的四个语义（都推翻了我原来的写法）

**① `status.inhibitedBy` 只返回一个抑制者指纹，不是「被几条规则压」。**
第一版断言写的是「两个根因同时存在 ⇒ `inhibitedBy` 长度 2」，实测恒为 1：Alertmanager 0.28
按**规则顺序**取第一个匹配的抑制源。于是「被几条规则压住」这件事从 API 数量上看不出来，
断言只能落在**「抑制者是谁」**（把指纹映射回 alertname）而不是「有几个」。

**② 抑制是逐 target 按当前活跃根因实时计算的，不是一次性扣帽子。**
同一时刻解析 OutOfSpace 后：MetadataCritical（只被规则 2 覆盖）立刻回到 `active`，
而 DataWarning（还被规则 1 的 DataCritical 覆盖）继续 `suppressed`，抑制者字段也从
OutOfSpace 变成 DataCritical。**「解除了一个、还压着另一个」才是正确行为**，
一刀切地「根因恢复就全解除」或「扣上就不动」都是错的。

**③ 被抑制的告警仍然可以抑制别人。**
MetadataCritical 自己正被 OutOfSpace 压着，但它照样是 DataWarning 在规则 1 下的抑制源
（`inhibitedBy` 报的就是它）。所以别把 `suppressed` 理解成「这条告警不参与计算」。

**④ 路由顺序在互斥 matcher 下不产生行为差异 —— §20.3 的表述过头了。**
把 warning 路由挪到 critical 之前，27 条断言**依然全绿**。原因很简单：`severity="critical"`
与 `severity="warning"` 互斥，一条告警只会命中一条子路由，顺序无关。§20.3 那句
「顺序错了 critical 会被静默降级成工单」只在 matcher 可重叠（如 `severity=~"warning|critical"`）
时成立。已在 §20.3 加注更正，并**刻意不给脚本加一条「顺序错就红」的假断言** ——
测不出东西的断言比没有更糟，它会让下一个人以为这段被覆盖了。

### 21.4 变异校验（6 处注入，5 红 1 绿）

| 注入 | 结果 |
| --- | --- |
| 规则 1 `equal: [node, vg]` → `[node]` | `[FAIL] 同 node 不同 vg：不抑制` |
| 关掉规则 2（`alertname="ThinPoolOutOfSpaceDisabled"`） | 4 条红（含「规则 2 专属」的 MetadataCritical） |
| 规则 3 `equal: [node, device]` → `[node]` | `[FAIL] 另一块盘（device=sdb）不受影响` |
| 追加「任意 critical 压同节点所有 warning」 | 5 条红（漂移/心跳/跨 vg/跨盘全被打掉） |
| pager ↔ ticket 对调 | `[FAIL] critical → pager`、`[FAIL] warning → ticket` |
| **路由顺序对调（warning 在前）** | **仍全绿** —— 见 21.3 ④，这条变异本就不该红 |

最后一行是本轮最重要的收获：**变异不红不一定是判据弱，也可能是「我以为的语义根本不存在」**。
判据写在纸上时是「配置意图」，跑在真实实例上才变成「运行时事实」，两者对上之前，
任何一条断言都只是我的猜想。

### 21.5 诚实边界

- **没有真实告警流**：告警是 `amtool alert add` 直接灌进 Alertmanager 的，不经过 Prometheus
  抓取与求值，所以「规则触发 → 路由 → 抑制」的整链仍未端到端验证（缺 Prometheus 实例）。
- **没验证投递**：接收器 URL 是形状示例（`hlvm-alert-sink...`），容器里根本解析不到；
  只验证了「选哪个接收器」，没验证「消息真的发出去 / 模板渲染正确 / 重试与超时」。
- **`equal` 标签在真实序列上是否存在仍未验证**：本脚本自己构造的告警当然带这些标签；
  真实的 `DiskSmartCritical` 会不会带 `device`、`ThinPoolOutOfSpace` 会不会带 `vg`，
  取决于 exporter 的实际输出 —— 这才是 §20.8 第一条边界的真正剩余部分。
- 只覆盖 3 条抑制规则与 2 条 severity 路由；`group_interval` / `repeat_interval` 的手感、
  `resolve_timeout` 的抖动抑制都未测。
- 镜像固定 `v0.28.1`；`inhibitedBy` 的行为在别的版本可能不同（本 ADR 的结论都标注了版本）。
- 脚本不进 CI（要拉 ~280MB 镜像），**CI 只保证「每条规则都有实测用例存在」**，不保证「用例跑过」。
- 未跑 `m15 all`，本轮无 agent/控制器二进制变更。
  - **2026-11-13 状态更正**：「未跑 `m15 all`」已由 §22 闭合（第五遍 16 个 verify 相位零 FAIL）。
    本条保留为 §21 交付时刻的历史快照，不改写；§20.8 同条亦已加注。

## 22. 扩 CP 使 D=3 与真机 `m15 all` 收口（2026-11-12 夜 → 11-13 记账）

### 22.1 起点：代码全绿，但记账落后于真机

§16.7 / §17.7 写「只覆盖 2 个 worker、CP 未扩」；§20.8 / §21.5 连续两节都留
「未跑 `m15 all`」。而此时 §15–§21 的判据、告警配置与部署清单已经改了 11 个 commit，
真机仍停在 `:v0.1.0-preview.5`。

这比代码有 bug 更危险：下一个人会照着过期的诚实边界决定「哪些还没验」，
从而重复验证或直接跳过。本轮把 ② 扩域与 ③ 真机全量回归做完，并把结论回填进
ADR / runbook / CHANGELOG。历史快照一律**加注更正**，不改写。

### 22.2 扩 CP 让对账有效域从 2 变 3

有效域 D 由 managed PV 所在节点推导，**不等于节点总数**：CP 带
`node-role.kubernetes.io/control-plane:NoSchedule`，若 DS / 测试 Pod 落不上去就不产生 PV，
D 仍是 2。要让 D=3，必须在 CP 上放**真实 PV**。

| 落地物 | 作用 |
|---|---|
| `control-plane/config/lvmd/nodevg-seed-187.yaml` | CP `10-60-131-187` 的 NodeVG 手工 seed（`hlvm-lvmd-vg-187`，盘 `virtio-UCLOUD_DISK_VDB`） |
| `control-plane/config/csi/40-node.yaml` | lvmd / topolvm-node / agent 三 DS 加 control-plane 容忍 |
| `docs/poc/scripts/expand-lvmd-nodes.sh` | 默认三节点 + 显式 `NODE_VG_MAP`（VG 名**不能**从节点名推导：153→`vg-153`、166→`vg-202`、187→`vg-187`） |
| `docs/poc/scripts/pvc-supply-e2e.sh` | 新增 `TOLERATE_CONTROL_PLANE=1`，修 CP 上消费 Pod 因 taint 无法调度导致的 E2E 假红 |

验收：3 个 NodeVG 均 `vgExists=true`；三 DS 在三节点全 Ready（agent 3/3）；
3 条独立 `CSIStorageCapacity`（`hlvm-b` / 36Gi / 各节点）；逐节点
PVC Bound → PV 亲和 `topology.topolvm.io/node` → Pod Running → 写 16MiB(ext4) →
thin LV 落入 thinpool → 回收，全 PASS。**D=3 成立**。

首跑 `expand-lvmd-nodes.sh` 有 1 条 FAIL：seed 窗口生成
`vg-hlvm-lvmd-vg-187-vgcreate` 任务（`SAFE=true`），脚本按设计要求必须显式
`PURGE_WINDOW_TASKS=1` 才清理，属闸门生效，不是产品缺陷。

### 22.3 bootstrap 守卫的「2 个 NodeDisk」是版本计数，不是对象计数

`m15 all` 首跑在 bootstrap 第 4/5 步被 `ensure_nodedisk_crd_baseline` 拦下：

> 集群里仍有 2 个 NodeDisk（当前 CRD 版本：v1alpha1 v1beta1），而目标基线只剩
> v1beta1……请先按 runbook 完成存储版本迁移。

先问「前提在真机成立吗」。实测 5 个 CRD 状态完全一致：

| 事实 | 实测 |
|---|---|
| `spec.versions` | `[v1alpha1(served, storage=false), v1beta1(served, storage=true)]` |
| `status.storedVersions` | `["v1beta1"]` —— **已干净**，无对象持久化为 v1alpha1 |
| 真实对象 | 1 个 `nodedisk`（`m15-cert-disk`）+ 3 个 `nodevg` |
| conversion webhook | `hlvm-crd-conversion` 2/2 Ready |

即 §10.5 的迁移（双版本 → 重写对象 → 清 storedVersions）**早已做完**，
只是 `restore_single_version_crds` 从未执行，集群停在一次被中断的
`verify-storage-migration` 中间态。守卫报的「2」是把同一个对象按两个 served 版本
各数了一次。

处置：先 `kubectl apply -f config/crd/bases --dry-run=server` 确认 apiserver 接受，
再执行忠实的 `restore_single_version_crds`（apply bases + 清 discovery 缓存）。
5 个 CRD 全部收回单 `v1beta1`、`conversion=None`、`storedVersions=["v1beta1"]`，
4 个真实对象无损。**没有删数据，也没有放宽守卫。**

### 22.4 `verify-lvmd` 假红：扩域把测试前提改了

第二遍 `all` 在 `verify-lvmd` 报两条 FAIL：「无可用 device-class 时托管 ConfigMap
未被撤销」「ConfigMap 未被 GC」。该相位用
`kc get nodes -o jsonpath='{.items[0].metadata.name}'` 选测试节点，而 D=3 扩域后
首节点正是 CP `10-60-131-187`，上面现在有**真实生产** `hlvm-lvmd-vg-187`：

```
测试 NodeVG(m15-lvmd-a/b/c) + 真实 NodeVG(vg-187) → 同一 hlmd-lvmd-187
```

控制器把两者一起聚合，自然**正确地**保留 CM（真实 VG 仍有效），于是两条
「应当被撤销 / 被 GC」的断言失败。断言本身没错，错的是前提：相位假设该节点
只有自己的测试对象。

处置：测试 NodeVG 隔离到专用假节点 `m15-lvmd-fake-node`（对齐既有
`m15-conv-fake-node` 模式）。先做可逆探针：为任意节点名建 NodeVG，控制器 1s 内
生成 CM；删除后 CM 被 GC —— 证明假节点不会让断言失去鉴别力。单独跑
`verify-lvmd` 全 PASS，含原先失败的两条。

同时确认中止**零生产损害**：3 份真实 `hlmd-lvmd-*` CM 内容干净（单 device-class、
正确 VG、`type: thin`），无 `/dev/m15-lvmd*` 污染，lvmd DS 三节点 Ready / RESTARTS=0，
常驻 agent DS 当时仍 3/3（`verify-agent` 尚未运行）。

### 22.5 `verify-cert-rotation`：从 2 小时死锁到端口冲突真凶

连续 4 遍重跑才定位，四个根因层层叠加：

| # | 根因 | 表现 | 修复 |
|---|---|---|---|
| 1 | `start_pf` 把探针 port-forward 到**具体 Pod 名** | 证书轮换删 serving-cert secret → webhook Pod 以新 hash 重建 → 探针永远指向 `NotFound` 的幽灵 Pod | 改转发到 `svc/hlvm-crd-conversion`（Pod 重建自动路由） |
| 2 | `server_leaf_live` 经 `$(...)` 子 shell 调用，`pf_rebuilds` 自增被丢弃 | 「重建探针第 1 次」重复 57 次，`<3` 上限永不触发 → 进程存活 2h+ | `pf_rebuilds` 落盘 `${tmpd}/pf_rebuilds` |
| 3 | Service 暴露 `port:443 → targetPort:9444`（`03-crd-conversion.yaml:107-108`），写成 `19443:9444` | svc 没有 9444 这个 port，port-forward 直接建不起来 | 用 svc 的 `443` |
| 4 | **本地 `19443` 被 `hnb-system` 的 `svc/tunnel-server` 常驻 port-forward 永久占用** | `Unable to listen on port 19443: bind: address already in use` → 探针连基线都读不到，连续多遍假红 | 探针本地端口改 `19499`（实测空闲），`start_pf` 前 `fuser -k 19499/tcp` 兜底，且**只清 19499，不碰 hnb 的 19443** |

第 4 条是最终真凶，前三条是表象或叠加。`pgrep` 实证：

```
kubectl -n hnb-system port-forward --address 0.0.0.0 svc/tunnel-server 19443:9443
```

关键纪律印证：该相位内大量 `PASS` 始终证明**证书轮换功能本身是成功的**
（TLS 链路真通、`v1alpha1` 转换读仍可用、Pod 未重启、caBundle 未变），
失败的只是「用探针读 leaf 指纹」这条**验证手段**。读不到证书 ≠ 证书没轮换，
所以修探针而不是放宽判据。

修复后先用轻量可逆验证（临时恢复 conversion 组件 → 手动
`port-forward svc ... 19499:443` → `openssl s_client` 读到 `GOT_CERT` → teardown +
还原单版本 CRD），确认端口可用再花 18 分钟重跑，避免继续盲目试错。
终止 2h 死锁时 EXIT trap 的 `conversion_teardown` 正常收口：CRD 回单 `v1beta1`、
conversion 部署删除、无残留测试对象、4 个真实对象无损。

### 22.6 第五遍 `m15 all`：16 相位零 FAIL

日志 `/tmp/m15-all-real-20261112-222225.log`（`M15_TARGET=real`，
`IMG_TAG=v0.1.0-preview.5`，`M15_GHCR_PUBLIC=1`）：

- preflight `PASS=11 / WARN=2 / FAIL=0`；
- 16 个 `verify` 相位 **`grep -c '^    FAIL:' = 0`**；
- `verify-cert-rotation` **16 条证书链断言 + 4 条多 Kind conversion smoke 全 PASS**，
  `TLS 探针无响应` 告警数 = 0；
- storedVersions 迁移、conversion、collector、跨节点调度、VG 端到端等全 PASS；
- `verify-velero` SKIP（见 §22.8）。

`all` 分支的 for 循环结束后**没有汇总行**（`done ;;` 直接结束，脚本设计），
所以「日志停在 `verify-velero`」是正常 exit 0，不是异常或日志截断。

`verify-agent` 相位结尾（脚本第 2247 行）会主动 `agent_cleanup` 删除常驻 DS
（注释：常驻会改变 `verify-ttl` 的前提），所以跑完 DS **本来就不存在**。
按「先备份清单、跑完恢复」的要求，用 `docs/poc/scripts/deploy-agent-real.sh`
逐节点恢复 3 节点生产版：

| 节点 | 结果 | agent Pod |
|---|---|---|
| `10-60-153-100` | `PASS=17 / FAIL=0`，`REAL_WRITE_OK` | `hlvm-storage-agent-rxq7r` |
| `10-60-166-202` | `PASS=17 / FAIL=0`，`REAL_WRITE_OK` | `hlvm-storage-agent-szslq` |
| `10-60-131-187`(CP) | `PASS=17 / FAIL=0`，`REAL_WRITE_OK` | `hlvm-storage-agent-gzcvq` |

`REAL_WRITE_OK` 指在各自宿主 VG 上真实完成 `lvcreate` / `lvs` / `lvremove`
（§5.3 wrapper 硬门禁，不是只读 `lvm version` 假绿）。DS 终态 `hlvm-storage-agent`
3/3 Ready、`:v0.1.0-preview.5`、`nodeSelector hlvm.io/lvmd=true`；跑前确认无孤儿
StorageTask。

### 22.7 变异校验与提交

- 假节点隔离：可逆探针（建 / 删 CM）+ 单独跑 `verify-lvmd`，两条原 FAIL 断言转 PASS；
- 探针端口：手动 `19499` 读到 `GOT_CERT`，`19443` 复现 `bind: address already in use`；
- 重建上限：第三遍重跑 `TLS 探针无响应` 恰好 3 次后相位正常中止（不再 2h 卡死），
  证明计数器落盘生效；
- 修复集中在 `scripts/m15-integration.sh`（+36/-14），`bash -n` 通过，提交 `20c3783`；
  push 后 CI run 131 的 Go / Rust / Observability / images / Ready 五个必需 job 全 success。

### 22.8 诚实边界（本轮之后仍然成立）

- **三个 SKIP 未覆盖**：`verify-velero`（docker.io 的 velero / minio 拉不到，端到端
  备份恢复与 RTO/RPO 未验）、`verify-device-hotplug`（无 `M15_DISK_ATTACH_CMD`）、
  `verify-kubelet-restart` 两条 checkpoint 断言（本环境 kubelet 不落盘
  `PodDeviceEntries`）。SKIP 一律不计 PASS。
- **真机二进制仍是 `:v0.1.0-preview.5`**：本轮 11 个 commit **无 Go / Rust 产品源码变更**，
  改的是部署清单、判据脚本、告警配置、测试与文档。`v0.1.0-preview.6` 只固化配置与
  版本串；升级到新 tag 需重新部署，行为等价但**未在新 tag 上重跑 `m15 all`**。
- §20.8 / §21.5 的**其余**边界仍有效：无常驻真实 Prometheus / Alertmanager / Grafana
  （离线求值与临时容器不等于整链）、接收器地址仍是形状示例、`equal` 标签在真实
  exporter 序列上是否存在未验、投递与模板渲染未验。
- §16.7 / §17.7 的**其余**边界仍有效：A 链路设备插件仍只在 153 单节点；
  `freeBytes` 是 VG 物理 free（约 2 GiB）≠ CSI 的 thin-pool 36 Gi；NodeVG 手工 seed；
  聚合 CM 由脚本同步而非控制器渲染；指标只在 leader 副本；平台**不自动修复**漂移。
- `runbook §4` 的 19 项 §B 递延（告警延迟演练、指标口径对账、dmeventd autoextend、
  thinpool 打满、灰度/评审门禁、Velero 闭环）**仍未逐项验收**；`m15 all` 零 FAIL
  不能代替它们，`M14-closure.md` 风险 #3「不能视为 production-ready」结论不变。
- hnb 联合验收仍停在接口级（`HTTP 200 /version`），平台级纳管缺 HTTPS
  `--platform-url` / bearer token / kubeconfig credential / agent enrollment。

## 23. 项目状态声明：模块先行、决策门未过（2026-11-13）

### 23.1 为什么单独立一节

§22 收口了「代码全绿、记账落后」的偏差，但带来新的误读风险：真机 `m15 all`
16 个 verify 相位零 FAIL、main / tag CI 全绿、`v0.1.0-preview.6` Release 已发，
很容易被读成「设计方案已验收」。设计 v1.1 §10 阶段 0 明确写着「以上未达标前，
不进入模块开发」，而本仓库是**模块先行**（`docs/poc/poc-report.md` 自注了这一点）。
两道门控的真实状态必须写在显眼处，且不能用「已实现」替代「已验收」。

### 23.2 对照：设计门控 vs 当前状态

| 门控 / 契约 | 设计要求 | 当前状态（2026-11-13） |
|---|---|---|
| §10 阶段 0 决策门 | 10 项全通过后才进模块开发 | 10 项全 `☐ 移交集成`；`poc-report.md` 空模板；`functional-test.sh` / `fio-baseline.sh` 存在但未执行 |
| 决策门 4 份 ADR | 语言 / RAID / 版本矩阵 / RTO-RPO 出结论 | 001、002「提议（评审中）」，003、004「框架 / 待实测填充」 |
| 设计待核实清单 | 5 项立项前关闭 | 1 / 2 / 3 / 5 未关闭（4 不需 POC） |
| §B 19 项递延 | 逐项真实验收并留证据 | `runbook §4` 可辨识 17 行：15 未验 + 2 部分，**零项通过** |
| §2.1 三方对账 | 读 TopoLVM `LogicalVolume` CR + PV + `lvs` | 实际 `ManagedLVsFromPVs`（PV `csi.volumeHandle` + nodeAffinity + NodeVG 反查），未接 LogicalVolume CR |
| §2 组件形态 | exporter 独立非特权 DaemonSet | 改为设备插件按盘授权 + 每盘 collector Pod；独立 exporter DS 未跑 |
| §5.2 / §11 安全基线 | agent 特权最小化、PSA / seccomp / 命令白名单 / 镜像签名与 SBOM | agent 仍 privileged、命名空间 PSA `enforce=privileged`、白名单仅 CM 声明、`04-image-signing.yaml` 仅骨架 |
| §4 / §8 / §11 可用性指标 | 分级 FailurePolicy、告警延迟、autoextend ≤30s、RPO ≤24h | 动态层调度级未复验；无常驻 Prometheus / Alertmanager / Grafana；非功能指标无一实测 |
| 版本与环境边界 | — | 真机仍 `:v0.1.0-preview.5`，`.6` 未在新 tag 重跑 `m15 all`；3 个 SKIP 不计 PASS |

**结论**：`docs/M14-closure.md` 风险 #3「不能视为 production-ready」不变；
`preview` 后缀仍然名副其实。

### 23.3 闭合顺序（已获用户授权推进）

1. 本节状态声明（本次提交）。
2. 真机升级到 `:v0.1.0-preview.6`、按 `runbook §10.20` 复跑前必查三件事重跑
   `m15 all`，跑完用 `deploy-agent-real.sh` 恢复 3 节点常驻 agent DS。
3. 阶段 0 基础功能与性能：functional-test（扩容 / 快照 / 克隆 / 重启恢复）、fio 基线。
4. 阶段 0 故障演练：thinpool 打满 + dmeventd、坏盘热拔、webhook 全宕机、节点断电恢复。
5. 常驻 Prometheus / Alertmanager / Grafana → 打通触发链、告警延迟与指标口径对账。
6. Velero 镜像可达 → 备份闭环与 RTO/RPO。
7. 四份 ADR 定稿 + `poc-report.md` 回填 + 待核实清单关闭 → 决策门评审。
8. 流程评审项（fio 评审、灰度放量、上线门禁）与 hnb 平台级纳管凭据、
   Go / Rust 依赖代差属外部依赖，登记后等待用户提供。

### 23.4 纪律（本节不是验收记录）

- **不以自动化覆盖代替验收**：`m15 all` / CI / promtool 离线求值 / 临时 Alertmanager
  容器都属 §A，不能 tick §B 任何一项。
- **能力缺失 SKIP + 写明未覆盖，绝不计 PASS**；判据失败先问前提是否在真机成立。
- **历史快照只加注不改写**：§1–§22 的结论保留原样，用「状态更正」注明后续变化。
- **无实测数据不得编造结论**：ADR-001~004 与 `poc-report.md` 只能在真实结果产出后回填；
  流程与评审项由人签字，脚本不代劳。

### 23.5 执行路径调整与能力边界（2026-11-13 实测复核）

§23.3 的第 2 步起会动真机，复核时**前提已变**：真机集群现在承载 hnb 平台运行中业务
（`hnb-system` 35 个 Running Pod），**11 个 PVC 全部挂在 `hlvm-b`**，含 PostgreSQL×3、
NATS×4、hnb-agent-state、demo-live-data。`m15 all` 会删常驻 DS / cordon CP / 重启 kubelet，
阶段 0 的打满、拔盘、断电演练更直接冲着承载这些数据的 thin-pool 去。按「两侧禁并行、
前提先行」纪律，改为**隔离环境优先**：真机只做只读验收与镜像滚动升级，破坏性相位移到
独立 kind 集群，真机现场证据等 hnb 错峰窗口补。清单已只读备份到 WSL
`~/hlvm-backups/pre-upgrade-20261113-155147/`。

**真机已完成的非破坏动作**：controller / webhook / `hlvm-storage-agent` DS /
`hlvm-disk-plugin` DS 四个工作负载滚动到 `:v0.1.0-preview.6`，rollout 全 OK、Pod 全 Ready；
复核 11 PVC 全 Bound、35 个业务 Pod Running、3 个 NodeVG `vgExists=true`、
0 条非终态 StorageTask、无 Warning 事件。**遗留**：3 个每盘 collector Pod 仍是
`:v0.1.0-preview.5`（控制器创建的独立 Pod，不随 DS 滚动），待窗口统一处理。
`.6` 与 `.5` 二进制等价（发布说明 §1），本次升级只消除「真机未跑新 tag」的记账缺口，
**不等于在新 tag 上重跑过 `m15 all`**。

**阶段 0 能力矩阵**（`kind` = 隔离环境 `hlvm-m15-20261113`，3 节点；真机 = 承载业务的集群）：

| 阶段 0 项 | 隔离 kind | 真机 | 当前结论 |
|---|---|---|---|
| `m15 all` 16 个 verify 相位 | **已跑通**（§23.6：15 相位 PASS + 1 SKIP、exit 0） | 需错峰窗口 | kind 结果属 §A，不可外推为真机验收 |
| PVC 创建 / 在线扩容 | 无 TopoLVM CSI，PVC 不绑定 | 有唯一 SC `hlvm-b`（`allowVolumeExpansion: true`） | 真机可用**新建** PVC 验，不碰已有 11 个 |
| 快照 / 克隆 / 重启恢复 | 无 `snapshot.storage.k8s.io` CRD | 同左，且无 VolumeSnapshotClass / snapshot-controller；CSI 覆盖值明确 `snapshot.enabled=false` | **能力缺失，不可验**（需 D2） |
| fio 性能基线 / p99 | 无真实块设备、无 lvm、无 `dm_thin_pool` | 有真实 LV 但承载业务数据 | 需专用 LV + 窗口（D1） |
| thinpool 打满 / dmeventd ≤30s | `dm_thin_pool` 未加载（preflight WARN） | 需窗口，高危 | 未覆盖 |
| 坏盘热拔 / 节点断电 | 无物理设备 | 需窗口，高危 | 未覆盖 |
| webhook 全宕机不阻塞非平台 PVC | 可跑（分级 `FailurePolicy` 已落地） | 可跑但会动业务 webhook | `webhook-availability.sh` 仍含 `<非 hlvm 的 StorageClass>` 占位符、无断言、无变异校验，**判据未达可执行级** |

**外部依赖清单**（脚本不能代劳，登记后等待）：

| # | 依赖 | 阻塞对象 |
|---|---|---|
| D1 | 真机维护窗口 + hnb 业务错峰 | `m15 all` 真机证据、全部故障演练 |
| D2 | snapshot CRD / controller / VolumeSnapshotClass + CSI 重渲染开 `snapshot.enabled` | 快照、克隆、functional-test |
| D3 | `functional-test.sh` 的 SC 从 `topolvm-thin/-thick` 适配 `hlvm-b`；`webhook-availability.sh` 去占位符并补正例+反例 | 阶段 0 基础功能、§5.4 |
| D4 | velero / minio 镜像可达（GHCR mirror 或本地 Harbor） | 备份闭环、RTO/RPO、ADR-004 |
| D5 | 常驻 Prometheus / Alertmanager / Grafana + 接收器凭据 | 告警整链、延迟演练、指标口径 |
| D6 | hnb 平台 HTTPS `--platform-url`、bearer token、kubeconfig credential、agent enrollment | 平台级纳管 |
| D7 | 评审签字：fio 报告、灰度放量、上线门禁、POC 决策门 | §B 流程项、阶段 0 决策门 |
| D8 | Go / Rust k8s 依赖代差单独立项 | 版本矩阵 ADR-003 |

**纪律**：表内「不可验」项一律 SKIP 并写明未覆盖，绝不计 PASS；判断据前先确认前提在
目标环境成立；`poc-report.md` 与 ADR-001~004 只能在 D1–D7 产出真实数据后回填。

---

### 23.6 隔离 kind 全量回归结果（2026-11-13，第六遍）

§23.3 第 2 步的破坏性相位按 §23.5 移到独立集群 `hlvm-m15-20261113`（全新集群名，
以避开残留 `kind-hlvm-kind` kubectl context 让脚本误判「集群已存在」而跳过建集群）。
命令：`M15_TARGET=kind CLUSTER_NAME=hlvm-m15-20261113 IMG_TAG=latest bash scripts/m15-wsl.sh all`。
前两次中止原因分别是残留 context 与 `verify-kubelet-restart` 假红（后者已由 `d02cb03`
修正：改用轮询 `kubelet.sock` 签名判定重启完成，并做正例 + 变异反例校验）。

**结果**（证据：WSL `~/m15-kind-all-20261113-3.log`，1774 行 / 19m24s）：

| 判据 | 实测 |
|---|---|
| 退出码 | `M15_ALL_RC=0` |
| `FAIL:` / `[error]` 行 | **0 条** |
| 每相位收尾汇总行 | **本轮日志 15/16**：14 条「验证全部 PASS / 验证通过」+ 1 条 SKIP（收尾句格式，不是 `SUMMARY:`）；`verify-admission` 只有 2 条 `PASS:` 断言、**无收尾行**，缺口与修复见下 |
| preflight | `PASS=6 WARN=12 FAIL=0`（12 项能力缺失已显式列出） |
| 相位结论 | **15 个 PASS + 1 个 SKIP**；SKIP 为 `backup-restore`：kind 节点拉不到 `docker.io/minio`（`ErrImagePull` / insufficient_scope），只校验了仓库自带 backup manifests 语法，端到端备份恢复未验 |

15 个 PASS 相位：NodeDisk 收敛基线、admission 4.3、VG controller、lvmd 聚合、StorageTask
归属与 GC、StorageTask TTL、节点 agent、设备插件、每盘 collector、kubelet 重启、设备热插拔、
跨节点拓扑/容量账、CRD conversion、serving 证书轮换、storedVersions 迁移。

**判据可观测性缺口（本轮发现并修复）**：`all` 的回归三件套是「exit 0 + 无
`FAIL:`/`[error]` + 每相位汇总行」，而 `phase_verify_admission` 历史上只在成功时逐条打
`PASS:`、末尾 `fail=0` 检查后直接返回，没有自己的收尾行 ⇒ 本轮日志严格口径下只满足
**15/16**。已在 `scripts/m15-integration.sh` 的 `fail=0` 分支之后补一行
`info "admission 4.3 可自动化部分验证全部 PASS(…)"`：**断言一字未改**，失败仍走 `die`。

- 正例：单独重跑 `verify-admission` rc=0，末尾出现该收尾行（`~/m15-admission-rerun.log`）；
- 反例（变异校验）：把注入期望表达式改成不可能匹配，相位 rc=1、`FAIL:` 1 条、
  `[error]` 1 条、**该收尾行出现 0 次**（`~/m15-admission-mutation.log`），证明失败路径
  不会打印假汇总；变异后脚本已还原。

**补丁后未重跑完整 `all`**（一轮 19m24s），所以「16 个相位逐个收尾」要留到下一次全量
回归确认。本轮结论按原始日志记为「exit 0 + 0 FAIL + 15/16 相位收尾行」，
不因补丁追认而改写。

> **2026-11-13 晚补记（只加注，不改写本轮历史快照）**：补丁后的完整 `all`
> 已跑两次，16/16 收尾行闭合，退出码 `M15_ALL_RC=0` 已落日志；见 §23.7。

**与第五遍真机（§22）的两处覆盖差异，均为环境能力差异而非结论回退**：

- kind 侧 `verify-device-hotplug` 用 `scsi_debug` 注入，8 条断言全 PASS；真机因未提供
  `M15_DISK_ATTACH_CMD` 仍为 SKIP。
- kind 侧 `verify-kubelet-restart` 的 checkpoint 恢复纳入 PASS；真机 kubelet v1.36.6 不落盘
  `podDeviceEntries`，对应两条断言 SKIP（§8.5 已知缺口）。

**诚实边界**：kind 无 TopoLVM CSI / lvm / udev / `dm_thin_pool`，PVC 不绑定、无
`snapshot.storage.k8s.io` CRD ⇒ §23.5 的阶段 0 能力矩阵不变，功能、性能、thin、故障演练
仍整体不可验；`verify-velero` 的 SKIP 不计 PASS。本结果只闭合「§A 自动化回归在隔离环境
可复现」，**不替代真机 `m15 all`、不替代 §B、不改变阶段 0 决策门未过与
「不能视为 production-ready」**（`M14-closure` 风险 #3）。

---

### 23.7 补丁后完整回归与 16/16 收尾行闭合（2026-11-13 晚）

§23.6 记录的「补丁后未重跑完整 `all`」已闭合。按用户要求后台再跑完整 `all`：
第一次（`-4.log`）本地 SSH 会话中断只断开客户端，WSL 侧进程仍自然跑完，
但**该次退出码不可得**；因此又重跑一次并把 `M15_ALL_RC` 直接写入日志（`-5.log`），
以「退出码 + 全日志无 `FAIL:`/`[error]` + 逐相位收尾行」三件套作为权威结论。

| 项 | 第四次 `-4.log`（会话中断） | 第五次 `-5.log`（权威） |
|---|---|---|
| 起始 / 行数 | 17:39:13 / 1777 行 | 17:58:27 / **1776 行，18m23s** |
| 退出码 | 不可得（rc 输出随会话丢失） | **`M15_ALL_RC=0`（已落日志）** |
| `FAIL:` / `[error]` | 0 条 | **0 条** |
| 相位数 / 有收尾行的相位数 | 16 / **16** | 16 / **16** |
| preflight | `PASS=6 WARN=12 FAIL=0` | `PASS=6 WARN=12 FAIL=0` |
| `verify-velero` | SKIP（minio 镜像不可达） | SKIP（同左，**不计 PASS**） |

**严格核验方法**（不是只数总行数是 16 就下结论）：按 `==> 验证` 行把日志切成 16 段，
每段独立查找收尾句（`验证全部 PASS` / `验证通过（` / `验证 SKIP`），并排除
`PASS:` 开头的断言行；两次日志均为 `PHASE_COUNT=16 PHASES_WITH_TAIL=16`，
每段恰好 1 条。第 2 段即 §23.6 新补的
`admission 4.3 可自动化部分验证全部 PASS`，证明补丁在完整 `all` 路径上生效，
而不只是单相位重跑时有效。

**纪律说明**：`-4.log` 的 16/16 只作观察证据，因缺退出码**不作为最终判据**；
`-5.log` 才满足三件套。两次回归没有并发：发起前显式检查残留 PID 并确认上一个
`all` 自然结束，日志无重复相位头、单调推进；收尾后无残留 `m15-integration.sh all`
进程。本节只追加补记，**不改写 §23.6 的「15/16、留待下轮确认」历史快照**。

**边界不变**：结果仍只属 §A 自动化覆盖；真机 `m15 all`、§B 19 项、阶段 0 决策门
仍未过，`M14-closure` 风险 #3「不能视为 production-ready」有效。

---

### 23.8 D3 脚本判据化与本轮新发现的准入契约偏差（2026-11-13 晚）

§23.5 的 D3 是**脚本层**依赖，不占真机窗口，本轮闭合。两个 POC 脚本从「框架 / 占位符」
改为可执行判据，共同纪律：能力前提不成立 → SKIP 并写明未覆盖（绝不计 PASS）；每条断言
显式 `PASS` / `FAIL` / `SKIP` 计数；末尾必打 `SUMMARY: PASS=n FAIL=n SKIP=n` 与 `RESULT:`；
rc `0` = 有 PASS 且无 FAIL、`1` = 存在 FAIL、`3` = 全部 SKIP（未覆盖，不算通过）；
清单 apply 全部 `|| { fail ...; summary; }` 兜底，避免 `set -euo pipefail` 下静默退出
且零日志；测试 namespace 带 PID 后缀、EXIT trap 清理（实测 Terminating 异步消失，
无残留 PVC / Pod）。

**`functional-test.sh`**（原写死 `topolvm-thin/-thick`，真机唯一 SC 是 `hlvm-b`）：

- 默认 SC 改 `hlvm-b`，可 `STORAGE_CLASS` 覆盖；`WaitForFirstConsumer` 必须由 consumer Pod
  触发绑定，原脚本直接 `wait --for=bound` 是假判据（无 Pod 时必然超时）；
- 在线扩容先查 `allowVolumeExpansion`，快照 / 克隆先查 snapshot CRD 与
  `VolumeSnapshotClass`，缺失即 SKIP 并标注 D2；节点重启恢复需物理/虚拟化重启，
  显式 SKIP 并标注 D1（原 `[PASS] 2.2 重启恢复脚本就绪` 属假绿）。

**`webhook-availability.sh`**（原含 `<非 hlvm 的 StorageClass>` 占位符、无断言）：

- 自动发现非平台 SC（可 `NONPLATFORM_SC` 指定），没有则退化为 `storageClassName: ""`
  的静态 PVC；
- 判据从 `wait --for=bound`（验的是 provisioner 能否供给，与 webhook FailurePolicy 无关，
  且在 `WaitForFirstConsumer` 下必然假红）改为「`apply` 成功 + 对象存在」，即 API 准入
  链路是否阻塞；
- 补静态断言 `validate-pvc` / `mutate-pod` 的 `failurePolicy=Ignore`、硬断言「endpoints
  清空 + `readyReplicas=0`」确已全宕机、EXIT trap 兜底恢复原副本数（失败路径也不留 0 副本）；
- 静态断言是必要补充：非平台 PVC 本就不匹配 `matchConditions`，只靠动态判据发现不了
  策略被改成 Fail（反例 3 实证）。

**隔离 kind 实测**（集群 `hlvm-m15-20261113`；WSL 证据 `~/poc-webhook-pos.log`、
`~/poc-func-missingsc.log`、`~/poc-func-standard.log`、`~/poc-mut/*.log`）：

| 用例 | 结果 |
|---|---|
| 正例 A：`webhook-availability.sh` | rc=0，`PASS=6 FAIL=0 SKIP=0`，含「全宕机不阻塞」与恢复 3/3 Available |
| 正例 B：`functional-test.sh` 默认 `hlvm-b`（kind 无此 SC） | rc=3，`PASS=0 SKIP=1`，**能力缺失不计 PASS** |
| 正例 C：`STORAGE_CLASS=standard DATA_CHECK=0` | rc=0，`PASS=1 SKIP=5`（PVC 供给绑定 PASS；扩容 / 快照 / 克隆 / 数据 / 重启恢复 SKIP） |
| 反例 1：把 `Bound` 期望改成不可能匹配（`PVC_TIMEOUT=5s`） | rc=1，`FAIL=1`，`RESULT: FAIL` |
| 反例 2：把 `scale --replicas=0` 改成 `=3`（不真的停 webhook） | rc=1，`PASS=4 FAIL=1 SKIP=1`，「未在 60s 内全部宕机」转红 |
| 反例 3：集群侧把 `validate-pvc.failurePolicy` patch 成 `Fail` | rc=1，`PASS=5 FAIL=1`，静态断言转红而动态判据仍 PASS ⇒ 印证静态断言必要性；patch 已还原 `Ignore`、webhook 3/3 |

**本轮新发现的准入契约偏差（登记，未修）**：`control-plane/internal/webhook/admission_logic.go`
的 `IsPlatformStorageClass` 按 `provisioner == topolvm.io` 判定平台 SC，而
`control-plane/config/webhook/manifests.yaml` 中 `validate-pvc` 的 CEL `matchConditions`
只认 `object.spec.storageClassName.startsWith('topolvm-')`。两处口径不一致：真机唯一 SC
`hlvm-b` 的 provisioner 是 `topolvm.io`（代码会认），但 API server 侧的 CEL 过滤先把它挡掉
⇒ **容量类 PVC 准入在真机空转**。`scripts/m15-integration.sh` 的 `verify-admission` 用的假 SC
恰好叫 `topolvm-${LOCK_TIER}`，匹配前缀，因此 §A 回归全绿也发现不了 —— 属「判据成功，
但前提在真机不成立」的反向案例。修法需统一口径（改 CEL 表达式或 SC 命名）并补真机前提
校验；改 SC 名会牵动 11 个业务 PVC，等 D1 窗口单独立项，**本轮不改实现、不计 PASS**。

**对 §23.5 的加注更正（不改写早间快照）**：能力矩阵末行「判据未达可执行级」与外部依赖
D3 行，自本节起视为**脚本层已闭合**；其「实测仍待 D1/D2」部分不变。

**边界**：D3 只闭合「脚本可执行且判据有鉴别力」。`poc-report.md` 字段仍全为 `___`，
`docs/poc/README.md` §10 十项仍 `☐ 移交集成`，runbook §4 的 §B 17 行结论不变；
真机侧功能 / 性能 / 故障 / 快照实测仍等 D1（维护窗口 + hnb 错峰）与 D2（snapshot 栈）。
阶段 0 决策门与「不能视为 production-ready」（`M14-closure` 风险 #3）结论不动。

### 23.9 D2 隔离环境快照栈落地与快照/克隆实测（2026-11-13 夜）

§23.5 的 D2 有两个层次，本轮都做，但**只落在隔离环境**：

1. **字面动作**：装 `snapshot.storage.k8s.io` CRD + snapshot-controller + VolumeSnapshotClass，
   并把 TopoLVM CSI 控制器按 `snapshot.enabled=true` 重渲染（带 `csi-snapshotter` sidecar）；
2. **判据层**：让 `functional-test.sh` 的快照 / 克隆从「能力缺失 SKIP」变成真正执行并通过，
   并用变异反例证明判据有鉴别力。

**为什么必须连 B 链路一起建**：隔离 kind `hlvm-m15-20261113` 起初**没有 TopoLVM CSI**
（`CSIDriver` 为空，`StorageClass` 只有 local-path 的 `standard`，`m15` 里的
`topolvm-${LOCK_TIER}` 只是准入相位的假 SC）。TopoLVM 的 `CreateSnapshot` 依赖 lvmd 对
thin-pool 的操作，上游 `docs/snapshot-and-restore.md` 明确 **仅支持 thin-pool 卷**。
所以「装完 CRD 就算 D2 完成」是假的：没有 thin-pool 卷，快照永远 `readyToUse=false`。

**对 §23.5 能力矩阵的两处实测更正（加注，不改写早间快照）**：

| §23.5 原记录 | 实测更正 |
|---|---|
| kind「无真实块设备、无 lvm、`dm_thin_pool` 未加载」 | **不成立**。`dm_thin_pool` 可 `modprobe`；lvm2 2.03.31 可从 `mirrors.nju.edu.cn`（Debian trixie）安装；loop 设备 + 稀疏文件即可造真 thin pool（`twi-a-t---`）。但 kind `/dev` 是 tmpfs 且无 udev，必须 `udev_sync=0` / `udev_rules=0` / `filter` 精确到本节点 loop / `lvcreate --zero n`，否则 LVM wipe 找不到 dm 节点而卡死 |
| kind「无 TopoLVM CSI，PVC 不绑定；快照/克隆能力缺失」 | 部署 B 链路（`00-crd-logicalvolume` / RBAC / CSIDriver / `hlvm-b` SC / lvmd DS / topolvm-node DS / 开快照的 controller）后**可绑定、可扩容、可快照、可克隆**，逐项 PASS |

**一个必须写清的 kind 约束**：三个 kind 节点是同一内核上的容器，`losetup` 绑定与
device-mapper 映射是**内核全局**的，各节点 `/dev/loop*` 又都预置存在。多节点各建一份同名 VG
会互相扫到 PV：本轮实测出现「4 个 loop 绑定 / 3 个 PV UUID / `vgs` 读空」，此前的
`THIN_POOL_OK` 属**共享设备下的假绿**。因此 VG 只在 **`hlvm-m15-20261113-worker` 单节点**建，
`lvm.conf` 的 `filter` 只认该 loop；lvmd 用 `nodeSelector: hlvm.io/lvmd=true` 钉在同一节点。
这也意味着隔离环境 B 链路的**有效域 D=1**（不是 3），与真机 D=3 不可混谈。

**新增/固化的清单与脚本（均在仓库内，不依赖临时下载）**：

| 文件 | 内容 |
|---|---|
| `docs/poc/snapshot/00-crd-*.yaml` | external-snapshotter **v8.2.0** 的 3 个 CRD（VolumeSnapshotClass / Content / Snapshot） |
| `docs/poc/snapshot/10-snapshot-controller-rbac.yaml`、`20-snapshot-controller.yaml` | 上游 RBAC（5 对象）+ Deployment；镜像 `registry.k8s.io/sig-storage/snapshot-controller:v8.2.0`（上游清单 tag 滞后写 `v8.0.1`，已对齐到实际缓存版本） |
| `docs/poc/snapshot/30-volumesnapshotclass.yaml` | `hlvm-b-snap`，`driver: topolvm.io`，`deletionPolicy: Delete` |
| `docs/poc/snapshot/40-csi-controller-snapshot-enabled.yaml` | `helm template --set snapshot.enabled=true` 重渲染的 topolvm-controller（Deployment + Service） |
| `docs/poc/scripts/setup-snapshot-kind.sh` | 装栈 + 逐项判据；无 `KUBECTL_CONTEXT` 直接 FAIL（防误连真机）；`PASS/FAIL/SKIP` + `SUMMARY` + rc `0|1|3` |
| `docs/poc/scripts/setup-kind-thinpool.sh` | kind 节点装 lvm2 + loop + VG + thin pool；`IMG_SIZE`/`POOL_SIZE` 可调；**只在显式 `KIND_NODE` 上建**，幂等 |

**重渲染的差异只有一处**：`snapshot.enabled=false → true` 的 controller 清单，归一化
（去 CRLF / 空行）后与 `control-plane/config/csi/30-controller.yaml` **逐行对比 164 行完全相同**，
唯一新增是 `csi-snapshotter` sidecar（约 20 行）。RBAC 清单对象**逐个一致** —— 上游
TopoLVM 的 controller RBAC 本就无条件包含 snapshot 权限，所以开开关不需要额外 RBAC。
产物放在 `docs/poc/snapshot/` 而**不覆盖真机主清单**：真机集群没有 snapshot CRD，直接开
`snapshot.enabled` 会让 `csi-snapshotter` CrashLoop 并连带影响 11 个业务 PVC。

**实测结果（隔离 kind，WSL 证据 `~/poc-d2-pos2.log`、`~/poc-d2-ev.log`）**：

| 用例 | 结果 |
|---|---|
| `setup-snapshot-kind.sh`（B 链路未部署时首轮） | rc=0，`PASS=8 SKIP=1`（`topolvm-controller` 因 B 链路缺失显式 SKIP，符合纪律） |
| `functional-test.sh`（`hlvm-b` + `hlvm-b-snap` + `DATA_CHECK=1`） | **rc=0，`PASS=5 FAIL=0 SKIP=1`**：PVC 供给绑定、在线扩容 1Gi→2Gi、**快照 `readyToUse=true`（`restoreSize=2Gi`）**、**克隆 PVC `Bound`**、数据落盘可读 `/mnt/f=hello-poc`；节点重启恢复如实 SKIP |
| 反例 1：`VolumeSnapshotClass.driver` 改为 `mutation.invalid.csi.io` | **rc=1**，`PASS=2 FAIL=1`，`[FAIL] 2.1 快照未在 90s 内 readyToUse=true`，`RESULT: FAIL`；driver 已还原 `topolvm.io` |
| 反例 2：克隆 `dataSource.name` 指向不存在的快照 | **rc=1**，`PASS=3 FAIL=1`，`[FAIL] 2.1 克隆 PVC 未在 90s 内绑定`，`RESULT: FAIL` |

**LV 级证据（不是「PVC Bound 就算过」）**：thin pool 内同时存在三层真实对象 ——
`twi-aot---`（thinpool 32G）、`Vri-a-t---`（只读快照卷，`origin` 指向源 LV）、
`Vwi-aot---`（克隆卷，`origin` 指向快照 LV）；`LogicalVolume` CR 中 `snapshot-<uuid>` 与
`pvc-<uuid>` 成对出现；`VolumeSnapshot` 的 `restoreSize=2Gi` 与源 PVC 容量一致。

**过程中踩到并已修正的坑**：

- **容量是判据前提**：pool 4G 时装 2Gi PVC + 2Gi 快照后 `VFree=0`（`overprovision-ratio: 1.00`），
  克隆被拒，csi-provisioner 报 `no enough space left on VG: free=0`。这不是产品缺陷，
  是 POC 环境容量配置；`setup-kind-thinpool.sh` 已把 `POOL_SIZE` 参数化（默认 16G，
  本轮用 32G / 40G 稀疏镜像），重跑即全绿。
- **无效驱动的 VSC 会卡 finalizer**：反例 1 留下的 `VolumeSnapshotContent` 因
  `deletionPolicy: Delete` 但 driver 不存在而删不掉，必须手动去 finalizer 才能清理；
  清理后终态为「0 poc namespace / 0 PV / 0 VSC / 0 LogicalVolume，仅剩 thinpool」。
- `--zero n` 只对 **thin pool 创建**有意义，thin LV 加它会失败；
- `mount ... | tail` 会把失败吞成成功（曾误报 `MOUNT_OK`），判据必须显式看 `$?`；
- `docker cp` 进 kind 节点 `/tmp` 无效（noexec tmpfs），改用 `docker exec -i ... bash < 脚本`；
- 本地 shell 会吃掉嵌套 heredoc，凡在节点内跑多行脚本一律**先上传文件再 stdin 喂入**。

**边界（不得据此扩大结论）**：

- 验的是**隔离环境**的 CSI 快照链路 + TopoLVM thin-pool 快照，卷后端是 **loop 上的稀疏文件**，
  不代表真机 NVMe/云盘性能，也不代表真实业务数据的快照语义；
- 隔离环境只有 **1 个节点**参与 B 链路（D=1）、无 scheduler extender、无多节点拓扑，
  与真机 D=3 的放置、容量账、`CSIStorageCapacity` 口径不可等同；
- **真机未做任何快照变更**：真机仍无 snapshot CRD / VolumeSnapshotClass，CSI 覆盖值仍是
  `snapshot.enabled=false`；真机启用需 D1 窗口 + 单独变更评审，且必须先装 CRD 再开 sidecar；
- `poc-report.md` 仍为空模板、`docs/poc/README.md` §10 十项仍 `☐ 移交集成`、runbook §4 的
  §B 17 行结论不变；fio 基线、thinpool 打满、dmeventd、坏盘、断电仍未执行 ——
  kind 侧现在具备 thin LV，fio 与打满在原理上可跑，但 loop 后端数据无评审价值，本轮不做；
- 阶段 0 决策门与「不能视为 production-ready」（`M14-closure` 风险 #3）结论不动。

### 23.10 隔离环境 fio 基线与 thinpool 打满 / dmeventd 演练（2026-11-13 深夜）

§23.9 末尾原写「fio 基线、thinpool 打满、dmeventd 仍未执行 —— kind 侧具备 thin LV，
原理上可跑，但 loop 后端数据无评审价值」。本轮把这两件事做了，并把「无评审价值」这个判断
落成**脚本里的硬约束**与**报告口径**，而不是靠口头声明。

**23.10.1 先说清口径（这段是结论的一部分）**

隔离 kind 的 VG / thin pool 建在 **loop + 稀疏文件**上，且三个 kind 节点共享同一宿主内核与磁盘。
因此：

- fio 数字**不是**容量/性能评审依据，**不能**回填 `poc-report.md` §3 的「实测值」，
  也不能用来验收「写放大 ≤10%」「p99 ≤ X ms」这类 SLO；
- 它只能证明三件事：① 采集链路可用（脚本能稳定取到 iops/bw/p99，字段/单位没搞错）；
  ② 判据有鉴别力（注入破坏会转红）；③ 同一后端内的相对关系（如首写 vs 覆盖）可被观测到；
- 打满 / dmeventd 演练同理：**内核行为、恢复顺序、观测手段**是真的；
  「扩容时延 5s」**不是**真机结论（loop 上写入 ~1.2GB/s，真机 NVMe/云盘完全不同）。

反证就在本轮数据里：`thick/64k/qd32` 读到 **4789 MB/s**、`4k/qd32` 读到 **361k IOPS** ——
单块云盘不可能有这种数字，它反映的是宿主页缓存与 loop 链路，而不是盘。

**23.10.2 `fio-baseline.sh` 判据化（顺带修掉一个真 bug）**

原脚本是「跑一遍、写 CSV、人肉看」的框架，且有一个**静默错值**：取数用
`jq '.jobs[0].read.iops // .jobs[0].write.iops'`。jq 的 `//` 只在 `false/null` 时回退，
而写任务的 `.read.iops` 是 **0（真值）**，于是**所有写行都被记成 iops=0** ——
看起来像「写性能为 0」，实际是取值方向错。本轮改为按 rw 方向取值，并把
「被测方向的 iops/bw/p99 必须 > 0」变成判据（读到 0 即 FAIL，不再当噪声）。

其余改动：

| 改动 | 目的 |
|---|---|
| `LAYERS` / `BS_LIST` / `QD_LIST` / `RUNTIME` / `SIZE` / `OUT` / `JSONDIR` 参数化 | 真机跑全矩阵、kind 跑短矩阵，同一份脚本 |
| 层可用性检查：目标不存在/不是挂载点 ⇒ 该层 **SKIP**（带原因），不计 PASS | 「没跑」和「跑过」必须区分 |
| **承载 PV 的设备拒绝裸写**（`pvs` 反查） | 在 PV 上 fio 会覆盖 LVM 元数据、直接毁 VG；本轮 `/dev/loop0` 被据此拒跑 |
| `PREP=1`：按 VG/POOL 建 thick LV / thin LV / 快照 + mkfs + mount，退出清理 | kind 可一键复现；不再依赖人工备盘 |
| 逐 cell 判据 + `SUMMARY PASS/FAIL/SKIP` + rc `0|1` | 与仓库其他脚本同一套判据语义 |
| 首写/覆盖**只记录不门禁** | loop 后端支撑不了「CoW 损耗 ≤10%」的结论，宁可不下结论 |

两个环境细节（写进脚本注释，避免下次再踩）：

- 快照卷激活带 `ACTIVATION_SKIP`（`lvs` attr 末位 `k`），`lvchange -ay` 会被直接跳过并打印
  `ACTIVATION_SKIP flag set ... skipping activation`，必须 `lvchange -ay -K`；
- 快照卷与源卷 XFS **UUID 相同**，挂载必须 `-o nouuid`，否则 `mount` 直接拒绝。

**实测（隔离 kind，`hlvm-m15-20261113-worker`，pool 32G / loop 40G）**：

```
PREP=1 VG=hlvm-poc-vg POOL=thinpool KIND_BACKEND=1 RAW=/dev/loop0 \
BS_LIST="4k 64k 1M" QD_LIST="1 32" RUNTIME=10 SIZE=512M \
M_THICK=/mnt/fio/thick M_THIN=/mnt/fio/thin M_SNAP=/mnt/fio/snap \
OUT=/tmp/fio-results.csv  docker exec -i ... bash -s   # 脚本经 stdin 喂入
```

结果：**`SUMMARY PASS=30 FAIL=0 SKIP=1`**（27 个 cell + 3 个 PREP 通过；SKIP 是 raw 层被 PV 保护拒跑）。

```
layer,bs,qd,mode,rw,iops,bw_mbps,clat_p99_ms
thick,4k,1,fs,randread,21939.61,85.70,0.113
thick,4k,1,fs,randwrite,19171.48,74.89,0.124
thick,4k,32,fs,randread,361355.96,1411.55,0.276
thick,4k,32,fs,randwrite,280297.97,1094.91,0.342
thick,64k,1,fs,randread,17380.66,1086.29,0.146
thick,64k,1,fs,randwrite,13880.21,867.51,0.163
thick,64k,32,fs,randread,76628.94,4789.31,0.864
thick,64k,32,fs,randwrite,52725.25,3295.33,1.237
thick,1M,1,fs,randread,3385.36,3385.36,0.569
thick,1M,1,fs,randwrite,2916.41,2916.41,0.586
thick,1M,32,fs,randread,3994.11,3994.10,12.124
thick,1M,32,fs,randwrite,3671.46,3671.46,15.794
thin-first,4k,1,fs,randwrite,9701.83,37.90,0.220
thin-over,4k,1,fs,randwrite,9643.78,37.67,0.249
thin-over,4k,32,fs,randwrite,174334.47,680.99,0.668
thin-first,64k,1,fs,randwrite,11951.40,746.96,0.208
thin-over,64k,1,fs,randwrite,11436.66,714.79,0.264
thin-over,64k,32,fs,randwrite,48508.05,3031.75,1.384
thin-first,1M,1,fs,randwrite,1885.61,1885.61,1.827
thin-over,1M,1,fs,randwrite,1933.21,1933.21,1.778
thin-over,1M,32,fs,randwrite,3120.28,3120.28,16.712
thin-snap,4k,1,fs,randwrite,10329.37,40.35,0.293
thin-snap,4k,32,fs,randwrite,228822.62,893.84,0.610
thin-snap,64k,1,fs,randwrite,13365.66,835.35,0.187
thin-snap,64k,32,fs,randwrite,44139.69,2758.73,1.499
thin-snap,1M,1,fs,randwrite,2088.19,2088.19,0.782
thin-snap,1M,32,fs,randwrite,2890.43,2890.43,17.695
```

**唯一可说的相对结论**：同 bs/qd 下 `thin-over` 与 `thin-first` 差异在噪声内
（如 4k/qd1：9643 vs 9701 IOPS，−0.6%），**说明不了** thin CoW 无损 —— loop 后端不足以支撑，
真机结论必须重测。

**23.10.3 `thinpool-drill.sh`：把「打满」做成带判据的演练**

`fault-injection.sh` 是命令框架 + 人工观察，不产出判据；本轮把其中**可单节点自动化**的
§4.1（thinpool 打满）独立成脚本，其余（坏盘热拔 4.2、节点断电 4.3）仍留在原脚本。

| 相位 | 内容 | 判据 |
|---|---|---|
| P0 | 池存在、`VG` 上无非演练卷、`A+B` 能覆盖扩容后的池 | 不满足直接 FAIL（防止把别人的 PVC 写死） |
| P1 | 写 `thin_pool_autoextend_threshold/percent`、`lvchange --monitor y`、查 dmeventd 进程 | 配置写入生效；dmeventd 缺失则**后续相位 SKIP** |
| P2–P3 | 建 A（12G，做基线占用）、B（`SIZE_B=auto`⇒2×池容量）、各自 mkfs.xfs + mount | 池占用涨幅 ≥ 85% 的预期 A 容量 |
| P4 | 后台写 B，前台轮询池容量与 data% | 观测到扩容，且每次增量 ≈ +20%（`|INC − k×20| ≤ 3`） |
| P5 | 打满 | `data ≥ 99.5%` + `lv_health_status=out_of_data`（dmesg 作补充证据） |
| P6 | 恢复 | 卸载顺序、释放空间后 `data < 95%`、`xfs_repair`、重挂、复写 64MiB 且大小正确 |
| P7 | 收尾 | 演练卷删除、`data ≤ 5%`、`lvm.conf` 恢复 |

`SIZE_B=auto` 是这轮踩出来的必须项：dmeventd 会**连续扩容多次**（每次 +20%，直到 VG 没空间），
写死 `SIZE_B=30G` 时出现过「连续扩两次后池变 55.3G，而 A+B 只有 52G ⇒ 永远打不满、
判据误报 FAIL」。薄卷是虚拟大小，给 2×池容量既不占空间，又能兜住任意次扩容。

**实测（重建 24G 池 / 40G loop，`SUMMARY PASS=21 FAIL=0 SKIP=1`）**：

| 观察点 | 实测值 |
|---|---|
| 初始池 / VG free | 24.0GiB / 15.95GiB，data 0.00%，meta 10.53% |
| 灌满 A（12G） | 10s（loop 后端），池 data 0.53% → 49.18%，`dd rc=1`（ENOSPC 正常返回） |
| **dmeventd 扩容** | **两次，均 +20.0%**：24.0→28.8GiB（第 5s）、28.8→34.6GiB（第 9s） |
| 打满 | data 峰值 **100.00%**，`lv_health_status=out_of_data`，dm 状态 `queue_if_no_space` |
| 打满时 IO | `dd` **被挂起**（脚本超时终止，rc=124），**没有**返回 EIO |
| 恢复 | 释放 A 后 data 66.03% → 卸 B → `xfs_repair -n` 无报错 → `xfs_repair` rc=0 → 重挂 → 复写 64MiB 成功 |
| 收尾 | data 0.00%，池 34.6GiB，meta 回落 10.32%，`lvm.conf` 已还原 |

**SKIP 的唯一一条**：本轮 dmesg 里没有 `out-of-data-space` 记录。原因是池带
`queue_if_no_space`，内核只把写入排队、**不打**切换消息（首轮尺寸更大时曾出现过
`switching pool to out-of-data-space (error IO) mode`）。所以本轮把打满的**权威判据**
换成 `lv_health_status=out_of_data`，dmesg 降级为补充证据 —— 不拿 SKIP 充 PASS。

**23.10.4 三个必须写进 runbook 的发现**

1. **打满不等于报错，首选行为是「写挂住」**：`queue_if_no_space` 下 `dd` 直接 hang（rc=124），
   业务侧表现为 IO 无响应而非 EIO。因此「监控到 EIO 再处理」的思路不成立，
   必须靠 `data%` / `lv_health_status` 提前处置。
2. **恢复顺序反直觉：先卸载并删除"没坏的那个卷"**。池满时 B 的在途 IO 被排队，
   `umount B` 会失败、`umount -l` 只摘挂载点而 dm 引用计数不归零 ⇒ `xfs_repair` 报
   `Device or resource busy`（上一轮就因此把 rc≠0 误读成「检出损坏」，是**假证据**）。
   正确顺序：`umount A`（A 的 IO 未被挂起）→ `lvremove A` 释放池空间 → 排队 IO 落地 →
   `umount B` 才成功。脚本已按此排序，并在 `xfs_repair` 前检查 `dm open == 0`、
   对 `busy` 单独判 FAIL。
3. **两个假绿来源**：dmesg 保留**历史**消息（上一轮的 `out-of-data-space` 会冒充本轮证据）⇒
   脚本先记基线行号、只看新增行；内核原文是 `out-of-data-space`（连字符），
   旧写法 `grep "out of data space"` 永远不命中。

**23.10.5 告警链：仍然不通，且原因在生产端不在规则端**

演练打满时会真的产出 `data_percent=100`、`out_of_space` 这两个事实，但**告警不会响**，因为：

- `storage_thinpool_data_percent / metadata_percent / out_of_space` 只在
  `control-plane/internal/metrics/metrics.go:291-295` 声明为常量，
  **全仓库没有任何写入点**（`grep` 只剩常量与守卫测试）⇒ 指标根本不存在；
- kind 内也没有 Prometheus / Alertmanager，无法端到端验链路；
- 规则本身没问题：`ThinPoolDataCritical`（`>= 85`，无 `for`）与 `ThinPoolOutOfSpace`（`== 1`）
  已由 `control-plane/config/prometheus/tests/alert-rules_test.yml` 用 76% / 86% / 1 三组
  序列做过求值用例（4m 静默、5m 触发），阈值语义是覆盖到的。

**结论**：本轮拿到的是「事实可观测（lvs/dm 侧）」+「规则可求值（离线）」两段，
**中间缺 producer**。这条登记为容量告警链的未闭环项，不能写成「告警已验证」。

**23.10.6 变异校验（判据必须能转红）**

| 变异 | 结果 |
|---|---|
| fio：把方向选择固定成 `read`（等价旧版 `//` 语义） | **rc=1**，`FAIL: thick-randwrite-bs4k-qd1 取不到 read 的 p99`，`MUTATION_CAUGHT` |
| 演练：把「增量 ≈ k×20%（±3pp）」改成 `DEV <= -50`（永不满足） | **rc=1**，`FAIL: 有 2/2 次扩容增量偏离 +20%`，`MUTATION_CAUGHT` |

（演练脚本的第一版判据是「总容量变化在 +5%~+30%」，被两次连续扩容打成 FAIL；
修正为逐次/合并事件判定后，变异校验仍在有扩容的前提下转红。）

**23.10.7 环境副作用与边界**

- **演练会把池"撑大"且不可逆**：每次 dmeventd 扩容 +20%，删卷只回收 data 不缩池。
  本轮跑完池从 24G 长到 34.6G；期间为做变异校验还长到过 49.4G，
  最后用 `setup-kind-thinpool.sh` + 重启 `lvmd`/`topolvm-node` 重建回 24G/40G。
  **演练脚本不得在共享环境执行**（P0 已用「VG 内是否只有 pool」做门禁）。
- kind 的 pool 重建会换 dm 设备，`lvmd`/`topolvm-node` 必须重启才能重新解析；
  重建后未重跑 D2 的 `functional-test.sh`（快照/克隆证据仍引用 §23.9 那一轮）。
- 真机**未跑** fio（会与 hnb 业务争 IO，且需先隔离窗口）与打满演练（破坏性）；
  真机告警链、`poc-report.md` §3/§4 回填、阶段 0 决策门均未因此推进。
- 本轮新增/改动的脚本：`docs/poc/scripts/fio-baseline.sh`（重写）、
  `docs/poc/scripts/thinpool-drill.sh`（新增）。两者都是 `PASS/FAIL/SKIP` + `SUMMARY` + rc，
  缺能力一律 SKIP、绝不计 PASS。

---

### 23.11 thin-pool 容量指标的 producer：为什么不是 exporter（2026-11-13 深夜）

§23.10 末尾登记「`storage_thinpool_*` 只在 `metrics.go` 声明为常量、全仓无任何写入点 ⇒
指标根本不存在；规则可由 promtool 离线求值，但序列不出现，容量告警链端到端未闭环」。
本节补上 producer，并把「为什么这件事不能按设计交给 exporter」的实测证据写下来——
这条约束会长期有效，不是本轮临时绕过。

**23.11.1 三条硬约束（kind `hlvm-m15-20261113-worker` 实测）**

| 检查 | 结果 |
|---|---|
| 非 root（uid 65532）跑 `lvs` | `data_percent` / `metadata_percent` 全空；`dmsetup status` 直接 `/dev/mapper/control: open failed: Permission denied` |
| **root 但清空 bounding set**（无 CAP_SYS_ADMIN） | `lvs` **退出码 0**，返回 `"data_percent":"","metadata_percent":"","lv_health_status":""`，错误只出现在 `log` 数组里 |
| root + 仅 CAP_SYS_ADMIN | 完整取到 `data_percent=0.00`、`metadata_percent=10.32`、`lv_health_status=""` |

第二行是本节最重要的事实：**权限不足时 `lvs` 不报错、退出 0、百分比为空**。任何
「读不到就当 0」的实现都会让 `storage_thinpool_data_percent >= 85` 永远为假——这比没有
指标更危险，因为看板上显示「池很空」。

部署侧还有两条约束叠加：

- `/run/lvm` 是 `drwx------ root root`，非 root 连目录都进不去；
- 非特权 Pod 受**设备 cgroup** 拦截（agent DS 注释已记录：加 capability 也绕不过，
  `dd if=/dev/loop77` 直接 EPERM），而「用设备插件替代 privileged exporter」是既定决策
  （`disk_collector_test.go` 断言 collector 不得 privileged，每盘一个 Pod 只拿一块盘）。
  thin-pool 不是块设备，collector 的授权范围内没有它。

**结论**：设计 §5.4 写的「`storage_*` 由 storage-exporter 暴露」在 thin-pool 这一类上
当前不可实现。改为 **Agent 采集 → `NodeVG.status.thinPool` → 控制面 reconcile 时暴露**。

这不是新发明：Go 侧 `VGThinPoolStatus` 的六个字段（`currentSizeBytes` / `dataPercent` /
`metadataPercent` / `provisionedBytes` / `outOfSpace` / `state`）与 §5.4 的五个指标
一一对应，本就是按「Agent 写 status、控制面读」设计的，只是此前没有人填。

**23.11.2 三段实现，每段都有失败关闭**

| 段 | 实现 | 失败时 |
|---|---|---|
| 采集（Rust） | `lvm::report_lv_capacity()` 用**独立列集**（不与对账共用：旧 LVM 没有 `lv_health_status` 列，混列会让对账整体退出非零）；`parse_thin_pools` 区分池自身与 thin LV 虚拟容量 | `parse_percent` 对空串返回 `None`，**不是 0** |
| 上报（Rust） | `build_nodevg_thinpool_patch` 写 `status.thinPool`；`state` ∈ {`ok`, `out-of-space`, `unreadable`} | 不可读 ⇒ 数值置 `null`（merge patch 语义 = 删除字段）+ `state=unreadable` |
| 暴露（Go） | `syncThinPoolMetrics` 挂在 VGReconciler；`metrics.SyncThinPool` / `ForgetThinPool` | `state` 为空或 `unreadable` ⇒ `DeleteLabelValues` 删序列，**不写 0** |

三处刻意的选择：

- **`state` 空串按不可读处理**。旧 agent（≤ preview.6）根本不写这个字段，零值 0% 会让
  85% 的 critical 永远不触发——升级过程中这是最容易踩的假绿。
- **不用 exporter 的 `render_metric` 路径**。本轮先写了 `render_thin_pool_series` 与
  `collect_lvm_metrics`，验证权限模型后整段删掉：能力拿不到就不该留一个「看起来能产
  指标」的函数。
- **写回节流用 0.01 个百分点死区**，`state` 变化不受死区限制。注意别拿 `50.01` 当边界
  值测：IEEE754 下 `50.01-50.0 = 0.00999…` < 0.01，会把边界值误判成「无变化」（测试里
  改用 50.02，并把原因写进注释）。

**23.11.3 实测证据（kind，AGP 已停用节点内的手工 agent 进程 + dev 镜像 controller）**

1. **上报**（`kubectl get nodevg hlvm-poc-vg -o jsonpath='{.status.thinPool}'`）：

   ```json
   {"currentSizeBytes":37111201792,"dataPercent":0,"metadataPercent":10.32,
    "outOfSpace":false,"provisionedBytes":0,"state":"ok"}
   ```

   与 `lvs` 实测（34.6GiB 池 / data 0.00% / meta 10.32%）逐项一致。

2. **变异校验**（把 `spec.thinPool.name` 改成不存在的池名，验证「采不到就清空」）：

   ```json
   {"outOfSpace":false,"state":"unreadable"}
   ```

   四个数值字段全部消失（`null` 删除生效），agent 日志同时打出
   `NodeVG thinPool 上报完成 data_percent=None out_of_space=None`。恢复池名后数值回来。

3. **`/metrics`**（leader 副本 `:8080`，port-forward 抓取）：

   ```
   storage_thinpool_data_percent{node="hlvm-m15-20261113-worker",pool="thinpool",vg="hlvm-poc-vg"} 0
   storage_thinpool_metadata_percent{...} 10.32
   storage_thinpool_out_of_space{...} 0
   storage_thinpool_provisioned_bytes{...} 0
   storage_thinpool_overprovision_ratio{...} 0
   ```

   标签 `node` / `vg` / `pool` 齐全，与告警 annotation 引用的 `$labels.node`、`$labels.vg`
   对齐。**非 leader 副本为空**（2 副本只有 leader 跑 reconcile）。

4. **删除清理**：删掉 NodeVG 后 `curl /metrics | grep -c '^storage_thinpool'` = **0**
   （`ForgetThinPool` 生效）。不清理的话，已删除的 VG 会在看板上永久显示「最后已知水位」。

**23.11.4 边界（新增，与 §23.10 不冲突）**

- **标签比设计多一个 `pool`**：设计 §5.4 表里写的是 `storage_thinpool_data_percent{node,vg}`，
  实现用 `{node,vg,pool}`。理由是池名可配置（`spec.thinPool.name`，真机是 `thinpool`，
  但不同环境可能不同），塞进 `vg` 会让「池名」这个事实丢失；且 PromQL 标签匹配是子集语义，
  设计里那些按 `node`/`vg` 写的查询不受影响。**指标名未改**，仍严格取自
  `internal/metrics` 的常量。
- 指标**只在 leader** 副本：抓非 leader 得到空，Prometheus 需抓 leader 或抓两副本后取非空。
  与 `storage_controller_*` 同一约束，不是本轮引入。
- 延迟 = Agent 30s 采样 + status 变更触发 reconcile ⇒ **30–60s**。`ThinPoolDataCritical`
  名义上没有 `for:`，实际等效带 30–60s 延迟；对容量水位可接受，对秒级故障不适用。
- **真机尚未部署本轮二进制**（D1 窗口未到）。真机现役 preview.6 的 agent 不写 `state`，
  控制面因此**不输出序列**——这是刻意的：宁可不报，也不拿 0% 冒充水位。
- `storage_vg_total_bytes` / `storage_vg_free_bytes` 仍无 producer（同属 exporter 口径、
  同样拿不到 dm/VG 数据），本轮未做，登记为后续。**→ 已在 §23.12 补上。**
- 告警链**仍未端到端**：kind 无 Prometheus / Alertmanager，规则求值仍是 promtool 离线；
  本轮打通的是「事实 → 指标序列」这一段，最后一段（Prometheus 抓取 → 规则 → 抑制 →
  通知）等 D5。

---

### 23.12 VG 容量指标的 producer：顺便修好「扩容上限恒等于池自身」（2026-11-13 深夜续）

§23.11.4 末尾登记「`storage_vg_total_bytes` / `storage_vg_free_bytes` 仍无 producer」。
补这两条时发现它不是「指标缺一条」这么轻——`NodeVG.status.totalBytes` 与 `freeBytes`
**从来没有被任何人写过**（全仓只有 Go 类型、控制面读取方与测试 fixture），于是
`capacity-ctrl` 的兜底扩容上限一直是错的。

**23.12.1 缺口先说清楚：谁在等这两个字段**

| 消费方 | 用法 | 恒为 0 时的实际行为 |
|---|---|---|
| `capacity_controller.go` §1.6 | `maxBytes := thinPool.currentSizeBytes + freeBytes` | 上限 == 池当前大小 ⇒ `maxBytes > currentSizeBytes` 恒假 ⇒ **兜底扩容永远不会被规划**（dmeventd 失效时没有第二道防线） |
| `capacity_controller.go` §1.5 | `CheckFreeVGSpace(status.FreeBytes, requireFreeVGSpace)` | 0 < 阈值 ⇒ `FreeVGInsufficient` 恒为 True（若策略配了阈值），或恒为假（未配置） |
| `alert_eval.go` | `VGFreeBytes` 参与「空闲不足且不可扩容」判定 | 同上，未知被当成「耗尽」 |
| `dashboard/server.go` | 看板 VG 卡片显示 `totalBytes` / `freeBytes` | 一直是 0 / 0 |

所以这一轮不只是「给 Prometheus 补两条序列」，而是把一条**控制逻辑的输入**补上。

**23.12.2 为什么 producer 也只能在 Agent**

`vgs` 与 `lvs` 走同一条路：读容量要打开 `/dev/mapper/control` 做 dm ioctl，`/run/lvm`
是 `drwx------ root root`，非特权 Pod 还受设备 cgroup 拦截。§23.11.1 的三条实测
（非 root 无数据 / root 无 CAP_SYS_ADMIN 时 `lvs` 退出 0 但列为空 / 只有 CAP_SYS_ADMIN
才拿到真值）对 `vgs` 同样成立，结论不必重做。因此沿用同一条链：

```
Agent（宿主 vgs） → NodeVG.status.{totalBytes,freeBytes} → 控制面 reconcile 时暴露
```

**23.12.3 三段实现，假绿防线与 §23.11 同构**

1. **读**（`agent/src/lvm/mod.rs`）：`VG_CAPACITY_ARGS` 固定
   `vgs -o vg_name,vg_size,vg_free --units b`。**显式 `-o`** 而非依赖默认列集——`vgs`
   不带 `-o` 时的默认列随 LVM 版本变化，缺一列就会退化成「读到空」。
   `parse_vgs` 改成**单条失败关闭**：`vg_name` 空、`vg_size`/`vg_free` 缺失或不可解析时
   整条丢弃，删掉了原来的 `unwrap_or(0)`。原来那句会把「读不到」记成 0，
   既让 `storage_vg_*` 带着假数字上线，又让 `requireFreeVGSpace` 把未知当耗尽。
2. **写**（`agent/src/reporter/{mod.rs,kube_rw.rs}`）：`build_nodevg_vg_capacity_patch`
   是纯函数——可读时写 `{totalBytes, freeBytes}`，不可读时写**两个 `null`**
   （JSON merge patch 中 null = 删除字段），与 thin-pool 的 `state: unreadable` 手法一致。
   写回节流用**相等比较**而非百分比死区：字节数是离散量，1 字节也是真变化。
   `vgs` 采集失败只清这两个字段，**不牵连**同轮的 thin-pool 与 LV 清单（三条读路径本来就独立）。
3. **暴露**（`control-plane/internal/{metrics,controller}`）：两个 `GaugeVec`（`{node,vg}`）
   + `SyncVGCapacity` / `ForgetVGCapacity`；`vg_controller` 的 `syncVGCapacityMetrics`
   在「NodeName 为空 / totalBytes ≤ 0 / freeBytes < 0」时一律忘却，NodeVG 删除时也忘却。

**23.12.4 关键设计取舍：不加 `state` 字段**

thin-pool 用 `state: ok|out-of-space|unreadable` 表达可读性。VG 容量没有加同类字段，
因为**不需要**，而且加了有代价（要动 v1alpha1/v1beta1 两套类型、双向 conversion、
以及实际集群的 CRD）：

- **`totalBytes > 0` 本身就是「本轮采到了」的判据**：VG 存在则总量恒大于 0，
  不存在 0 字节的 VG。Agent 采不到时把字段置 null 删掉，控制面读到 0 ⇒ 撤销序列。
- **`freeBytes == 0` 不是未知，是「VG 打满」**：必须原样暴露 0。
  这两条一起给出的语义是——序列不在 = 不知道；序列在且为 0 = 真的满了。
  把 0 当未知（或反过来）会直接吃掉容量告警。
- 代价是**无法区分「从未上报」与「本轮读不到」**：两者都表现为「没有序列」。
  对一个「未知就不该有观点」的指标来说这是可接受的等价，写在这里是为了不让人
  以后误以为能靠 `absent()` 分辨两种原因。

**23.12.5 kind 实测（`hlvm-m15-20261113`，worker 上真 VG `hlvm-poc-vg`）**

1. **落真值**：`vgs -o vg_name,vg_size,vg_free --units b --noheadings` =
   `hlvm-poc-vg 42945478656B 5725224960B`；对应
   `status.totalBytes=42945478656`、`status.freeBytes=5725224960`，逐字节一致。
2. **暴露**：leader 副本 `curl :8080/metrics | grep '^storage_vg_'` 得两条：

   ```
   storage_vg_free_bytes{node="hlvm-m15-20261113-worker",vg="hlvm-poc-vg"} 5.72522496e+09
   storage_vg_total_bytes{node="hlvm-m15-20261113-worker",vg="hlvm-poc-vg"} 4.2945478656e+10
   ```

   非 leader 副本为空（与 `storage_thinpool_*` 同一约束）。
3. **变异（fail-closed）**：先 `pkill` agent（避免它下一轮把真值写回来干扰观测），
   再把 status 两字段清空（与 Agent 采集失败时写的 merge patch 产物逐字节相同）⇒
   序列在 **2s 内消失**，持续 10s 无序列。
4. **自愈**：重启 Agent ⇒ 序列在 **5s 内回来**且数值正确（写回节流按 diff 判断，
   字段缺失必然判为变化）。另有一次未停 Agent 的直接变异，序列在 5s 内被 Agent 写回——
   说明「控制面撤销」与「Agent 恢复」互不阻塞。
5. **删除清理**：`kubectl delete nodevg hlvm-poc-vg` 后 `grep -c '^storage_vg_'` 从 2 → **0**，
   `storage_thinpool` 同时归 0。

环境已还原：agent 进程与二进制清除、NodeVG 删除、控制器镜像回滚 `:latest` 且 rollout 成功。

**23.12.6 边界（不粉饰）**

- **`freeBytes` ≠ 可供给 PVC 的容量**。TopoLVM 按 thin-pool 的 36 GiB 供 PVC，
  VG free 只对「池还能扩多少」有意义。看板若拿 `storage_vg_free_bytes` 当「还能建多少卷」
  会算错——这一条在 §23.10 的诚实边界里已有同源记录。
- **没有保活写入**：只在值变化时写。Agent 挂掉后序列会保留最后已知值，
  不会自己老化消失（与 thin-pool 同源；统一靠 D5 常驻可观测栈的 staleness 规则处理，
  本轮不引入第二套新鲜度机制）。判断 agent 是否活着仍看 `storage_agent_heartbeat`。
- **只在 leader**、延迟 30–60s，与 §23.11.4 相同。
- **真机未部署**本轮二进制（D1 窗口未到）。
- **本轮的产出只到「序列存在且可信」为止**。这里要修正本节初稿的一句错话：
  当时写「看板也没用」，实际 `dashboard/server.go` 的 VG 卡片读的是
  `NodeVG.status.{totalBytes,freeBytes}`（不是指标），producer 一补上它自动就对了，
  不需要额外接线。真正没有消费方的是**指标序列**本身，而这符合既定分工：
  `alert-rules.yaml` 的头部注释早已写明「VG free 不足由 capacity-ctrl 发布
  `NodeVG.status` 条件（`CapacityForecast` / `FreeVGInsufficient`，M7b 已落地），
  本文件不重复定义指标」。所以「规则不引用 `storage_vg_*`」是刻意避重，不是漏项；
  两个指标留给看板与临时查询用。**唯一真正未闭环的是「序列消失」这件事**，
  已由 §23.13 的 `storage_thinpool_collect_ok` 那条路补上（thin-pool 侧），
  VG 容量侧的同类哨兵尚未做，登记在这里。
- 顺带修正：§23.11.4 里「`storage_vg_*` 仍无 producer」一句自本节起过期。

---

### 23.13 给 fail-closed 配一条「仪表坏了」的告警：`storage_thinpool_collect_ok`

**23.13.1 问题：fail-closed 的代价是告警静默**

§23.11 把「采不到」设计成删序列而不是写 0，动机是对的（0% 会让 `>= 85` 判成安全）。
但副作用当时没配平：`alert-rules.yaml` 里那五条基于 `storage_thinpool_*` 的告警
（data 75/85、metadata 50/75、out_of_space）全是**阈值比较**，没有序列就是空集，
空集不触发。于是下面两种情形在告警侧完全一样——

- 池 99% 满，agent 采不到 ⇒ 两条 critical 都不响；
- 池很健康，agent 采不到 ⇒ 也不响。

运维看到的只有「很平静」。`AgentHeartbeatLost` 兜不住这一层：它管的是 agent 整个挂了，
而这里 agent 活着、心跳照发、LV 清单照报，坏的只是 `lvs` 这一条读路径
（`/run/lvm` 权限被收、池改名、VG 改名、dmeventd 卡住）。

**23.13.2 为什么不能直接拿 `state: unreadable` 当判据**

最直觉的方案是「看 NodeVG 条件」，但 Prometheus 看不到 CR 对象；退一步用
`absent(storage_thinpool_data_percent{...})` 也不行——Prometheus 不知道某个 VG
**本该**有池。

根因在 Agent 侧的结构：`NodeVG.spec.thinPool` 是**非指针 struct**（`ThinPoolSpec`，
而 `omitempty` 对 struct 无效），所以没配池的 VG 在 `sync_thin_pools` 里也走
`pool = None` 分支，同样被写成 `state: "unreadable"`。kind 实测确认了这一点（23.13.5
第 4 项）：新建一个不带 `spec.thinPool.name` 的 NodeVG，40s 后它的
`status.thinPool.state` 就是 `unreadable`。

即 `unreadable` 同时表示「配了但采不到」和「根本不该采」两种截然相反的事实。
拿它当判据，每个 thick-only VG（A 链路设备直通的 VG）都会常亮告警，把真故障淹掉。
**一个字段承担两种含义，正是「空值语义必须显式」要避免的东西。**

**23.13.3 方案：由唯一同时握着 spec 与 status 的一方产出 0/1**

控制面同时读得到 `spec.thinPool.name`（该不该有池）与 `status.thinPool`（采到没有），
所以由它显式产出：

```
storage_thinpool_collect_ok{node,vg,pool} = 1      采到了
                                             0      配了池但采不到
                                             无序列  该 VG 不涉及 thin-pool
```

三个分支：

| 条件 | 动作 | `/metrics` 上留下什么 |
|---|---|---|
| `spec.thinPool.name == ""` 或 `spec.nodeName == ""` | `ForgetThinPool` | **什么都没有**（不该告警） |
| `state` 不是 `ok`/`out-of-space` | `MarkThinPoolCollectFailed` | 5 条容量序列删除 + `collect_ok=0` |
| `state` 是 `ok`/`out-of-space` | `SyncThinPool` | 6 条齐全，`collect_ok=1` |

关键在第二行「删数据序列」与「留失败信号」**同时发生**：删数据是因为未知不能冒充数值，
留 `collect_ok=0` 是因为「不知道」本身必须可被观测。这两件事不矛盾，缺任何一件都会
退化成一种假绿。

**23.13.4 一个必须一起修掉的回归：池名改名后的孤儿序列**

改造中发现 `MarkThinPoolCollectFailed(node, vg, pool)` 只按**当前** pool 名操作，
而 `NodeVG.spec.thinPool` 是单池：`spec.thinPool.name` 从 `tp-old` 改成 `tp-new` 后，
旧池名的序列再没有任何上报者，会永久留在 `/metrics` 上显示 90%——看板上一个不存在的池
满了，真池可能真的满了却没人看。原实现靠 `ForgetThinPool(vg)` 全清，改造后反而丢了
这层保护。

补 `pruneOtherPools(vg, keep)`：`SyncThinPool` 与 `MarkThinPoolCollectFailed` 都先清掉
该 VG 名下除 keep 以外的全部序列（5 条容量 + `collect_ok`）。依据是一 VG 一池，
任何时刻只该有一组序列。这不是「顺手优化」——不修就是本轮引入的回归。

**23.13.5 kind 实测（`hlvm-m15-20261113`，真池 `thinpool@hlvm-poc-vg`）**

刻意**不停 agent**，因为要验证的正是「agent 活着但采不到」：

| 阶段 | `status.state` | `collect_ok` | `data_percent` 条数 | `storage_thinpool_` 总行数 |
|---|---|---|---|---|
| T0 健康 | `ok` | **1** | 1 | 6 |
| T1 池名改 `nosuchpool` | `unreadable` | **0** | **0** | **1** |
| T2 改回 `thinpool` | `ok` | **1** | 1 | 6 |

T1 那一行就是本节的全部意义：故障态不是「什么都没有」（那会和「这个 VG 不存在」混成
一回事），而是「只剩一条明确说我不知道的序列」。

另两项：

- **无池 VG 不误报**：新建 `hlvm-nopool-vg`（无 `spec.thinPool.name`、同节点），40s 后
  其 `status.thinPool.state=unreadable`，但 `collect_ok` 条数仍为 **1**（只有
  `hlvm-poc-vg` 那条）。这一项同时是 23.13.2 的实证：只看 `unreadable` 必然误报。
- **删除清零**：删掉 `hlvm-poc-vg` 后 `storage_thinpool_` 总行数 = **0**，`collect_ok`
  一起消失。

环境已还原：agent 进程与二进制清除、两个测试 NodeVG 删除、控制器镜像回滚 `:latest`
且 rollout 成功。

**23.13.6 判据侧（promtool 离线求值）**

- 规则 `ThinPoolCollectFailing`：`storage_thinpool_collect_ok == 0`，`for: 5m`，
  severity **warning**。不给 critical 的理由：数据面不受影响（池还在、PVC 还能写），
  失去的只是观测能力；critical 该留给 `out_of_space` 那种真打满。
- 用例四组，刻意覆盖四个语义点：`=0` 的 4m 静默 / 5m 触发（证明 `for` 不是摆设）、
  `=1` 静默且 40% 的 data 不触发阈值告警（证明哨兵不会在健康态常亮）、`0→1` 后撤警
  （证明不是单向门闩）、**无序列不触发**（thick-only VG 不误报）。
- 静态守卫 `TestAlertRulesReferenceKnownMetrics` 要求 `MetricThinPoolCollectOK` 进
  `knownMetricNames`，否则「规则引用未知指标」判红。这是既有联动，不是障碍。
- **变异校验**（一次就绿必须做）：把 `Set(0)` 改成 `Set(1)` ⇒ 3 个 Go 用例转红；
  把规则 `== 0` 改成 `== 1` ⇒ promtool 3 处断言转红（该触发的没触发、该静默的触发了）。
  恢复后 `PASS=35 FAIL=0 SKIP=0`，23 条告警全覆盖。

**23.13.7 边界**

- **只覆盖 thin-pool**。`storage_vg_*` 的同类「序列消失」还没有哨兵（§23.12.6 已登记）。
  后者的判据其实更简单——`storage_controller_lv_report_present == 1 unless on(node,vg)
  storage_vg_total_bytes`（同一节点 LV 清单报上来了，VG 容量却没有 ⇒ `vgs` 这一条读
  路径坏了）——但它属于另一条链，本轮不扩。
- **`collect_ok` 不携带原因**。0 只说明采不到，不区分权限/改名/LVM 卡住，排查靠 agent
  日志与 `lvs` 实测。加 reason 标签会让序列随原因变化而分叉（同一故障换原因即产生新
  序列），得不偿失。
- **`for: 5m` 叠加 30–60s 上报周期** ⇒ 从真故障到告警最长约 6–7min。对「失去观测」这种
  非数据面故障可接受；真打满仍由 `ThinPoolDataCritical`（无 `for`，立即）负责。
- **只在 leader 副本**（与全部 `storage_*` 同源约束）。Prometheus 抓 Service 后端的
  所有副本，会看到 leader 有序列、非 leader 没有——这是「指标只在 leader」那条既有
  边界的又一次体现，不是本轮新问题，但会让人误以为序列在抖动。
- **真机未部署**本轮二进制（D1 窗口未到）。
