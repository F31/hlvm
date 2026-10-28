# Tasks: add-node-agent

> 进度说明（截至 M6）：骨架、发现、SMART（NVMe+SATA/SAS 解析）、LVM 解析、executor 闭环、StorageTask 状态回写（kube-rs）已完成并通过单测。
> 剩余项（预检全规则、部署清单、权限隔离、低频刷新）移交后续 change（add-observability / add-hardening-rollout 等）或单独收尾。

## 1. 骨架与发现

- [x] 1.1 单二进制多模式骨架（--mode=agent|exporter|doctor），语言按 POC ADR（Rust）
- [x] 1.2 discovery：`lsblk --json` 枚举 + 解析（`parse_lsblk` 扁平化 children）；`enumerate_disks` 运行时调用（周期扫描/udev 即时重扫待后续）
- [x] 1.3 by-id 路径解析（`resolve_by_id` 经 /dev/disk/by-id 软链真实解析）；身份生成由控制面 NodeDisk 负责

## 2. SMART 与健康度

- [x] 2.1 NVMe 采集（nvme-cli）：critical_warning / available_spare / percentage_used 解析与映射
- [x] 2.2 SATA/SAS 采集（smartctl --json）：reallocated / pending / offline_uncorrectable + smart_status 解析与映射（**M6**）
- [ ] 2.3 Health 枚举映射 + 阈值 ConfigMap 热加载；media_errors 增量判定（映射函数已就位，热加载未做）
- [ ] 2.4 SMART 全量只进 Prometheus，status 仅变化或 10 分钟低频刷新（指标渲染已有，低频刷新/全量上报未接）

## 3. 预检引擎

- [x] 3.1 规则（部分）：系统盘判定（根/boot/kubelet 挂载）、PV 占用、SMART failed 已实现
- [ ] 3.1 规则（余下）：fs/LVM/md 签名、multipath/dm 持有者、tier 容量/介质不符检测
- [ ] 3.2 预检通过 → Candidate→PreChecked 状态机（当前仅返回 eligible 布尔，未在 NodeDisk 落 phase）
- [ ] 3.3 规则引擎单测：每条规则独立用例 + 组合场景（当前为 eligible 维度的少量用例）

## 4. LVM 执行环境

- [x] 4.2 --reportformat json 统一解析（vgs/lvs/pvs）；解析失败一律"未知"（Option::None），不得推断
- [~] 4.1 chroot/nsenter 宿主机 lvm 调用封装：已通过 `HLVM_HOST_WRAPPER` 环境变量注入前缀（nsenter -t 1 -m -- chroot /host）；默认以 `lvm` 占位
- [ ] 4.3 宿主机 lvm.conf devices{} / devices file 限定扫描纳管盘
- [ ] 4.4 dmeventd 启用与 thin_pool_autoextend_* 配置管理与校验

## 5. executor 与操作安全（M4 已完成）

- [x] 5.1 StorageTask 消费循环：节点级过滤（kube_rw 按 spec.nodeName 客户端过滤）
- [x] 5.2 命令执行：argv 数组、禁止 shell 拼接、设备路径 by-id 格式校验（`require_by_id`）
- [x] 5.3 破坏性动作二次校验：serial 匹配、系统盘保护、已审批；dryRun 支持
- [x] 5.4 wipe 流程命令构造（`wipefs -a`）；wipePolicy 多策略落控制面 Spe
- [x] 5.5 幂等：taskID 去重、崩溃恢复"已执行未回执"补回执（已是 PV 探测）
- [x] 5.6 executor 单测：dryRun 全 type、幂等回归、危险输入（非 by-id / 路径穿越 / serial 不一致 / 系统盘）拒绝

## 6. 上报与权限

- [x] 6.1 StorageTask 状态回写逻辑（**M6**）：`build_status_patch` 纯函数 + `plan_to_status` 映射 + `KubeReporter`(patch_status) + `run_task_reconciler` 轮询协调；agent 离线回退 LogReporter
- [ ] 6.1 余下：status 低频刷新、agent 心跳指标
- [ ] 6.2 节点级权限隔离：SA 绑定 + ValidatingAdmissionPolicy（自身节点 Task/Disk），类似 NodeRestriction
- [ ] 6.3 资源定稿：以 POC 实测确定 requests/limits

## 7. 部署

- [ ] 7.1 特权 agent DaemonSet：最小 capability 与 hostPath 清单、PSA 标签、seccomp
- [ ] 7.2 与 lvmd 同机并发操作验证（集成测试）

## 验证回路

- [~] V.1 build / vet(lint) / test 全绿（Rust 47 单测通过；二进制 --help 正常；Go 侧同步 build/vet/test 通过）
- [ ] V.2 混沌预演：kill -9 agent 验证崩溃恢复幂等补回执（待集群）
- [ ] V.3 commit + push（里程碑闭环）
