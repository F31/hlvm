# Tasks: add-node-agent

## 1. 骨架与发现

- [ ] 1.1 单二进制多模式骨架（--mode=agent|exporter|doctor），语言按 POC ADR
- [ ] 1.2 discovery：/sys/block + lsblk --json 枚举；周期扫描；udev 事件触发即时重扫
- [ ] 1.3 Disk 身份生成：{node}-{serial/wwn 短名}；by-id 路径解析；首次发现创建 phase=Discovered 的 NodeDisk

## 2. SMART 与健康度

- [ ] 2.1 NVMe 采集（nvme-cli / ioctl）：critical_warning、available_spare、percentage_used、media_errors、temperature、unsafe_shutdowns
- [ ] 2.2 SATA/SAS 采集（smartctl --json）：reallocated / pending / offline uncorrectable
- [ ] 2.3 Health 枚举映射 + 阈值 ConfigMap 热加载；media_errors 增量判定（累计值非 0 但不变不告警）
- [ ] 2.4 SMART 全量只进 Prometheus，status 仅变化或 10 分钟低频刷新

## 3. 预检引擎

- [ ] 3.1 规则实现：系统盘判定（根/boot/swap/kubelet 目录及 holders）、fs/LVM/md 签名、multipath/dm 持有者、已是 PV、SMART failed、tier 容量/介质不符
- [ ] 3.2 预检通过 → phase=Candidate→PreChecked；命中任一规则 → 记录拒绝原因
- [ ] 3.3 规则引擎单测：每条规则独立用例 + 组合场景

## 4. LVM 执行环境

- [ ] 4.1 chroot/nsenter 宿主机 lvm 调用封装，共享 /run/lock/lvm 锁目录
- [ ] 4.2 --reportformat json 统一解析；解析失败一律"未知"，不得推断
- [ ] 4.3 宿主机 lvm.conf devices{} / devices file 限定扫描纳管盘
- [ ] 4.4 dmeventd 启用与 thin_pool_autoextend_* 配置管理与校验

## 5. executor 与操作安全

- [ ] 5.1 StorageTask 消费循环：节点级过滤（只处理 spec.nodeName=自身节点）
- [ ] 5.2 命令执行：argv 数组、禁止 shell 拼接、设备路径 by-id 格式校验
- [ ] 5.3 破坏性动作二次校验：执行前重读实际状态（serial 匹配、无签名/无持有者、非系统盘）；dryRun 支持
- [ ] 5.4 wipe 流程：wipePolicy（none|zero|secure-erase）+ confirmSerial 匹配
- [ ] 5.5 幂等：taskID 去重、执行日志落盘、崩溃恢复后"已执行未回执"任务重探测补回执不重复执行
- [ ] 5.6 executor 单测：dryRun 全 type 覆盖、幂等回归、危险输入（路径穿越/拼接注入）拒绝

## 6. 上报与权限

- [ ] 6.1 reporter：status 低频更新；agent 心跳指标
- [ ] 6.2 节点级权限隔离：SA 绑定 + ValidatingAdmissionPolicy（只能读写自身节点的 Task/Disk），类似 NodeRestriction
- [ ] 6.3 资源定稿：以 POC 实测（多盘节点、smartctl fork 峰值、日志量）确定 requests/limits

## 7. 部署

- [ ] 7.1 特权 agent DaemonSet：最小 capability 与 hostPath 清单、PSA 标签、seccomp
- [ ] 7.2 与 lvmd 同机并发操作验证：与 TopoLVM lvmd 对同一 VG 并发操作无锁冲突（集成测试）

## 验证回路

- [ ] V.1 build / vet(lint) / test 全绿；测试节点 dryRun 全链路集成测试通过
- [ ] V.2 混沌预演：kill -9 agent 验证崩溃恢复幂等补回执
- [ ] V.3 commit + push（里程碑闭环）
