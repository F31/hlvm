# Tasks: add-disk-device-plugin

## 1. 协议与服务（已交付）

- [x] 1.1 引入 v1beta1 协议定义 `agent/proto/deviceplugin.proto`
  （字段号与 `k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1/api.proto` 逐字对齐；含 `Registration` 服务）
- [x] 1.2 生成代码入库 `agent/src/plugin/generated.rs`（tonic-build 0.12 + prost 0.13），
  构建期不需要 protoc；头部注释写明重生成命令，`#[rustfmt::skip]` 保证重生成 diff 可读
- [x] 1.3 实现 `DevicePlugin` 五个方法：`GetDevicePluginOptions` / `ListAndWatch`（5s 比对，变化才推）/
  `Allocate` / `GetPreferredAllocation` / `PreStartContainer`
- [x] 1.4 kubelet 注册：Unix socket gRPC（tonic 无内建 UDS connector，用 `connect_with_connector` +
  `service_fn` + `TokioIo`）；注册失败 5s 重试；`kubelet.sock` inode 变化即重注册
- [x] 1.5 `--mode=device-plugin` 接入 CLI（同一二进制，遵循设计 §5.1）

## 2. 设备选择与分配（已交付）

- [x] 2.1 只暴露整盘：排除 part/loop/rom/ram/zram/fd；`TYPE` 缺失按不可分配处理（失败关闭）
- [x] 2.2 系统盘剔除：宿主 `/proc/1/mountinfo`（hostPID）→ `/sys/dev/block/<maj>:<min>` → 父盘名；
  与 lsblk 挂载点判定取并集
- [x] 2.3 设备 ID：`/dev/disk/by-id` 末段归一化为 `[A-Za-z0-9._-]`（≤63 字符），冲突即跳过；
  无 by-id 环境回退 `dev-<name>`
- [x] 2.4 `Allocate`：`DeviceSpec{host_path=container_path=/dev/<disk>, permissions=rw}`；
  未知 ID 报错（不静默跳过）
- [x] 2.5 单测 19 例（ID 归一化/截断、整盘过滤、系统盘剔除、ID 去重、占用启发式、分配与未知 ID、
  preferred allocation、注册请求字段、mountinfo 解析、sysfs 路径→盘名、`dev_rel` 合法性、
  自定义设备根下的 by-id 反查）

## 3. 部署清单（已交付）

- [x] 3.1 `agent/config/daemonset-device-plugin.yaml`：SA + 非特权 DaemonSet
  （`privileged: false`、`drop ALL`、`RuntimeDefault`、只读根、`runAsUser: 0` 仅为在 kubelet 目录建 socket）
- [x] 3.2 挂载：kubelet `device-plugins` 目录（rw）、`/sys`（ro）、宿主 `/dev` → **`/host/dev`**（ro）
  ——挂 `/dev` 会被 runc 的 tmpfs 盖住（实测 `/dev/disk/by-id` 不存在）
- [x] 3.3 防回归 `TestDevicePluginDaemonSetIsNonPrivileged`（负向验证：改 `privileged: true` 或改错
  `--mode` 均失败）

## 4. 集成验证（已交付）

- [x] 4.1 `scripts/m15-integration.sh` 新增 `verify-device-plugin` 并接入 `all`
- [x] 4.2 断言：插件 Pod 就绪 / 节点 `allocatable.hlvm.io/disk > 0` / 非特权 Pod 申请后可读（`READ_OK`）/
  未申请的同条件 Pod 仍 `EPERM`
- [x] 4.3 kind 实测（2026-10-30）：4 断言全 PASS，节点可分配 `hlvm.io/disk=2`
- [x] 4.4 抽出 `ensure_agent_image` helper（agent 与 device-plugin 共用镜像，避免两处重复构建逻辑）

## 5. 文档（已交付）

- [x] 5.1 runbook §8（用途/部署/用法/验证/边界）+ §3 表格 + §6 表述更新
- [x] 5.2 本变更 proposal / spec delta / tasks

## 6. 后续（未完成，明确移交）

- [x] 6.1 SMART 采集改为「每盘一个 collector Pod」（控制面按 NodeDisk 创建、申请 `hlvm.io/disk: 1`）
  - 实现：`control-plane/internal/controller/disk_collector_controller.go`（生命周期 + 孤儿回收 + 盘位保护）
    + `agent/src/reporter` 的 `HLVM_EXPORTER_DEVICE=auto`（枚举容器内实际可见块设备）。
  - 实测（2026-10-30 kind 1.36，`verify-collector` 7 断言全 PASS）：Pod 申请 1 块盘、`privileged:false`、
    未挂宿主 `/dev`、Ready、`/metrics` 有盘级序列、删除 NodeDisk 后 Pod 被主动回收。
  - 两个必须记住的事实：① **分到哪块盘由 kubelet 决定**，`spec.deviceRef` 只是意图——实测声明 `/dev/sda`
    却拿到 `sdb`，因此采集侧按实际设备名打标，硬编码 `deviceRef` 会把读数标错盘；
    ② NodeDisk 是 Cluster-scoped、Pod 是 namespaced，**不能设 ownerReference**（跨作用域会被 GC 立即删除），
    回收由控制器在 NodeDisk 删除的 NotFound 分支全量比对完成。
  - 边界：kind 的 virtio 盘不支持 SMART，健康值走文档化回退（`0`，与真的健康不可区分）；真实盘数值仍待验。
- [ ] 6.2 真实节点验证 by-id 路径（kind 无 udev，本次只覆盖回退分支）
- [ ] 6.3 设备热插拔的 ListAndWatch 增量验证（需真实可插拔硬件）
- [x] 6.4 容量上限与回收（本轮在 kind 内补验）
  - `verify-device-plugin` 新增 3 条：申请数=盘位时全部 Running；再多申请一个必须 Pending
    （事件 `Insufficient hlvm.io/disk`）；释放一个盘位后它必须转 Running。
  - **关键认知**：扩展资源的 `status.allocatable` 是**静态上限**，kubelet 不因分配而扣减
    （记账在调度器）。第一版按「allocatable 变小」写断言，实测占用期间仍是 2——断言本身错了，
    判断容量是否真的被消耗只能靠「超发被拒」。
- [ ] 6.5 目标集群上确认 `hlvm.io/disk` 与调度器的 NodeAffinity/拓扑、节点扩容缩容、
  以及 kubelet 重启后 device plugin 重新注册与 checkpoint 恢复行为（kind 单节点无法覆盖）
