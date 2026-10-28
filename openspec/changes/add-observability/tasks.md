# Tasks: add-observability

> 进度说明（M10）：控制面可观测性代码收口并通过单测——`internal/metrics`（控制面+webhook 指标，注册到 controller-runtime metrics.Registry；导出 storage_* 平台指标规范名常量作为单一真相源）+ `internal/alerting`（§8 告警矩阵纯函数评估 + AlertRouter 按 level 路由到 webhook/mail/sms/ticket）。8 个控制器与 3 个 webhook 处理器完成 reconcile 错误数/耗时、准入延迟/拒绝计数埋点。
> 部署与清单（1.1–1.4 exporter DaemonSet/指标采集、2.5 Prometheus 规则 promtool 校验、3.1 Grafana 仪表盘）移交 M10b（YAML/JSON 清单）；UI（3.2/3.3）与告警延迟演练（4.1/4.2）移交集成验证（需测试集群 + agent exporter 运行）。

## 1. exporter

- [ ] 1.1 exporter 模式实现：独立非特权 DaemonSet、独立 SA、只读挂载
- [ ] 1.2 磁盘指标：smart_health(0/1/2/3)、temperature、media_errors_total、available_spare_percent、percent_used{node,device,media}
- [ ] 1.3 容量指标：vg_total/free_bytes、thinpool_data/metadata_percent、provisioned_bytes、overprovision_ratio、out_of_space{node,vg}
- [ ] 1.4 运维指标：raid_degraded、agent_last_scan_timestamp、task_failures_total、drift_detected
- [x] 1.5 与 TopoLVM topolvm_* 指标并存口径确认：仪表盘与告警统一使用本方案指标；LV 级指标 Top-N 限流（M10 在 internal/metrics 导出 storage_* 规范名常量作为单一真相源，告警与仪表盘均引用之；避免双口径）

## 2. 告警矩阵（§8 全表）

- [x] 2.1 容量类：data ≥75%(Warning,5min) / ≥85%(Critical,立即+locked)、timeToFull 24h/4h、metadata 50%/75%、out-of-space 或 needs_check、VG free 不足（M10 EvaluateCapacityAlerts 全表，DataSustained 承接 Prometheus for:5m；VG free 不足转 ticket 渠道）
- [x] 2.2 磁盘类：SMART failed / critical_warning≠0 / available_spare 低于阈值（Critical，区分无 RAID 明确数据风险文案）、media_errors 增量判定、温度/寿命 Warning（M10 EvaluateDiskAlerts + MediaErrorsIncremental）
- [x] 2.3 结构类：PV missing / RAID degraded、dmesg XFS 或 IO error、CR/PV/LV 漂移（Warning）（M10 EvaluateStructuralAlerts）
- [x] 2.4 组件类：agent 心跳丢失 >3min（Warning，与存储不可用分级）、webhook 异常 / 控制面 leader 丢失 >2min（Warning）（M10 EvaluateComponentAlerts，数据面独立原则）
- [ ] 2.5 promtool 校验告警规则；接入平台既有告警渠道（webhook/mail/sms）

## 3. 仪表盘与 UI

- [ ] 3.1 Grafana 仪表盘：thinpool 状态矩阵、锁状态、磁盘健康、任务失败率、drift
- [ ] 3.2 UI 只读大盘：Disk/VG/容量/健康状态、预检报告展示
- [ ] 3.3 UI 纳管入口：adopt 置位与 confirmSerial 双确认交互，破坏性操作仅生成待审批任务

## 4. 验证

- [ ] 4.1 告警延迟演练：触发 thinpool 打满、拔盘、kill agent，核对 Critical ≤1min / Warning ≤5min
- [ ] 4.2 指标口径核对：与 lvs/vgs 实测值对账（口径冲突以实测为准）

## 验证回路

- [ ] V.1 build/vet/test + promtool 全绿；告警延迟演练达标
- [ ] V.2 commit + push（里程碑闭环）
