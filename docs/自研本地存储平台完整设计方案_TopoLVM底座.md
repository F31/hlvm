# 自研本地存储平台完整设计方案（TopoLVM 底座 + 自研控制面 + Rust Agent）

> 版本：v1.0 | 2026-10-15
> 目标：基于 TopoLVM 构建轻量、高性能、具备完整磁盘生命周期管理能力的本地存储平台
> 核心决策：**CSI 复用 TopoLVM（跟随上游）｜控制面自研（Go）｜节点 Agent 自研（Rust）**

---

## 1. 设计原则

1. **CSI 不出自研代码**：TopoLVM 的 CSI plugin / lvmd / scheduler extender 三个组件直接使用上游镜像，私有改动最小化，可跟随版本升级。
2. **差异化全部在旁路**：磁盘纳管、SMART、thinpool 保护、生命周期控制器全部以独立组件 + CRD 实现，不改 TopoLVM 核心逻辑。
3. **能上上游就上上游**：确需增强 TopoLVM 的能力，优先提 PR 回社区，避免长期维护私有 patch。
4. **故障剧本化**：节点故障、坏盘、thinpool 打满等场景必须有平台内建的标准操作流程（Runbook），并演练验证。
5. **Rust 用在刀刃上**：常驻节点、资源敏感、系统调用密集的工作用 Rust；CRD reconcile、webhook 等复杂控制逻辑用 Go（controller-runtime 生态最稳）。

## 2. 总体架构

```javascript
                        ┌────────────────────────────────────────────────┐
                        │           自研存储控制面（Go，单 Deployment）     │
                        │  ┌───────────┐ ┌───────────┐ ┌──────────────┐ │
                        │  │ disk-ctrl │ │ vg-ctrl   │ │ capacity-ctrl│ │
                        │  │ (Disk CRD)│ │ (VG CRD)  │ │ (ThinPool)   │ │
                        │  └───────────┘ └───────────┘ └──────────────┘ │
                        │  ┌───────────┐ ┌───────────┐ ┌──────────────┐ │
                        │  │ lifecycle │ │ snapshot  │ │ audit / rbac │ │
                        │  │ -ctrl     │ │ -ctrl     │ │              │ │
                        │  └───────────┘ └───────────┘ └──────────────┘ │
                        │  准入 Webhook（PVC 拦截）｜ 调度标签维护           │
                        └───────┬───────────────────────┬────────────────┘
                                │ Watch / reconcile     │ gRPC / exec
        ┌───────────────────────┼───────────────────────┼────────────────────┐
        │                       │                       │                    │
┌───────▼────────┐    ┌─────────▼─────────┐    ┌────────▼─────────┐   ┌──────▼───────┐
│ TopoLVM（上游） │    │ storage-agent      │    │ storage-exporter │   │ 平台 Web UI   │
│ csi-controller │    │ （Rust，DaemonSet） │    │ （Rust/node）     │   │ VG/磁盘/PVC   │
│ csi-node       │    │  磁盘扫描/SMART/    │    │  指标采集上报     │   │ 大盘/告警/    │
│ lvmd           │    │  nvme-cli/坏盘检测/ │    │  thinpool/vg/PV  │   │ 运维操作台   │
│ scheduler      │    │  RAID 状态/磁盘预检 │    │                  │   │              │
│  -extender     │    │  （危险操作执行器）  │    │                  │   │              │
└───────┬────────┘    └─────────┬─────────┘    └──────────────────┘   └──────────────┘
        │                       │
        │              ┌────────▼────────┐
        │              │  lvm2 / mdadm /  │  ← 所有 LVM 操作最终落地于系统工具
        │              │  smartctl/nvme   │
        │              └────────┬────────┘
        │              ┌────────▼────────┐
        └─────────────►│   节点磁盘/VG    │
                       └─────────────────┘
```

### 组件清单

| 组件 | 语言 | 部署形态 | 职责 | 来源 |
| --- | --- | --- | --- | --- |
| csi-controller / csi-node / lvmd / scheduler-extender | Go | TopoLVM 官方 Helm | CSI 供给、扩容、快照、容量感知调度 | **上游，不自研** |
| storage-control-plane | Go | Deployment（2 副本，leader election） | 所有 CRD 控制器、准入 webhook、审计 | 自研 |
| storage-agent | Rust | DaemonSet（每节点 1 个） | 磁盘扫描、SMART、预检、危险操作执行 | 自研 |
| storage-exporter | Rust | DaemonSet（可与 agent 合并为一个二进制，子命令区分） | Prometheus 指标采集 | 自研 |
| 平台 UI / OpenAPI | 平台既有 | — | 磁盘/VG/容量大盘、运维操作台、审计查询 | 平台侧集成 |

> **建议 agent 与 exporter 合并为同一个 Rust 二进制**（`storage-agent --mode=agent|exporter`），减少镜像和运维对象数量；exporter 模式下只读、不执行任何写操作，天然满足监控组件最小权限原则。

## 3. CRD 设计（控制面的地基）

API Group 建议：`storage.example.io/v1alpha1`（上线时替换为平台域名）。

### 3.1 Disk（磁盘）

代表一块物理盘的生命周期。由 agent 自动发现创建，控制面只读不可手工创建。

```yaml
apiVersion: storage.example.io/v1alpha1
kind: Disk
metadata:
  name: node37-nvme0n1           # {node}-{device} 命名
  labels:
    storage.example.io/node: node37
    storage.example.io/media: nvme      # nvme | ssd | hdd
    storage.example.io/state: healthy   # healthy | warning | critical | failed
spec:
  nodeName: node37
  device: /dev/nvme0n1
  wipePolicy: secure-erase      # none | zero | secure-erase（加入 VG 前擦除）
status:
  capacityBytes: 1920383410176
  model: "Samsung PM9A3"
  serial: "S5YJNX0R123456"
  smart:
    overallStatus: passed        # passed | failed | unknown
    temperatureCelsius: 41
    percentUsed: 12              # NVMe: percentage used
    mediaErrors: 0
    numErrLogEntries: 3
    reallocatedSectorCt: 0       # SATA SSD
    predictiveFailure: false
  fsInfo: { occupiedBy: "none" } # none | filesystem:sdb1 | lvm-pv:vg01 | md:md0 | unknown
  raid:
    memberOf: ""                 # 所属 md 设备
    degraded: false
  conditions: [...]              # 标准 conditions（Ready / Healthy / InVG）
  inVG: vg-nvme-node37           # 空表示未纳管
```

关键设计点：

- **状态机**：`Unmanaged → Candidate → PreChecked → InVG → Draining → Removed`。只有 `PreChecked` 状态的盘允许被 VG 引用。
- **预检结果即准入**：SMART failed / 存在文件系统签名 / 是系统盘 / 已是 PV 的盘，agent 直接打 `state: failed` 或 `fsInfo.occupiedBy != none`，VG 控制器拒绝引用。
- **故障自动标注**：agent 周期性巡检，SMART 越限自动改 `state`，联动告警和（可选）VG 自愈流程。

### 3.2 VG（卷组）

对应一个 LVM VG，是 StorageClass 与物理盘的绑定枢纽。

```yaml
apiVersion: storage.example.io/v1alpha1
kind: VG
metadata:
  name: vg-nvme-node37
  labels:
    storage.example.io/tier: nvme         # 绑定 StorageClass
    storage.example.io/topology: local    # 本地卷组
spec:
  nodeName: node37
  storageClass: topolvm-nvme              # 一对一绑定
  raid:
    type: none                            # none | raid1（LVM RAID）
    minCopies: 1
  thinPool:
    name: tp-nvme-node37
    sizePercent: 90                       # thinpool 占 VG 比例（预留 10% 救急扩容）
    metadataSize: 8Gi
    overprovisionRatio: 3.0               # 超分配上限（平台全局或按 VG 配置）
  disks: [node37-nvme0n1, node37-nvme1n1] # 引用 Disk 名称
  operations:
    removeDisks: []                       # 计划下线磁盘（需 PVC 校验通过才执行）
status:
  vgExists: true
  vgUUID: "..."
  totalBytes: ...
  freeBytes: ...
  thinPool:
    dataPercent: 42.3
    metadataPercent: 8.1
    state: healthy                      # healthy | warning(≥75) | critical(≥85)
    provisionedBytes: ...               # 已分配的 LV 容量合计
  capacityStatus: available             # available | pressure | locked(拒绝新 PVC)
  pendingOps: [...]
```

关键设计点：

- **ReclaimPolicy 与保护锁**：`spec.disks` 中任何一块盘被移除，控制器必须校验该盘上无 LV（`lvs --noheadings`），且若该操作会触发 thinpool 故障（如 RAID1 只剩一份副本），直接拒绝并写 `status.pendingOps` 原因。
- **扩容即声明式**：`spec.disks` 加盘 = 在线扩容 VG（`vgextend`）；thinpool 扩容由 capacity-ctrl 按阈值自动改 `thinPool.sizePercent`。
- **绑定 StorageClass**：一个 VG 只服务一个 SC，一个节点一个 tier 一个 VG，命名规范化 `vg-{tier}-{node}`，方便运维和告警定位。

### 3.3 ThinPoolPolicy（容量策略，集群级单例）

```yaml
apiVersion: storage.example.io/v1alpha1
kind: ThinPoolPolicy
metadata: { name: default }
spec:
  thresholds:
    warningPercent: 75
    criticalPercent: 85
    metadataWarningPercent: 50
  autoExpand:
    enabled: true
    targetPercent: 65            # 扩容后回落目标
    maxSizePercent: 98           # 最多扩到 VG 的 98%
    requireFreeVGSpace: 10Gi     # VG 剩余不足则转人工工单
  newPVCLock:
    enabled: true                # critical 时拦截新 PVC
  alertChannels: [webhook, mail, sms]
```

capacity-ctrl 消费此策略，同时负责计算每个 VG 的 `status.thinPool.state` 与 `capacityStatus`——**准入 webhook 只读 VG 状态，不做实时计算**，保证拦截逻辑简单可靠（秒级延迟可接受）。

### 3.4 （可选）StorageNodeOps —— 节点运维剧本对象

把节点退役、故障隔离等长流程做成 CRD（一个节点一个对象），控制器分阶段推进并在 `status.phase` 中暴露进度，UI 直接展示。这能把"运维文档里的流程"变成"平台内建的状态机"，是本方案相对纯文档方案的重要增量。

```yaml
kind: StorageNodeOps
spec:
  nodeName: node37
  operation: retire               # retire | isolate | recover-disk
  force: false
status:
  phase: draining                 # validate → drain → wait-pvc-cleanup → wipe → done
  blockingPVCs: ["mysql/mysql-data"]   # 阻塞推进的 PVC 列表，推送给业务
```

## 4. Rust Agent 设计（storage-agent）

### 4.1 模块划分

```javascript
src/
  main.rs            # 模式入口：agent / exporter / doctor
  discovery/         # 块设备发现：读 /sys/block、/proc/partitions、lsblk JSON
  smart/             # NVMe（nvme-cli ioctl）与 SATA（libatasmart 或 smartctl）统一抽象
  precheck/          # 预检规则引擎：系统盘识别、签名探测（blkid）、占用检测
  executor/          # 危险操作执行器（唯一写路径）
  reporter/          # 节点心跳、指标上报（prometheus /metrics）
  doctor/            # 一键诊断数据打包
```

### 4.2 关键设计

1. **读写分离**：exporter 模式全部代码只读；所有写操作（wipe、pvcreate、vgextend、盘下线）只存在于 executor，且**只能从 apiserver 的指令队列消费**（watch VG/Disk 的 annotation 或专用任务 CRD），不接受任何外部直接调用。executor 执行前二次校验目标盘状态，执行后回写结果。
2. **操作幂等与回执**：每个任务带 `taskID`，agent 落盘记录执行日志（/var/log/storage-agent/tasks/），崩溃恢复后能对账（任务已下发但未回执 → 重新探测实际状态后补回执或告警）。
3. **SMART 抽象**：统一成 `enum Health { Healthy, Warning, Critical, Failed }`，NVMe 用 `nvme smart-log`（或直接 ioctl），SATA/SAS 用 smartctl 解析。阈值表放在 ConfigMap，agent 热加载。
4. **资源约束**：agent limit 建议 CPU 100m / Memory 128Mi；采集周期默认 60s（NVMe）/ 300s（SATA），SMART 采集本身开销极低，瓶颈在 smartctl fork，可接受。
5. **doctor 子命令**：一键打包 `lvs/vgs/pvs -a -o +devices`、`dmesg` 中 IO error、smartctl 全量输出、agent 日志、topolvm 日志 → tar.gz 供排障。

### 4.3 exporter 指标

```javascript
storage_disk_smart_health{node,device,media}          # 0/1/2/3 状态码
storage_disk_smart_temperature_celsius{node,device}
storage_disk_media_errors_total{node,device}
storage_vg_free_bytes{node,vg}
storage_thinpool_data_percent{node,vg}
storage_thinpool_metadata_percent{node,vg}
storage_thinpool_overprovision_ratio{node,vg}
storage_agent_task_failures_total{node,task_type}
```

> TopoLVM 自身已暴露 `topolvm_thinpool_*` 指标（由 lvmd 上报），若两者并存以本方案指标为准（标签规范统一），避免双口径。

## 5. Go 控制面设计

基于 controller-runtime，单二进制多控制器：

| 控制器 | 监听 | 核心逻辑 |
| --- | --- | --- |
| disk-ctrl | Disk、Node | 节点失联超时可配置时长（默认30min）→ Disk 标 stale，触发节点故障流程（见 §8.2） |
| vg-ctrl | VG、Disk | 声明式 reconcile：`spec.disks` → pvs/vg/thinpool 实际状态；保护锁校验；RAID1 降级检测 |
| capacity-ctrl | VG、ThinPoolPolicy | 阈值评估 → 状态标注 / 自动扩 thinpool / 告警；新 PVC 锁的读写方 |
| lifecycle-ctrl | StorageNodeOps | 节点退役/隔离/盘迁移流程状态机推进 |
| snapshot-ctrl | VolumeSnapshot | 快照创建后导出 S3 的任务编排（解耦：快照由 TopoLVM CSI 完成，导出走独立 Job） |
| audit | 所有写操作 | 审计日志（操作人、对象、前后值、时间、来源 IP），写入平台审计存储 |

**准入 Webhook**（独立于控制器，FailurePolicy=Fail）：

- 拦截 PVC 创建：读取对应 VG 的 `capacityStatus`，为 `locked/pressure` 时拒绝并返回可读原因（"VG vg-nvme-node37 thinpool 使用率 87%，已达平台安全阈值，请联系管理员或稍后重试"）。
- 同时校验 StorageClass 绑定的 VG 存在且 healthy。
- 拦截 VG/Disk 的删除类操作（RBAC + webhook 双保险）。

**调度标签维护**：watch VG 状态，给节点打/摘 `storage.example.io/tier-nvme-ready: "true"` 标签；TopoLVM scheduler-extender 继续按自身容量感知工作，两者互补不冲突。

## 6. StorageClass 与使用规范

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: topolvm-nvme
provisioner: topolvm.cybozu.com
parameters:
  csi.storage.k8s.io/fstype: xfs
  # device-class 对应 lvmd 的 device-class，映射到本节点 NVMe VG
  topolvm.cybozu.io/device-class: nvme
reclaimPolicy: Retain              # 数据库业务默认 Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

平台规范（必须在 UI 与文档体现，源自你原文档的产品侧提示）：

1. 单副本本地卷，磁盘损坏即丢数据——**仅限多副本业务**（MySQL 主从、Redis Cluster、ES、Kafka）。
2. 单实例数据库禁止直接选用本存储（准入 + 选型评审双控）。
3. Thin 模式有超分配风险，平台默认 overprovisionRatio=3.0 且强制告警。
4. 快照≠备份，平台为每个生产 PVC 提供"定期备份到对象存储"的开关（默认开）。
5. 建议业务侧开启数据库一致性备份窗口（平台在备份前提供 pre-hook 钩子提示 flush/锁表）。

## 7. 监控告警矩阵

| 告警 | 级别 | 条件 | 动作 |
| --- | --- | --- | --- |
| ThinPool data ≥75% | Warning | 持续 5min | 通知 |
| ThinPool data ≥85% | Critical | 立即 | 锁 VG + 自动扩容 + 通知 |
| ThinPool metadata ≥50% | Warning | 持续 5min | 通知（metadata 爆掉更致命，阈值更低） |
| VG free < 10Gi 且 autoExpand 失败 | Critical | — | 转人工工单 |
| Disk SMART Failed / media errors>0 | Critical | 立即 | 标记盘、若 InVG 则启动换盘流程（RAID1 场景）/ 告警（无 RAID 场景，明确告知数据风险） |
| Disk state warning（温度/寿命） | Warning | — | 通知 + 巡检建议 |
| PV 离线（pvs 显示 missing） | Critical | 立即 | 节点故障流程 |
| agent 心跳丢失 > 3min | Warning | — | 通知（节点 agent 挂不等于存储挂，分级） |

## 8. 故障标准剧本（Runbook as Code）

### 8.1 ThinPool 打满（最高危）

1. capacity-ctrl 检测越限 → 置 VG `capacityStatus=locked`（webhook 即刻拦截新 PVC）+ 自动 `lvextend --size +X% --pooldata tp`。
2. 若 VG free 不足：告警转人工；预案清单：紧急 `lvreduce` 可回收的临时卷、临时挂新盘 `vgextend` 扩容。
3. 事后分析：该 VG 超配比例审计 + overprovisionRatio 下调建议自动生成。

### 8.2 节点整机故障

1. disk-ctrl 判定失联（默认 30min，可配）→ Node 打 `node.kubernetes.io/storage-unavailable` 污点（NoSchedule），StorageNodeOps(isolate) 自动创建。
2. 多副本业务：UI 展示受影响 PVC 清单，一键生成"重建 PVC 到新节点"工单模板（含业务确认步骤）；旧节点恢复后 agent 自动清理残留 LV（按 PV 名对应）。
3. 盘可迁移场景：提供 `recover-disk` 剧本：新节点插入磁盘 → agent 识别 foreign VG → 人工确认后 `vgimport`，平台校验 LV 与 PV 的对应关系并提示修复（**全程人工确认，不自动迁移数据**）。

### 8.3 VG 内磁盘损坏（无 RAID）

**数据该 VG 全部 LV 损坏，进入恢复流程**：

1. agent 检测到 PV missing → Critical 告警（明确文案：该 VG 上所有数据不可恢复，依赖业务副本）。
2. 业务层重建：按多副本业务从其他节点副本恢复，平台提供"故障 VG 标记 → 业务重建 PVC → 清理坏 VG（vgreduce --removemissing --force）"的引导流程。
3. 若启用了 RAID1：检测降级 → 换盘 → 重建副本（`lvconvert --repair`），过程中持续监控。

### 8.4 节点退役

StorageNodeOps(retire) 状态机：`validate（列出所有 PVC）→ drain（驱逐 Pod，等待业务确认）→ wait-pvc-cleanup（PVC 全部删除/迁移）→ wipe（可选安全擦除）→ done`。任何一步被阻塞在 `status.blockingPVCs` 可见，**存在在用 PV 时禁止删除节点对象**（finalizer 保护）。

## 9. 实施路线图

### 阶段 0：POC 验证（2–3 周，3 节点环境）

| 项 | 验证内容 | 通过标准 |
| --- | --- | --- |
| 基础 | PVC 动态创建、在线扩容、快照 | 全通过 |
| ThinPool 打满 | fio 打满 thinpool 数据区 | 记录 IO hang 前兆特征、告警时延、自动扩容成功率、文件系统是否可救 |
| 坏盘 | 热拔掉 VG 内一块盘 | 验证 §8.3 剧本可执行、告警准确、清理流程可靠 |
| 节点宕机 | 强制断电 | 验证失联判定、污点、PVC 重建流程、恢复后残留清理 |
| RAID 对比 | 硬件 RAID / mdadm / LVM RAID1 写性能实测 | 输出选型结论，写入平台规范 |

### 阶段 1：MVP（磁盘纳管 + 容量管控，约 8–10 周）

1. Disk/VG/ThinPoolPolicy CRD 与控制面骨架（disk-ctrl、vg-ctrl、capacity-ctrl、准入 webhook）
2. storage-agent（discovery + smart + precheck + executor 基础操作：wipe/pvcreate/vgcreate/vgextend）
3. exporter + 告警通道（先接平台已有告警）
4. UI 只读大盘 + VG/磁盘纳管操作入口

### 阶段 2：生命周期与备份（约 8 周）

1. StorageNodeOps 全套状态机 + 节点退役/隔离/盘迁移剧本
2. 快照 + S3 导出备份（snapshot-ctrl + 导出 Job 模板 + 数据库 pre-hook 提示）
3. 审计与 RBAC、诊断工具

### 阶段 3：硬化与上线

1. 混沌演练（随机拔盘、断网、kill agent/controller）
2. 性能基线报告（对比裸盘，证明 CSI 无额外开销）
3. 灰度上线：先内部中间件 → 开放给业务多副本场景

## 10. 风险登记与规避

| 风险 | 等级 | 规避措施 |
| --- | --- | --- |
| ThinPool 数据区打满导致文件系统损坏 | 高 | 阈值+锁+自动扩容三重防线；POC 实测扩容时延；关键业务强制 overprovisionRatio≤2 |
| ThinPool metadata 打满 | 高 | 独立阈值（50% 告警），metadata 默认预分配 8Gi，扩容预案入 runbook |
| agent 误执行危险操作 | 高 | 写路径唯一（executor）、二次校验、任务幂等对账、审计全留痕 |
| 多副本业务其实只有单副本 | 中 | 平台准入做"副本数提示"，选型评审留痕，不做强制拦截（避免误杀 StatefulSet） |
| TopoLVM 上游 API 变更 | 低 | 组件边界隔离，升级在 POC 环境回归后再灰度 |
| LVM RAID 工具链粗糙 | 中 | 阶段 0 实测；若 LVM RAID 不达标，平台规范改为硬件 RAID 或 mdadm 前置 |
| 社区 PR 不被接受 | 低 | 备选：fork 内部维护 + 定期 rebase（控制 patch 面） |

## 11. 与你原文档的对照

| 原文档模块 | 本方案落点 |
| --- | --- |
| 模块1 磁盘纳管/VG 管理 | Disk/VG CRD + vg-ctrl + Rust agent discovery/precheck/executor（最大工作量，与预估一致） |
| 模块2 容量管控/thinpool 保护 | ThinPoolPolicy + capacity-ctrl + 准入 webhook |
| 模块3 监控告警 | storage-exporter + 指标矩阵（§7） |
| 模块4 节点故障/PV 生命周期 | StorageNodeOps + lifecycle-ctrl + 剧本 §8 |
| 模块5 快照+备份 | snapshot-ctrl（CSI 快照复用 TopoLVM，S3 导出自研） |
| 模块6 调度/多租户 | 准入 webhook + 命名空间 ResourceQuota + 拓扑标签维护 |
| 模块7 审计/诊断/RBAC | audit 控制器 + doctor 子命令 + webhook/RBAC 双控 |

## 12. 关键决策建议汇总

1. **Go + Rust 混合**：CSI 用上游 TopoLVM；控制面 Go（controller-runtime）；节点 agent/exporter 合并为一个 Rust 二进制。
2. **CRD 声明式**：Disk/VG/ThinPoolPolicy/StorageNodeOps 四类 CRD 是全部自研能力的载体，UI、agent、控制器都围绕 CRD 交互。
3. **POC 先行**：thinpool 打满、坏盘、宕机三个剧本未实测前，不进入模块开发。
4. **"少改 TopoLVM"是铁律**：私有 patch 控制在 0–2 处，否则升级红利归零。

---

# 附录：hlvm 与业界同类方案对比（基于 Carina 官方对比框架扩展）

## A.1 能力对比矩阵

| 维度 | NFS/NAS | SAN | Ceph | Carina | **hlvm（本方案）** |
| --- | --- | --- | --- | --- | --- |
| typical usage | general storage | high performance block device | extremely scalability | high performance block device for cloudnative apps | high performance local block storage for cloudnative stateful apps, with platform-managed disk lifecycle |
| filesystem | yes | yes | yes | yes | yes |
| filesystem type | NFS | driver specific | ext4/xfs | ext4/xfs | ext4/xfs |
| block | no | yes | yes | yes | yes |
| bandwidth | standard | standard | high | high | **high（接近裸盘，thin LVM 无复制开销）** |
| IOPS | standard | high | standard | high | **high（本地单副本，IO 路径无网络跳转）** |
| latency | standard | low | standard | low | **low（本地盘最短路径，无副本同步延迟）** |
| CSI support | yes | yes | yes | yes | **yes（TopoLVM 上游标准 CSI，持续跟进规范）** |
| snapshot | no | driver specific | yes | no | **yes（标准 CSI 快照 + 快照导出 S3 备份闭环）** |
| clone | no | driver specific | yes | not yet | **yes（基于快照/PVC 克隆）** |
| quota | no | yes | yes | yes | **yes（命名空间配额 + thinpool 超分配比例双重限额）** |
| resizing | yes | driver specific | yes | yes | **yes（在线扩容）** |
| data HA | RAID or NAS appliance | yes | yes | RAID | **RAID（平台规范：硬件 RAID / mdadm / LVM RAID 三选一实测定标）+ 强制业务多副本** |
| ease of maintenance | driver specific | multiple drivers | high maintenance effort | ops-free | **medium：控制面自研需平台运维，但磁盘生命周期 / thinpool 保护 / 故障剧本已自动化（runbook-as-code）** |
| budget | high for NAS | high | high | low, reuse extra disks | **low，同 Carina，复用集群闲置盘** |
| others | data migrates with pods | data migrates with pods | data migrates with pods | binpack or spreadout scheduling; data doesn't migrate, inplace rebuild | **容量感知调度（scheduler extender）+ thinpool 压力准入拦截；数据不随 Pod 迁移，故障按剧本重建；磁盘自动发现 + SMART 预检 + 声明式 VG 生命周期；全量审计与 RBAC** |

## A.2 关键能力结论

hlvm 在 Carina 的框架内**补齐了三项硬缺口**，同时保持相同的性能档与成本模型：

1. **快照/克隆**：Carina 快照列为 no，hlvm 直接继承 TopoLVM 的标准 CSI 快照能力，并进一步做 S3 导出，形成"快照 + 跨节点备份"闭环——解决本地卷"快照同盘同 VG、损坏即全丢"的原生缺陷。
2. **quota 的深度**：Carina 的 quota 主要是卷级容量，hlvm 在此之上增加 thinpool 超分配比例（overprovisionRatio）与命名空间租户配额，把"防止平台被写爆"做成一等能力。
3. **可维护性的结构差异**：Carina 的 ops-free 依赖项目自身的组件闭环，社区迭代放缓时能力演进受阻；hlvm 把运维能力收敛到平台自有 CRD 控制面，演进节奏由平台自己掌控。

## A.3 差异化优势（hlvm vs Carina）

| 差异点 | Carina | hlvm |
| --- | --- | --- |
| CSI 演进路径 | 自研 CSI，跟随社区节奏 | 直接跟随 TopoLVM 上游，生态成熟、规范跟进快，无厂商锁定 |
| Thin 治理 | 有 thin 能力，治理靠组件自身 | thinpool 治理为平台一等能力：阈值分级 + 新 PVC 准入拦截 + 自动扩容 + 超分配限额（§A.1 quota 行） |
| 磁盘纳管形态 | node-manager 自动纳管 | 声明式 Disk/VG CRD + 状态机（Candidate→PreChecked→InVG→Draining），预检不通过的盘物理上无法入 VG |
| 故障处理 | inplace rebuild | 故障剧本即代码：节点隔离/退役/盘迁移/坏盘重建均为状态机 + UI 可视化阻塞点 |
| 可观测与审计 | 组件级指标 | 指标 + SMART 健康度 + 操作审计 + RBAC + 一键诊断打包，面向多租户平台交付 |
| 工程效率 | Go 全栈 | 控制面 Go（controller-runtime）+ 节点 Rust agent（常驻 <128Mi，单二进制交付） |

## A.4 诚实的短板（评审时必须承认）

1. **运维责任在平台侧**：Carina 宣称 ops-free，hlvm 的控制面是自研软件，需要平台团队承担维护与升级责任——这是"掌控力"的对价。
2. **无跨节点副本**：与 Carina 相同的单副本路线，数据 HA 依赖 RAID + 业务多副本，平台以准入和选型评审强制约束。
3. **生态背书弱于 TopoLVM 原生**：hlvm 的差异化组件无社区背书，质量依赖自身测试体系（混沌演练为上线门禁）。

## A.5 一句话定位

> **Carina 是"开箱即用的本地 LVM 存储"，hlvm 是"平台原生的磁盘生命周期与容量治理系统，以 TopoLVM 为供给引擎"**——同性能、同成本，多付一份控制面的维护成本，换来快照备份闭环、thinpool 防爆、故障剧本自动化和完全自主的演进节奏。
