# M15 集成验收 Runbook

> 配套脚本：`scripts/m15-integration.sh`；跟踪变更：`openspec/changes/m15-integration/`；M14 收尾背景：`docs/M14-closure.md`。
>
> **诚实边界**：本 runbook 把 19 项递延需求拆成「kind / 本地脚本可自动化」与「必须真实 LV、Velero、评审灰度」两类。脚本只覆盖前者，**不得**用脚本通过代替 §B 的真实验收。

## 1. 环境前置

| 组件 | 最低要求 | 说明 |
|------|----------|------|
| kubectl | v1.36.x | 与目标集群对齐；envtest 已同步升级到 1.36.2（见 `ENVTEST_K8S_VERSION`） |
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

# 节点 Agent 真机验证：SA/RBAC 可解析、节点名注入、任务状态回写、NodeDisk 观测写回
# 磁盘设备插件验证：kubelet 注册、节点可分配量、非特权 Pod 按盘读取（含未授权对照）
# 每盘 collector 验证：NodeDisk → 单盘非特权 Pod → /metrics 盘级序列 → 删除后回收
# kubelet 重启验证：插件自愈重注册、运行中容器不重建、checkpoint 恢复后不重复分配（kind 限定）
# 本机无 Rust 时用容器内 rust:slim 构建（首次拉 1.3GB 镜像；走代理则加 AGENT_BUILD_PROXY）
AGENT_BUILD_PROXY=http://172.17.0.1:17890 bash scripts/m15-integration.sh verify-agent
AGENT_BUILD_PROXY=http://172.17.0.1:17890 bash scripts/m15-integration.sh verify-device-plugin
bash scripts/m15-integration.sh verify-collector
bash scripts/m15-integration.sh verify-kubelet-restart
# CRD 双版本 + conversion webhook（会临时改写 NodeDisk CRD，结束自动恢复单版本）
bash scripts/m15-integration.sh verify-conversion
# storedVersions 切换与回滚（破坏性：会改 CRD 的存储版本，结束自动恢复单版本）
bash scripts/m15-integration.sh verify-storage-migration

# 一键（全部 verify-* 顺序执行；conversion 与 storage-migration 放最后，它们会临时改写 NodeDisk CRD）
bash scripts/m15-integration.sh all
```

> 所有 `verify-*` 阶段自带集群兜底（节点容器停在 `Exited` 时自动 `docker start`、等待 API 就绪、
> 重试读取节点），因此可单独执行，不要求先跑 `bootstrap`。

### 2.1 在 WSL 本地环境执行（推荐）

Windows 侧与 WSL 是**两个独立的 docker daemon 与 kind 集群**（`docker ps`、`kind get clusters`
互不可见），在 Windows 侧得到的部署结论不能当作用 WSL 环境的结果；反之亦然。本仓库的部署
测试统一在 WSL 内执行。

直接在 `/mnt/e`（9p 文件系统）上跑会踩两个坑：docker build context 与「容器内 cargo 绑定挂载
编译」都慢一个量级；`HTTP_PROXY` 被 WSL 自动注入为 `127.0.0.1:7890`，而构建容器内的
127.0.0.1 是**容器自身**（详见 §7.1）。`scripts/m15-wsl.sh` 把两件事收敛成一个入口：先 rsync
工作树到 WSL ext4（`~/hlvm`），探测 docker0 网关上的代理转发器后修正构建代理，再原样转发
子命令——**不改变任何断言与阶段语义**。

```bash
# Windows / Git Bash 侧调用。MSYS_NO_PATHCONV=1 防止 /mnt/e 被 MSYS 改写成 E:/
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu24.04LTS -- \
  bash /mnt/e/projects/hlvm/scripts/m15-wsl.sh all

# 单个阶段同样可用
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu24.04LTS -- \
  bash /mnt/e/projects/hlvm/scripts/m15-wsl.sh verify-device-plugin
```

| 环境变量 | 默认 | 作用 |
|----------|------|------|
| `HLVM_WSL_SRC` | `/mnt/e/projects/hlvm` | Windows 侧工作树 |
| `HLVM_WSL_DST` | `$HOME/hlvm` | WSL 内构建目录（ext4） |
| `HLVM_WSL_NO_SYNC` | 未设 | 设 `1` 跳过同步，直接跑已有副本 |
| `HLVM_CONTAINER_PROXY` | `http://172.17.0.1:17890` | 容器可达的代理地址 |
| `HLVM_KEEP_PROXY` | 未设 | 设 `1` 不修正 `HTTP_PROXY` |

**审计日志要把两个流分开**：脚本自身输出走 stdout（块缓冲），docker build 进度走 stderr
（无缓冲），合并重定向时阶段标题会被构建输出插断，看起来像「阶段没跑」——实测现象，不影响
断言结果与退出码。

```bash
... m15-wsl.sh all > out.log 2> err.log; echo "EXIT=$?"
grep -c 'PASS' out.log; grep -c 'FAIL' out.log   # 断言结果都在 stdout（fail_msg）
grep -E '^\[error\]' err.log                    # 阶段级致命原因仍在 stderr
```

> 断言失败曾用 `warn` 写 stderr，导致 `grep FAIL out.log` 恒为 0——真失败也会「看起来全绿」。
> 已改为 `fail_msg` 写 stdout；结论仍以**退出码**为准。

**已验证**（2026-10-30，WSL2 Ubuntu 24.04 / Docker 29.4.1 / kind 1.36.1）：`all` 连续 4 次
exit 0，最新一次 **84 PASS / 0 FAIL**，18 个阶段标题齐全（`check` 的 4 个子步骤 + `build` + 11 个 `verify-*`
阶段 + WSL 包装层的 2 条）；代理修正另
以 `--no-cache-filter=builder` 强制失效缓存验证（`go mod download` 真实联网 37.3s、编译 19.2s）。

WSL 内没有 Go / Rust 工具链也不影响：单测在容器里跑同样可行（模块与 cargo 缓存放命名卷）。
以下命令**在 WSL shell 内**执行（`wsl -d Ubuntu24.04LTS` 进入后再跑，`$HOME` 才会展开；
从 Windows 侧经 `wsl.exe` 直调时 `~` 不会被展开，需写成绝对路径）。

```bash
# Go：vet + 单测（envtest 用例在无 KUBEBUILDER_ASSETS 时自行 skip；envtest 请用 make test-envtest）
docker run --rm --network bridge \
  -e HTTP_PROXY=http://172.17.0.1:17890 -e HTTPS_PROXY=http://172.17.0.1:17890 \
  -v "$HOME/hlvm:/src" -w /src/control-plane -v hlvm-gomod:/go/pkg/mod \
  golang:1.24-bookworm sh -c 'go vet ./... && go test ./...'

# Rust：全部测试目标
docker run --rm \
  -v "$HOME/hlvm/agent:/src" -w /src -e CARGO_TARGET_DIR=/target \
  -v hlvm-cargo-target:/target -v hlvm-cargo-registry:/usr/local/cargo/registry \
  rust:slim cargo test --all-targets
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
| StorageTask 执行窗口（ADR-006 补遗） | `verify-ttl`：`ttl=2s` → 断言 phase=Failed 且 result 以 `DeadlineExceeded` 开头、对象保留；`ttl=1h` 观察 8s 断言未被改写；`ttl=nonsense` 断言失败关闭 | **控制面侧已验收**；agent 侧执行前复核已补（`common::ttl`，见 §6） |
| 磁盘设备插件（`hlvm.io/disk`，K8s Device Plugin v1beta1） | `verify-device-plugin`：断言 ① 节点 `status.allocatable.hlvm.io/disk > 0`；② 申请 1 块盘的**非特权** Pod（uid0 / `privileged:false` / drop ALL）能读该设备；③ 同样非特权、挂 hostPath `/dev` 但**不申请**的对照 Pod 读设备得 `EPERM` | **按盘分配链路已验收**（kubelet 注册 + ListAndWatch + devices cgroup 放行）。kind 节点无 `/dev/disk/by-id`（无 udev），设备 ID 走 `dev-<name>` 回退；**SMART 仍不可采**（插件非特权不读盘），exporter 的指标缺口未由本项关闭（见 §8 边界） |
| 每盘 collector（SMART 采集闭环） | `verify-collector`：建 NodeDisk → 断言 ① controller 创建 collector Pod 且申请 `hlvm.io/disk: 1`；② `privileged:false` 且**未**挂宿主 `/dev`；③ Pod Ready（readinessProbe 即 `/metrics`）；④ `/metrics` 含心跳与盘级 SMART 序列；⑤ 删除 NodeDisk 后 Pod 被主动回收；⑥ NodeDisk 多于盘位时不超额创建 Pod | **授权链路 / 指标端点 / 生命周期 / 盘位保护已验收**（3 个 NodeDisk、2 个盘位时只生成 2 个 Pod）。kind 的 virtio 盘不支持 SMART，健康值走文档化回退（`Healthy`）；「SMART 数值正确」仍需真实盘 |
| kubelet 重启后的自愈与 checkpoint 恢复（6.5 的 kind 部分） | `verify-kubelet-restart`：`docker exec <cluster>-control-plane systemctl restart kubelet` 后断言 ① socket 重生且 T0 之后出现**新**注册日志（60s 内）；② `allocatable` 恢复；③ 运行中 Pod 的 `containerID` 不变；④ 插件 Pod 未被重建（进程级自愈）；⑤ checkpoint 仍记录原 Pod 的分配；⑥ 新申请拿到**另一块盘**（不重复分配） | **自愈与 checkpoint 恢复已在 kind 验证**（自愈 2–4s）。真实集群的 kubelet 重启方式（节点池滚动 / 排水）、调度器拓扑与扩缩容仍未覆盖 |

| CRD 双版本与 conversion webhook（hardening 3.1b） | `verify-conversion`：先起转换服务再开双版本 CRD，断言 ① Deployment 2 副本就绪；② serving 证书由 cert-manager 签发；③ CRD `conversion.strategy=Webhook` 且 caBundle 已注入；④ `preferredVersion=v1beta1`；⑤ 以 v1alpha1 写 `deviceRef=/dev/sda`，以 v1beta1 读到 `device.path=/dev/sda`；⑥ v1beta1 视图不含 `deviceRef`；⑦ 以 v1beta1 写 `/dev/sdb`，v1alpha1 读回同名值；⑧ 列表两版本条目数一致；⑨ **把 webhook 缩到 0 后 v1beta1 读失败、v1alpha1 仍可读**（证明转换真依赖 webhook 且爆炸半径受限）；⑩ 恢复副本后自愈 |
**已覆盖**：协议、字段映射、证书/caBundle 接线、依赖关系。**未覆盖**：storedVersions 切换（需迁移方案）、真实证书过期演练、其余 4 个 Kind 的版本化 |

| storedVersions 切换与回滚（hardening 3.1b 尾巴） | `verify-storage-migration`：etcd 直读判定存储版本，断言 ① 转换服务就绪；② **schema 护栏**（v1alpha1 字段路径在 v1beta1 都有对应，仅 `deviceRef` 有意演进）；③ 切换前对象以 v1alpha1 落盘；④ 切存储成功；⑤ **storedVersions 已含 v1beta1 而对象字节仍 v1alpha1**（判据陷阱）；⑥ 迁移期老客户端新建的对象自动以 v1beta1 落盘（不必停写）；⑦ 重写后存量对象以 v1beta1 落盘；⑧ spec 规范化一致 + status 逐字段相等；⑨ **webhook 下线后连 v1alpha1 也读不了**（爆炸半径扩大）；⑩ 恢复后自愈；⑪ **K8s 拒绝在 storedVersions 未清理时移除 v1beta1**；⑫ 清 storedVersions 后两版本仍可读写；⑬ 回滚 storage 后对象仍 v1beta1 落盘但两版本可读；⑭ 回滚后重写才回到 v1alpha1 落盘；⑮ 收尾干净 | **切换与回滚均已在 kind 验证**（15 断言）。真实数据量、多 apiserver 副本的转换行为、其余 4 个 Kind 未覆盖 |

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

- **版本差（已消除，2026-10-29）**：envtest 由 1.33.0 升到 **1.36.2**（与 kind `kindest/node:v1.36.1` 同 minor），
  并接入 CI 门禁（`make test-envtest`）。升级后立即暴露两类**此前只在本机偶发、CI 完全看不到**的测试缺陷，
  均已修复：① controller-runtime 的 controller 名称唯一性检查是**进程级全局集合**
  （`pkg/controller/name.go` 的 `usedNames`，manager 销毁不清理），多个 envtest 同进程会报
  `controller with name nodedisk already exists`，测试侧统一用 `newEnvtestManager` 跳过该校验；
  ② 测试用 `mgr.GetClient()`（读走缓存）写 status，新建对象在缓存同步前 `not found`，且与控制器 reconcile
  抢同一对象报 `the object has been modified`，改为直连 client + `RetryOnConflict`（`updateStatusRetry`）。
  注意 client-go 仍为 v0.33 —— 与 1.36 apiserver 通信兼容，但 SDK 侧字段滞后属独立议题。
- **kind 无 CSI/LVM**：不能替代真实调度与硬件验收（见 §3 诚实结论列）。
- **镜像可达性（2026-10-30 确证私有）**：`f31/hlvm/storage-controller` / `storage-webhook` 为**私有**——
  `ghcr.io/token?scope=repository:f31/hlvm/<pkg>:pull` 匿名请求返回 **401**
  （`{"errors":[{"code":"UNAUTHORIZED"}]}`），带 token 的 manifest 请求 403。
  `storage-agent` 此前**从未被构建/推送**（详见下条），GHCR 对不存在的包同样回 401，故其可见性
  待首次推送后复核；按同仓库同权限设置，预期同为私有。因此：
  - kind 内一律用 `kind load docker-image` + 运行时 patch `imagePullPolicy: IfNotPresent`
    （`:latest` 默认 `Always`，否则 kubelet 会回源拉私有包而失败）；
  - 真实集群部署必须提供凭据，否则 `ImagePullBackOff`：
    ```bash
    kubectl -n hlvm-system create secret docker-registry ghcr-pull \
      --docker-server=ghcr.io --docker-username=<user> --docker-password=<PAT> 
    # 然后在 manager/webhook/agent 的 podSpec 增加：
    #   imagePullSecrets: [{name: ghcr-pull}]
    ```
    仓库内清单**未内置** `imagePullSecrets`（硬引用不存在的 secret 会让 kind 流程也拉不到镜像），
    故真实集群需手工注入；另一条路是把 GHCR 包改为 public。
  - 三个清单（`control-plane/config/manager/manager.yaml`、`webhook/deployment.yaml`、
    `agent/config/daemonset-agent.yaml`）均未声明 `imagePullPolicy`，非 kind 环境按 `:latest` 语义
    会走 `Always`，改动镜像内容时属预期行为，但会放大凭据缺失的失败面。
- **CI 结果可查（2026-10-30 确证）**：此前「`images` job 结果未能确认」的记录作废——仓库
  `F31/hlvm` 的 Actions runs 与 job 明细可**匿名只读**（本机无 `gh`，用 `curl` + `api.github.com`
  即可）。HEAD `1ffb629` 的 run `40888920900`：`Go (control-plane)` / `Rust (agent)` /
  `Container images` / `Ready` **4 job 全 success**，其中 Rust job 即
  `cargo test --all-targets` 的 CI 证据，images job 在 main push 上 `push: true` 已推送两镜像到 GHCR。
  注：Windows 侧 `curl` 走系统 schannel，需加 `--ssl-no-revoke`，否则代理下报
  `CRYPT_E_REVOCATION_OFFLINE`（exit 35），容易被误判为「代理不通」。
- **agent 镜像已补建（2026-10-30）**：核对 CI 发现 images job 只构建 controller/webhook，而
  `agent/config/daemonset-agent.yaml` 与 `control-plane/config/exporter/daemonset.yaml` 都引用 agent 镜像
  ——该镜像从未产出，真实集群部署必然 `ImagePullBackOff`（本机无 Rust 链接器，无法本地补建，故一直未被发现）。
  现 rust job 上传 `hlvm-agent-bin` artifact，images job `needs: [go, rust]` 后下载并用
  `agent/Dockerfile` 构建推送 `ghcr.io/f31/hlvm/storage-agent:latest`；exporter 清单的旧名
  `ghcr.io/f31/hlvm/agent:latest`（原标注「占位」）已统一为 `storage-agent`。
  基础层是 `kindest/node:v1.36.1`（约 1GB，含 nsenter/blkid/lsblk），首次构建推送较慢，gha 缓存可复用。
- **清单镜像引用审计（2026-10-30，已闭环）**：全仓 `ghcr.io/f31/hlvm/*` 共 4 个引用，此前 CI 只覆盖 3 个
  （`storage-controller` / `storage-webhook` / `storage-agent`），`crd-conversion` 无实现。
  现已在 `control-plane/cmd/crd-conversion` 实现、CI `images` job 增加对应构建推送，
  清单 `config/hardening/03-crd-conversion.yaml` + `03b-nodedisk-dual-version.yaml` 转为可部署，
  「请勿 apply」警告已移除（但**必须按 §10.2 的顺序** apply）。验证见 §10 与 `verify-conversion`。
- **cert-manager 网络依赖**：离线环境需预置 chart 与镜像。
- **agent 已可部署并验证（2026-10-30 首次真机运行）**：`verify-agent` 阶段会构建本地镜像、apply RBAC
  与 DaemonSet、断言 **7** 条链路后**撤掉 DaemonSet**（保留 RBAC）——撤掉的原因是 `verify-ttl` 依赖
  「无 agent 时窗口内任务不被写」这一前提，常驻 Agent 会让该断言失真。因此 `all` 跑完后集群里
  **没有**常驻 agent；需要长期运行请单独 `kubectl apply -f agent/config/daemonset-agent.yaml`
  并处理私有镜像凭据（见上条）。orphan-gc / drift-detector 的 lvs 三方对账仍需真实 LV（§1.2）。
  首次真跑暴露并修复的 5 个缺陷（此前从未在集群里运行，故一直未发现）：
  1. **SA 命名空间错配**：`hlvm-agent` 建在 `kube-system`（早期 chaos 实验残留），DaemonSet 在
     `hlvm-system` → `serviceaccount "hlvm-agent" not found`，Pod 根本不会被创建；
  2. **节点名未注入**：DaemonSet 通过 Downward API 注入 `HLVM_NODE_NAME`/`NODE_NAME`，但代码只读
     `--node-name`，缺省回退 `"unknown"`；而任务过滤条件是 `spec.nodeName == node`，于是 Agent
     **表面 1/1 Running、日志正常，却永远不执行任何任务**。现按 命令行 > `HLVM_NODE_NAME` > `NODE_NAME`
     解析，缺失即失败关闭（不再静默空转）；
  3. **lsblk 字节模式解析失败**：`lsblk -J -b` 的 `size` 是 JSON **数字**（如 `407490560`），而模型声明
     `Option<String>`，导致 discovery 整体报错，日志写作「discovery 失败（非节点环境？）」极具误导性。
     现兼容数字与字符串两种形态。
  4. **「特权最小化」把数据面彻底废掉（设备 cgroup，非 capability 问题）**：按 hardening 4.1 改成
     `privileged: false` + drop ALL + add `SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO` 后，容器内 **uid=0 仍读不了
     块设备**：`dd if=/dev/loop77` / `blkid` / `wipefs` 一律 `Operation not permitted`。根因是 runc 的
     device cgroup 过滤器——非特权 Pod 的 device allowlist 为空，加 capability 绕不过去。后果是 wipe /
     pvcreate（平台唯一写路径）与签名预检全部不可用。已按 spec（agent 特权、读写）回退为
     `privileged: true`，并由 `deploy_manifests_test.go::TestAgentDaemonSetIsPrivileged` 防回归。
     若要恢复非特权，必须先有 device plugin 为每块盘做分配——**该插件已实现并验收**（§8），
     但 agent 需要「本节点全部盘」，而设备插件只能表达「申请 N 块」，故 agent 仍保持 privileged。
     **排障提示**：这类失败极隐蔽——`blkid` 的 EPERM 与「无签名」**同样以退出码 2 返回**，
     只看退出码会把「读不了」当成「干净盘」并放行纳管。现按「退出码 2 且 stderr 非空 ⇒ 探测失败」判定。
  5. **`occupiedBy` 恒为 `none`，且签名规则从未生效**：观测路径曾硬编码 `occupied_by: None`、
     `is_pv: false`、`holders: []`；同时签名探测调用的是 `blkid --json`——**blkid 没有这个选项**
     （`--json` 属于 lsblk），命令必然失败，于是「存在 fs/LVM/md 签名即拦截纳管」在生产路径上从未执行过
     （单测只直接喂解析函数，掩盖了这一点）。现改为：`blkid -o export` 探测签名、lsblk `TYPE/FSTYPE`
     辅助、`pvs` 确认 PV 归属，按 CRD 枚举写出 `filesystem|lvm-pv|md|mpath|holder|none`，
     探测失败写 `unknown` 并失败关闭。`verify-agent` 新增断言：节点内造一块 ext4 loop 设备，要求
     `occupiedBy=filesystem` 且 phase 不推进到 `PreChecked`。
  另：`agent/config/daemonset-agent.yaml` 里曾有一份 exporter DaemonSet 副本，与
  `control-plane/config/exporter/daemonset.yaml` 同名不同名、命名空间/端口/阈值 ConfigMap 均不一致，
  两者同时 apply 会在每节点起两个 exporter。已删除副本，唯一来源为 `control-plane/config/exporter/`。
  **exporter 的 SMART 缺口（采集形态已改造，数值待真实盘复验）**：exporter 按 spec 必须非特权，而同一
  设备 cgroup 限制使它读不到 SMART（`smartctl`/`nvme` 均需打开设备）。设备插件（§8）让**非特权 Pod 按盘
  获得访问权**，但 exporter 是 **DaemonSet**，需要「本节点全部盘」，扩展资源的申请数量是**静态值**、无法随
  节点盘数变化。因此采用的方案是 ①：把 SMART 采集改为**每盘一个 collector Pod**（§9，控制器按 NodeDisk
  创建、申请 `hlvm.io/disk: 1`），已由 `verify-collector` 实测通过（授权链路/端点/生命周期）。
  仍需注意：kind 的 virtio 盘不支持 SMART，健康值走回退 `0`；**真实盘的 SMART 数值尚未验证**，
  `control-plane/config/exporter/daemonset.yaml` 这份旧清单也未删除（不在自动化路径里）。
  **顺带发现的部署缺口（2026-10-30）**：kind 集群里存在一个手工 apply 的 `hlvm-storage-exporter`
  DaemonSet，长期 `FailedCreate`——`serviceaccount "hlvm-storage-exporter" not found`，因为 SA 在
  `control-plane/config/exporter/rbac.yaml`，而 apply 时只用了 `daemonset.yaml`。该 DS 实际从未跑起来
  （CURRENT=0），已删除。**结论：exporter 不在任何自动化路径里**（bootstrap/verify-* 都不 apply 它），
  单独部署时必须先 apply RBAC；清单级测试只校验「仓库内 SA 有定义」，覆盖不到「部署时漏 apply」。
  这也说明设备插件阶段为什么用**自带对照**的验证方式：只看「Pod 起来了」不足以发现这类半部署。
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
  **残余竞态已关闭（2026-10-29）**：agent 走轮询 list，若在控制面标记前已取走任务仍可能执行一次；
  现在 agent 在执行前复核 `creationTimestamp + spec.ttl`（`agent/src/common/ttl.rs` +
  `reporter::kube_rw::expired_reason`），命中即直接回写 `Failed` 并跳过执行器，语义与控制面逐条对齐
  （仅拦未开始任务、非法 TTL 与缺 `creationTimestamp` 均失败关闭）。`cargo test` 99 项通过
  （新增 11 例），`cargo fmt --check` 通过。仍未覆盖两侧**时钟偏差**（部署前提，NTP 正常时误差可忽略）。
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

**docker build 的额外坑**：WSL 的 docker daemon 代理可能被配置为 `127.0.0.1:7892`（该端口默认无监听，
`docker info` 的 `HTTP Proxy`/`HTTPS Proxy` 可见）。daemon 拉基础镜像走的是这个代理，**`--build-arg` 不生效**。

**已实测的解法**（2026-10-29，`docker pull gcr.io/distroless/static:nonroot` 成功）：
让转发器直接监听 daemon 期望的端口，无需改 daemon 配置、无需重启 Docker：

```bash
# 与 daemon 的 HTTP(S)_PROXY 对齐（本机为 127.0.0.1:7892）
python3 scripts/wsl-proxy-fwd.py --listen 127.0.0.1:7892
curl -sS -x http://127.0.0.1:7892 -o /dev/null -w '%{http_code}\n' https://gcr.io/v2/   # 期望 401
```

**推荐做法：装成用户级 systemd 单元常驻**（无需 root，仓库内已有模板
`scripts/systemd/hlvm-proxy-fwd.service`，一个进程同时监听 7892 与 17890）：

```bash
mkdir -p ~/.config/systemd/user
cp scripts/systemd/hlvm-proxy-fwd.service ~/.config/systemd/user/
# 仓库不在 /mnt/e/projects/hlvm 时先改 ExecStart 路径
systemctl --user daemon-reload
systemctl --user enable --now hlvm-proxy-fwd.service
systemctl --user status hlvm-proxy-fwd.service      # active (running)
```

手工 `nohup` 启动的转发器在 WSL 会话结束后会被回收，表现为构建中途突然报同样的
`proxyconnect ... connection refused`——这是常驻单元要解决的问题。

其余注意点：
- `go mod download` 需网络，脚本把 `HTTP_PROXY/HTTPS_PROXY/NO_PROXY` 作为 build-arg 透传，
  且容器内要访问宿主需用 docker0 网关 `172.17.0.1:17890`（见上一步的 0.0.0.0 转发）；
- 该代理在并发下载时会截断（`unexpected EOF`），Dockerfile 已用 BuildKit cache mount
  （`/go/pkg/mod`、`/root/.cache/go-build`）使重试收敛；
- 默认运行态基础镜像是 `gcr.io/distroless/static:nonroot`，`docker build` 需要能拉取它；
  `RUNTIME_IMAGE=<已缓存镜像>` 仅作应急本地验证用，不代表生产路径。

### 7.2 集群重启后控制面全部失联（`kube-proxy` CrashLoop，`10.96.0.1:443` 超时）

**现象**：Docker Desktop / kind 节点容器重启后，`kubectl`（宿主直连 6443）正常，但
`hlvm-storage-controller`、`webhook`、`coredns` 全部无法访问 `https://10.96.0.1:443`，
日志持续 `context deadline exceeded`；所有 `verify-*` 断言同时失败（看起来像代码回归，实为集群故障）。
控制器日志只有 leader election 超时，`verify-taskgc` 报「未下发 vgcreate 任务」。

**根因**：`kube-proxy` 反复重启，日志
`"command failed" err="failed complete: too many open files"` —— 宿主机/VM 的
`fs.inotify.max_user_instances`（默认 128）被同机其它容器耗尽，kube-proxy 无法建立
Service 规则，ClusterIP `10.96.0.1` 因此不可达（`kubectl` 走 kubeconfig 的宿主地址不受影响）。

**处理（已自动化）**：`./scripts/m15-integration.sh bootstrap` 会调用 `ensure_kernel_limits`，
检测到 `fs.inotify.max_user_instances < 2048` 时自动提升、写入 `/etc/sysctl.d/99-hlvm-kind.conf`，
并在 kube-proxy 非就绪时重建 kube-proxy 与 CoreDNS。

> **持久化边界（实测，2026-10-29 两次复现）**：容器 stop/start（内核未重启）后设置可保留；
> 但 **Docker Desktop / WSL VM 重启会把内核参数重置**，实测再次回落到 128。也就是说
> `/etc/sysctl.d/` 只是记录意图，**不能替代每次校验**——真正的保障是 bootstrap 时自动修复。
> 该现象在 2026-10-29 本轮中复现两次（一次 kube-proxy CrashLoop，一次构建中途节点容器退出）。

手工兜底步骤：

```bash
# 1) 提高并持久化 inotify 限制（作用于同一内核/用户命名空间）
docker exec hlvm-kind-control-plane sh -c \
  'printf "fs.inotify.max_user_instances=2048\nfs.inotify.max_user_watches=1048576\n" \
     > /etc/sysctl.d/99-hlvm-kind.conf && sysctl -p /etc/sysctl.d/99-hlvm-kind.conf'

# 2) 重建 kube-proxy 与 CoreDNS（已崩溃的进程不会自愈）
kubectl --context kind-hlvm-kind -n kube-system delete pod -l k8s-app=kube-proxy
kubectl --context kind-hlvm-kind -n kube-system delete pod -l k8s-app=kube-dns

# 3) 断言恢复：kube-proxy 1/1、coredns 1/1，lease 的 renewTime 持续刷新
kubectl --context kind-hlvm-kind -n kube-system get pods | grep -E 'kube-proxy|coredns'
kubectl --context kind-hlvm-kind -n hlvm-system get lease hlvm-storage-controller -o yaml | grep -E 'holderIdentity|renewTime'
```

**判读要点**：`kubectl` 能连 ≠ 集群内可达。区分方法是看**控制器自己的日志**（只有 leader election
超时、无 reconcile 报错）与 `kube-system` 的 `kube-proxy` 状态；不要先怀疑刚改的代码。

**为什么反复出现**：kind 集群共享同一内核的 inotify 实例配额，同时运行多个集群时默认 128 很快耗尽
（2026-10-29 已清理 `graphify` / `hnb-s4-target` / `hnb-s4-clean`，现仅保留 `hlvm-kind`）。
但 Docker Desktop 重启会重置内核参数（见 §7.3），故 `ensure_kernel_limits` 仍需每次 bootstrap 校验——
把 `bootstrap` 当作每次开始工作前的入口，而不是只在建集群时执行一次。

### 7.3 Docker Desktop 重启后 kubectl 全部 `connection refused`（kind 容器停在 Exited）

**现象**：所有 `kubectl` 命令报
`The connection to the server 127.0.0.1:44885 was refused`，但 `kind get clusters` 仍列出 `hlvm-kind`；
`docker ps` 看不到节点容器，`docker ps -a` 显示 `hlvm-kind-control-plane  Exited (128)`。

**根因**：kind 节点容器**没有 restart policy**。Docker Desktop / WSL VM 重启（或异常恢复）时容器被停，
不会自动拉起；而 `kind get clusters` 按容器标签枚举、**不看容器状态**，因此仍报告集群存在。
脚本若只按 `kind get clusters` 判断，会进入「复用集群」分支，随后 apply/wait 全体失败，
且错误信息（connection refused）与被改动的代码毫无关系，极易误判为回归。

**处置**（bootstrap 已自动化，通常无需手工）：
```bash
docker start hlvm-kind-control-plane
kubectl --context kind-hlvm-kind get --raw /readyz   # 通常 20–60s 内就绪
```

`bootstrap` 现在先执行 `ensure_node_running`：状态为 `exited/created/paused` 时自动 `docker start`
并轮询 `/readyz`（上限 90s）；容器不存在则直接报错并提示 `kind delete cluster` 后重建。
`check` 保持只读（不启动容器），API 不可达时明确输出「集群内资源状态未检查（不是「未安装」，是查不到）」，
不再把连接失败报成资源丢失。

**实测（2026-10-30）**：手工 `docker stop` 模拟该状态后，`check` 正确告警、`bootstrap` 自动拉起并完成
全部 apply/wait；随后**从停止状态**执行 `all`，8 个阶段 29 个断言全 PASS、0 FAIL。

## 8. 磁盘设备插件（`hlvm.io/disk`）

### 8.1 它解决什么

非特权 Pod 受 **devices cgroup**（runc 的 BPF device filter）限制，即便 `uid=0`、即便挂了
hostPath `/dev`，打开块设备仍是 `EPERM`——2026-10-30 在 kind 里实测确认（加
`SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO` 也绕不过）。设备插件是 kubelet 提供的正规出口：
插件把每块盘作为一个可分配扩展资源暴露，Pod 申请后 kubelet 只把**被分配的那几个**设备节点写进
容器 cgroup 允许列表并注入 `/dev`。

实现见 `agent/src/plugin/`（同一二进制 `--mode=device-plugin`），协议为 K8s Device Plugin
**v1beta1**（gRPC over Unix socket），部署清单 `agent/config/daemonset-device-plugin.yaml`。

### 8.2 部署与使用

```bash
kubectl apply -f agent/config/daemonset-device-plugin.yaml
kubectl get node -o jsonpath='{.status.allocatable.hlvm\.io/disk}'   # 期望 ≥ 1
```

Pod 侧申请（**必须**同时给 limits 与 requests；扩展资源只写 limits 也会被 kubelet 补齐 requests）：

```yaml
resources:
  limits:
    hlvm.io/disk: 1
securityContext:
  privileged: false        # 关键：不需要特权
  runAsUser: 0             # 见 8.4 文件权限
  capabilities: { drop: ["ALL"] }
```

分配到的设备以**宿主机真实节点路径**注入（如 `/dev/nvme0n1`），不做重命名——`smartctl`/`nvme`
靠路径名判断设备类型，改名会导致采集侧误判。

### 8.3 验证（`verify-device-plugin`）

```bash
# 标准入口（WSL，见 §2.1）
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu24.04LTS -- bash /mnt/e/projects/hlvm/scripts/m15-wsl.sh verify-device-plugin
```

7 条断言，全部以**kubelet / 调度器侧客观事实**为准（不看插件日志自述）：
1. 插件 Pod 就绪；
2. `status.allocatable.hlvm.io/disk > 0`（注册 + ListAndWatch 生效）；
3. 申请 1 块盘的非特权 Pod 能读该设备（`READ_OK`）；
4. **对照**：同样非特权、挂 hostPath `/dev` 但不申请的 Pod 读同一设备得 `EPERM`
   ——没有这一条，第 3 条无法排除「环境本来就允许」；
5. 盘位用满时（申请数 = allocatable）**全部** Running；
6. 再多申请一个必须 **Pending**（事件文本 `Insufficient hlvm.io/disk`）——容量账生效；
7. 释放一个盘位后，第 6 条那个 Pod 必须转 **Running**——设备真的回到 kubelet，
   而不只是数字被还原。

实测（2026-10-30，kind 1.36）：7 条全 PASS，`allocatable=2`，第 3 个申请者被
`Insufficient hlvm.io/disk` 挡在 Pending，删掉一个 holder 后转 Running。

**一个必须记住的坑**：扩展资源的 `status.allocatable` 是**静态上限**，kubelet **不会**
因为分配而扣减它（真正的记账在调度器）。第一版按「allocatable 变小」写断言，实测占用
期间仍是 2，断言本身就错了。判断「容量是否真的被消耗」只能靠超发被拒。

对照组首次跑被判 FAIL 是脚本自身的判定错误（对照组最后一条命令是失败的 `dd`，phase 本就该是
`Failed`），已改为「只要求申请组 Succeeded、对照组到终态」。

### 8.4 已知边界（不要误解其能力）

- **不采集 SMART**：插件非特权、不读盘，`Device.Health` 恒为 `Healthy`。健康判定仍在 agent/exporter。
- **不做纳管决策**：占用判定（fs/LVM/md 签名、PV 归属）的权威实现在 agent 预检（需要读盘）。
  插件只用 lsblk 的 `TYPE/FSTYPE/子设备` 做启发式标注（`none|filesystem|holder`），不阻止分配。
- **文件权限仍生效**：设备节点通常是 `brw-rw---- root:disk`。设备插件解决的是 **cgroup**，不是
  文件权限——非 root 消费者需要 `runAsUser: 0`（非特权）或加入 `disk` 组，否则仍是 `EACCES`
  （与 `EPERM` 不同，注意区分）。
- **不解决 agent 的特权**：agent 需要对**本节点全部盘**做 wipe/pvcreate，而扩展资源只能申请
  「N 块」，表达不了「全集」。agent 因此仍 `privileged: true`。
- **不解决 exporter 的 DaemonSet 形状**：exporter 需要本节点全部盘的 SMART，同样受「静态申请数」
  限制。该缺口由 §9 的每盘 collector 关闭（形态改为「一个 NodeDisk 一个 Pod」）。
- **kind 环境差异**：kind 节点没有 `/dev/disk/by-id`（无 udev），设备 ID 回退为 `dev-<name>`；
  真实节点应解析出 by-id 并以其归一化作 ID。两者都只影响设备 ID，不影响 Allocate 下发的路径。
- 宿主 `/dev` **不能**挂到容器 `/dev`（runc 的 tmpfs 会盖住，实测 `/dev/disk/by-id` 直接不存在），
  清单挂到 `/host/dev` 并用 `HLVM_DEVICE_ROOT` 指路。

### 8.5 kubelet 重启：插件自愈与 checkpoint 恢复（`verify-kubelet-restart`）

kubelet 重启是常规运维（升级、调参、改 cgroup），但设备的**注册状态只存在于 kubelet 内存**里。
2026-10-30 在 kind 上实测，三条路径同时出问题，表现完全一致：**节点 `hlvm.io/disk` 归零后
永不恢复**，只能删插件 Pod 救回。

| 缺陷 | 现象（实测） | 修复 |
|------|--------------|------|
| kubelet 启动清空 `device-plugins` 下的插件 socket | 插件进程活着、监听 fd 还有效，但目录项没了；kubelet 反向连接 endpoint 得 `ENOENT`，注册永远失败 | 监视自身 socket 签名，被删则**重建监听**并重注册 |
| `kubelet.sock` 重建可能**复用 inode** | 只比 inode 的旧实现感知不到「重启过」，一次都不重注册（`allocatable` 一直 0） | 签名改为 `(dev, inode, mtime)` |
| 注册 RPC 无超时 | socket 已在、kubelet 尚未应答时挂死，注册循环从此不再前进 | 5s 超时 + 300s 低频兜底重注册 |

**9 条断言**（全部以 kubelet / 容器运行时侧的客观事实为准）：

1. 前置：`allocatable > 0`；
2. 重启前 Pod A 申请到 1 块盘并 Running（记录实际设备名，kind 里「申请 `/dev/sda` 拿到 `sdb`」是常态）；
3. 重启前 checkpoint 已记录 A 的分配；
4. 重启后 **60s 内** socket 重生 + 出现 **T0 之后**的新注册日志（无需重启插件 Pod）；
5. `allocatable` 恢复 > 0；
6. Pod A 的 `containerID` 不变——kubelet 重启不应重建运行中的容器；
7. 插件 Pod 名字/UID 不变——证明是**进程级自愈**，不是靠重调度 Pod 糊弄；
8. checkpoint 仍把该盘算在 A 名下；
9. 重启后新申请的 Pod B 拿到**另一块盘**（实测 A=`sda`、B=`sdb`）——checkpoint 生效，没有把同一块盘分配两次。

实测（2026-10-30 kind 1.36）：自愈耗时 2–4s，9 条全 PASS。

两个判据上的坑：
- **不能用 `--tail` 数注册次数**：重启前那次注册也在 tail 里，判据会恒为「已自愈」。
  必须用 `--since-time=<重启前时间戳>`。
- 不能用「重启后立刻读 allocatable」判断是否掉零：node status 有上报延迟，重启瞬间可能仍读到旧值。
  判据应是「socket 重生 + T0 后新注册」这一对客观事件，再看容量是否恢复。

**覆盖边界**：只用 `docker exec <cluster>-control-plane systemctl restart kubelet`，仅适配 kind。
真实集群的 kubelet 重启方式不同（ssh / 节点池滚动 / 不可用节点排水），本阶段会打印
「跳过……未覆盖」并 `return 0`，不当成 PASS。调度器拓扑、节点扩缩容仍属 §4 的真实环境项。

## 9. 每盘 collector（SMART 采集闭环）

### 9.1 形态与理由

旧 exporter 是 DaemonSet：非 root（65532）挂宿主 `/dev`，而块设备是 `brw-rw---- root:disk`，
打开即 `EACCES`——它**从来没有真正采到过** SMART（不是因为盘不支持）。设备插件解决的是
**cgroup** 授权，因此采集侧必须改成「按盘申请授权」，即：

```
一个 NodeDisk  →  一个 collector Pod（limit hlvm.io/disk: 1）  →  只采分到的那块盘
```

实现：`control-plane/internal/controller/disk_collector_controller.go`（控制器）+
`agent/src/reporter` 的 `HLVM_EXPORTER_DEVICE=auto`（采集侧）。容器安全上下文只保留
`uid 0` + `SYS_RAWIO`（smartctl 的 SG_IO ioctl），`privileged:false`、`drop ALL`、只读根、
不挂宿主 `/dev`、不挂 SA token。

### 9.2 三个必须知道的取舍

1. **分到哪块盘由 kubelet 决定**。扩展资源只能表达「申请 N 块」，不能指定「要 sdb」。
   因此采集侧不硬编码 `spec.deviceRef`（那会把 A 盘读数标成 B 盘），而是枚举 `/dev`——
   实测申请 1 块后容器内**只有**被分配的那块（`sda` 存在、`sdb` 不存在），枚举结果即授权集合。
   `deviceRef` 作为「意图」保留在 Pod 注解 `hlvm.io/disk-device`，供排查。
2. **不能设 ownerReference**。NodeDisk 是 Cluster-scoped、Pod 是 namespaced，跨作用域 owner
   会被 GC 判为无效并**立即删除** Pod。回收改由控制器主动完成：NodeDisk 删除触发 reconcile 的
   NotFound 分支，全量比对后删掉孤儿 Pod（也顺带清掉控制器重启期间漏掉的残留）。
3. **盘位保护**。同节点 collector 数达到 `allocatable.hlvm.io/disk` 时不再创建；否则多出来的
   Pod 会永久 Pending 并占住调度位。有盘位释放时 Pod watch 会把对应 NodeDisk 重新入队。

### 9.3 使用与验证

前置：跑过 `bootstrap`（应用 collector 的 Role/RoleBinding）与 `build`（controller 新镜像）。
本阶段自带两项兜底，可单独执行：缺 `collector_role.yaml` 时自动 apply；controller 镜像是
`ghcr.io/...:latest` 时自动改指本地 dev 镜像并等滚动完成。

```bash
# 标准入口（WSL，见 §2.1）
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu24.04LTS -- bash /mnt/e/projects/hlvm/scripts/m15-wsl.sh verify-collector
```

断言（9 条）：申请 `hlvm.io/disk=1` / `privileged:false` / 未挂宿主 `/dev` /
Pod Ready / `/metrics` 有心跳 / `/metrics` 有盘级 SMART 序列 / 删除 NodeDisk 后 Pod 被回收 /
**盘位保护**（NodeDisk 数 > 盘位时多出来的不创建 Pod）/ 批量删除后全部回收无残留。

指标经 `kubectl port-forward` 读取，不依赖镜像内有 `curl`；**读的时候必须 `--noproxy '*'`**，
否则 WSL 注入的 `HTTP_PROXY` 会把 `127.0.0.1:<port>` 也送进代理，拿到的是代理错误页。

副作用（有意保留）：阶段会把 `HLVM_AGENT_IMAGE=hlvm-storage-agent:dev` 写到 controller
Deployment 上并不还原——kind 里父镜像在 GHCR 私有、拉不下来，还原反而会让后续 collector
卡在 `ImagePullBackOff`。生产集群不要跑本阶段。

### 9.4 已知边界

- **kind 的 virtio 盘不支持 SMART**：健康值走文档化回退（`Healthy`，指标值 `0`）。本阶段证明的是
  「授权链路 + 端点 + 生命周期」，**不是**「SMART 数值正确」——后者需真实 SATA/SAS/NVMe。
  注意 `0` 与「真的健康」在指标上**不可区分**，因此 kind 里的 `storage_disk_smart_health=0`
  不能被当作健康结论引用。
- **NodeDisk 与实采盘的对应关系不保证**：Pod 覆盖的是它实际分到的盘。磁盘数 = collector 数时
  覆盖完整，但「disk-a 的 Pod 一定采 sda」不成立。
- **未内置 Prometheus 抓取配置**：Pod 带 `prometheus.io/scrape=true` 与端口注解，需集群侧
  Prometheus 的 Pod 服务发现生效。
- **成本与盘数线性相关**：每盘一个 Pod，盘多时 Pod 数 = 盘数（换来的是最小权限与按盘隔离）。

## 10. CRD 双版本与 conversion webhook

对应 `add-hardening-rollout` 3.1b。目标是把「升级能力」从骨架变成可运行的东西：
两个 API 版本之间由我们自己的 webhook 做字段转换。

### 10.1 组成

| 部分 | 位置 | 说明 |
|------|------|------|
| 转换服务 | `control-plane/cmd/crd-conversion` | 独立 HTTPS 服务，只处理 `/convert`；**不用 manager**（不 watch 集群、无 client，故障面最小） |
| API 版本 | `control-plane/api/v1beta1` | NodeDisk 试点：`spec.deviceRef`(string) → `spec.device.path`(object) |
| 转换实现 | `api/v1alpha1/nodedisk_conversion.go` | v1beta1 是 hub（`Hub()`），v1alpha1 是 spoke（`ConvertTo/ConvertFrom`），逐字段显式映射 |
| 清单 | `config/hardening/03-crd-conversion.yaml`（服务/证书）+ `03b-nodedisk-dual-version.yaml`（双版本 CRD） | 两份文件是**为顺序服务的**，见 10.2 |

### 10.2 部署顺序（反了会让 NodeDisk 不可用）

```bash
kubectl apply -f control-plane/config/hardening/03-crd-conversion.yaml
kubectl -n hlvm-system rollout status deploy/hlvm-crd-conversion --timeout=180s
kubectl apply -f control-plane/config/hardening/03b-nodedisk-dual-version.yaml
```

第二份文件把 CRD 的 `conversion.strategy` 设为 Webhook。若此时服务还没 Ready，
apiserver 对 v1beta1 的每次读写都会失败（`service "hlvm-crd-conversion" not found`）。

### 10.3 版本与爆炸半径

- `v1alpha1` 仍是**存储版本**，`v1beta1` 是 `served` + 非存储。写入仍以 v1alpha1 落盘。
- 因此 webhook 挂掉时：**v1beta1 读写失败，v1alpha1 读路径不经过转换，控制器不受影响**。
  `verify-conversion` 的第 9 条断言就是把服务缩到 0 来证明这一点，而不是嘴上说。
- **以上「爆炸半径受限」只在 v1alpha1 是存储版本时成立。** 一旦把存储版本切到 v1beta1
  （见 10.5），读 v1alpha1 也需要从 v1beta1 转回来，两个版本会一起挂 —— 实测见 10.6 第 3 条。
- **`preferredVersion` 会被改成 v1beta1**（CRD 版本优先级 v1beta1 > v1alpha1，与存储版本无关）。
  后果：不带版本限定的 `kubectl get nodedisk` 从此解析到 v1beta1，既有脚本的 jsonpath 可能读空。
  排查这类"字段莫名消失"时，先确认自己读的是哪个版本（本仓库脚本一律显式写
  `nodedisks.v1alpha1.storage.example.io`）。
- **kubectl 的 discovery 缓存会迟到约 10 分钟**：`verify-conversion` 结束、CRD 恢复单版本后，
  缓存里仍记着 `preferredVersion=v1beta1`，裸资源名会被解析到已移除的版本，报
  `404 the server could not find the requested resource`——看起来像"对象被删了"。
  脚本在 `conversion_cleanup` 里删除 `~/.kube/cache/discovery`；手工排查时也可
  `kubectl --cache-dir=/tmp/kubectl-fresh get ...` 或删掉该目录复现/消除。

### 10.4 证书轮换

cert-manager 签发 `hlvm-crd-conversion-serving-cert`，并通过 CRD 上的
`cert-manager.io/inject-ca-from` 注解把 CA 注入 `conversion.webhook.clientConfig.caBundle`。
服务端用 `certwatcher` 监听挂载目录里的 `tls.crt`/`tls.key`，续签后**不需要重启进程**。

已覆盖：证书被签发、caBundle 被注入。**未覆盖**：真实过期/轮换演练（没有等一个证书到期）。

### 10.5 storedVersions 切换：已演练（`verify-storage-migration`）

2026-10-30 在 kind 上完成切换与回滚演练，**15 断言全 PASS**。实测步骤（顺序不能换）：

```bash
# 1) 前置：转换服务就绪 + 双版本 CRD（见 10.2）
# 2) 切存储：v1beta1 变存储版本，v1alpha1 保持 served（老客户端仍可写）
kubectl patch crd nodedisks.storage.example.io --type=json -p='[
  {"op":"test","path":"/spec/versions/0/name","value":"v1alpha1"},
  {"op":"test","path":"/spec/versions/1/name","value":"v1beta1"},
  {"op":"replace","path":"/spec/versions/0/storage","value":false},
  {"op":"replace","path":"/spec/versions/1/storage","value":true}]'
# 3) 重写存量对象（这一步真的会改存储版本，已用 etcd 直读证实）
kubectl get nodedisks.v1alpha1.storage.example.io <name> -o json | kubectl replace -f -
# 4) 清 storedVersions 里的旧版本 —— 用子资源，且**必须先清**才能做第 5 步
kubectl patch crd nodedisks.storage.example.io --subresource=status --type=merge   -p='{"status":{"storedVersions":["v1beta1"]}}'
# 5) 此时才能把 v1alpha1 从 spec.versions 里移除
kubectl apply -f control-plane/config/crd/bases/storage.example.io_nodedisks.yaml
```

回滚（`storage` 改回 v1alpha1 + 重写对象，两步都要）：

```bash
kubectl patch crd nodedisks.storage.example.io --type=json -p='[
  {"op":"replace","path":"/spec/versions/0/storage","value":true},
  {"op":"replace","path":"/spec/versions/1/storage","value":false}]'
kubectl get nodedisks.v1alpha1.storage.example.io <name> -o json | kubectl replace -f -
```

### 10.6 切换过程里四条反直觉的实测结论

都不是从文档抄的，是这一轮在 kind 上撞出来的（脚本断言逐条锁住）：

1. **`status.storedVersions` 不能当迁移完成判据**。切 storage 的**那一瞬间**它就把新版本写进去了，
   而对象字节此时还是旧版本；而且它**只增不减**——写入时自动加，永不自动删。
   「看到 storedVersions 有两个版本就宣布迁移完成」是错的。真正的判据是 etcd 里的字节。
2. **迁移期不需要停写**。切 storage 后，用 v1alpha1 新建的对象会**自动以 v1beta1 落盘**
   （因为存储版本决定落盘版本，而 v1alpha1 仍 served）。这是「滚动迁移不断服」的依据。
3. **爆炸半径会扩大**。切存储前，webhook 挂了只有 v1beta1 受影响、v1alpha1 读路径不经过转换；
   切之后**两个版本都读不了**（读 v1alpha1 也要从 v1beta1 转回来）。
   所以**回滚不能当作 webhook 故障的逃生通道**——恰恰在那种时候，回滚本身也需要 webhook。
4. **K8s 会拒绝「移除曾为存储版本的版本」**，只要 `storedVersions` 还记着它：

   ```
   v1beta1 was previously a storage version, and must remain in spec.versions
   until a storage migration ensures no data remains persisted in v1beta1
   and removes v1beta1 from status.storedVersions
   ```

   这条护栏正是「第 4 步不能跳过」的原因。第一次跑本阶段时收尾就栽在这里：以为
   `apply` 单版本 YAML 就能收干净，实际被静默拒绝（错误被 `|| true` 吞了）。
   现在 `verify-storage-migration` 用 `--dry-run=server` 把这条护栏本身变成断言。

**判定「对象到底以哪个版本落盘」的方法**（脚本里叫 `stored_api`）：distroless 的 etcd 容器没有 `sh`，
`kubectl exec` 进不去；改从节点容器走 etcd v3 gateway：

```bash
KEY="/registry/storage.example.io/nodedisks/<name>"
docker exec <cluster>-control-plane sh -c "curl -s \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key \
  https://127.0.0.1:2379/v3/kv/range -X POST \
  -d '{\"key\":\"'$(printf %s "$KEY" | base64 -w0)'\"}'"
```

返回值是 base64 的 protobuf，解出来 grep `storage.example.io/v1` 即可看到 `.../v1alpha1` 或 `.../v1beta1`。

### 10.7 仍未覆盖（不要当成已具备）

- **只有 NodeDisk 版本化**：其余 4 个 Kind（NodeVG / StorageTask / StorageNodeOps /
  ThinPoolPolicy）仍只有 v1alpha1，推广时要复制 `03b` 的 schema 段与对应的 hub/spoke。
- **控制器仍在用 v1alpha1 读写**。切换后这仍然工作（v1alpha1 保持 served，读写都经转换），
  但意味着「v1alpha1 不能下线」。要真正下线 v1alpha1，得先把控制器迁到 v1beta1。
- **真实规模未验证**：演练只有 3 个对象，没有验证大批量重写的耗时、失败重试与中断续跑。
- **多 apiserver 副本**：kind 单控制面。多副本下转换调用是每副本各自发起的，未观测。
- **证书轮换**只验证了「会签发 + 进程会热加载」，没有真实过期演练。
