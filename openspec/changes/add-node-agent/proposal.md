# Proposal: add-node-agent

## Why

设计方案 v1.1 §5：节点 Agent 是磁盘纳管与 PV/VG/thinpool 唯一写路径的执行者（单写者原则，§1.5），承担发现、SMART 采集、预检、StorageTask 执行与上报。没有 Agent，Disk CRD 无数据来源、vg-ctrl 的 StorageTask 无法落地。这是 MVP（§10 阶段 1 第 2 项）的核心交付。

## What Changes

- 单一二进制多模式：`--mode=agent | exporter | doctor`（§5.1）；语言按 POC 决策门结论（ADR）定稿，CRD 契约与指标不受语言影响。
- discovery 模块：`/sys/block`、`lsblk --json`、udev 事件（热插拔即时重扫）+ 周期扫描。
- smart 模块：NVMe（nvme-cli/ioctl）与 SATA/SAS（smartctl --json）统一抽象为 `Health{Healthy,Warning,Critical,Failed}`；阈值表放 ConfigMap 热加载；NVMe 关注 critical_warning / available_spare / percentage_used / media_errors 增量。
- precheck 规则引擎：系统盘（根/boot/swap/kubelet 目录及 holders）、fs/LVM/md 签名、multipath/dm 持有、已是 PV、SMART failed、容量/介质不符 tier——任一命中不进入 PreChecked。
- executor：StorageTask 消费者，唯一 PV/VG/pool 写路径。
- lvm 封装：经 `chroot /host`（或 nsenter）调用宿主机 lvm，共享 `/run/lock/lvm` 锁，`--reportformat json` 统一解析，解析失败视为未知；宿主机 lvm.conf devices 限定扫描纳管盘（§5.3）。
- 操作安全（§5.2）：argv 数组执行禁止 shell 拼接；设备路径只接受 by-id 并格式校验；破坏性动作前二次读取实际状态（serial 匹配、无签名/无持有者、非系统盘）；支持 dryRun；幂等（taskID 去重 + 崩溃恢复补回执不重复执行）。
- reporter：CRD status 低频更新（遵守 etcd 写放大约束）+ 节点级权限隔离（ServiceAccount 只能读写自身节点的 Task/Disk，ValidatingAdmissionPolicy + 节点绑定 token）。
- dmeventd 启用与 `thin_pool_autoextend_*` 配置由 agent 管理并校验。
- 资源 requests/limits 以 POC 实测为准（初始 50m/64Mi ~ 200m/256Mi，非猜测值定稿）。

## 前置核实清单

1. add-poc-decision-gate 的语言 ADR 已定稿。
2. 宿主机 lvm2 版本、dmeventd 行为、`--reportformat json` 可用性（POC §4.4 结论）。

## Out of Scope

- exporter 指标与告警（add-observability，同一二进制但独立 DaemonSet 交付）。
- StorageTask 的生成方（vg-ctrl / lifecycle-ctrl）。
- doctor 诊断打包的 UI 集成。

## Impact

- **Affected specs**: `node-agent`（新增）
- **Affected code**: 节点 agent 代码库（discovery/smart/precheck/executor/lvm/reporter/doctor 模块）、DaemonSet manifests（特权 agent / 独立非特权 exporter 两个 DS，§2 最小权限修正）、节点级 RBAC 与 VAP。
- **验证回路**：单测（预检规则引擎、命令解析、幂等）+ 集成测试（测试节点上 dryRun 全链路）+ go/rust build/vet/test。
