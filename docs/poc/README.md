# POC 决策门（add-poc-decision-gate）

> 设计 v1.1 §10 阶段 0 规定：**POC 决策门未达标前，不进入任何自研模块开发**。
> 本 change 在 OpenSpec 顺序中为**收尾项**——结构化交付 POC 脚本框架与决策记录模板；
> 真实集群实测（环境搭建、fio、故障注入、备份演练、灰度）标注「移交集成」，不阻塞本仓库代码收口。
>
> **状态复核（2026-11-13）**：下表 10 项仍全部 `☐ 移交集成`，`poc-report.md` 仍是空模板，
> 四份 ADR 仍为「提议 / 框架」。模块先行是既定事实，但**决策门未过**；CI 全绿、
> 真机 `m15 all` 零 FAIL、已发 `v0.1.0-preview.6` 都**不能**代替本表验收。
> 闭合顺序与对照见 `docs/poc/adr/006-lvmd-deployment.md §23`。
>
> **D3 脚本层补记（2026-11-13 晚）**：`scripts/functional-test.sh` 与
> `scripts/webhook-availability.sh` 已去占位符 / 适配 `hlvm-b`，补能力前提 SKIP、
> `SUMMARY` 汇总行、rc `0|1|3` 语义，并在隔离 kind 跑通 3 组正例 + 3 类变异反例
> （ADR-006 §23.8）。**脚本可执行 ≠ 真机实测**：下表 10 项仍全部 `☐ 移交集成`，
> `poc-report.md` 仍为空模板，实测仍等 D1（维护窗口）与 D2（snapshot 栈）。
>
> **D2 隔离层补记（2026-11-13 夜）**：在隔离 kind 上补齐 external-snapshotter v8.2.0 三 CRD +
> snapshot-controller + `VolumeSnapshotClass hlvm-b-snap`，并用 `snapshot.enabled=true`
> 重渲染 controller（新增 `csi-snapshotter` sidecar，其余 164 行与主清单逐行一致）。
> 由于 TopoLVM 快照**只支持 thin-pool 卷**，同时在单节点造了真 thin pool 并部署 B 链路，
> `functional-test.sh` 得到 **rc=0 / PASS=5 / SKIP=1**：PVC 绑定、在线扩容、快照
> `readyToUse=true`、克隆 PVC `Bound`、数据落盘可读全部实测通过，另用两类变异反例
> 证明判据有鉴别力（ADR-006 §23.9）。**真机零变更**：真机仍无 snapshot CRD、CSI 覆盖值仍
> `snapshot.enabled=false`，下表 10 项状态**不变**，快照能力在真机仍未验证。
>
> **fio / 打满 隔离层补记（2026-11-13 深夜）**：`fio-baseline.sh` 判据化（修掉「写方向永远取到
> 0 IOPS」的取值 bug、加 PV 保护与 `SUMMARY`），隔离 kind 跑 27 个 cell 全 PASS；
> 新增 `thinpool-drill.sh` 把 §4.1 做成带判据的演练：dmeventd 两次各 +20% 自动扩容、
> 池打满到 100% 且 IO **被排队挂起（不是 EIO）**、释放空间后可修复重挂复写
> （`PASS=21 FAIL=0 SKIP=1`，ADR-006 §23.10）。**这些数字不作性能评审依据**——
> 后端是 loop + 稀疏文件；真机 fio 与打满仍未执行，§10 状态不变。
>
> **thin-pool 指标 producer 补记（2026-11-13 深夜）**：`storage_thinpool_*` 此前只在
> `metrics.go` 里声明常量、全仓无写入点，容量告警等于空转。本轮补上生产端：Agent 读宿主
> `lvs` 写 `NodeVG.status.thinPool`，控制面 reconcile 时转成指标。**不走 exporter 是实测
> 结论不是偏好**——非 root 打开 `/dev/mapper/control` 直接 EPERM，root 缺 `CAP_SYS_ADMIN`
> 时 `lvs` 仍退出 0 但百分比全空（假绿陷阱），叠加设备 cgroup 与「collector 不得 privileged」
> 的既定决策（ADR-006 §23.11）。kind 实测：status 值与 `lvs` 逐项一致、变异校验转为
> `state=unreadable` 且数值清空、`/metrics` 出现 5 条序列、删 NodeVG 后序列归零。
> **仍未闭环**：指标只在 leader 副本、延迟 30–60s、真机未部署本轮二进制、
> kind 无 Prometheus/Alertmanager ⇒ 告警链最后一段仍等 D5。
>
> **VG 容量 producer 补记（2026-11-13 深夜续）**：`storage_vg_total_bytes` /
> `storage_vg_free_bytes` 同样只有常量、无写入点，而 `NodeVG.status.{totalBytes,freeBytes}`
> 从来没被任何一方写过 ⇒ `capacity-ctrl` 的兜底扩容上限恒等于 thin-pool 当前大小
> （`maxBytes > currentSizeBytes` 恒假，等于第二道防线从未生效）。本轮用同一条链补上：
> Agent 读宿主 `vgs` 写 status，控制面 reconcile 时暴露（ADR-006 §23.12）。
> 可读性判据取 `totalBytes > 0`——VG 存在则总量恒为正，因此不必新增 `state` 字段、
> 也不必动 CRD；`freeBytes == 0` 是合法的「VG 打满」，必须原样暴露 0。
> kind 实测：status 与 `vgs` 逐字节一致、停 Agent 清空 status 后序列 2s 内消失、
> 重启 Agent 5s 内自愈、删 NodeVG 后序列 2 → 0。
> **仍未闭环**：指标本身没有告警规则引用（按设计，VG 空闲不足走 `capacity-ctrl` 发布的
> `FreeVGInsufficient` 条件，规则文件刻意不重复定义指标；看板 VG 卡片读的是 status 字段
> 而非指标，producer 一补上就已生效）、只在 leader、真机未部署。
>
> **采集失败哨兵补记（2026-11-13 深夜三）**：前面两轮都把「采不到」设计成**删序列**
> （不写 0，正确），但没配平代价——`ThinPoolDataWarning/Critical` 等都是阈值比较，
> 没有序列就是空集，**空集不触发**。于是「池 99% 满但采不到」与「池很健康」在告警侧
> 长得一模一样，运维只看到平静；`AgentHeartbeatLost` 兜不住，因为它管的是 agent 整体挂掉，
> 而这里 agent 活着、只坏了 `lvs` 一条读路径。本轮补 `storage_thinpool_collect_ok{node,vg,pool}`
> 与告警 `ThinPoolCollectFailing`（ADR-006 §23.13）。
> **判据不能取 `state: unreadable`**：`spec.thinPool` 是非指针 struct，没配池的 VG 也会被
> 写成 `unreadable`（kind 实测确认），拿它当判据会让每个 thick-only VG 常亮告警。
> 改由控制面按 `spec.thinPool.name` 判定：无池 ⇒ 无序列（不告警）、有池但采不到 ⇒ `0`
> （告警）、正常 ⇒ `1`。kind 实测：健康 `collect_ok=1` 且 6 条序列；池名改错后
> `collect_ok=0` 且 `storage_thinpool_` 总行数 6 → **1**（只剩这条「我采不到」）；
> 改回后自愈；无池 VG 不产生序列；删 NodeVG 归零。变异校验双向转红。
> **仍未闭环**：`collect_ok` 不带原因标签、只在 leader、真机未部署。
>
> **VG 容量哨兵补记（2026-11-14 凌晨）**：上一条的同一类盲区在 VG 容量上还开着——
> `storage_vg_*` 同样是 fail-closed（读不到就删序列），阈值类规则永远发现不了
> 「序列干脆不存在」。本轮补 `VGCapacityCollectFailing`：判据不是阈值而是**存在性比较**
> ——`storage_controller_lv_report_present{node!=""} == 1 unless on(node,vg) storage_vg_total_bytes`。
> `present=1` 证明 Agent 活着、LV 清单在报，同一 node+vg 的容量序列却 10min 不出现
> ⇒ 只有 `vgs` 这一条读路径坏了（ADR-006 §23.14）。
> **为什么不用 `absent()`**：Prometheus 不知道某个 NodeVG *本该*有容量序列，`present`
> 恰好提供了这个锚点。三个刻意不报的情形：`present=0`（归 drift 组）、`node=""`（脏序列）、
> `freeBytes=0`（真打满，序列在即已覆盖）。kind 实测：健康态两侧序列同标签集并存
> ⇒ 不误报；停 Agent 清空 status 后 `present=1` 而 `storage_vg_total_bytes` 归 **0**
> ⇒ 正是触发条件；重启自愈；删 NodeVG 后两侧一起归零（不会把「对象消失」当故障）。
> promtool `PASS=36 FAIL=0`，24 条告警全覆盖；变异 `unless→and`、去掉 `node!=""` 双向转红。
> **仍未闭环**：规则只覆盖「采到没有」，容量水位告警仍走 `NodeVG.status` 的
> `FreeVGInsufficient` 条件（刻意分工，不是漏项）；只在 leader、10min 延迟、真机未部署。

## 目录

| 文件 | 内容 | 对应任务 |
| --- | --- | --- |
| `env-setup.md` | ≥3 节点集群 + TopoLVM Helm 安装 + 版本/特性核实命令 | §1.1–1.3 |
| `scripts/functional-test.sh` | PVC 创建/扩容/快照/克隆/重启恢复（已判据化；隔离 kind 实测 PASS=5，ADR-006 §23.8 §23.9） | §2.1–2.2 |
| `scripts/setup-snapshot-kind.sh` | 隔离环境装 snapshot CRD/controller/VSC 并逐项判据（ADR-006 §23.9） | §2.1（D2） |
| `scripts/setup-kind-thinpool.sh` | 隔离 kind 单节点造 lvm2 + loop + thin pool，快照链路前提（ADR-006 §23.9） | §2.1（D2） |
| `snapshot/` | external-snapshotter v8.2.0 清单 + `snapshot.enabled=true` 重渲染产物（仅隔离环境用） | §2.1（D2） |
| `scripts/fio-baseline.sh` | 裸盘/thick/thin（首写·覆盖）/快照卷的 fio 矩阵 + p99（已判据化；kind 27 cell 全 PASS，**loop 数据不作评审依据**，ADR-006 §23.10） | §3.1–3.3 |
| `scripts/thinpool-drill.sh` | thinpool 打满 / dmeventd 自动扩容 / out-of-data-space 恢复的**判据化**演练（隔离 kind `PASS=21 FAIL=0 SKIP=1`，ADR-006 §23.10） | §4.1 |
| `scripts/fault-injection.sh` | 坏盘热拔/节点断电/lvextend 核实（§4.1 已由 `thinpool-drill.sh` 判据化） | §4.2–4.4 |
| `scripts/webhook-availability.sh` | 全 webhook 宕机不阻塞非平台 PVC（已判据化 + 正例/反例，ADR-006 §23.8） | §5.4 |
| `adr/001-agent-language.md` | agent 语言决策（Rust vs Go，§5.5） | §5.1 |
| `adr/002-raid-selection.md` | RAID 选型（硬件/mdadm/LVM RAID1） | §5.2 |
| `adr/003-version-matrix.md` | TopoLVM 目标版本矩阵 | spec §3 |
| `adr/004-backup-rto-rpo.md` | 备份演练 RTO/RPO（Velero/Kopia） | §5.3 |
| `poc-report.md` | POC 汇总报告模板（实测填入） | §5.5 |

## §10 阶段 0 通过标准清单

| 项 | 验证内容 | 通过标准 | 状态 |
| --- | --- | --- | --- |
| 基础 | PVC 创建、在线扩容、快照、克隆、重启恢复 | 全通过 | ☐ 移交集成（隔离 kind：前四项实测 PASS、重启恢复 SKIP，§23.9；真机未验） |
| 性能基线 | fio 裸盘/thick/thin（首写/覆盖写/有快照）/XFS，p99 | 输出损耗数据与目标（覆盖写 ≤10% 假设） | ☐ 移交集成（隔离 kind 已跑通判据链路 27 cell，但 loop 后端无评审价值，§23.10；真机未跑） |
| thinpool 打满 | 突发写入打满 pool | 前兆/dmeventd 时延成功率/IO 行为/可恢复 | ☐ 移交集成（隔离 kind 已验 dmeventd 两次 +20%、打满后 IO 排队挂起、释放后可修复复写，§23.10；真机未演） |
| 坏盘 | 热拔 pooled 与 per-disk 各一块 | §9.3 可执行、告警准确 | ☐ 移交集成 |
| 节点宕机 | 强制断电与恢复 | 失联判定/重建/隔离期 | ☐ 移交集成 |
| webhook 可用性 | 全部 webhook 副本宕机 | 不阻塞非本平台 PVC（§4 分级） | ☐ 移交集成 |
| TopoLVM 集成 | lvmd 下发/重载、scheduler/CSIStorageCapacity | 明确上游版本矩阵 | ☐ 移交集成 |
| RAID 选型 | 硬件 RAID/mdadm/LVM RAID1 | 结论写入规范 | ☐ 见 ADR-002 |
| 语言决策 | Rust vs Go 原型 | 决策记录（§5.5） | ☐ 见 ADR-001 |
| 备份 | Velero/Kopia 恢复演练 | 实测 RTO/RPO | ☐ 见 ADR-004 |

## 设计【待核实清单】关闭状态

| # | 待核实项 | POC 关闭方式 | 状态 |
| --- | --- | --- | --- |
| 1 | TopoLVM 目标版本 / device-class 键 / lvmd 热加载 / 调度现状 / thin 快照克隆限制 / RAID 配置 | `env-setup.md` §2–3 + `adr/003` | ☐ 移交集成 |
| 2 | `lvextend` 参数 / `thin_pool_autoextend_*` / out-of-data-space 恢复 | `fault-injection.sh` §4.4 + `poc-report.md` | ☐ 移交集成 |
| 3 | K8s 对 matchConditions / ValidatingAdmissionPolicy / Scheduling Gate 支持 | `env-setup.md` §1.1 | ☐ 移交集成 |
| 4 | Carina 等对比对象当前能力 | 立项时评估，非 POC 阻塞 | ☐ 不需 POC |
| 5 | LUKS 与 TopoLVM 组合 / LVM RAID 对 thin-pool 元数据冗余 | `adr/002` + `luks-evaluation.md`(hardening) | ☐ 见 ADR-002 |

## 执行顺序说明（重要）

本仓库的 OpenSpec 执行顺序中，`add-poc-decision-gate` 排在最后，但设计上它是**第一道门控**。
在用户驱动的"按 change 顺序推进"执行中，自研模块（M0–M12b，控制面/Agent/Webhook/exporter + 备份/硬化）
已先行完成。因此本 change 的产出定位为：
- **结构化交付** POC 脚本与决策记录模板（本次提交）；
- **真实实测** 移交集成环境执行，结果回填 `poc-report.md`；
- POC 实测结论将作为后续**回归基线与版本门控输入**（性能基线、版本矩阵、故障剧本可重复性），而非"是否开发"的门控。
