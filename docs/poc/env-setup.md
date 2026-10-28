# POC 环境搭建（设计 §10 阶段 0 / add-poc-decision-gate §1）

> 本文件给出 ≥3 节点 POC 集群的搭建与 TopoLVM 集成验证步骤。**命令需在真实集群执行**，本仓库仅结构化交付脚本与清单；实测结果填入 `poc-report.md`。
> 标注「移交集成」的步骤需具备 ≥3 节点裸金属/带本地盘虚拟机环境。

## 1. 集群与 K8s 版本核实（§1.1）

```bash
# 节点数与版本
kubectl get nodes -o wide
kubectl version --short

# 核实 POC 依赖的 K8s 特性支持（设计【待核实】第 3 项）：
#  - matchConditions：ValidatingAdmissionPolicy 的 CEL matchConditions（1.30+ GA）
#  - ValidatingAdmissionPolicy：admissionregistration.k8s.io/v1（1.30+）
#  - Scheduling Gate / PodSchedulingReadiness：1.26+，TopoLVM scheduler 依赖
kubectl api-versions | grep -E "admissionregistration|storage"
```

**记录**：K8s 版本、上述特性可用性 → 填入 `poc-report.md` §1.1 与 `adr/003-version-matrix.md`。

## 2. 上游 TopoLVM 安装（§1.2）

```bash
# 官方 Helm（以 TopoLVM 0.20.x 为例，须以官网为准）
helm repo add topolvm https://topolvm.github.io/topolvm
helm repo update

# 渲染并审查（确认 provisioner 参数键 topolvm.io/device-class、目标版本）
helm show values topolvm/topolvm --version 0.20.x > topolvm-values.yaml
helm template topolvm/topolvm --version 0.20.x -n topolvm-system > topolvm-render.yaml

# 安装
helm install topolvm topolvm/topolvm --version 0.20.x -n topolvm-system --create-namespace \
  --set controller.metrics.bindAddress=:8080

# 核实 provisioner 与 StorageClass
kubectl get storageclass
kubectl get pods -n topolvm-system
```

**记录**：TopoLVM 目标版本、`topolvm.io/device-class` 键、StorageClass 列表 → `adr/003-version-matrix.md`。

## 3. lvmd 热加载与调度现状（§1.3）

```bash
# lvmd 配置热加载能力：TopoLVM 0.20 的 lvmd 是否支持 SIGHUP/文件 watch 重载（设计 §2.1 待核实）
# 核查 lvmd 文档与进程信号处理；若不支持热加载，记录为「需滚动重启 lvmd」。
kubectl -n topolvm-system exec <lvmd-pod> -- ps aux | grep lvmd

# scheduler-extender 与 CSIStorageCapacity 现状
kubectl get pods -n topolvm-system -l app.kubernetes.io/component=scheduler
kubectl get csinode -o wide   # CSIStorageCapacity 由 external-provisioner 上报
```

**记录**：热加载结论、调度组件现状 → `poc-report.md` §1.3。

## 4. 本地盘准备

POC 节点需有**未分区、未使用的裸盘**（系统盘不可用于存储池）。用 `lsblk`/`blkdiscard` 清理待测盘，确保 agent 预检规则（设计 §3.1）可通过（无 fs/LVM/md 签名、非系统盘）。
