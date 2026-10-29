# Proposal: add-observability

## Why

设计方案 v1.1 §5.4 定义了平台指标体系，§8 定义了 14 条告警矩阵，§10 阶段 1 第 3/4 项要求 exporter + 告警接入 + 仪表盘 + UI 只读大盘。监控告警是容量治理与故障剧本的"眼睛"：§8 的 Critical 告警延迟目标 ≤1min，且告警口径必须统一到本方案指标（与 TopoLVM `topolvm_*` 并存时避免双口径）。

## What Changes

- exporter：以同一二进制 `--mode=exporter` 运行为独立非特权 DaemonSet（§5.4），采集 §5.4 全部指标（SMART 健康/温度/media_errors/available_spare/percent_used、VG 容量、thinpool data/metadata/provisioned/out_of_space、RAID 降级、agent 心跳与任务失败、drift 计数）。
- 告警矩阵落地（§8 全表）：thinpool data/metadata 阈值、timeToFull 预测、out-of-space/needs_check、SMART failed / critical_warning / available_spare / media_errors 增量、温度寿命、PV missing / RAID degraded、dmesg XFS/IO error、漂移、agent 心跳、webhook/控制面异常——级别与动作对齐 §8。
- 仪表盘：以本方案指标为准的统一大盘（含 thinpool 状态、锁状态、磁盘健康矩阵）。
- UI 只读大盘 + 纳管入口（§10 阶段 1 第 4 项）：展示 Disk/VG/容量状态、预检报告，纳管操作（adopt/confirmSerial）入口。
- 告警接入平台既有告警渠道（webhook/mail/sms，§3.3 alertChannels）。

## 前置核实清单

1. add-node-agent 已交付（exporter 与 agent 同一二进制）。

## Out of Scope

- drift-detector 的检测逻辑（add-lifecycle-ops）；本 change 只暴露 `storage_drift_detected` 指标位。
- 备份相关监控（add-backup-restore）。
- LV 级指标只做 Top-N（避免基数爆炸），完整 LV 明细不在本 change。

## Impact

- **Affected specs**: `observability`（新增）
- **Affected code**: exporter 采集模块（--mode=exporter）、Prometheus 告警规则（`config/prometheus/`）、Grafana 仪表盘、UI 只读大盘与纳管入口。
- **验证回路**：单测（指标口径）+ 告警规则单元验证（promtool）+ 演练触发关键告警（打满/拔盘/心跳丢失）核对延迟（Critical ≤1min）。
