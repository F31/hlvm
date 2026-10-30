# Proposal: add-disk-device-plugin

## Why

2026-10-30 在 kind 里做 `occupiedBy` 真机验证时，撞上一个**跨组件的基础设施缺陷**：非特权 Pod 受
**devices cgroup**（runc 的 BPF device filter）限制，`uid=0` 也打不开块设备——`dd` / `blkid` /
`wipefs` 全部 `Operation not permitted`，即使 `capabilities.add` 了
`SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO` 也绕不过（`dd` 直接 EPERM 说明不是文件权限问题）。

这条限制导致两个真实后果：

1. **agent 无法收敛特权**：按 hardening 4.1 改成 `privileged: false` 后，平台唯一写路径
   （wipe/pvcreate）与签名预检全部失效，只能回退 `privileged: true`；
2. **exporter 采不到 SMART**：`smartctl`/`nvme` 都要打开设备，spec 又要求 exporter 非特权，
   于是真实环境里 SMART 类指标直接缺失。

设备插件（Kubernetes Device Plugin v1beta1）是 kubelet 提供的正规出口：把每块盘作为可分配扩展资源
暴露，Pod 申请后 kubelet 只把**被分配的那几个**设备节点写进容器 cgroup 允许列表并注入 `/dev`。
它是「不靠特权也能按盘授权」的唯一路径。

## What Changes

- **新增 `--mode=device-plugin`**（同一 `hlvm-agent` 二进制，遵循设计 §5.1 单二进制多模式）：
  - 实现 v1beta1 `DevicePlugin` 服务：`GetDevicePluginOptions` / `ListAndWatch` / `Allocate` /
    `GetPreferredAllocation` / `PreStartContainer`；
  - 自注册到 kubelet（`unix:///var/lib/kubelet/device-plugins/kubelet.sock`），并按 socket inode 变化
    **自动重注册**（kubelet 重启会清空注册表）；
  - 资源名 `hlvm.io/disk`，每块**非系统整盘**一个设备；`Allocate` 返回
    `DeviceSpec{host_path=container_path=/dev/<disk>, permissions=rw}`。
- **协议代码入库**：`agent/proto/deviceplugin.proto`（字段号与上游 k8s 一致）+ 生成的
  `agent/src/plugin/generated.rs`。构建期**不需要 protoc**（CI 无需增装工具链），改了 proto 才需重生成。
- **新增部署清单** `agent/config/daemonset-device-plugin.yaml`：非特权 DaemonSet（`privileged: false`、
  `drop ALL`、`seccomp RuntimeDefault`、只读根），挂 kubelet 的 `device-plugins` 目录、`/sys` 与
  宿主 `/dev`（挂到 `/host/dev`，见下）。
- **新增集成验证** `scripts/m15-integration.sh verify-device-plugin`，并接入 `all` 链：
  节点可分配量 > 0、非特权 Pod 申请后可读设备、**未申请的同条件 Pod 仍 EPERM**（对照）。

## 关键设计决定（含踩坑证据）

1. **必须 privileged: false**：插件不读盘（只读 `/sys`、`/dev/disk/by-id`、kubelet 目录），特权化会让
   集群多一个对全部盘有原始读写权的常驻进程，与「按盘最小授权」的目的冲突。防回归
   `TestDevicePluginDaemonSetIsNonPrivileged`（与 agent 的 `IsPrivileged` 恰好相反，容易被「顺手统一」改错）。
2. **宿主 `/dev` 挂到 `/host/dev`，不能挂 `/dev`**：runc 会先用 tmpfs 建容器 `/dev`，hostPath 挂 `/dev`
   会被盖住——实测容器内 `/dev/disk/by-id` 根本不存在，设备列表恒为 0。
3. **设备 ID 用 by-id 归一化，缺失时回退 `dev-<name>`**：kind 节点没有 udev，`/dev/disk` 整个目录都不存在；
   若坚持「无 by-id 即跳过」，插件在这些环境里恒为零设备、无法验证。ID 只在插件与 kubelet 之间用于
   一次分配，不落盘、不做 Task 目标，故回退不影响写路径的 by-id 安全约束（StorageTask 仍只收
   `/dev/disk/by-id/...`）。
4. **Allocate 下发宿主真实节点路径**（而非 `/dev/hlvm/<id>`）：`smartctl`/`nvme` 按路径名猜设备类型，
   改名会让采集侧误判。
5. **未知设备 ID 报错而非跳过**：静默跳过会让 Pod 拿到少于申请数的设备，而 kubelet 认为分配成功。
6. **系统盘判定用宿主 `/proc/1/mountinfo`**（hostPID）：容器内 `/proc/mounts` 是容器自己的命名空间，
   根是 overlay，看不到宿主根分区在哪块盘上。

## Out of Scope

- **不解决 agent 的特权**：agent 需要「本节点全部盘」做 wipe/pvcreate，而扩展资源只能申请「N 块」，
  表达不了全集。
- **不解决 exporter 的 DaemonSet 形状**：exporter 需要本节点全部盘的 SMART，同样受「静态申请数」限制。
  正解是把 SMART 采集改为「每盘一个 collector Pod」（由控制面按 NodeDisk 创建、申请 `hlvm.io/disk: 1`），
  属后续变更；本次只提供其所需的分配能力。
- **不采集 SMART**：插件非特权、不读盘，`Device.Health` 恒 `Healthy`；健康判定仍在 agent/exporter。
- **不做纳管决策**：占用判定仍是 agent 预检的职责（需读盘）。插件只做启发式标注（展示用）。
- **不引入 DRA**（`resource.k8s.io`）：DRA 能让 Pod 按名称申请特定设备，但驱动形态与 kube-rs 支持都更重，
  且当前无「按名申请某块盘」的需求。

## Impact

- **Affected specs**: `node-agent`（新增「按盘设备分配」需求；`读写分离靠部署` 增加一条：设备插件非特权）。
- **Affected code**:
  - `agent/Cargo.toml`（tonic/prost/tower/hyper-util/tokio-stream）、`agent/src/main.rs`（新 mode）、
    `agent/src/plugin/`（新模块 + 生成代码）、`agent/src/discovery/mod.rs`（采集 `MODEL`）、
    `agent/proto/deviceplugin.proto`（新）；
  - `agent/config/daemonset-device-plugin.yaml`（新）、`control-plane/internal/controller/deploy_manifests_test.go`
    （非特权防回归）、`scripts/m15-integration.sh`（新阶段 + 镜像构建 helper）、
    `docs/m15-integration-runbook.md`（§8）。
- **验证回路**：
  - `cargo test --all-targets`（135 项，含 19 例插件单测：ID 归一化/过滤/分配/by-id 回退/mountinfo 解析）、
    `cargo fmt --check`；
  - `go vet ./...` + `go test ./...`（清单 SA/镜像/非特权防回归）；
  - kind 真机（WSL 内，`scripts/m15-wsl.sh`）`verify-device-plugin` 4 断言全 PASS、
    `verify-device-plugin` 7 断言全 PASS（含容量上限与回收）、
    `verify-collector` 9 断言全 PASS，`verify-kubelet-restart` 9 断言全 PASS，`all` 链 69 PASS / 0 FAIL
    （含 hardening 3.1b 的 `verify-conversion` 12 断言）。
