# Tasks: add-crd-controller-skeleton

## 1. API 类型定义

- [ ] 1.1 确定最终 API Group 域名与 Kind 命名（NodeDisk/NodeVG，StorageTask/StorageNodeOps/ThinPoolPolicy），记录到 ADR
- [ ] 1.2 NodeDisk 类型：identity(serial/wwn/byId)、spec.adopt/confirmSerial/wipePolicy、status.phase 状态机枚举、status.health、status.smart、status.occupiedBy、isSystemDisk、vgRef、conditions
- [ ] 1.3 NodeVG 类型：tier/layout/redundancy/disks/thinPool(initialSizePercent=80, maxSizePercent=95, metadataSize, chunkSize, overprovisionRatio)/operations.removeDisks；status 容量与 thinpool 状态字段
- [ ] 1.4 ThinPoolPolicy 类型：thresholds（含 unlockPercent 滞回、metadata 阈值）、forecast、lock(blockNewPVC/blockPVCExpansion)、requireFreeVGSpace、按 tier 覆盖合并逻辑
- [ ] 1.5 StorageTask 类型：nodeName/type 白名单/target/confirmSerial/dryRun/approvedBy/ttl、status.phase 与 result
- [ ] 1.6 StorageNodeOps 类型：operation(retire/isolate/recover-disk)/force、status.phase 与 blockingPVCs
- [ ] 1.7 生成 deepcopy 与 CRD manifests，cluster-scoped 确认；添加 kubebuilder 校验标记（枚举、必填、pattern）

## 2. 控制器骨架

- [ ] 2.1 storage-controller main：manager、Deployment ×2 + leader election、RBAC 最小权限
- [ ] 2.2 disk-ctrl：NodeDisk 汇总健康、节点失联 >30min（可配）标 stale 触发隔离流程入口
- [ ] 2.3 vg-ctrl：reconcile 生成 StorageTask（pvcreate/vgcreate/vgextend）、删盘保护（校验无 LV 占用、冗余不丧失，拒绝原因写 status.pendingOps）、加盘即扩容路径
- [ ] 2.4 status 低频刷新机制：phase/health 变化即时写，其余 10 分钟周期，SMART 全量只进 Prometheus 不进 status

## 3. 测试

- [ ] 3.1 envtest 单测：NodeDisk phase 状态机推进规则（adopt/confirmSerial 门控）、vg-ctrl 的 StorageTask 生成与删盘保护
- [ ] 3.2 spec/status 分离校验：控制器不回写 spec 的 lint/单测约束

## 验证回路

- [ ] V.1 go build / go vet / go test 全绿；CRD 在测试集群 apply 并通过最小 e2e（手工创建 NodeDisk/NodeVG 对象被正确 reconcile）
- [ ] V.2 commit + push（里程碑闭环）
