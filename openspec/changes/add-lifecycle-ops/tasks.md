# Tasks: add-lifecycle-ops

> 进度说明（M8）：StorageNodeOps 状态机核心已落地并通过单测——纯函数 NextNodeOpsPhase + NodeOpsReconciler（validate→drain→wait-pvc-cleanup→wipe→done 推进，retire 经 PV 注解阻塞门控与 cordon，isolate 打节点存储故障标签，recover-disk 需 force 门控）。
> 剩余项（1.4 recover-disk 全程人工确认链路、§2 节点故障/坏盘剧本、§3 orphan-gc/drift-detector/break-glass、§4 审计/RBAC/doctor、§5 演练）移交 M8b 或后续 change。

## 1. StorageNodeOps 状态机

- [x] 1.1 状态机实现：validate → drain → wait-pvc-cleanup → wipe(可选) → done；阻塞点写 blockingPVCs（纯函数 NextNodeOpsPhase + reconciler 推进）
- [x] 1.2 retire：validate 列 PVC（按 hlvm.dev/node 注解统计 Bound PV）→ drain（cordon 节点）→ wait-pvc-cleanup → wipe；允许同节点多对象（M8 推进至 wipe，实际擦除经 StorageTask 下发，M8b 完成）
- [x] 1.3 isolate：打存储故障标签 `storage.example.io/storage-isolated`（非 NoSchedule 污点）；与 add-admission-scheduling 的调度约束联动
- [ ] 1.4 recover-disk：foreign VG 识别 → 人工确认 → vgimport → LV/PV 对应关系校验；全程人工确认不自动迁移数据（M8 仅实现 force 门控，完整链路移交 M8b）

## 2. 节点故障与坏盘剧本（§9.2/§9.3）

- [ ] 2.1 失联判定联动：disk-ctrl stale → 自动创建 isolate
- [ ] 2.2 隔离期机制：旧节点恢复后残留 LV 不自动删除；隔离期默认 7 天可配；人工确认后经 StorageTask 清理
- [ ] 2.3 坏盘流程：无 RAID pooled（全部 LV 不可恢复文案）/ per-disk（单盘影响）差异化；vgreduce --removemissing 需审批；换盘重新纳管走新 Disk 对象
- [ ] 2.4 RAID 场景：降级告警 → 换盘 → 重建进度监控与重建期性能提示

## 3. orphan-gc 与 drift-detector

- [ ] 3.1 orphan-gc：Retain 后 Released PV 与孤儿 LV 检测（LogicalVolume CR / PV / lvs 三方对账）、占用统计、提醒人工回收（不自动删）
- [ ] 3.2 drift-detector：CR/PV/lvs 对账发现绕过平台变更；告警 + 补录/回滚建议
- [ ] 3.3 break-glass：授权窗口机制（窗口内允许手工操作、事后补录强制）

## 4. 审计、RBAC、doctor

- [ ] 4.1 audit：所有写操作（操作人/对象/前后值/时间/来源）；与 K8s audit log 交叉校验
- [ ] 4.2 RBAC 审查：各组件最小权限核对
- [ ] 4.3 doctor：节点诊断打包（lvm 状态、agent 日志、任务历史、对账结果）

## 5. 演练

- [ ] 5.1 模拟节点故障与恢复：验证隔离期、人工清理路径
- [ ] 5.2 手工 lvcreate 触发 drift：验证告警、补录建议、break-glass 流程

## 验证回路

- [ ] V.1 go build / vet / test 全绿；两项演练通过
- [ ] V.2 commit + push（里程碑闭环）
