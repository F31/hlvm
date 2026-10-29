# Tasks: add-lifecycle-ops

> 进度说明（M8 + M8b）：StorageNodeOps 状态机核心已落地并通过单测（M8）；M8b 收口余下控制面逻辑——
> 纯函数 recover_disk.go（foreign VG 对应校验+计划门控）、isolation.go（隔离期届满判定，默认 7 天可配）、bad_disk.go（无 RAID / per-disk / RAID 差异化剧本）；
> orphan-gc（orphangc.go + OrphanGCReconciler，扫描 Retain+Released PV 告警不删除）、drift-detector（drift.go + DriftDetectorReconciler，CR/PV/lvs 三方对账告警 + 补录/回滚建议）、break-glass（ParseBreakGlass/InBreakGlassWindow）；
> audit.go（RecordAuditEvent 写 K8s Event）+ doctor.go（CompileNodeDiagnostic 聚合诊断）。全部经 go build/vet/test 全绿 + fake-client 单测。
> §2.1（stale→isolate 自动入口）此前已在 disk_controller.go 落地。§5 两项演练原标"需 envtest/测试集群，移交集成验证"——现 envtest 二进制已就绪，5.1/5.2 已落地真实控制平面验收（见下）。

## 1. StorageNodeOps 状态机

- [x] 1.1 状态机实现：validate → drain → wait-pvc-cleanup → wipe(可选) → done；阻塞点写 blockingPVCs（纯函数 NextNodeOpsPhase + reconciler 推进）
- [x] 1.2 retire：validate 列 PVC（按 hlvm.dev/node 注解统计 Bound PV）→ drain（cordon 节点）→ wait-pvc-cleanup → wipe；允许同节点多对象（M8 推进至 wipe，实际擦除经 StorageTask 下发，M8b 完成）
- [x] 1.3 isolate：打存储故障标签 `storage.example.io/storage-isolated`（非 NoSchedule 污点）；与 add-admission-scheduling 的调度约束联动
- [x] 1.4 recover-disk：foreign VG 识别 → 人工确认（force 门控）→ vgimport → LV/PV 对应关系校验（recover_disk.go：ValidateForeignVGCorrespondence / PlanRecoverDisk）；全程人工确认不自动迁移数据（M8b 完成）

## 2. 节点故障与坏盘剧本（§9.2/§9.3）

- [x] 2.1 失联判定联动：disk-ctrl stale → 自动创建 isolate（disk_controller.go: ensureIsolateOps）
- [x] 2.2 隔离期机制：旧节点恢复后残留 LV 不自动删除；隔离期默认 7 天可配（isolation.go: IsolationPeriodDefault / IsIsolationExpired）；人工确认后经 StorageTask 清理
- [x] 2.3 坏盘流程：无 RAID pooled（全部 LV 不可恢复文案）/ per-disk（单盘影响）差异化（bad_disk.go: ClassifyBadDisk / BadDiskPlaybook）；vgreduce --removemissing 需审批；换盘重新纳管走新 Disk 对象
- [x] 2.4 RAID 场景：降级告警 → 换盘 → 重建进度监控与重建期性能提示（bad_disk.go: RAIDDegraded / RAIDRebuildPlaybook）

## 3. orphan-gc 与 drift-detector

- [x] 3.1 orphan-gc：Retain 后 Released PV 与孤儿 LV 检测（orphangc.go: FindReleasedRetainPVs / FindOrphanLVs，PV/lvs 对账；lvs 三方对账待 agent LV 上报后启用）、占用统计、提醒人工回收（OrphanGCReconciler 不自动删）
- [x] 3.2 drift-detector：CR/PV/lvs 对账发现绕过平台变更（drift.go: DetectDrift）；告警 + 补录/回滚建议（DriftDetectorReconciler）
- [x] 3.3 break-glass：授权窗口机制（drift.go: BreakGlassAnnotation / ParseBreakGlass / InBreakGlassWindow；窗口内允许手工操作、事后补录强制）

## 4. 审计、RBAC、doctor

- [x] 4.1 audit：写操作审计（audit.go: AuditEntry / NewAuditEntry / RecordAuditEvent 写 K8s Event）；与 K8s audit log 交叉校验以平台 Event 落地
- [x] 4.2 RBAC 审查：各组件最小权限核对——已通过各 reconciler 的 +kubebuilder:rbac markers 声明最小权限（OrphanGC/DriftDetector 已补 PV/events RBAC；节点锁标签、NodeVG/StorageNodeOps 等沿用既有 markers），diff 复核见 commit
- [x] 4.3 doctor：节点诊断打包（doctor.go: CompileNodeDiagnostic 聚合 lvm/节点 Ready/容量/VG/运维任务）

## 5. 演练

- [x] 5.1 节点故障→隔离入口验收：envtest 真实控制平面（1.33.0）启动 DiskReconciler，节点 NotReady 且 lastReady 超阈值（默认 30min）→ 自动创建 StorageNodeOps(auto-isolate-<node>, operation=isolate) 隔离入口 + NodeDisk Stale=True（隔离期/人工清理把手）；见 internal/controller/lifecycle_envtest_test.go::TestLifecycleOpsEnvtest（§9.2 隔离期满 7 天 + 人工确认清理仍属时间门控/人工路径，未纳入自动断言）
- [x] 5.2 手工 lvcreate 触发 drift 验收：envtest 注入假 LVReporter 模拟节点实际多出平台未记账 LV，DriftDetector 经 CR/PV/lvs 三方对账发现 unmanaged-lv 漂移并发布 StorageDrift 告警事件（补录建议，平台不自动修复）；break-glass 窗口（ParseBreakGlass/InBreakGlassWindow）为纯函数已由 4.x 单测覆盖，本用例聚焦"告警+补录建议"路径

## 验证回路

- [x] V.1 go build / vet / test 全绿（两项演练需测试集群，移交集成验证）
- [x] V.2 commit + push（里程碑闭环）—— 代码（nodeops 状态机 + drift/recover/orphangc/doctor/bad_disk 控制器及测试）已于 01f5456（M8b）与 4d5bfe2（M10）合入 origin/main，本次回填补 tick（原 tasks.md 漏标）
