# Tasks: add-crd-controller-skeleton

## 1. API 类型定义

- [x] 1.1 确定最终 API Group 域名与 Kind 命名（NodeDisk/NodeVG，StorageTask/StorageNodeOps/ThinPoolPolicy），记录到 ADR —— `api/v1alpha1/groupversion_info.go`（Group="storage.example.io", Version="v1alpha1）、5 个 `*_types.go` 的 Kind 命名（`NodeDisk`/`NodeVG`/`ThinPoolPolicy`/`StorageTask`/`StorageNodeOps`），cluster-scoped 见各类型 `+kubebuilder:resource:scope=Cluster`。
- [x] 1.2 NodeDisk 类型：identity(serial/wwn/byId)、spec.adopt/confirmSerial/wipePolicy、status.phase 状态机枚举、status.health、status.smart、status.occupiedBy、isSystemDisk、vgRef、conditions —— `api/v1alpha1/nodedisk_types.go`（DiskSpec/DiskIdentity/DiskSMART/DiskRaid/DiskStatus 全字段）。
- [x] 1.3 NodeVG 类型：tier/layout/redundancy/disks/thinPool(initialSizePercent=80, maxSizePercent=95, metadataSize, chunkSize, overprovisionRatio)/operations.removeDisks；status 容量与 thinpool 状态字段 —— `api/v1alpha1/nodevg_types.go`（VGSpec/VGOperations/VGThinPoolStatus/VGStatus）。
- [x] 1.4 ThinPoolPolicy 类型：thresholds（含 unlockPercent 滞回、metadata 阈值）、forecast、lock(blockNewPVC/blockPVCExpansion)、requireFreeVGSpace、按 tier 覆盖合并逻辑 —— `api/v1alpha1/thinpoolpolicy_types.go`（ThinPoolThresholds/ThinPoolForecast/ThinPoolLock/ThinPoolPolicySpec，TierOverrides map 合并）。
- [x] 1.5 StorageTask 类型：nodeName/type 白名单/target/confirmSerial/dryRun/approvedBy/ttl、status.phase 与 result —— `api/v1alpha1/storagetask_types.go`（StorageTaskSpec 含 Type 白名单枚举、StorageTaskStatus.Phase/Result）。
- [x] 1.6 StorageNodeOps 类型：operation(retire/isolate/recover-disk)/force、status.phase 与 blockingPVCs —— `api/v1alpha1/storagenodeops_types.go`（StorageNodeOpsSpec/StorageNodeOpsStatus）。
- [x] 1.7 生成 deepcopy 与 CRD manifests，cluster-scoped 确认；添加 kubebuilder 校验标记（枚举、必填、pattern）—— `api/v1alpha1/zz_generated.deepcopy.go`（41 个 DeepCopy 函数）已生成；CRD 手写于 `config/crd/bases/*.yaml`（cluster-scoped 已确认）。**2026-10-29 补完校验标记**：5 个类型全部加 `+kubebuilder:validation:Enum`（phase/health/media/wipePolicy/occupiedBy/VGLayout/Redundancy/CapacityStatus/TaskType/TaskPhase/NodeOperation/NodeOpsPhase）、`Required`（各 Spec.NodeName/StorageTask.Type/StorageNodeOps.Operation/ThinPoolSpec.Name）、`MaxLength=128`（ConfirmSerial）、`Minimum:0/Maximum:100`（ThinPoolPolicy 7 个百分比字段）；手写 CRD 同步补 `thinpoolpolicies` 百分比 min/max 与 `nodedisks`/`storagetasks` 的 confirmSerial maxLength（注：本环境 controller-gen 生成不稳定，仅产出 `_.yaml` 垃圾文件，CRD 维持手写并手工与 Go 标记保持一致）。

## 2. 控制器骨架

- [x] 2.1 storage-controller main：manager、Deployment ×2 + leader election、RBAC 最小权限 —— `cmd/storage-controller/main.go` 已存在（manager + 多控制器注册 + leader election）。
- [x] 2.2 disk-ctrl：NodeDisk 汇总健康、节点失联 >30min（可配）标 stale 触发隔离流程入口 —— `internal/controller/` 下 disk controller（NodeDiskReconciler）已实现对 NodeDisk 健康汇总与节点失联 stale 标记（见 ② 核查：控制器代码与单测均存在）。
- [x] 2.3 vg-ctrl：reconcile 生成 StorageTask（vgcreate / vgreduce[已批准]）、删盘保护（校验无 LV 占用、冗余不丧失，拒绝原因写 status.pendingOps）；disk-ctrl 下发纳管 StorageTask（wipe→pvcreate）。新增 StorageTaskReconciler 消费终态结果回写 NodeDisk/NodeVG status（单写者闭环）
- [x] 2.4 status 低频刷新机制：phase/health 变化即时写，其余 10 分钟周期，SMART 全量只进 Prometheus 不进 status —— **规划错位澄清**：语义主体为 Agent 写回 NodeDisk/NodeVG.status，已由 node-agent 实现并单测，非控制面待实现项。`agent/src/reporter/mod.rs` 的 `diff_nodedisk_status`（line 231，判定 phase/health/occupiedBy/isSystemDisk 变化）+ `should_refresh`（line 241，变化⇒立即刷新；否则距上次刷新 ≥interval 才刷新，默认 10 分钟），对应 node-agent 基线 spec「NodeDisk 低频状态写回」需求（openspec/specs/node-agent/spec.md:72-81），单测见 reporter/mod.rs:446-524（覆盖"未变化<interval⇒不刷新 / ≥interval⇒刷新"）。控制面侧对应职责（etcd 写放大约束，§7）由各控制器"变化才写"逻辑满足：DiskReconciler 仅 Stale 条件变化才 `Status().Update`（disk_controller.go:109）、VGReconciler 仅 pendingOps 变化才写（vg_controller.go:72）、StorageTaskReconciler 仅任务结果 changed 才回写（storage_task_controller.go:65/85）。SMART 全量进 Prometheus 由 add-observability 的 exporter 承载（control-plane/internal/metrics + Agent exporter）。

## 3. 测试

- [x] 3.1 reconcile 单测（controller-runtime fake client，替代 envtest）：NodeDisk 纳管下发、vg-ctrl 的 StorageTask 生成与删盘保护、StorageTask 终态回写
- [x] 3.2 spec/status 分离校验：reconcile 不回写 spec（单测断言 Spec 不变），单写者原则落地

## 验证回路

- [x] V.1 go build / go vet / go test 全绿；二进制 `--help` 正常
- [ ] V.2 测试集群 e2e（envtest 或 kind）：手工创建 NodeDisk/NodeVG 对象被正确 reconcile（本环境无 etcd/kube-apiserver 二进制，暂缓；fake-client 已覆盖单元级）
- [x] V.3 commit + push（里程碑闭环）—— 2026-10-29 提交：① 1.1–1.7/2.1/2.2 滞后跟踪回填；② 5 个 API 类型补 kubebuilder 校验标记（35 处）+ 手写 CRD 同步（thinpoolpolicies 百分比 min/max、nodedisks/storagetasks confirmSerial maxLength、nodevgs thinPool.name required）；③ 新增 api/v1alpha1/types_test.go（DeepCopy 独立性/JSON 往返/枚举常量一致性/Scheme 注册）；go build/vet/test 全绿（含 control-plane 全量测试）后推送 main。
