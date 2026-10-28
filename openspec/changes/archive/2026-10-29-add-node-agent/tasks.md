# Tasks: add-node-agent（补齐 14 项未实现功能）

> 历史：M6 完成骨架、发现、SMART 解析、LVM 解析、executor 闭环、StorageTask 回写。
> 本文件将剩余 14 项缺口拆分为 M14a（纯逻辑，无集群依赖，可单测）/ M14b（NodeDisk 写回 + exporter + 状态机，逻辑可单测、集群验证移交）/ M14c（清单 + 集群依赖验证）三个里程碑。
> 约束更新（2026-10-28）：本机 Windows 开发箱仍无链接器，但 WSL2（Ubuntu 24.04，Docker 29.4.1）已装原生 rustup/cargo 1.96.0，`agent/scripts/build-wsl-native.sh` 在 WSL 内走原生编译（fmt/clippy/build --release/test 全绿后回写 Windows src）。`cargo build/test` 门禁仍由 Linux CI（.github/workflows/ci.yml）二次把关；未经验证（本机 WSL 构建 + CI 任一侧未绿）不推送 main。

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
- [x] 7.2.1 并发操作集成测试脚本（agent 与 lvmd 同机串行化验证）：docs/poc/scripts/concurrency-lvmd-test.sh

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
- [x] V.1 cargo build / test 全绿 —— Linux CI（.github/workflows/ci.yml rust job：cargo test/clippy/fmt/build --release）已于 2026-10-28 跑绿。M14 依赖墙（k8s-openapi 0.28+v1_36 与 kube ^0.28 兼容）与代码编译墙（3 处 E0599/E0382 error + 1 处 unused import warning 已据 CI 报错修复，f3e0161）双双清除，cargo test 在 ubuntu runner 真实通过。Agent 编译目标 k8s 1.36（k8s-openapi 0.28.0 含 v1_36）。
- [x] V.2 混沌预演：kill -9 agent 验证崩溃恢复幂等补回执（**2026-10-28 于本地 WSL kind 集群 hlvm（kindest/node:v1.36.1，k8s 1.36.1）实测通过**）。`pkill -9 -f hlvm-agent`（hostPID 下 PID 1 为节点 systemd，kill -9 1 无效）后：Pod `restartCount=1`、新 PID 2951、Agent 重入两协调循环；`NodeDisk.status` 与基线完全一致（phase=Discovered / health=healthy / occupiedBy=none / isSystemDisk=false），证明无本地持久状态、崩溃重启后收敛幂等。测试清单见 `agent/config/v2-chaos-kind.yaml`。
- [x] V.3 commit + push（里程碑闭环已达成：M14 全部代码+清单本地提交后经 Linux CI 验证，feat/m14-agent-and-ci 快进合入 main 并推送 origin/main，共 11 个 commit；本机无 cargo 时以 CI 代为编译验证）

### M14 收口修正记录（2026-10-28，WSL kind 真实集群暴露并修复）
> 此前 CI 单测不连集群，掩盖了多个仅真实集群才暴露的 API/权限/类型 bug。以下均在 `hlvm` kind 集群（k8s 1.36.1）部署验证时暴露并修复：

- **Bug 1 · API group 不一致（真实集群 NotFound）**：Rust 侧 `CustomResource` 派生写 `group="storage.hlvm.io"`，与控制面权威 group `storage.example.io` 冲突。修复：`agent/src/reporter/kube_rw.rs`（StorageTask/NodeDisk 两处派生）+ `control-plane/config/hardening/05-node-rbac-isolation.yaml`（matchConstraints 与 VAP 各一处 `apiGroups`）。权威 group 统一为 `storage.example.io`。
- **Bug 2 · Agent 缺 `nodedisks/status` 写权限**：原 `agent_role.yaml` 仅授权 `nodedisks` get/list/watch，M14b `run_nodedisk_reconciler` 写 status 会 Forbidden。修复：新增 `apiGroups:["storage.example.io"] resources:["nodedisks/status"] verbs:["get","update","patch"]`；并澄清单写者职责（Agent 写观测字段 phase/health/occupiedBy/isSystemDisk，控制面写任务结果字段）。
- **Bug 3 · DaemonSet SA 名错配**：`agent/config/daemonset-agent.yaml` 误用 `hlvm-storage-agent`，与 `agent_role.yaml` 的 `hlvm-agent` 不一致 → 绑定失败。修复：`serviceAccountName: hlvm-agent`。
- **Bug 4 · NodeDisk CRD 缺 `deviceRef` 字段**：Agent `NodeDiskSpecMirror` 读 `deviceRef`，但 Go `DiskSpec`/CRD 无此字段 → 应用报 `unknown field "spec.deviceRef"`。修复：`control-plane/config/crd/bases/storage.example.io_nodedisks.yaml` spec.properties 补 `deviceRef: { type: string }`。
- **Bug 5 · `lsblk -b` SIZE 类型不匹配（discovery 容量永远解析失败）**：`LsblkDevice.size` 原定义为 `Option<String>`，但 `lsblk -b` 输出整数 SIZE → `invalid type: integer 407490560, expected a string`。修复：`agent/src/discovery/mod.rs` 改 `size: Option<serde_json::Value>` 并加 `size_bytes()` 容错提取（整数直取 / 字符串解析 / 其余回退 None）；同步更新消费点 `agent/src/agent/mod.rs:125` 与 `agent/src/reporter/mod.rs:370`。
- **工具链统一**：`cargo fmt/clippy` 此前未统一（CI 非阻塞、本机无 rustfmt）。现以 WSL 原生 rustup（cargo 1.96.0）+ `agent/scripts/build-wsl-native.sh` 统一 fmt/clippy/build --release/test，并回写 Windows src；`Dockerfile` 改以 `kindest/node:v1.36.1` 为基础镜像（含 util-linux blkid/lsblk，免拉取 `rust:1-bookworm`，规避失效的 Docker 守护进程代理 7892）。
- **环境要点**：WSL 内 `wsl` 调用须 `MSYS_NO_PATHCONV=1`（否则 `/mnt/e` 被 MSYS 扭曲）；新建第 4 个 kind 节点需 `wsl -u root sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576`（默认 128 被 3 个运行节点吃满 → systemd boot EMFILE）。
