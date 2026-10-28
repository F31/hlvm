# 版本兼容矩阵与升级回滚（设计 §11 升级 / add-hardening-rollout §3.3 + §3.4）

## 1. 版本兼容矩阵（声明，§3.3）

| 组件 | 最低版本 | 验证版本 | 备注 |
| --- | --- | --- | --- |
| Kubernetes | 1.28 | 1.33 | TopoLVM 0.20+ 要求；CEL/ValidatingAdmissionPolicy 需 1.30+ |
| 内核 | 5.15 | 6.x | thin-pool / dmeventd 行为依赖；需开启 dmeventd 监控 |
| lvm2 | 2.03.x | 2.03.21+ | `thin_pool_autoextend_*` 配置；`thin_check` 修复步骤 |
| TopoLVM | 0.20 | 0.20.x | CSI 快照、device-class；上游版本矩阵以官方为准（阶段 0 明确） |
| controller-runtime | 0.20.x | 0.20.4 | 本控制面依赖 |
| Rust（agent） | 1.75 | 1.80+ | agent 构建工具链 |

> 矩阵须在阶段 0 用真实版本组合验证（设计 §10 阶段 0「TopoLVM 集成 / 明确上游版本矩阵」），
> 任一组件升级须先在此矩阵登记并回归。

## 2. TopoLVM 升级演练与回滚（§3.3）

1. 升级前：记录当前 TopoLVM 版本、device-class 配置、运行中 PVC 清单。
2. 演练环境先升 TopoLVM（含 CSI 插件、node 组件、scheduler），验证 PVC 创建/扩容/快照。
3. 回滚：保留上一版本镜像 tag，出问题即 `kubectl rollout undo` + 镜像回退；数据面不受影响（本地 PV 不依赖 TopoLVM 运行时）。
4. 升级窗口内暂停 hlvm 容量变更类 StorageTask（避免与 TopoLVM 变更叠加）。

## 3. 任一组件可回滚验证（§3.4）

| 组件 | 回滚方式 | 验证点 |
| --- | --- | --- |
| storage-webhook | Deployment 回退镜像 + PDB 保证 ≥2 副本 | 非平台 PVC 不阻塞；admission 行为与旧版一致 |
| storage-controller | Deployment 回退镜像 | reconcile 恢复；无状态错误回写（status 单写者保障） |
| storage-agent | DaemonSet 回退镜像（maxUnavailable=1 逐节点） | 节点写路径恢复；在飞任务幂等重发（confirmSerial 防重复） |
| crd-conversion | Deployment 回退 | conversion 向后兼容；v1alpha1 存储对象不损坏 |
| TopoLVM | 镜像回退 | 供给能力恢复；已有 PV 不受影响 |

> 回滚验证须纳入每次版本发布清单；CRD 升级须先确认 conversion 逻辑就绪（见 03-crd-conversion.yaml）。
