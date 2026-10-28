# 混沌演练 Runbook（设计 §9 剧本 / 阶段 3 / add-hardening-rollout §1）

> 混沌演练是**上线门禁**：未通过不得放量。本文件给出注入工具、观察指标、数据面独立性验证与 §9 剧本回放脚本。
> 标注「移交集成」的项需测试集群 + 真实节点执行，本仓库仅结构化交付清单与脚本框架。

## 1. 注入工具（§1.1）

| 故障注入 | 工具/命令（测试集群） | 观察指标 |
| --- | --- | --- |
| 随机拔盘 | 物理/虚拟拔盘（测试机）；或 `echo 1 > /sys/block/<dev>/device/delete` | SMART/预检告警、drift、任务失败率、数据面 IO |
| 断网 | `iptables -A OUTPUT -p tcp --dport 6443 -j DROP`（节点隔离）；或 `tc qdisc add dev eth0 root netem loss 100%` | agent 心跳丢失、隔离期流程、已有卷 IO 零影响 |
| kill agent | `kubectl -n hlvm-system delete pod -l app.kubernetes.io/component=storage-agent --field-selector spec.nodeName=<n>` | 该节点写路径不可用、控制面 detect-lost、隔离期 |
| kill controller | `kubectl -n hlvm-system delete pod -l app.kubernetes.io/component=storage-controller` | 已有卷 IO/挂载零影响（§1.2 核心断言） |
| kill webhook | `kubectl -n hlvm-system delete pod -l app.kubernetes.io/component=storage-webhook` | 非本平台 PVC 创建**不阻塞**（§4 分级 FailurePolicy=Ignore） |
| etcd 抖动 | `tc qdisc add dev eth0 root netem delay 200ms 50ms`（etcd 端口） | reconcile 延迟、leader 切换、告警延迟 ≤1min/≤5min（§11） |

## 2. 数据面独立性验证（§1.2，核心门禁）

**断言：控制面 / Agent / Webhook 各自整体宕机，已有卷的 IO 与挂载必须零影响。**

验证步骤（每个组件单独执行）：
1. 提前在目标节点创建业务 PVC 并挂载，运行持续 `fio` 直写该卷（`--runtime=600`）。
2. 整体 kill 该组件所有副本（见上表）。
3. 观察 `fio` 的 IOPS/延迟曲线：无断崖、无 EIO、挂载点不失效。
4. 组件恢复后，drift/orphan-gc 巡检无异常、无错误回写。

> 关键：本地 PV 的数据面不依赖控制面运行时。若 fio 出现 EIO/挂载失效，即门禁失败，阻断上线。

## 3. 剧本回放（§1.3，对齐 §9.1–9.4）

- **§9.1 ThinPool 打满**：注入突发写入打满 pool → 验证 dmeventd 扩容时延 ≤30s（§11）、`locked` 置位、非 critical 业务不被新增 PVC 挤占、文件系统可恢复。
- **§9.2 节点整机故障**：断电 → 失联判定（30min）→ `StorageNodeOps(isolate)` + 存储故障标签 → 多副本重建工单；旧节点恢复后**不自动删残留 LV**（隔离期 7d）。
- **§9.3 VG 内磁盘损坏**：热拔 pooled 盘 → Critical 告警文案准确 → 经审批 `vgreduce --removemissing`（--force 仅确认后）→ 换盘重新纳管（不复用旧对象）。
- **§9.4 节点退役**：`StorageNodeOps(retire)` 状态机走通（validate→drain→wait-pvc-cleanup→wipe→done）；存在在用 PV 时 webhook 拒绝删除（§4 删除保护）。

上述动作须与 §8 告警矩阵一致（容量/磁盘/结构/组件四类，Critical ≤1min、Warning ≤5min）。

## 4. 演练报告与问题闭环（§1.4）

每次演练产出报告，至少含：注入项、预期、实际、门禁结论（通过/阻断）、遗留问题单。
遗留问题须在下次放量前回归验证关闭。报告归档于发布评审材料（§5.3 / V.1）。
