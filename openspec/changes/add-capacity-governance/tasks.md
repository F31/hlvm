# Tasks: add-capacity-governance

> 进度说明（截至 M7）：capacity-ctrl 核心已落地并通过单测——阈值解析（默认+policy+tier覆盖）、带滞回的 capacityStatus 决策、节点锁标签打/摘（§3.3 tasks 1.1–1.3）。
> 剩余项（预测告警 1.4、requireFreeVGSpace 1.5、lvm.conf 渲染 1.6、lvmd-config-ctrl、thinpool 自动扩容）移交 M7b 或后续 change。

## 1. capacity-ctrl

- [x] 1.1 capacityStatus 评估：available(<75%) / pressure(75–85%) / locked(≥85% 或 metadata≥75% 或 outOfSpace)
- [x] 1.2 滞回解锁：回落到 unlockPercent 以下才解锁，边界不抖动（单测覆盖 80–85% 波动场景）
- [x] 1.3 锁标签：locked 时打 `storage.example.io/<tier>-locked=true`，解锁移除；标签变更写审计
- [ ] 1.4 预测告警：按增长速率计算 timeToFull，Warning(<24h)/Critical(<4h)
- [ ] 1.5 requireFreeVGSpace 检查：VG 空间不足转人工工单
- [ ] 1.6 lvm.conf autoextend 配置渲染与生效校验（与 agent 的下发对接）

## 2. lvmd-config-ctrl

- [ ] 2.1 由 NodeVG 渲染各节点 lvmd ConfigMap（device-class、thin-pool、overprovision-ratio）
- [ ] 2.2 变更灰度 + 滚动重载机制（热加载与否按 POC 结论）
- [ ] 2.3 渲染漂移检测：ConfigMap 被人工修改时发现并纠正/告警

## 3. thinpool 自动扩容（有限缓冲）

- [ ] 3.1 dmeventd 第一防线验证：autoextend 配置在测试节点生效，越线后 ≤30s 完成扩容（对照非功能指标）
- [ ] 3.2 控制面兜底扩容：周期评估触发，扩容目标受 maxSizePercent=95 约束，超限转人工
- [ ] 3.3 扩容结果写 status.thinPool.currentSizeBytes，不回写 spec

## 4. 测试

- [ ] 4.1 单测：状态映射、滞回、预测算法（恒定/突发/衰减增长率）
- [ ] 4.2 envtest：locked 流转、标签联动、metadata 阈值独立评估
- [ ] 4.3 测试集群复测 thinpool 打满演练，验证锁与告警链路

## 验证回路

- [ ] V.1 go build / vet / test 全绿；打满演练通过
- [ ] V.2 commit + push（里程碑闭环）
