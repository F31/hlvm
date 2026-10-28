# Tasks: add-capacity-governance

> 进度说明（截至 M7c）：add-capacity-governance 控制面逻辑全部落地并通过单测——capacity-ctrl(M7/M7b) + lvmd-config-ctrl 的 ConfigMap 渲染与漂移纠正(M7c)。
> 依赖测试集群/真实环境的项（§2.2 灰度滚动重载、§3.1 dmeventd 实测、§4.2 envtest、§4.3 打满演练）移交后续集成验证；§3.3 扩容结果写回已由 Agent 上报通道 + 控制面读取支撑。

## 1. capacity-ctrl

- [x] 1.1 capacityStatus 评估：available(<75%) / pressure(75–85%) / locked(≥85% 或 metadata≥75% 或 outOfSpace)
- [x] 1.2 滞回解锁：回落到 unlockPercent 以下才解锁，边界不抖动（单测覆盖 80–85% 波动场景）
- [x] 1.3 锁标签：locked 时打 `storage.example.io/<tier>-locked=true`，解锁移除；标签变更写审计
- [x] 1.4 预测告警：按增长速率计算 timeToFull，Warning(<24h)/Critical(<4h)（纯函数 ForecastCapacityAlert + 条件发布）
- [x] 1.5 requireFreeVGSpace 检查：VG 空间不足转人工（FreeVGInsufficient=True 条件，解析错误告警）
- [x] 1.6 lvm.conf autoextend 配置渲染（RenderLVMConfAutoExtend → status.LvmdConfig）；生效校验依赖 §3.1 实测

## 2. lvmd-config-ctrl

- [x] 2.1 由 NodeVG 渲染各节点 lvmd ConfigMap（device-class、thin-pool、overprovision-ratio）→ LvmdConfigReconciler
- [ ] 2.2 变更灰度 + 滚动重载机制（热加载与否按 POC 结论；依赖测试集群）
- [x] 2.3 渲染漂移检测：ConfigMap 被人工修改时纠正回控制面口径（LvmdConfigReconciler 漂移分支 + 告警日志）

## 3. thinpool 自动扩容（有限缓冲）

- [ ] 3.1 dmeventd 第一防线验证：autoextend 配置在测试节点生效，越线后 ≤30s 完成扩容（对照非功能指标，依赖测试集群）
- [x] 3.2 控制面兜底扩容：周期评估触发，扩容目标受 VG 剩余空间硬上限约束（PlanThinPoolExtend），超限转人工（ThinPoolExtendCapped）
- [x] 3.3 扩容结果写 status.thinPool.currentSizeBytes，不回写 spec（Agent 上报通道已建，控制面 Forecast/Plan 读取）

## 4. 测试

- [x] 4.1 单测：状态映射、滞回、预测算法（恒定速率矩阵）、requireFreeVGSpace、lvm.conf 渲染、兜底扩容、lvmd ConfigMap 创建/漂移
- [ ] 4.2 envtest：locked 流转、标签联动、metadata 阈值独立评估（依赖 envtest/etcd，本环境用 fake-client 等价覆盖）
- [ ] 4.3 测试集群复测 thinpool 打满演练，验证锁与告警链路（依赖测试集群）

## 验证回路

- [x] V.1 go build / vet / test 全绿
- [ ] V.2 打满演练通过（依赖测试集群，见 §4.3）
- [x] V.3 commit + push（M7c 里程碑闭环；add-capacity-governance 控制面逻辑收口）
