# Tasks: add-node-agent（补齐 14 项未实现功能）

> 历史：M6 完成骨架、发现、SMART 解析、LVM 解析、executor 闭环、StorageTask 回写。
> 本文件将剩余 14 项缺口拆分为 M14a（纯逻辑，无集群依赖，可单测）/ M14b（NodeDisk 写回 + exporter + 状态机，逻辑可单测、集群验证移交）/ M14c（清单 + 集群依赖验证）三个里程碑。
> 约束：本机无 Rust 工具链，`cargo build/test` 门禁需在安装 cargo 后执行；未验证不推送。

## M14a — 纯逻辑实现（无集群依赖，可单测）

> 代码已写 + 单测已写；`cargo build/test` 门禁待安装 Rust 工具链后执行（本机当前无 cargo）。

### 3.1 预检规则全覆盖
- [x] 3.1.1 blkid 输出解析（fs/LVM/md 签名识别）纯函数 + 单测
- [x] 3.1.2 multipath / device-mapper 持有者识别（lsblk holders / dm 类型）纯函数 + 单测
- [x] 3.1.3 tier 容量/介质不符检测（期望 vs 实际）纯函数 + 单测
- [x] 3.1.4 `precheck::run` 接入上述规则（扩展 PrecheckInput + issues）

### 3.3 规则引擎单测
- [x] 3.3.1 每条规则独立用例（系统盘 / PV / SMART failed / fs 签名 / md 签名 / multipath / tier 不符）
- [x] 3.3.2 组合场景用例（多规则同时命中、边界值）

### 2.3 阈值热加载 + media_errors 增量
- [x] 2.3.1 `ThresholdTable` 结构体 + 默认值 + `from_configmap_json` 解析（纯函数 + 单测）
- [x] 2.3.2 阈值感知映射 `map_nvme_health_with` / `map_sata_health_with`（保留原字面量变体兼容）
- [x] 2.3.3 `MediaErrorTracker` 增量判定（两次采样间增量，非累计）纯函数 + 单测

### 4.3 宿主机 lvm.conf devices-file 限定扫描
- [x] 4.3.1 devices file 内容渲染（by-id 白名单）纯函数 + 单测
- [x] 4.3.2 lvm.conf `devices{}` 片段渲染 + 写回命令构造（纯函数）+ 校验

### 4.4 dmeventd 与 thin_pool_autoextend
- [x] 4.4.1 `thin_pool_autoextend_threshold` / `thin_pool_autoextend_percent` 配置渲染（纯函数）+ 单测
- [x] 4.4.2 启用 dmeventd 的写回命令构造与校验（纯函数）

### 6.1 心跳指标
- [x] 6.1.1 `render_heartbeat` 纯函数（storage_agent_heartbeat 指标）+ 单测

## M14b — NodeDisk 写回 + exporter + 预检状态机（逻辑可单测，集群验证移交）

### 2.4 SMART 全量进 Prometheus（exporter 独立非特权 DaemonSet）
- [x] 2.4.1 exporter 真实采集循环：`run_exporter`/`serve_exporter` 经 tokio TcpListener 在 `:9105/metrics` 暴露 Prometheus 文本指标（替代原空占位）
- [x] 2.4.2 暴露 `storage_disk_smart_health` / `storage_disk_media_errors` / `storage_disk_capacity_bytes` / `storage_agent_heartbeat`（健康/介质错误/容量/心跳）；VG/thinpool 级指标为后续项（M14c 或控制面 exporter）

### 6.1 余下：status 低频刷新
- [x] 6.1.2 `NodeDiskReporter` 节流纯函数（`build_nodedisk_patch` / `diff_nodedisk_status` / `should_refresh` 变化即时 + 10 分钟低频）+ 单测（`LogNodeDiskReporter` 回退）
- [x] 6.1.3 kube-rs `KubeNodeDiskReporter` + `run_nodedisk_reconciler` 写回 `NodeDisk.status`（仅 status 子资源，单写者：Agent 写观测字段，控制面写任务结果字段）

### 3.2 预检状态机落盘
- [x] 3.2.1 `DiskPhase` 枚举 + `advance_phase` 纯函数 Candidate→PreChecked（规则全过才推进）+ 单测
- [x] 3.2.2 `propose_nodedisk_status` + `scan_node_disk`（blkid/lsblk/SMART 观测）+ 经 `NodeDiskReporter` 写回 `NodeDisk.status.phase`；`agent/mod.rs` 编排（离线 Log 演示 / 集群 kube 写回）

### 7.2 与 lvmd 同机并发验证（集成）
- [ ] 7.2.1 并发操作集成测试脚本（agent 与 lvmd 同机串行化验证，待集群）

## M14c — 节点权限清单 + 集群依赖项（移交集成 / 待集群）

### 6.2 节点级权限隔离
- [x] 6.2.1 ValidatingAdmissionPolicy（自身节点 Task/Disk，NodeRestriction 式）+ SA 绑定清单（control-plane/config/hardening/05-node-rbac-isolation.yaml）
- [x] 6.2.2 节点绑定 token（projected token / TokenRequest）配置（同 05-node-rbac-isolation.yaml 注释段）

### 6.3 资源定稿
- [x] 6.3.1 以 POC 实测回填 requests/limits（文档模板 + 占位值）：daemonset-agent.yaml 两容器 resources 占位 + docs/poc/resource-profiles.md 模板

### 7.1 特权 agent DaemonSet（已完成，M12b）
- [x] 7.1.1 最小 capability + hostPath 清单、PSA 标签、seccomp（见 control-plane/config/hardening + agent/config/daemonset-agent.yaml）

### 7.2 与 lvmd 同机并发验证（集成）
- [x] 7.2.1 并发操作集成测试脚本（agent 与 lvmd 同机串行化验证）：docs/poc/scripts/concurrency-lvmd-test.sh

### 验证回路
- [ ] V.1 cargo build / test 全绿（安装 cargo 后执行；独立 HOME 工具链安装中）
- [ ] V.2 混沌预演：kill -9 agent 验证崩溃恢复幂等补回执（待集群）
- [x] V.3 commit + push（里程碑闭环；本机无 cargo 时仅本地提交、验证后推送）
