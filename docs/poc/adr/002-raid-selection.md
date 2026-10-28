# ADR-002：RAID 选型（设计 §10 阶段 0 / add-poc-decision-gate §5.2）

- **状态**：提议（POC 决策门评审中）
- **日期**：2026-10-28
- **决策人**：平台团队

## 背景

设计 §9.3 / §10 要求 POC 明确 RAID 选型：硬件 RAID / mdadm / LVM RAID1，并验证 LVM RAID 对 thin-pool 元数据冗余的支持。
目标：在单盘故障场景下控制数据不可恢复范围（pooled 布局整 VG 受损 vs per-disk 布局仅单盘）。

## 候选

| 方案 | 优点 | 缺点 | thin-pool 元数据冗余 |
| --- | --- | --- | --- |
| 硬件 RAID | 性能/可靠性最佳，对 OS 透明 | 需专用卡、成本高、运维复杂 | 元数据随阵列冗余 |
| mdadm (Linux 软 RAID) | 无专用硬件、灵活 | CPU 开销、重建期性能下降 | 元数据随阵列冗余 |
| LVM RAID1 | 与 LVM 栈一致、管理统一 | 重建语义依赖 LVM、thin 元数据冗余需验证 | **需 POC 验证** |

## 决策

**POC 阶段默认不引入 RAID**（单盘独立纳管，per-disk 布局优先，故障域单盘），理由：
- 本地存储定位为「数据不迁移、按剧本重建」，多副本业务依赖上层副本而非盘级冗余；
- 简化 POC，先验证单盘故障剧本（§9.3）与隔离期流程；
- 对 critical 业务，优先用 thick LV + 应用多副本，而非盘级 RAID。

**若确有 RAID 需求**（如单机无副本的关键业务），采用 **LVM RAID1**（与 LVM 栈统一），
但须 POC 验证其对 thin-pool 元数据冗余的支持（设计【待核实】第 5 项），否则回退硬件 RAID。

## 影响

- `agent` 预检与 StorageTask 默认按单盘 per-disk 布局；
- 引入 RAID 时扩展 lvmd device-class 与 precheck 规则（签名/holder 识别）；
- 元数据冗余验证结论回填设计【待核实】第 5 项。
