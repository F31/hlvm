# M15 集成验收 Runbook

> 配套脚本：`scripts/m15-integration.sh`；跟踪变更：`openspec/changes/m15-integration/`；M14 收尾背景：`docs/M14-closure.md`。
>
> **诚实边界**：本 runbook 把 19 项递延需求拆成「kind / 本地脚本可自动化」与「必须真实 LV、Velero、评审灰度」两类。脚本只覆盖前者，**不得**用脚本通过代替 §B 的真实验收。

## 1. 环境前置

| 组件 | 最低要求 | 说明 |
|------|----------|------|
| kubectl | v1.36.x | 与目标集群对齐，消 envtest 1.33 版本差 |
| kind | v0.32.x | 节点镜像 `kindest/node:v1.36.1` |
| docker | daemon 可用 | 构建 `storage-controller` / `storage-webhook` 镜像 |
| helm | v3.14+ | 安装 cert-manager（v1.17.x） |
| LVM 工具 | lvm2 / dmeventd / smartctl | **仅 §B 真实硬件验收需要** |
| Velero | v1.14 | **仅 backup-restore 闭环需要** |

## 2. 快速开始

```bash
# 只读前置检查（不改动集群，也不切换 kubeconfig context）
bash scripts/m15-integration.sh check

# 复用/创建 kind 集群 + 安装 cert-manager + apply CRD/命名空间/RBAC/证书/webhook/manager
bash scripts/m15-integration.sh bootstrap

# 用 control-plane/Dockerfile 构建两镜像并 kind load（:latest 默认 Always，脚本会 patch 为 IfNotPresent）
bash scripts/m15-integration.sh build

# admission 4.3 可自动化部分：验证锁标签 nodeAffinity 注入链路
bash scripts/m15-integration.sh verify-admission

# VG controller 端到端：删盘保护阻塞写 pendingOps、vgcreate 下发、解除意图后清空
bash scripts/m15-integration.sh verify-controller

# lvmd ConfigMap 聚合语义（ADR-005）：多 VG 聚合/排序/无可用 class 时撤 CM/篡改自愈/删除收敛/GC
bash scripts/m15-integration.sh verify-lvmd

# StorageTask 归属与回收（ADR-006）：NodeVG/NodeDisk ownerReference + 删拥有者后 GC 回收
bash scripts/m15-integration.sh verify-taskgc

# StorageTask 执行窗口（spec.ttl）：到期失败关闭 / 窗口内不误杀 / 非法值失败关闭
bash scripts/m15-integration.sh verify-ttl

# 一键（check → bootstrap → build → verify-admission → verify-controller → verify-lvmd → verify-taskgc → verify-ttl）
bash scripts/m15-integration.sh all
```

可覆盖的环境变量：`CLUSTER_NAME`、`NODE_IMAGE`、`IMG_REGISTRY`、`IMG_TAG`、`CERT_MANAGER_VERSION`、`LOCK_TIER`。

## 3. §A：kind / 本地可自动化覆盖

| 项 | 验证内容 | 诚实结论 |
|----|----------|----------|
| admission-scheduling 4.3（动态层 · 注入链路） | `verify-admission` 检查 `MutatingWebhookConfiguration.caBundle` 是否被 cert-manager 注入；创建平台 SC（`provisioner: topolvm.io`、`topolvm.io/device-class: <tier>`）+ PVC + 引用该 PVC 的 Pod，断言 Pod 被注入 `storage.example.io/<tier>-locked NotIn ["true"]` 的 nodeAffinity | **只证明 mutation 注入生效**。kind 无 TopoLVM CSI，PVC 不绑定、Pod 不会真正调度；「新 Pod 排除 locked 节点、已有 Pod 不受影响」的**调度级**结论仍需真 CSI/LV 环境复验 |
| admission-scheduling 4.2（VAP 静态层） | M14 已在 kind 1.36 验证：`validationActions` 强制、CEL `has()` 空值防御；可重跑 `kubectl apply -f control-plane/config/webhook/validatingadmissionpolicy.yaml` 并做负向测试 | 静态层已验收；非本脚本重复项 |
| capacity-governance 4.2（locked 流转） | 已由 envtest 覆盖（`go test ./internal/controller -run Envtest`，含标签联动、metadata 独立阈值、滞回解锁） | envtest 验收；kind 无 LVM 不做重复 |
| VG controller 端到端（删盘保护 / 任务下发 / 幂等） | `verify-controller` 创建 `pooled + md-raid1 + 2 盘` 的 NodeVG 并请求移除 1 盘，断言：① `status.pendingOps` 写入「冗余丧失」阻塞；② 下发 `vgcreate` StorageTask；③ **不**下发 `vgreduce`；④ 解除 `removeDisks` 后 `pendingOps` 清空 | **controller 运行时链路已验收**（同时反证 controller 注册名唯一性与 RBAC 修复有效——若缺 `nodedisks` list 权限，Reconcile 直接失败、pendingOps 不会写入）。不含真实 `vgcreate/vgreduce` 执行，那由 agent + 真实 LV 承担 |
| lvmd ConfigMap 聚合（ADR-005） | `verify-lvmd` 建同节点两个 VG（tier=data/metadata）→ 断言聚合为两个 device-class 且按名升序、两个非 controller ownerRef；断言 `vgExists=false` 窗口期**不**写 `device-classes: []`（lvmd 拒绝空列表），且已存在的托管 CM 会被撤销、恢复后重建；篡改 CM 断言自愈；加 `deviceClassName=cold` 断言生效；删一个 VG 断言收敛；删最后一个断言 CM 被 GC | **聚合与生命周期已验收**（自愈 1s、收敛 2s、GC 2s；空列表撤销与重建）。`vgExists` 用 `--subresource=status` 手工置真以模拟 agent 上报；**空列表被 lvmd 拒绝**为上游源码结论（`ValidateDeviceClasses`），真实 lvmd 运行行为仍需目标环境复验 |
| StorageTask 归属与回收（ADR-006） | `verify-taskgc` 建 NodeVG（2 盘、`vgExists=false`）→ 断言下发 `vgcreate` 任务且持有 NodeVG 的 ownerReference（Kind/Name/**UID 一致**、`controller=false`）→ 删除 NodeVG 断言任务被 GC；再用 NodeDisk（adopt+byId+Discovered）验证 `pvcreate` 任务归属与删除后 GC | **两条拥有者路径均已验收**（NodeVG 2s、NodeDisk 1s） |
| StorageTask 执行窗口（ADR-006 补遗） | `verify-ttl`：`ttl=2s` → 断言 phase=Failed 且 result 以 `DeadlineExceeded` 开头、对象保留；`ttl=1h` 观察 8s 断言未被改写；`ttl=nonsense` 断言失败关闭 | **控制面侧已验收**。agent 侧执行前复核未实现（无 Rust 工具链），存在轮询窗口竞态 |

## 4. §B：必须真实 LV / 外部依赖 / 流程（不可用脚本伪造）

### 4.1 observability（已归档，2 项）

| 项 | 依赖 | 验收方法要点 |
|----|------|--------------|
| 4.1 告警延迟演练 | 真实 LV、Prometheus/Alertmanager、agent | thinpool 打满 / 拔盘 / kill agent 三类故障；核对告警触发时间戳：Critical ≤ 1min、Warning ≤ 5min |
| 4.2 指标口径核对 | 真实 LV | `vgs --units b --nosuffix -o vg_name,vg_size,vg_free`、`lvs -o lv_name,data_percent,lv_size` 与 exporter 指标对账；口径冲突以实测为准 |

### 4.2 capacity-governance（已归档，4 项）

| 项 | 依赖 | 验收方法要点 |
|----|------|--------------|
| 2.2 灰度 + 滚动重载 | 测试集群 | 控制器配置变更灰度发布，验证滚动重载不中断在飞变更 |
| 3.1 dmeventd 第一防线 | 真实 LV + dmeventd | 配 `thin_pool_autoextend_threshold=80`、`thin_pool_autoextend_percent=20`；越线后 ≤30s 完成 autoextend |
| 4.3 thinpool 打满演练 | 真实 LV | 写满 thinpool → 验证 `CapacityStatus=Locked`、节点标签 `storage.example.io/<tier>-locked=true`、PVC 准入拒绝、告警链路 |
| V.2 打满演练通过 | 真实 LV | 同 4.3，作为发布门禁记录 |

### 4.3 backup-restore（活跃，2 项）

| 项 | 依赖 | 验收方法要点 |
|----|------|--------------|
| 2.2 块/文件系统一致性 | 测试集群 + Velero + 业务负载 | 有 / 无 pre-hook（见 `control-plane/config/backup/02-mysql-prehook.yaml`）的恢复结果对比 |
| 5.1 完整闭环 | 测试集群 + Velero + 对象存储 | 备份 → 删除 PVC/PV → 恢复 → 应用侧数据校验 → 记录 RTO/RPO |

### 4.4 hardening-rollout（活跃，5 项）与 poc-decision-gate（活跃，5 项）

演练报告、fio 实测评审、灰度期问题闭环与放量决策、上线评审门禁、POC 实测与 ADR 评审——**流程项，非脚本可自动化**，需按各自 `tasks.md` 逐项执行并归档证据后回填。

## 5. 回填规则（验收通过后）

1. **活跃变更**：在 `openspec/changes/<change>/tasks.md` 对应项原地改 `[x]`。
2. **已归档变更**：在 `openspec/changes/archive/2026-10-29-<change>/tasks.md` 改 `[x]`（归档不改变验证责任）。
3. **跟踪变更**：同步勾 `openspec/changes/m15-integration/tasks.md`。
4. 全部通过后 `openspec archive m15-integration`。

> 纪律：**未真实执行并留存证据的项，一律不得 tick。**

## 6. 已知限制与风险

- **版本差**：envtest 固定 1.33，目标集群 1.36；M14 已因该差异暴露 VAP `validationActions` 缺失与 CEL null 缺陷。
- **kind 无 CSI/LVM**：不能替代真实调度与硬件验收（见 §3 诚实结论列）。
- **镜像可达性**：GHCR 包可能为私有；kind 内优先 `kind load docker-image`，生产需 `imagePullSecret`。
- **cert-manager 网络依赖**：离线环境需预置 chart 与镜像。
- **agent 未部署**：kind 环境默认不部署 `storage-agent`，orphan-gc / drift-detector 的 lvs 三方对账无法启用。
- **lvmd ConfigMap 聚合语义（已由 ADR-005 修复，2026-10-29）**：`hlmd-lvmd-<node>` 现由该节点**全部** NodeVG
  聚合渲染（`device-classes` 数组、按名稳定升序），只含 `status.vgExists=true` 的 VG；`spec.deviceClassName`
  可显式命名（缺省回退 tier），重名返回错误而非写入非法配置。ConfigMap 持有每个同节点 VG 的**非 controller**
  ownerReference，控制器用 `Owns(&ConfigMap{}, builder.MatchEveryOwner)` 注册 watch
  （v0.20 默认 `OnlyControllerOwner()`，不显式传则多 owner 不触发）。实测：篡改 1s 内自愈、删一个 VG 2s 内收敛、
  删最后一个 VG 后 2s 由 GC 回收。详见 `docs/poc/adr/005-lvmd-config-aggregation.md`。
  **空 device-class 已定案（2026-10-29，源码 + 运行态双重验证）**：TopoLVM lvmd 的 `ValidateDeviceClasses`
  对空列表直接报错（`should have at least one device-class`），且在启动路径上 `return err`；kind 内以真实
  lvmd 0.42.0 运行确认：配置加载后立即 `Error: should have at least one device-class` 并以 exitCode=1 退出。
  lvmd 自身无配置热加载（仅处理 SIGTERM/Interrupt）。因此 `AggregateLVMDConfig` 在节点无可服务 VG 时返回
  `ok=false`，控制器**删除托管 ConfigMap**（不再写 `device-classes: []`），使「ConfigMap 存在」等价于
  「该节点可服务」。详见 ADR-005 补遗。仍需真实环境验证：删除 CM 后 agent/lvmd 的实际表现、
  「class 指向不存在 VG」的运行态行为（kind 内 lvmd 因 nsenter 权限在 ListVolumeGroups 阶段退出）、热加载。
- **StorageTask 归属（已修复，2026-10-29，ADR-006）**：任务现持有 `NodeVG`/`NodeDisk` 的**非 controller**
  `ownerReference`（`controller=false`、`blockOwnerDeletion=false`），拥有者删除后由 K8s GC 回收；
  既消除孤儿堆积，也阻断「对已删除对象继续下发 wipe/vgcreate」。kind 实测（`verify-taskgc`）：
  NodeVG 路径 ownerReference UID 一致、删除后 2s 内 GC；NodeDisk 路径（pvcreate）UID 一致、删除后 1s 内 GC。
- **StorageTask 执行窗口（已实现，2026-10-29，ADR-006 补遗）**：`spec.ttl` 对齐 K8s Job 的
  `activeDeadlineSeconds`——自 `creationTimestamp` 起算，只拦截**尚未开始**（phase 空/Pending）的任务；
  到期标记 `Failed`（`Result` 前缀 `DeadlineExceeded:`）并**保留对象**，不自动重试；TTL 非法或 `<=0` 时
  **失败关闭**（拒绝执行）。`Running`/`Unknown` 的任务不被改写（单写者：结果由 agent 收敛）。
  kind 实测（`verify-ttl`）：`ttl=2s` 3s 内标 Failed；`ttl=1h` 8s 内未被改写；`ttl=nonsense` 失败关闭。
  **残余竞态**：agent 走轮询 list，若在控制面标记前已取走任务仍可能执行一次；彻底关闭需 agent 执行前复核
  `creationTimestamp + ttl`——当前环境无 Rust 工具链（`cargo` 不可用），该改动无法编译验证，未写入 agent。
- **本轮验证暴露并修复的两个部署期缺陷（envtest/单测均不覆盖）**：
  1. ClusterRole 缺 `storagetasks/status` 更新权限 → TTL 到期标记与结果回写持续 403
     （日志：`cannot update resource "storagetasks/status" ... forbidden`），任务永远停在 Pending；
  2. StorageTask CRD 缺 `subresources.status` → `/status` 请求 404，**agent 的 patch_status 回执链路
     （设计 §3.4 单写者）实际不可用**；此前因无 agent、无状态写入而未被发现。
  两者均已修复，并新增 `internal/controller/deploy_manifests_test.go` 做清单级防回归
  （CRD 必须声明 status 子资源；ClusterRole 必须授予 `storagetasks/status` update）。

## 7. 故障排查

### 7.1 kind 节点拉取镜像失败（`proxyconnect tcp: dial tcp 127.0.0.1:...`）

**现象**：cert-manager Pod 处于 `ImagePullBackOff`，事件形如
`proxyconnect tcp: dial tcp 127.0.0.1:7890: connect: connection refused` 或 `i/o timeout`。

**原因**：`HTTP(S)_PROXY` 指向 `127.0.0.1`。在 WSL / kind 节点容器内，`127.0.0.1` 是节点自身，不是宿主机代理端口；`ip route` 的默认网关（本机为 `10.0.0.129`）也不是 Windows 宿主，7890/7892 在该地址均不可达。

**已实测可行的方案**（2026-10-29）：在 WSL host 上把可用的 `127.0.0.1:7890` 暴露到 docker0 网关，kind 节点经 `172.17.0.1:17890` 走代理。

```bash
# 1) 确认 WSL 内 127.0.0.1:7890 可用（应返回 401，表示可达）
curl -sS -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code}\n' https://quay.io/v2/

# 2) 在 WSL host 起 TCP 转发：0.0.0.0:17890 -> 127.0.0.1:7890
python3 scripts/wsl-proxy-fwd.py

# 3) 验证节点可达（应返回 401）
docker exec hlvm-kind-control-plane \
  curl -sS -x http://172.17.0.1:17890 -o /dev/null -w '%{http_code}\n' https://quay.io/v2/

# 4) 用 172.17.0.1:17890 重建集群（docker0 网关稳定，不随 kind 网络重建变化）
HTTP_PROXY=http://172.17.0.1:17890 HTTPS_PROXY=http://172.17.0.1:17890 \
http_proxy=http://172.17.0.1:17890 https_proxy=http://172.17.0.1:17890 \
NO_PROXY="localhost,127.0.0.1,::1,10.96.0.0/12,10.244.0.0/16,.svc,.cluster.local,172.17.0.0/16,172.20.0.0/16" \
  kind create cluster --name hlvm-kind --image kindest/node:v1.36.1
```

**docker build 的额外坑**：WSL 的 docker daemon 代理可能被配置为 `127.0.0.1:7892`（无监听）。
- 若基础镜像已本地缓存，构建不会触发拉取；
- `go mod download` 需网络，脚本会把 `HTTP_PROXY/HTTPS_PROXY/NO_PROXY` 作为 build-arg 透传；
- 该代理在并发下载时会截断（`unexpected EOF`），Dockerfile 已用 BuildKit cache mount
  （`/go/pkg/mod`、`/root/.cache/go-build`）使重试收敛；
- 无法拉取 distroless 时，用 `RUNTIME_IMAGE=<已缓存镜像>` 覆盖运行态基础镜像（仅本地验证）。

### 7.2 集群重启后控制面全部失联（`kube-proxy` CrashLoop，`10.96.0.1:443` 超时）

**现象**：Docker Desktop / kind 节点容器重启后，`kubectl`（宿主直连 6443）正常，但
`hlvm-storage-controller`、`webhook`、`coredns` 全部无法访问 `https://10.96.0.1:443`，
日志持续 `context deadline exceeded`；所有 `verify-*` 断言同时失败（看起来像代码回归，实为集群故障）。
控制器日志只有 leader election 超时，`verify-taskgc` 报「未下发 vgcreate 任务」。

**根因**：`kube-proxy` 反复重启，日志
`"command failed" err="failed complete: too many open files"` —— 宿主机/VM 的
`fs.inotify.max_user_instances`（默认 128）被同机其它容器耗尽，kube-proxy 无法建立
Service 规则，ClusterIP `10.96.0.1` 因此不可达（`kubectl` 走 kubeconfig 的宿主地址不受影响）。

**处理**（2026-10-29 实测有效）：

```bash
# 1) 提高 inotify 限制（在 kind 节点容器内生效，作用于同一内核/用户命名空间）
docker exec hlvm-kind-control-plane sysctl -w \
  fs.inotify.max_user_instances=2048 fs.inotify.max_user_watches=1048576

# 2) 重建 kube-proxy 与 CoreDNS
kubectl --context kind-hlvm-kind -n kube-system delete pod -l k8s-app=kube-proxy
kubectl --context kind-hlvm-kind -n kube-system delete pod -l k8s-app=kube-dns

# 3) 断言恢复：kube-proxy 1/1、coredns 1/1，lease 的 renewTime 持续刷新
kubectl --context kind-hlvm-kind -n kube-system get pods | grep -E 'kube-proxy|coredns'
kubectl --context kind-hlvm-kind -n hlvm-system get lease hlvm-storage-controller -o yaml | grep -E 'holderIdentity|renewTime'
```

**判读要点**：`kubectl` 能连 ≠ 集群内可达。区分方法是看**控制器自己的日志**（只有 leader election
超时、无 reconcile 报错）与 `kube-system` 的 `kube-proxy` 状态；不要先怀疑刚改的代码。
