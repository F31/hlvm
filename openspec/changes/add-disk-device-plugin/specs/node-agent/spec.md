# node-agent 规格 Delta

## ADDED Requirements

### Requirement: 按盘设备分配（Device Plugin）

平台 SHALL 以 Kubernetes Device Plugin（v1beta1）把每块**非系统整盘**作为扩展资源 `hlvm.io/disk`
暴露给 kubelet，使 Pod 可在**非特权**前提下获得指定磁盘的访问权；插件 SHALL NOT 要求
`privileged`，且 SHALL NOT 读取磁盘内容（不承担预检与 SMART 判定）。

#### Scenario: 非特权 Pod 按盘读取
- **WHEN** 一个 `privileged: false` 的 Pod 申请 `hlvm.io/disk: 1`
- **THEN** kubelet 只把被分配的那块设备节点注入容器并写入其 devices cgroup 允许列表，Pod 可打开该设备

#### Scenario: 未申请则无权限
- **WHEN** 同样非特权的 Pod 挂载宿主 `/dev` 但未申请 `hlvm.io/disk`
- **THEN** 打开设备返回 `EPERM`（devices cgroup 未放行），证明授权来自按盘分配而非环境默认

#### Scenario: 系统盘不被暴露
- **WHEN** 某整盘承载宿主根/boot/kubelet 数据目录（经宿主 mountinfo 或 lsblk 挂载点判定）
- **THEN** 该盘 SHALL NOT 出现在可分配设备列表中

### Requirement: 插件注册的自我恢复

设备插件 SHALL 在 kubelet 重启（`kubelet.sock` 被重建）后自动重新注册，SHALL NOT 要求重启 Pod；
注册失败 SHALL 重试并记录原因，SHALL NOT 以退出码 0 静默空转。

#### Scenario: kubelet 重启后自动重注册
- **WHEN** kubelet 重启导致 `kubelet.sock` inode 变化
- **THEN** 插件在下一轮探测（≤5s）内重新 Register，节点重新出现 `hlvm.io/disk` 可分配量

### Requirement: 设备插件保持非特权

设备插件 SHALL 以 `privileged: false`、`drop ALL`、`seccompProfile: RuntimeDefault`、只读根文件系统运行；
它是「按盘最小授权」的载体，SHALL NOT 以特权换便利。若插件读设备失败，正确修法是核对挂载与属主/文件权限，
而不是提升特权。

#### Scenario: 清单防回归
- **WHEN** 清单被改成 `privileged: true`
- **THEN** 清单级测试失败（`TestDevicePluginDaemonSetIsNonPrivileged`）

## 边界（本变更不解决的部分，避免规格被过度解读）

- Agent 仍为 `privileged: true`：它需要对**本节点全部盘**执行 wipe/pvcreate，而扩展资源只能表达
  「申请 N 块」。
- Exporter 的 SMART 采集仍受限于「DaemonSet 无法表达本节点全部盘」；正解是每盘一个 collector Pod
  （后续变更）。设备插件只提供该模式所需的分配能力。
- 插件不提供 SMART 健康：`Device.Health` 恒为 `Healthy`；健康判定仍在 agent/exporter。
