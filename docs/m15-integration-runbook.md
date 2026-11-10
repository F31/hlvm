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
# 设备热插拔：ListAndWatch 增量推送、设备节点就绪才暴露、双向增减去留（用 scsi_debug 造真整盘，kind 限定）
bash scripts/m15-integration.sh verify-device-hotplug
# CRD 双版本 + conversion webhook（会临时改写 NodeDisk CRD，结束自动恢复单版本 v1beta1）
bash scripts/m15-integration.sh verify-conversion
# serving 证书轮换：固定 CA 使 caBundle 免重注入、证书热加载、Pod 不重启（含 selfSigned 反证）
bash scripts/m15-integration.sh verify-cert-rotation
# storedVersions 切换与回滚（破坏性：演练把存储版本临时切到 v1alpha1 再回滚，
# 结束自动恢复单版本 v1beta1）
bash scripts/m15-integration.sh verify-storage-migration

# 一键（全部 verify-* 顺序执行；conversion / cert-rotation / storage-migration 放最后，它们会临时改写 NodeDisk CRD）
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

**已验证**（WSL2 Ubuntu 24.04 / Docker 29.4.1 / kind 1.36.1）：`all` 持续跑出 exit 0，
最新一次为 **2026-11-01 的 120 条断言 PASS / 0 FAIL、exit 0**（23 个阶段标题：WSL 包装层 2 + `check` 的
4 个子步骤 + `build` + **16** 个 `verify-*`，即此前 15 个再加 `verify-topology-scale`）。
`verify-velero` 在本机 kind 因 WSL 代理无法拉取 docker.io/minio 与 docker.io/velero 镜像
（鉴权 insufficient_scope）而 **SKIP**（return 0，不阻塞 all），端到端备份/恢复闭环移交真实测试集群。

> **计数口径（重要）**：断言条数会随环境分支浮动（SKIP / 降级路径 / 注入重试等会增减打印行），
> 所以**不要拿不同日期的条数直接相减**当回归判据。唯一判据是：**退出码 0 + 全日志无 `FAIL:` 与
> `[error]` + 每个相位都打出自己的收尾 PASS 汇总行**。2026-10-31 的 125 与今日的 120 是不同环境
> 分支下的条数，不代表断言减少（本轮实际新增了 `verify-topology-scale` 的 9 条）。

**多节点 kind 重建（2026-10-31）**：新增 `scripts/kind-config.yaml`（1 control-plane + 2 workers），
删旧单节点集群后 `bootstrap` 按该配置从零建成 **3 节点**集群（K8s 1.36.1，全部 Ready）；
`all` 在该多节点集群上**同样跑出 125 PASS / 0 FAIL、exit 0**（仅 `verify-velero` SKIP）。
重建暴露并修复了集成脚手架的「单节点假设」：① agent / device-plugin DaemonSet 缺 control-plane
容忍度，多节点下被 CP 的 `NoSchedule` taint 挡在 worker，而验证以 `NODE_NAME=items[0]`（CP）为被测
节点 → 级联误判 FAIL；已给两个 DaemonSet 加 CP 容忍度（单节点下为 no-op）。② 验证相位里申请类 Pod
（设备插件容量上限、kubelet 重启占用、热插拔消费）未固定到被测节点，多节点下会落到有余量的 worker
→ 误判；已用 `nodeSelector` + CP 容忍度固定到 CP，保留「超额即 Pending」语义。详见 §10.10。
> 断言全绿**不等于**通过：本轮曾出现 107 PASS / 0 FAIL 却 `exit 1`——收尾缺陷让脚本在
> 断言之外崩掉，且错误信息被 trap 掩盖。结论一律以**退出码**为准，见 §7.1.2。
2026-10-30 另有 `all` 连续 5 次 exit 0 的记录，并以 `--no-cache-filter=builder` 强制失效缓存
验证（`go mod download` 真实联网 37.3s、编译 19.2s）。

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

> **envtest 有独立的 CRD 目录** `control-plane/config/crd/envtest/`：envtest 起的是真实
> kube-apiserver 但**没有 conversion 服务**，所以不能喂生产那份双版本 NodeDisk CRD
> （v1alpha1 served 会要求调用不可用的 webhook ⇒ 读写全失败）。该目录里 NodeDisk 是
> **单版本 v1beta1**——既可用，也与「控制器走 v1beta1 存储版本」的生产语义一致；
> 其余 4 个 Kind 仍只有 v1alpha1，共用同一目录。改动 CRD schema 时要记得同步这里，
> 否则会出现「单测绿、集成挂」或反过来。

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
**已覆盖**：协议、字段映射、证书/caBundle 接线、依赖关系。存储版本切换见下一条（1.12），
证书轮换见 3.1d（§10.4）。**未覆盖**：其余 4 个 Kind 的版本化 |

| storedVersions 切换与回滚（hardening 3.1b 尾巴） | `verify-storage-migration`：etcd 直读判定存储版本，断言 ① 转换服务就绪；② **schema 护栏**（v1alpha1 字段路径在 v1beta1 都有对应，仅 `deviceRef` 有意演进）；③ 切换前对象以 v1alpha1 落盘；④ 切存储成功；⑤ **storedVersions 已含 v1beta1 而对象字节仍 v1alpha1**（判据陷阱）；⑥ 迁移期老客户端新建的对象自动以 v1beta1 落盘（不必停写）；⑦ 重写后存量对象以 v1beta1 落盘；⑧ spec 规范化一致 + status 逐字段相等；⑨ **webhook 下线后连 v1alpha1 也读不了**（爆炸半径扩大）；⑩ 恢复后自愈；⑪ **K8s 拒绝在 storedVersions 未清理时移除 v1beta1**；⑫ 清 storedVersions 后两版本仍可读写；⑬ 回滚 storage 后对象仍 v1beta1 落盘但两版本可读；⑭ 回滚后重写才回到 v1alpha1 落盘；⑮ 收尾干净 | **切换与回滚均已在 kind 验证**（15 断言）。真实数据量、多 apiserver 副本的转换行为、其余 4 个 Kind 未覆盖 |
| serving 证书轮换与 CA 稳定性（hardening 3.1d） | `verify-cert-rotation`：断言 ① 转换服务就绪；② 根 CA `BasicConstraints=CA:TRUE`；③ serving 证书由根 CA 签发；④ caBundle 注入的正是该 CA；⑤ `openssl verify` 链验证通过；⑥ `port-forward`+`s_client` 生效探针就绪；⑦ 删 secret 后证书重签；⑧ **服务端实际证书已更换**（实测 74s，进程未重启）；⑨ 根 CA 未变；⑩ caBundle 未变；⑪ 新服务端证书仍被 caBundle 验证；⑫ 转换仍可用；⑬ Pod 未重启；⑭ **反证：改回 selfSigned 后根 CA 会变**；⑮ **反证：caBundle 随之变化**；⑯ 恢复清单后自愈 | **固定 CA 链已在 kind 验证**（16 断言）。真实到期续签（cert-manager 最小 duration 为 1h）与根 CA 自身轮换未覆盖；详见 §10.4 |

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
- **NodeDisk 基线切换的升级约束（2026-10-31）**：NodeDisk 的存储版本已从 v1alpha1 收敛到
  v1beta1（版本布局见 §10.3），`config/crd/bases` 现在是**单版本 v1beta1**。这意味着在
  「曾经以 v1alpha1 为存储版本」的存量集群上直接 `kubectl apply -f config/crd/bases` 会失败——
  K8s 拒绝移除 `status.storedVersions` 里还记着的旧存储版本：
  ```
  must remain in spec.versions until a storage migration ensures no data remains
  persisted in v1alpha1 and removes v1alpha1 from status.storedVersions
  ```
  `phase_bootstrap` 里的 `ensure_nodedisk_crd_baseline` 按「有没有数据」分叉处理：
  **一个 NodeDisk 对象都没有** ⇒ 删 CRD 重建（这是唯一不需要走迁移就能归位的路径，
  `storedVersions` 随 CRD 一起消失）；**有对象** ⇒ 直接 `die`，要求先按 §10.5 完成迁移。
  刻意不做静默删数据——这里的集群可能有别人的对象，擅自删 CRD 会把它们一起带走。
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

**7.1.1 CP 镜像构建的离线假失败与自动回退（2026-10-30 全量 all 实测）**

即使转发器常驻，全量 `all` 仍可能走到 `verify-conversion` 才炸：`docker build` 内 buildkit
解析 distroless manifest 报 `#4 [internal] load metadata for gcr.io/distroless/static:nonroot
→ failed to do request: Head ... EOF`。这与此前 12 个阶段都构建成功并不矛盾——buildkit 对
manifest 有 TTL 缓存，前面的阶段命中缓存，到本阶段恰好过期需要重新解析。

脚本已把三处 CP 镜像构建（`phase_build` 的 controller/webhook、`ensure_conversion_image`、
`verify-storage-migration` 内联）统一收敛到 `cp_build`：仅在**明确的** manifest/front-end/
授权类网络错误文本出现时，自动回退 `RUNTIME_IMAGE=scratch`（仓库 Go 二进制 CGO_ENABLED=0
静态链接，scratch 可用），并用 `CP_RUNTIME_FALLBACK` 记住结论，本轮后续镜像直接走 scratch、
不再逐个白等超时。

三个实测陷阱（都踩过，别再犯）：
1. **不能用外部探测预判**：`docker buildx imagetools inspect` 3s 就返回可达，但 build 内
   `load metadata` 走不同代理路径仍 EOF；`docker manifest inspect` 套 `timeout 20` 实测 85s
   才返回。只看 `docker build` 自身的结果。
2. **不要 `docker buildx prune -af` 清缓存做验证**：它会连 Dockerfile 第一行
   `# syntax=docker/dockerfile:1` 的 front-end 镜像一起清掉，制造出比真实场景更极端的失败
   （`#2 resolve ... failed to authorize: failed to fetch anonymous token ... EOF`）。front-end
   与 `RUNTIME_IMAGE` 无关，**回退 scratch 也救不了**。它还会清掉 `go mod` 的 buildkit cache
   mount，冷缓存下 55 个直接依赖 × 单请求约 5s 要几分钟。
3. **纯超时（rc=124）不触发回退**：慢代理下冷缓存的 `go mod download` 会超时，而回退 scratch
   一样要跑 `go mod download`，徒劳重试还会掩盖真正原因。判据只认错误文本，超时直接失败并
   打印 buildkit 输出。首次构建超时默认 `CP_BUILD_TIMEOUT=480`（给冷缓存留余量，热缓存仍秒级）。

环境恢复：front-end 镜像 `docker/dockerfile:1` 可经 CLI 层 `docker pull`（走
`127.0.0.1:7890`，`auth.docker.io` token 偶发 EOF，重试可成）恢复；`hlvm-gomod` 命名卷保有
完整 Go 模块缓存；`go mod` 的 buildkit cache mount 需一次完整联网下载重新预热。

**7.1.2 节点内访问本地回环被代理劫持（2026-10-31：etcd 直读静默返回空）**

`scripts/m15-integration.sh` 的 `stored_api` 要直读 etcd 原始字节，做法是
`docker exec <node> curl https://127.0.0.1:2379/v3/kv/range`。若 kind 节点容器继承了宿主的
`https_proxy`（本项目为容器构建配的 `172.17.0.1:17890`，见 7.1），curl 会拿它去
`CONNECT 127.0.0.1:2379` —— **本地回环请求被送去代理**：

```
* Uses proxy env variable https_proxy == 'http://172.17.0.1:17890'
> CONNECT 127.0.0.1:2379 HTTP/1.1
* TLS connect error: error:0A000410:SSL routines::ssl/tls alert handshake failure
```

响应为空，于是「对象以哪个版本落盘」这个唯一判据凭空消失。
**结论：脚本里凡是访问节点本地回环地址的请求，一律加 `--noproxy '*'`**。

这个坑难查，是因为三个缺陷叠加，最后一个把前两个彻底掩盖：

1. curl 走代理 ⇒ etcd 直读为空（真正的根因）；
2. `stored_api` 末尾 grep 无匹配返回 1，而脚本是 `set -e` + `pipefail` ⇒
   `api="$(stored_api ...)"` 这条赋值直接让脚本退出，`fail_msg` 都来不及打；
3. `trap ... EXIT` 的 cleanup 引用了函数级 `local` 变量，阶段返回后变量已销毁，
   trap 在脚本退出时才跑 ⇒ `set -u` 报 `unbound variable`，**真正的失败原因被这一句取代**。

排查「断言全绿但退出码非零」这类故障时，**不要只数 PASS/FAIL**：先取真实退出码，
再用 `bash -x scripts/m15-integration.sh <子命令>` 抓终止前的最后几行轨迹
（trace 会精确停在 `+ migration_cleanup` 这样的行上）。

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
1. 插件 Pod 就绪并完成**本次** gRPC 注册（见下方「注册时序」坑）；
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

**必须记住的两个坑**：

1. 扩展资源的 `status.allocatable` 是**静态上限**，kubelet **不会**因为分配而扣减它
   （真正的记账在调度器）。第一版按「allocatable 变小」写断言，实测占用期间仍是 2，
   断言本身就错了。判断「容量是否真的被消耗」只能靠超发被拒。

2. **插件重建窗口（2026-10-30 全量 all 实测）**：`plugin_cleanup` 删掉旧 DaemonSet →
   旧插件进程退出使 kubelet 的 `ListAndWatch` 断开（`ListAndWatch ended unexpectedly ... EOF`），
   但 `allocatable` **仍是旧值**（静态缓存，插件断开期间不清零），`rollout status` 也只保证
   新 Pod Running。若此刻就创建申请设备的 Pod，kubelet 会以
   `UnexpectedAdmissionError: Allocate failed due to no healthy devices present` 拒绝准入，
   容器根本没被创建——`kubectl logs` 报 `container "probe" is not available`，表现为
   「phase=Failed + 读不到设备」两条断言同时失败。
   **判据必须是插件自己的注册日志，且用 `--since-time` 限定在本次 apply 之后**，
   否则上一轮注册日志会恒判「已注册」、把这个窗口掩盖掉。
   脚本抽成 `deploy_plugin_and_wait`（先删旧 DS 保证 Pod 真的重建 → 等 rollout → 等本次注册
   日志 → 留 3s 给 kubelet 标 healthy），`verify-device-plugin` / `verify-collector` /
   `verify-kubelet-restart` 三处共用——三者都曾在删 DS 后只等 rollout 就申请盘，同一个坑。

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

### 8.6 设备热插拔：ListAndWatch 增量与「设备节点就绪才暴露」（`verify-device-hotplug`）

任务书原把这一项标为「需真实可插拔硬件」。2026-10-31 复核后认为过于保守：要验证的是
**设备集合变化能否被感知并增量推送**，不是某一类具体总线。kind 节点容器是 privileged
（`CapEff` 含 `CAP_SYS_MODULE`），容器内 `modprobe scsi_debug` 能造出真正的整盘
（`type=disk`、`/sys/block` 下可见），与物理拔插在内核层是同一类事件（block device add/remove）。

```bash
# 手工复现（排障时很好用）
docker exec hlvm-kind-control-plane modprobe scsi_debug dev_size_mb=64 num_parts=0
docker exec hlvm-kind-control-plane lsblk -d -o NAME,TYPE,SIZE   # 多出一块 sde
docker exec hlvm-kind-control-plane rmmod scsi_debug             # 拔掉
```

**沿途发现并修掉了一个会静默吃掉 Pod 的缺陷。** 这是本阶段真正的价值——它不是照着清单
走一遍过场，而是在验证过程中把设计漏洞逼了出来：

| 环节 | 修复前的行为（2026-10-31 实测） |
|------|--------------------------------|
| `lsblk` 可见 vs `/dev` 有节点 | `lsblk` 读 sysfs，设备一注册到内核就出现在列表里；而 `/dev/<name>` 由 udev **稍后**建立（kind 无 udev，本例始终不建） |
| 插件 | 照单全收，立刻把这块盘暴露给 kubelet |
| 调度器 | 节点 `allocatable.hlvm.io/disk` 虚高 ⇒ 敢把「申请这块盘」的 Pod 放到该节点 |
| kubelet | 按 hostPath 注入设备时 `lstat /dev/sde: no such file or directory` |
| Pod | 永久停在 `CreateContainerError`，而且**一直重试**——不是失败一次就结束 |

修复在 `agent/src/plugin/mod.rs` 的 `rescan()` 末尾：`select_disks` 之后再过一道
`host_node_ready`，要求宿主侧（`$HLVM_DEVICE_ROOT`，默认 `/host/dev`）对应项是**真实块设备**
才暴露，丢弃时打 warn 明示原因（否则将来只能对着「盘怎么没出来」干瞪眼）。
宁可晚一轮暴露（下一轮 rescan 自然纳入），也不能让 Pod 掉进黑洞。单测 141 → 142。

**8 类断言**（按生命周期排布，避免只测一半）：

1. 基准 `allocatable = N`；
2. **对照组**：插入前申请 `N+1` 个设备必须 Pending——证明基准容量确实是 N，
   否则第 6 条「这是新盘带来的」无从谈起；
3. `modprobe` 后内核真的认下了新整盘（`lsblk` 差异比对，不是靠预期）；
4. **节点缺失时不暴露**：等满一个 rescan 周期，`allocatable` 仍是 N，且插件日志出现
   「宿主设备节点缺失」——修复的直接证据；
5. 手动 `mknod` 补上 `/dev/<name>` 后必须 N→N+1，且日志出现「设备集合变化，更新
   ListAndWatch 快照」——证明不是「永不暴露」，而是「就绪才暴露」；
6. 同一个申请 `N+1` 的 Pod 必须真正 Running（**修复前此处正是 CreateContainerError**）；
7. `rmmod` 后回落 N（反方向的一次增量推送）；
8. 收尾干净：`scsi_debug` 已卸载且盘集合还原——断言通过却把副作用留在机器上等于没通过。

**两条交付纪律**（已写进阶段实现，别省）：

- 阶段用 `trap hotplug_cleanup EXIT` 兜底。本阶段多处 `die` 是 `exit`，而内核模块是
  **宿主机全局可见**的，只靠末尾顺序清理必然会漏（残留一块盘会让下一个人摸不着头脑）。
- 无法 `modprobe` 的环境（非 Linux 宿主 / docker-desktop / 无 `CAP_SYS_MODULE`）打印
  「跳过……未覆盖」并 `return 0`，**不计 PASS**——与 §8.5 的 kind 限定保持一致。

实测（2026-10-31，WSL2 + kind 1.36）：8 条全 PASS。时延符合生产默认参数——
插入后 **54s** 才被感知（60s rescan + 5s ListAndWatch tick），拔出后 **60s** 回落；
这两个数字可以当作「热插拔后容量就绪需要等多久」的经验值。

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

> **2026-10-31 起存储版本已经翻转**：NodeDisk 完成收敛（`add-hardening-rollout` 3.1e）后，
> **v1beta1 是存储版本**，v1alpha1 降级为「served 非存储」的兼容层。下面的爆炸半径按新布局描述，
> 早期文档中「v1alpha1 是存储版本」的表述已作废。

| 清单 | 角色 | 版本布局 |
|------|------|----------|
| `config/crd/bases/storage.example.io_nodedisks.yaml` | bootstrap 与常规验证的**基线** | 单版本 **v1beta1**（storage），无 conversion 接线 |
| `config/hardening/03b-nodedisk-dual-version.yaml` | 收敛后的**目标形态** | v1beta1（storage）+ v1alpha1（served）+ conversion webhook |

这样分层的理由：**bootstrap 与常规阶段不依赖 webhook**。CRD 一旦接线 conversion，
webhook 不可用就会让依赖它的读写失败（见 10.2），而 node_disk 是控制面的主数据路径；
把 webhook 只留给「老客户端兼容」这条窄路径，才能让 conversion 故障不扩散到控制器。

- 控制器、dashboard、agent 全部走 **v1beta1**（= 存储版本），**读写都不经过 conversion**。
- 老客户端显式用 v1alpha1 时：写入经 webhook 转存为 v1beta1；读取经 webhook 从 v1beta1 转回。
  所以 **v1alpha1 的读写依赖 webhook，v1beta1 不依赖**。
- 因此 webhook 挂掉时：**v1alpha1 读写失败，v1beta1 读路径不经过转换，控制器不受影响**。
  `verify-conversion` 的第 9 条断言就是把服务缩到 0 来证明这一点，而不是嘴上说
  （方向在 3.1e 里随存储版本一起翻转了）。
- **`preferredVersion` 是 v1beta1**（CRD 版本优先级 v1beta1 > v1alpha1，与存储版本无关）。
  后果：不带版本限定的 `kubectl get nodedisk` 会解析到 v1beta1。v1beta1 的字段路径与 v1alpha1
  不同（`spec.device.path` vs `spec.deviceRef`），既有脚本的 jsonpath 可能读空——看起来像
  "转换丢字段"，其实是读到了另一个版本的视图。
  排查这类问题先确认自己读的是哪个版本：**本仓库脚本一律显式写全限定资源名**
  （`nodedisks.v1beta1.storage.example.io` / `nodedisks.v1alpha1.storage.example.io`），
  常规阶段用前者，只有「刻意扮演老客户端」的演练探针才用后者。
- **kubectl 的 discovery 缓存会迟到约 10 分钟**：CRD 的 served 版本变化后（尤其移除某个版本），
  缓存里仍记着旧版本集合，裸资源名会被解析到已移除的版本，报
  `404 the server could not find the requested resource`——看起来像"对象被删了"。
  脚本在版本切换后的清理路径里删除 `~/.kube/cache/discovery`；手工排查时也可
  `kubectl --cache-dir=/tmp/kubectl-fresh get ...` 或删掉该目录复现/消除。

### 10.4 证书轮换：已演练（`verify-cert-rotation`）

2026-10-30 在 kind 上完成，**16 断言全 PASS**。演练的直接结果是**改掉了原来的证书方案**。

**原方案错在哪**（实测）：原清单用 `selfSigned Issuer` 直接签 serving 证书。selfSigned 签出的
每张证书**自己就是根**，所以删掉 secret 触发重签后，校验链的根也跟着换了；而 CRD 上的
`caBundle` 由 cainjector **异步**重新注入——证书先到、caBundle 后到。中间这段时间 apiserver
拿旧 CA 校验新证书：

- **连续 8–45 次调用失败**，服务端日志刷 `TLS handshake error ... tls: bad certificate`；
- 而 Pod 全程 `Ready`、`restartCount=0` —— 没有就绪降级、没有告警。属于「假 Ready」：
  看板是绿的，转换是全挂的。

**现方案**：自签根 CA（10 年有效期、`privateKey.rotationPolicy: Never`）→ `ca` Issuer →
serving 证书。serving 证书重建**不改变校验链**，caBundle 无需重注入。

| 观测项 | selfSigned（原） | 固定 CA（现） |
|--------|------------------|---------------|
| 重建 serving 证书后根 CA | 变 | **不变** |
| caBundle | 变（要重注入） | **不变** |
| 重建后调用可用性 | 8–45 次失败 | 重建后立即可用 |

反证也在脚本里：把 Certificate 改回 selfSigned 再重跑同样的删除动作，CA 与 caBundle **必须**
变化（否则说明断言语境不灵敏，不能归因于固定链）。

**仍然存在的窗口（诚实边界）**：caBundle 与 Pod 内挂载的证书不是同一时刻更新的。
实测 Pod 里的证书要等 kubelet 同步，**61–74s**——删 secret 后第 74s 服务端才换上新证书。
在固定 CA 下这不影响可用性（旧证书仍被同一 CA 信任），但有两个直接后果：

- **判断「证书已生效」不能读 secret**：secret 里是新证书时，进程可能还在用旧的。
  判据只能是服务端实际提供的证书——`kubectl port-forward pod/<pod> 19443:9444` 之后
  `openssl s_client -connect 127.0.0.1:19443 -servername <svc>` 取指纹。
- **一次性迁移本身有窗口**：从 selfSigned 切到固定 CA 会触发重签 + caBundle 重注入，
  而 Pod 还要等约 1 分钟。期间 admission webhook 因 `failurePolicy: Ignore` 表现为
  「静默不注入」（Pod 照建、但没有 nodeAffinity）。建议在维护窗口执行，或执行后立刻
  `kubectl -n hlvm-system rollout restart deploy/hlvm-storage-webhook`。

**storage-webhook 一并改了**（`control-plane/config/webhook/certificate.yaml`）：
新增 `hlvm-webhook-ca`（固定根 CA）+ `hlvm-ca-issuer`，serving 证书由它签发。
它的 certwatcher 每 10s 轮询，实测切链后 15:27:33 完成热加载、Pod 未重启。
`verify-admission` 因此新增两条断言：caBundle 能验证 serving 证书、未注入时判 **FAIL**
（此前只 `warn`，导致「证书失配 + 静默不注入」时退出码仍是 0——等于没断言）。

**未覆盖**：
- **真实到期续签**：cert-manager 的最小 duration 是 1h，等续签不现实。本演练用
  「删 secret 触发重签」代替——这是最坏的入口（私钥都丢了），结论偏向保守。
- **CA 自身轮换**：根 CA 10 年到期后的迁移流程（需要同时换 caBundle 与所有 serving 证书）
  未演练，属独立运维动作。

### 10.5 storedVersions 切换：已演练（`verify-storage-migration`）

2026-10-30 在 kind 上首次完成切换与回滚演练（**15 断言全 PASS**）；2026-10-31 随 NodeDisk
收敛把基准存储版本翻转成 v1beta1，演练方向随之反过来（现在是
**v1beta1 → v1alpha1 → 回滚 v1beta1**），断言仍全绿。**这套步骤与方向无关**，
差别只在「哪个版本是目标、哪个要被移除」：

```bash
# 1) 前置：转换服务就绪 + 双版本 CRD（见 10.2）
#    2026-10-31 起双版本里 storage 是 v1beta1、v1alpha1 是 served 非存储。
# 2) 切存储到目标版本（下例切到 v1alpha1，目标是 v1beta1 时把 true/false 对调）
kubectl patch crd nodedisks.storage.example.io --type=json -p='[
  {"op":"test","path":"/spec/versions/0/name","value":"v1alpha1"},
  {"op":"test","path":"/spec/versions/1/name","value":"v1beta1"},
  {"op":"replace","path":"/spec/versions/0/storage","value":true},
  {"op":"replace","path":"/spec/versions/1/storage","value":false}]'
# 3) 重写存量对象（这一步真的会改存储版本，已用 etcd 直读证实）
kubectl get nodedisks.v1beta1.storage.example.io <name> -o json | kubectl replace -f -
# 4) 清 storedVersions 里的旧版本 —— 用子资源，且**必须先清**才能做第 5 步
kubectl patch crd nodedisks.storage.example.io --subresource=status --type=merge   -p='{"status":{"storedVersions":["v1alpha1"]}}'
# 5) 此时才能把 v1beta1 从 spec.versions 里移除
kubectl apply -f control-plane/config/crd/bases/storage.example.io_nodedisks.yaml
```

回滚（把 `storage` 改回原版本 **并**重写对象，两步都要）：

```bash
kubectl patch crd nodedisks.storage.example.io --type=json -p='[
  {"op":"replace","path":"/spec/versions/0/storage","value":false},
  {"op":"replace","path":"/spec/versions/1/storage","value":true}]'
kubectl get nodedisks.v1beta1.storage.example.io <name> -o json | kubectl replace -f -
```

> `test` op 建议保留：它顺带校验版本**顺序**。少了这一步，一旦有人调整 `versions` 数组
> 顺序就会把 `storage` 打在错误的版本上，而且不报错。

### 10.6 切换过程里四条反直觉的实测结论

都不是从文档抄的，是这一轮在 kind 上撞出来的（脚本断言逐条锁住）：

1. **`status.storedVersions` 不能当迁移完成判据**。切 storage 的**那一瞬间**它就把新版本写进去了，
   而对象字节此时还是旧版本；而且它**只增不减**——写入时自动加，永不自动删。
   「看到 storedVersions 有两个版本就宣布迁移完成」是错的。真正的判据是 etcd 里的字节。
2. **迁移期不需要停写**。切 storage 后，**仍用非存储版本新建的对象会自动以新的存储版本落盘**
   （存储版本决定落盘版本，而旧版本仍 served）。这是「滚动迁移不断服」的依据。
   2026-10-31 起方向反过来验证了同一条：以 v1beta1（控制器版本）写入、自动以 v1alpha1 落盘。
3. **爆炸半径由「谁是存储版本」决定，切一次翻一次**。读取的存储方向决定了要不要转换：
   - storage=v1beta1（收敛后的常态）：只有显式用 v1alpha1 的老客户端需要转换，
     webhook 挂了**控制面不受影响**（控制器走 v1beta1）；
   - storage=v1alpha1（`verify-storage-migration` 演练中的形态）：v1beta1 成了非存储版本，
     webhook 挂掉时**连 v1beta1 也读不了**，控制器随之不可用。
   所以**回滚不能当作 webhook 故障的逃生通道**——恰恰在那种时候，回滚本身也需要 webhook；
   反过来，控制面的安全落点始终是「存储版本 = 控制器所用的版本」。
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
  注意混合局面已经存在：`storage_task_plan.go` 里 ownerReference 的 `apiVersion` 是
  **按 owner 类型动态取的**（NodeDisk → `storage.example.io/v1beta1`，NodeVG →
  `storage.example.io/v1alpha1`）。K8s GC 靠它定位 owner，写错会让孤儿永远收不掉，
  所以每推广一个 Kind 都要同步这个 switch。
- **真实规模未验证**：演练只有 3 个对象，没有验证大批量重写的耗时、失败重试与中断续跑。
- **多 apiserver 副本**：kind 单控制面。多副本下转换调用是每副本各自发起的，未观测。
- **证书**：轮换已演练并改造成固定 CA 链（§10.4），但**真实到期续签**未观察
  （cert-manager 最小 duration 为 1h），**根 CA 自身轮换**也未覆盖。

### 10.8 NodeDisk 收敛基线回归护栏（`verify-nodedisk-convergence`）

3.1e 把 NodeDisk 收敛到 **v1beta1 单版本存储**后，这套「单版本基线」本身需要一个集成层护栏，
否则两类回归会悄悄滑回：

1. **双版本被带回 `config/crd/bases`**：一旦 v1beta1 之外又出现 served 版本，裸资源名
   `kubectl get nodedisk` 会按版本优先级解析到别处，老客户端按旧版本 jsonpath 读会读空，
   看起来像「转换丢字段」的假象（见 §10.5/§10.6 的版本优先级陷阱）。
2. **ownerReference.apiVersion 写错**：`storage_task_plan.go` 的 `nonControllerOwnerRef` 按 owner
   类型动态取 apiVersion（NodeDisk → `v1beta1`、NodeVG → `v1alpha1`），单测已覆盖，但集成层
   原 `verify-taskgc` 只验了 `kind`/`uid`/`controller`，漏了 `apiVersion`——若回归写成 v1alpha1，
   单版本基线下 GC 按 v1alpha1 找不到 NodeDisk 拥有者，任务变孤儿却查不出。

护栏做法（相位跑在破坏性相位之前，先断言基线完好）：

- `verify-nodedisk-convergence`（新增，2 条断言）：① 线上 CRD `spec.versions` 必须恰好是
  `v1beta1`（单版本 ⇒ 仅它 served 且 storage）；② 裸资源名创建/读取的 NodeDisk 经 v1beta1 免转换
  路径、`spec.device.path` 字段完好。
- `verify-taskgc` 增强（补 2 条断言）：NodeVG-owned 任务的 `ownerReferences[0].apiVersion`
  必须等于 `v1alpha1`、NodeDisk-owned 任务必须等于 `v1beta1`，把单测的映射保证延伸到真实集群端到端。

结果：`all` 复核 **125 PASS / 0 FAIL、exit 0**，断言数较上一轮 +4、阶段 +1。

### 10.9 backup-restore 集成相位（`verify-velero`）

选项 A 的软件栈集成项之一：`verify-velero` 验证 Velero + minio 后端在 kind 内的 backup/restore 闭环，
并校验项目自带的三份 backup manifests（`control-plane/config/backup/01-backup-schedule.yaml` /
`02-mysql-prehook.yaml` / `03-drill-job.yaml`）语法可解析。

相位流程：① 项目自带 manifests 语法校验（`--dry-run=client`，跳过 `00-velero-install` 部署参考）；
② 核心组件就绪（velero Deployment / node-agent DaemonSet）；③ BSL Available（minio 后端连通）；
④ 最小端到端：写 marker → 备份 → 删 PVC/PV → 恢复 → 读回数据一致（Kopia 文件备份，普通 PVC）。

**本机 WSL/kind 环境无法完成端到端验证（已多次实测，非 hlvm 缺陷）**：
- kind 节点容器运行时经 WSL 代理拉取 `docker.io/velero` / `docker.io/minio` 镜像时 token 鉴权失败
  （`insufficient_scope`）；`ghcr.io` 无 MinIO 镜像、`quay.io` 无对应 tag。
- 2026-11-01 进一步实测镜像获取的全部可行路径，**均不可匿名拉取**，故「本地 registry 导入让
  `verify-velero` 转 PASS」方案在零成本前提下不可行（本机无任何镜像凭证）：
  - WSL docker daemon 代理（`127.0.0.1:7892`）拉 `docker.io/minio:RELEASE.2024-05-28T17-19-04Z`
    → `pull access denied ... may require 'docker login'`（用户仓库鉴权被阻断）；
  - `quay.io/minio/...` 与 `quay.io/velero/...` → `401 UNAUTHORIZED`（quay 受保护仓库需凭证）；
  - kind 节点 containerd 拉 `docker.io/minio` / `docker.io/velero` → `insufficient_scope`。
  三条路径均无匿名可用来源，本地 registry 导入不应继续投入。
- 因此 `ensure_minio` / `ensure_velero` 在拉取失败（ImagePullBackOff/ErrImagePull）时**立即返回**，
  相位以 **SKIP（return 0）** 结束，不阻塞 `all`；并明确打印根因，区别于 PASS。
- 端到端备份/恢复闭环**移交真实测试集群**（选项 A 目标环境，镜像可正常拉取）执行，届时本相位将从
  SKIP 转为 PASS。

相位实现中修掉的两个真实缺陷：
1. `02-mysql-prehook.yaml` 含一个 `ResourcePolicy`（velero.io/v1）文档，而 **Velero v1.14 无此 CRD**
   → `--dry-run=client` 报 "no matches for kind ResourcePolicy"；已移除该文档（pod 资源限制改由 velero
   server / node-agent 的 Deployment 规格统一管控，已在文件头注释说明）。
2. 原 `ensure_velero` 仅按「deploy 对象存在」判定已装，导致 ImagePullBackOff 的残损 deploy 被误判为
   已装、相位继续跑断言而 **FAIL 并阻塞 all**；已改为按 **Ready（Available）** 判定，未就绪一律重新校验，
   残损态下正确 SKIP。

### 10.10 多节点 kind 重建与集成脚手架改造（2026-10-31）

**背景**：选项 A（真实测试集群）的软件栈集成需要先确认本地 kind 能跑多节点拓扑。`scripts/kind-config.yaml`
已就绪（1 control-plane + 2 workers），但 `kind` 的多节点集群会给 control-plane 加
`node-role.kubernetes.io/control-plane:NoSchedule` taint，而单节点集群默认去掉该 taint——这导致
原先在**单节点**验证通过的脚手架，在**多节点**下出现一批「单节点假设」误判。

**重建步骤**（破坏性，需先 `kind delete` 再 `bootstrap`，因 `bootstrap` 复用逻辑不会重建已有集群）：
```bash
kind delete cluster --name hlvm-kind
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu24.04LTS -- bash /mnt/e/projects/hlvm/scripts/m15-wsl.sh all
# bootstrap 按 scripts/kind-config.yaml 从零建成 3 节点集群，随后 build + 全 verify
```
实测：`all` 在 3 节点集群（K8s 1.36.1，全部 Ready）上跑出 **125 PASS / 0 FAIL、exit 0**，与单节点一致。

**暴露并修复的两类「单节点假设」**：

1. **DaemonSet 缺 CP 容忍度**：`daemonset-agent.yaml` / `daemonset-device-plugin.yaml` 原本没有
   control-plane 容忍度。多节点下 agent / device-plugin 只落 2 个 worker，而验证相位以
   `NODE_NAME=kc get nodes` 的 `items[0]`（= control-plane）为被测节点，并用 CP 节点名去 grep agent
   日志、在 CP 容器里 `modprobe scsi_debug`——节点不匹配 → 级联误判 FAIL（agent 实际已正确解析自身节点名）。
   修复：给两个 DaemonSet 加 `control-plane:NoSchedule` 容忍度（组件设计意图即「跑在每个有盘的节点上」；
   单节点下 CP 本就可调度，此容忍度为 no-op，不改变 125 PASS）。

2. **申请类测试 Pod 未固定节点**：`verify-device-plugin`（容量上限）、`verify-kubelet-restart`（占用/对照）、
   `verify-device-hotplug`（消费 Pod）里申请 `hlvm.io/disk` 的 Pod 没有固定到被测节点。多节点下第 N 个
   申请会落到有余量的 worker，被误判为「容量上限失效 / 插入前竟已分配」。修复：这些 Pod 用
   `nodeSelector: kubernetes.io/hostname: ${NODE_NAME}` + 同一 CP 容忍度固定到 CP——既约束到被测节点
   （走调度器、保留「超额即 Pending」语义，不破坏热插拔的「插入前不可调度」断言），又允许落到被 taint 的 CP。

3. **读 DaemonSet 日志未定点到被测节点**（2026-11-01 补修）：`verify-device-hotplug` 用
   `kc logs ds/hlvm-disk-plugin` 读「宿主设备节点缺失」这条日志。`logs ds/...` 会在 DaemonSet 里**任取一个
   Pod**，3 节点下常读到没插盘的 worker/CP，那条日志永远不在其中 ⇒ 断言恒假阴性。症状是**行为正确却报错**：
   `过早暴露=0 有明晰日志=0`（前半句说明插件没提前暴露，是对的；后半句是读错了 Pod）。单节点时代只有
   1 个 Pod，所以这条假设一直没暴露；它还会**偶发**——取到哪个 Pod 不确定，于是有时 PASS 有时 FAIL。
   修复：按 `-l app.kubernetes.io/component=disk-device-plugin` + `jsonpath {.items[?(@.spec.nodeName=="<node>")]}`
   定点取 Pod，并 `--tail=120`；失败信息里打印**实际读取的 Pod 名**与被测节点名，避免下次再靠猜。
   > 通用教训：**任何 `kubectl logs ds/...` 在多节点下都不安全**，必须按 `spec.nodeName` 定点。

> 诚实边界（2026-11-01 更新）：本多节点验证仍以「CP 为被测节点」复刻单节点逻辑，但 **6.5b 的
> 「跨节点调度拓扑 / 容量账」半数已在 kind 闭环**（见 §10.11 `verify-topology-scale`）：约束到被测节点的
> Pod 在 3 节点集群上会落到与 CP 不同的 worker，验证「无 nodeSelector 必落容量节点 / 每节点填满后集群
> 耗尽必 Pending / 释放盘位后 Pending Pod 跨节点回调度」。仍**未覆盖**的是 6.5b 的「节点扩容 / 缩容」
> （真实增减节点、调度器重平衡），需在真实测试集群或动态增删节点的 kind 拓扑上演练。

### 10.11 6.5b 跨节点拓扑 / 容量账相位（`verify-topology-scale`，2026-11-01）

选项 A 软件栈集成需要确认本地多节点 kind 能覆盖 6.5b 的「跨节点调度拓扑 / 容量账」目标
（`openspec/changes/add-disk-device-plugin/tasks.md` 中 `6.5b NodeAffinity/拓扑、节点扩容缩容`）。
本相位在既有 3 节点 kind 上**零成本闭环其拓扑 / 容量账部分**（节点扩缩容仍移交真实集群，见 §10.10 边界）。

相位流程（插入在 `verify-device-hotplug` 之后、`verify-collector` 之前）：
1. cordon control-plane，防止验证 Pod 落 CP 干扰被测 worker 拓扑；
2. 列出 worker（`grep -v -- '-control-plane'`），读取各 worker 基线 `hlvm.io/disk` 容量
   （kind 节点自身磁盘已被设备插件暴露为扩展资源，基线即 2，**无需注入**即可验证跨节点拓扑）；
3. 仅对基线 0 的 worker best-effort `modprobe scsi_debug`（不判负，避免把「注入失败」误判为拓扑失败）；
4. **负向拓扑**：不写 nodeSelector 的申请 Pod 必须落「有 `hlvm.io/disk` 容量」的节点，而非被 cordon 的 CP；
5. **容量账**：按各 worker 基线容量在**每个** worker 填 hold Pod 占满其盘位；
6. **集群耗尽**：所有 worker 盘位占满后再申请必 `Pending`（reason `Insufficient hlvm.io/disk`）；
7. **跨节点回调度**：释放一个 worker 的盘位后，该 Pending Pod 必须重新调度到「腾出盘位的节点」，
   验证调度器能感知跨节点容量变化并回补；
8. 清理：删 hold Pod / `rmmod scsi_debug` / uncordon CP / 删 DaemonSet。

实测（2026-11-01）：standalone 与 `all` 集成均跑出全 PASS（集成时 9 条，含收尾 uncordon 断言）。
其余未勾选项仍带「移交集成 / 真实 LV 硬件 / Velero / 多节点 / 产品决策」标记。

**本相位踩到并修掉的两个坑（都有普遍性）**：

1. **`EXIT` trap 里 uncordon 会被静默跳过**：初版把 `uncordon CP` / `rmmod` 只放在 EXIT trap 里，
   阶段体末尾只删 Pod。但 trap 要等**脚本退出**才执行，彼时函数局部变量 `cp_node` / `workers`
   已离开作用域，`${cp_node:-}` 求值为空 ⇒ `[ -n ... ] && uncordon` 直接短路 ⇒ **CP 永久留在
   `SchedulingDisabled`**。危险之处在于：`all` 仍 0 FAIL、退出码 0，没有任何信号。
   修复：阶段内**显式**调用一次 `topo_cleanup` 再 `trap - EXIT`，并断言
   `{.spec.unschedulable}` 为空（新增第 9 条 PASS）。
   > 通用规则：**trap 只当兜底，不要当主清理路径**；凡依赖局部变量的清理，必须在作用域内显式跑一次。

2. **`Available: 0` 的 allocation 归还竞态**：`verify-device-plugin` / `verify-device-hotplug` /
   本相位的清理原先都用 `kubectl delete pod --wait=false`，删完立刻继续。kubelet 的 device
   allocation 是在 **Pod 删除流程里**归还的，于是紧跟其后的相位（`verify-collector`，它在 `all` 里
   紧接 `verify-device-plugin`）申请 `hlvm.io/disk` 时被判
   `UnexpectedAdmissionError ... Requested: 1, Available: 0`——看起来像容量坏了，其实 pod 已经不在了。
   修复：三处清理统一改 `--wait=true --timeout=90s`；`verify-collector` 另加一次**有界重试**
   （识别 `UnexpectedAdmissionError` → 删 Pod 让控制器重建 → 再等 120s，成功时打印 WARN，不静默吞）。

### 10.12 集成脚手架的「静默失败」清单（2026-11-01 汇总，2026-11-02 补三类）

`m15 all` 的价值全靠「失败就必须非 0」；而 K8s 与 shell 里有几处设计会**静默吞掉**失败，让断言以
「看起来像产品坏了」或「看起来全绿」的形式报出来。已踩过的七类，统一记在这里：

| 现象 | 真实原因 | 判据/修复 |
|---|---|---|
| `过早暴露=0 有明晰日志=0`（行为对却判失败） | `kubectl logs ds/...` 在 DaemonSet 里**任取一个 Pod**，多节点下常读到没插盘的节点 | 一律按 `spec.nodeName==<被测节点>` 定点取 Pod；失败信息打印实际 Pod 名 |
| `UnexpectedAdmissionError ... Available: 0`（容量看起来坏了） | `delete pod --wait=false` 后立刻继续，kubelet **还没归还 device allocation** | 清理改 `--wait=true --timeout=Ns`；关键相位加有界重试，成功时打印 WARN |
| 注入类断言失败但证书/配置都对 | webhook `failurePolicy: Ignore`：apiserver 调不通时**静默放行**，资源照建、只是没被改 | 断言前等 Service **endpoints** 就绪；注入断言做有界重建重试 |
| `all` 退出码 0 但 CP 仍是 `SchedulingDisabled` | 清理只写在 `EXIT` trap 里，脚本退出时局部变量已离开作用域，`uncordon` 被静默跳过 | trap 只当兜底；**阶段内显式清理一次**再 `trap - EXIT`，并断言 `{.spec.unschedulable}` 为空 |
| 构建日志里明明有 `ERROR: failed to build`，脚本却继续跑断言并 PASS | `cp_build` 里写成 `if cmd; then return 0; fi; rc=$?`——**`$?` 取的是 if 语句整体的退出码（恒为 0）**，于是失败被当成成功，随即装载上一次的旧镜像 | `rc=$?` 必须紧跟命令本身，或写进 `else` 分支；失败一律 `die`，不许「构建失败但用旧镜像继续」 |
| `go mod download` 连试 5 次全 `connection reset by peer`，回退 scratch 仍失败 | ① 代理探测用 `curl -I` 会**假阳性**（短请求 200，go 的 keep-alive 长连接被 reset）；② 回退重试**沿用了同一代理**，把同一次失败重演 | 代理只用于**首次尝试**，回退/重试一律不带（`M15_BUILD_PROXY` 与 `HTTP_PROXY` 解耦）；真缺依赖会给出明确错误 |
| 集成镜像里 `--version` 打出 `dev (commit unknown)` | 脚手架构建 `cp_build` 没传版本 build-arg；且 WSL 副本排除了 `.git`，`git rev-parse` 必失败 | `cp_build` 注入 `VERSION/COMMIT/BUILD_DATE`；`m15-wsl.sh` 在 rsync 前取 commit 下传 `M15_GIT_COMMIT` |

> 共同模式：**K8s 的「容错默认值」会把测试脚手架的时序问题伪装成产品缺陷**。
> 遇到「断言失败但行为看着正常」，先怀疑「读错了对象 / 还没轮到我 / 失败被 Ignore 吞了」，
> 再怀疑被测组件。

### 10.13 真实集群模式（`M15_TARGET=real`）

**动机**：kind 能给「控制面行为」，给不了「真实盘」。具体缺三样，且都影响结论可信度：
① 没有 `/dev/disk/by-id`（无 udev）→ 设备 ID 只能回退 `dev-<name>`，6.2 永远验证不到；
② 没有真实 `/dev` 块设备 → thin pool、`dmsetup`、`lvs/vgs` 对账、拔盘全靠模拟；
③ 单机多节点的调度器行为与「真机跨主机」不完全等价（网络、污点、资源碎片）。

**拓扑与规格**：见 `scripts/real-cluster/README.md`（3 台起步 / 4 台可练扩缩容；
CP 4C8G、worker 4C8G、每 worker 2×100GiB virtio 数据盘）。

**脚本做了哪些适配**（收敛在 `m15-integration.sh` 的抽象层，相位代码不感知）：

| 抽象 | kind | real |
|---|---|---|
| `node_exec` | `docker exec <容器> sh -c` | `ssh <user>@<InternalIP>`（BatchMode，避免卡密码挂死） |
| `image_load` | `kind load docker-image` | 空操作（节点从 `IMG_REGISTRY` 拉） |
| `agent_image` / `conversion_image` | 本地 tag | `<IMG_REGISTRY>/<name>:<tag>` |
| `disk_inject` / `disk_eject` | `modprobe scsi_debug` | `M15_DISK_ATTACH_CMD` / `M15_DISK_DETACH_CMD`（未提供→相位 SKIP） |
| `pick_test_node` | `items[0]`（= control-plane） | 优先 worker（避开控制面） |
| `control_plane_node` | `<cluster>-control-plane` | 带 CP 标签的节点（etcd 直读 / kubelet 重启用） |

**为什么被测节点与「控制面节点」必须分开**：real 模式下被测节点是 worker，而 etcd 直读
（`verify-storage-migration`）与 `systemctl restart kubelet`（`verify-kubelet-restart`）只能打在
控制面上。早期实现把二者都写成 `${CLUSTER_NAME}-control-plane`，在 kind 下恰好等价，
到真机就会「重启 worker 的 kubelet，却去断言 CP 的 checkpoint」——这类错误不会报错，只会静默假绿。

**运行方式**：
```bash
M15_TARGET=real \
KCTX=$(kubectl config current-context) \
M15_SSH_USER=root M15_SSH_KEY=~/.ssh/id_ed25519 \
IMG_REGISTRY=ghcr.io/f31/hlvm IMG_TAG=v0.1.0-preview.2 \
  ./scripts/m15-integration.sh check      # 先只读检查
  ./scripts/m15-integration.sh preflight  # 再跑环境体检（§10.14）
```

**注意**：
- real 模式 `bootstrap` **不建集群**（集群由 `scripts/real-cluster/` 的 kubeadm 流程建好），
  只做 cert-manager / CRD / RBAC / webhook / manager 的安装。
- `M15_SKIP_BUILD` 在 real 下默认 **1**：镜像来自 CI。此时脚本会把 controller/webhook 的
  `imagePullPolicy` 改成 `Always`，否则 `:latest` 会命中节点缓存，跑的是旧镜像而没人发现。
- `all` 里 `verify-storage-migration` 是**破坏性**相位（临时把 NodeDisk 存储版本切到 v1alpha1）。
  对真机集群跑 `all` 前确认里面没有别人依赖的数据。
- **镜像标签**：real 模式默认 `IMG_TAG=latest`，但 `preflight` 会把它判 **FAIL**（§10.14）——
  `:latest` 跑出的结论无法对应到具体版本，下一次 main 构建就会覆盖。请显式传版本标签
  `IMG_TAG=v0.1.0-preview.2`（见 §11.3）。确要试跑 latest 设 `M15_ALLOW_LATEST=1`，
  但该次结论不得用于验收或汇报。
- **首次使用尚未在真实云主机端到端演练**：`scripts/real-cluster/*` 只做过语法/YAML 校验，
  kind 侧适配层已回归（`all` 120 PASS / 0 FAIL）。首次上真机请按 README §4 的检查点逐步确认，
  并先跑 `preflight`。

### 10.14 首跑预检（`preflight`，2026-11-02）

真机首跑的失败很少发生在「context 连不上」，而是 ssh 打不通、私有镜像没凭据、云盘早被格式化、
节点没有 udev——这些在第 5~15 个相位才以「产品缺陷」的样子爆出来（`ImagePullBackOff`、
by-id 为空、VG 建不出来），归因成本极高。`preflight` 把它们压成一次只读扫描：

```bash
M15_TARGET=real KCTX=... IMG_TAG=v0.1.0-preview.2 \
M15_SSH_USER=root M15_SSH_KEY=~/.ssh/id_ed25519 \
  ./scripts/m15-integration.sh preflight
```

它只读、不改集群、不装东西；`all` 在两种目标下都会先跑它。

**断言分级（重要，别照着改）**

| 级别 | 判据 | 含义 |
|---|---|---|
| FAIL（非 0 退出） | context 不可达 / API server 不通 / 无 Ready 节点 / real 下无独立 worker / 私有镜像缺 `imagePullSecret` / `IMG_TAG=latest`（未显式放行）/ 造盘钩子给了但不可执行 / 任一节点 `node_exec` 不通 | 结构性缺失，本次结论必然不可信 |
| WARN | cgroup v1 / swap 开着 / `dm_thin_pool` 未加载 / 无 by-id / 无 lvm 命令 / 无 udevadm / inotify 过低 / 无 etcd PKI | 能力缺失：对应相位会 SKIP 或断言退化，其余结论仍有效 |

**为什么能力项只 WARN**：实测 kind 节点 `dm_thin_pool=no`、`lvm=no`、`/dev/disk/by-id` 为空、
swap 开着，却照样跑出 120 PASS（agent 镜像内自带工具、盘由 `scsi_debug` 造）。把这些静态量
当门禁，等于用一个从没验证过的代理指标卡自己，还会让「kind 绿、真机红」更不可解释。
它们的价值是**解释性**——看见 WARN 就知道哪些相位会 SKIP、为什么。

**造盘钩子为什么是 FAIL 而不是 WARN**：`M15_DISK_ATTACH_CMD` 写错路径时，
`disk_inject` 返回非 0，`verify-device-hotplug` 会**静默 `return 0`**——`all` 照样绿，
但热插拔这条覆盖整个消失。这正是 §10.12 那类「失败被伪装成通过」，所以必须是 FAIL。

**实测（2026-11-02）**

| 场景 | 结果 |
|---|---|
| kind 全绿基线 | `PASS=6 WARN=12 FAIL=0`，exit 0 |
| `M15_TARGET=real` 指向 kind 集群（无 sshd） | `FAIL=4`（3 节点不可达 + 缺 imagePullSecret），exit 1 |
| 同上 + `M15_DISK_ATTACH_CMD=/nonexistent` | `FAIL=5`（多一条钩子不可执行），exit 1 |
| `M15_ALLOW_LATEST=1 IMG_TAG=latest` | 降为 WARN（「不得用于验收/汇报」），不再 PASS |

数据盘能否被纳管的**深度**判定（分区签名、系统挂载、容量、by-id）仍在
`scripts/real-cluster/disk-precheck.sh`，逐节点只读跑；`preflight` 只做计数与指路，
不重复它那套判定。

### 10.15 副本分布与调度（有效域 D、拓扑分散、PDB，2026-11-03）

**先纠正一个常见误算：可用故障域 D ≠ 节点总数。**

control-plane 带 `node-role.kubernetes.io/control-plane:NoSchedule` taint，而三个控制面
Deployment（controller / webhook / conversion）**都未加 CP 容忍度**，因此它们只能落在 worker 上：

```
D = 可调度节点数 = 不带 NoSchedule taint（或本 Deployment 已容忍）的 Ready 节点数
```

3 节点 kind（1 CP + 2 worker）下 **D=2**，不是 3。`scripts/real-cluster/` 建议的
1 CP + 2 worker 同样是 D=2。

**机制：`topologySpreadConstraints`，不是应用数节点。**

调度器每次都持有当前节点集合的视图，按 `maxSkew` 计算落位——节点增减自动反映，
应用侧不需要任何"感知"逻辑。三个 Deployment 现均配置：

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway   # 软约束：域不足时允许堆叠，不 Pending
    labelSelector:
      matchLabels: { app.kubernetes.io/component: <本组件> }
```

webhook 原先的 `preferred` 反亲和已删除：它只是若干打分项之一（与资源均衡、镜像本地性竞争），
无法表达"副本间差异不超过 N"；spread 是显式约束。

**R（副本数）与 D 决定结果，与"调优"无关**：

| R | D | 可达分布 | 说明 |
|---|---|---|---|
| 3 | 3 | 1:1:1 | skew=0 |
| 3 | 2 | 2:1 | skew=1，**已是理论最优**，不是配置缺陷 |
| 2 | 1 | 2:0 | 单节点，HA 本就不成立 |

要保证"每节点最多一副本"必须 **R ≤ D 且改硬约束**（`DoNotSchedule` / required 反亲和），
代价是节点少一个就有一个副本 Pending——比软约束更脆弱，生产一般不用。

**为什么必须是 `ScheduleAnyway`（软）**：硬约束下 3 副本 + 2 域 = 1 个永久 Pending，
单节点部署直接起不来。软约束在 D=1 时全堆叠但仍可用，这是单机测试的前提。

**实测（2026-11-03，3 节点 kind，D=2）**

| 操作 | 结果 |
|---|---|
| apply 后 rollout | `rollout status` 成功，全部 Running，无 Pending |
| 干净调度（删 Pod 触发同时重建） | controller **1:1**（worker / worker2），skew=0 |
| webhook 3 副本 | **2:1**（worker 1 / worker2 2），D=2 下的最优 |
| PDB `maxUnavailable: 1` | R=3 → allowed=1；**R=2 → allowed=1**；R=1 → allowed=1 |
| `kubectl drain --dry-run=server` | exit 0，不阻塞 |

**踩到的真实陷阱：滚动更新期间旧 Pod 计入 spread 计数。**

apply 后第一次 rollout 得到的是 controller **2:0**（两个新副本都堆在 worker），skew=2 > maxSkew，
而资源完全充裕（节点内存请求仅 200~300Mi）。原因不是调度器错了：

1. 新 Pod 调度时，旧 ReplicaSet 的 Pod（Terminating 中）**仍参与 labelSelector 计数**；
2. 新 Pod 按"旧 Pod 还在"的计数落位；
3. 旧 Pod 随后消失，最终分布失衡，而 `ScheduleAnyway` **只在调度期生效**，不会自我修正。

同一份清单，删掉 Pod 让它们同时重建后立刻变成 1:1 —— 证明清单正确，是滚动期计数污染。

**运维含义**：
- 滚动发布/扩容后若分布畸形，`kubectl rollout restart` 或删 Pod 重排；必要时用
  descheduler 的 `RemovePodsViolatingTopologySpreadConstraint` 插件做持续重平衡。
- 不要用"发布后立刻看分布"来判定约束是否生效，会被这个假象误导。

**PDB 为什么改用 `maxUnavailable`**：`minAvailable` 是绝对值，不随副本数缩放——
3 副本时 `minAvailable: 2` 与 `maxUnavailable: 1` 等价，但副本降到 2 时前者变成
"不允许任何不可用"，降到 1 时永远无法满足，两种情况都会让 `kubectl drain` 永久阻塞，
且报错只提 disruption budget，不指向根因。实测 R=2 时 `maxUnavailable: 1` 给出 allowed=1。

**副本数不会自动随节点数变化**（Deployment 静态字段，K8s 无内置机制）：

| 方案 | 做法 | 评价 |
|---|---|---|
| 固定副本 + 软 spread（当前） | R 写死 2/3/2 | 1~N 节点都能工作，仅副本密度变化；推荐 |
| 部署侧算 | 渲染时 `R = min(desired, D)` | 可控，节点变化需重跑 |
| controller 改 replicas | watch Node → patch | 不建议：与滚动更新/PDB 打架，节点抖动引起反复增删 |

**单机模式边界**：D=1 时三个组件全部堆在唯一节点，功能可用但 **HA 完全不成立**——
PDB、leader 切换、webhook 多活都无法验证。单机通过只能说明功能正确性（详见 §10.14 的
`preflight` 分级与 §10.10 的假设边界）。

### 10.16 单节点模式（`M15_SINGLE_NODE=1`，2026-11-03）

**先回答「hlvm 支不支持单机」——要把两件事分开：**

| 事项 | 单节点 | 依据 |
|---|---|---|
| **部署**（清单能不能起来） | **支持** | 三个控制面 Deployment 用软 spread（`ScheduleAnyway`），D=1 时全堆在唯一节点仍 Running；PDB 是 `maxUnavailable: 1`，1 副本下 allowed=1 不阻塞 drain；设备插件/agent DaemonSet 已容忍 CP taint |
| **集成验收**（`all` 能不能跑） | **需要显式开关** | 默认路径里 `preflight` 把「real 模式没有 worker」判 FAIL，`verify-topology-scale` 无 worker 直接 `die`。不是不能跑，而是**默认拒绝替你决定降低覆盖** |

**开关语义：只认显式声明，禁止静默降级。**

```bash
M15_SINGLE_NODE=1 CLUSTER_NAME=hlvm-single bash scripts/m15-wsl.sh all
```

不做「检测到只有一个节点就自动跳过跨节点相位」的原因很直接：本套脚本大量断言以
「被测节点 ≠ 控制面」「节点间容量独立」为前提，环境削掉一层会表现为
**测试变少但仍然全绿**，与真实回归无法区分。所以只有一个开关，设了才按单节点跑，
并同步收窄结论范围。

**三条硬约束（违反即 FAIL / 立即退出，不会降级放行）：**

1. 声明单节点但实测 N>1 个节点 → `preflight` **FAIL**。多节点上跳过拓扑断言，
   等于用谎报的环境换「变少但全绿」；此时应去掉开关，而不是保留开关继续。
2. `M15_SINGLE_NODE=1` 且已有 kind 集群节点数 ≠ 1 → `bootstrap` 直接 `die`，
   提示先 `kind delete cluster`。bootstrap 可单独执行（不经过 preflight），所以两处都挡。
3. 未设开关而 `M15_TARGET=real` 且没有 worker → 仍按原逻辑 **FAIL**，只是报错文案
   多了一句「确为单节点部署请显式设 `M15_SINGLE_NODE=1`，并接受拓扑相位 SKIP」。

**相位影响（只有三处，其余断言强度不变）：**

| 位置 | 默认（多节点） | `M15_SINGLE_NODE=1` |
|---|---|---|
| `phase_check` | — | 打印「部署形态: 单节点」 |
| `preflight` worker 不变量 | 有 worker 才 PASS | 改判「声明与实测节点数一致」；并 WARN 结论不含跨节点调度 |
| `pick_test_node` | kind 取 `items[0]`；real 优先 worker | 显式取唯一节点（不靠 real 分支「worker 为空 → 回退」的副作用） |
| `bootstrap` 副本 | 按清单 2/2/3 | controller/webhook 缩到 1（贴合单机部署形态，非产品默认值） |
| `verify-topology-scale` | 4 组跨节点断言 | **显式 SKIP + 写明缺口**，不产出假绿 |

**单节点上仍然被验证的东西**（不要因为 SKIP 一条就以为单机没覆盖容量）：

- 单机容量上限、超发必 Pending、归还可再分配 → `verify-device-plugin` 第 4 步
  （申请满盘位全 Running → 多申请一个必须 Pending → 释放一个后能 Running）。
- 设备热插拔的双向增减去留 → `verify-device-hotplug`（8 条）。
- kubelet 重启后插件自愈重注册、checkpoint 恢复 → `verify-kubelet-restart`。
- CRD 双版本 / conversion / 证书轮换 / storedVersions 迁移 → 与节点数无关，全部照跑。

**单节点上仍然缺失的东西（写清楚，避免被当成已具备）：**

- 每节点容量独立记账、无选择子申请被调度到有容量节点、释放后**跨节点**回调度。
- 6.5b 节点扩缩容。
- HA：D=1 时三副本全在一台机器，PDB / leader 切换 / webhook 多活无对象可验。
- `topologySpreadConstraints` 在 D=1 时不起作用（永远 skew=0），单节点通过**不能**证明分散策略正确。

**实测（2026-11-03，kind 单节点 `hlvm-single`，K8s 1.36.1）**

| 项 | 结果 |
|---|---|
| `preflight` | PASS=5 WARN=4 FAIL=0（WARN 全是 kind 固有：swap / dm_thin_pool / 无 by-id / 无 lvm） |
| 全量 `all` | **116 PASS / 0 FAIL / 无 `[error]`**（多节点基线 126 PASS，差 10 条即拓扑相位） |
| `verify-topology-scale` | 显式 SKIP，日志给出缺口与替代覆盖 |
| `verify-velero` | SKIP（本机 kind 拉不动 docker.io 镜像，与节点数无关） |
| controller/webhook | 各 1 副本 Running |

**顺手修掉的一个脚手架缺陷：`all` 在全新集群上永远跑不起来。**

`all` 原顺序是 `check → preflight → bootstrap`，而 `preflight` 的第一条断言就是
「context 存在」。全新机器（或新的 `CLUSTER_NAME`）上集群还没建，preflight 直接 `die`，
现象是「一键 all 在干净环境必然失败；只有先手工 bootstrap 才能跑」。现在：

- `M15_TARGET=kind` 且 context 不存在 → 先 `bootstrap` 再 `preflight`（体检仍然在任何 verify 相位之前）；
- 其它情况（含 real）保持 `preflight → bootstrap`，真机首跑仍要求先单独体检。

### 10.17 by-id 多别名：选哪一个不是细节（2026-11-03）

**问题**：同一块盘在 `/dev/disk/by-id` 下常有多条别名。kind 实测 4 块 virtio 盘各有
`scsi-*` 与 `wwn-*` 两条。原实现是「遍历 `read_dir`，命中即返回第一条」，
而 `/dev` 是 tmpfs，`read_dir` 顺序＝目录项插入顺序（重启/换盘/驱动加载顺序都会变）。
后果不是报错，而是**同一块盘的 NodeDisk 名字在两次枚举之间漂移**：旧对象变孤儿、
新对象重复纳管同一块盘。

**现在的规则**（`agent/src/common/mod.rs::by_id_alias_rank`，两个入口共用）：

| 优先级 | 前缀 | 理由 |
|---|---|---|
| 0 | `virtio-` | 序列号来自 hypervisor 配置，与总线槽位无关 |
| 1 | `scsi-` | 带 vendor_model_serial，稳定；优先于纯位置类名字 |
| 2 | `nvme-`（含 `nvme-eui.*`） | NVMe 自身标识，天然唯一 |
| 3 | `wwn-0x...` | WWN 稳定，但常与 `scsi-*` 指向同一盘，作次选 |
| 4 | `ata-` | ATA 序列号稳定但信息量最低 |
| 5 | 其它（`dm-uuid-*`/`md-uuid-*`/`lvm-pv-uuid-*`/`usb-*`） | 虚拟或可重建标识 |

同优先级按名字字典序定序，保证**同一组候选在任何 `read_dir` 顺序下得到同一结果**。
未知前缀不返回 `None` 而是排最后——否则「有别名但都不认识」会退化成
`dev-<name>`，反而丢掉持久标识。

**收敛实现**：`plugin::resolve_by_id_in` 不再自己遍历，改为调用
`agent::resolve_by_id_under(root, path)`，两条路径（agent 模式 / 设备插件）不可能再选出不同名字。

**单测**（`cargo test --all-targets`，146 项）：

- `picks_stable_alias_regardless_of_order`：正反两种枚举顺序给同一结果；
- `alias_priority_follows_declared_order`：优先级顺序、未知前缀仍解析；
- `same_rank_breaks_tie_by_name` + 空输入返回 `None`；
- `resolve_by_id_in_picks_stable_alias_among_many`：临时目录里给同一设备造
  `wwn-*`/`scsi-*`/`ata-*` 三条别名，连续三次都选 `scsi-*`。

**仍未闭环**：`resolve_by_id` 只在有 udev 的环境才有别名可选，而 kind 节点无 udev、
`/dev/disk/by-id` 为空，走 `dev-<name>` 回退——真机上「别名稳定」这一条要等云主机首跑确认。

## 11. 版本与发布流程

### 11.1 版本号的单一事实源

仓库根 `VERSION` 是唯一事实源，CI 用 tag 名覆盖注入：

| 位置 | 用途 | 不同步的后果 |
|---|---|---|
| `VERSION`（根） | Go 侧 `-ldflags -X ...version.Version` | 二进制里版本号与 tag 不符 |
| `agent/Cargo.toml` `version` | `hlvm-agent --version` 与启动日志 | Agent 镜像标签与二进制自述不一致 |
| git tag `v<版本>` | 镜像版本标签 + GitHub Release | — |

`go job` 第一步有门禁：tag push 时若 `VERSION` 与 tag 去掉 `v` 后不一致，**直接失败**，
`images` job 不会跑（`needs: [go, rust]`），坏标签推不出去。

### 11.2 发版步骤

```bash
# 1) 改版本号（两处必须同步）
echo "0.2.0-preview.1" > VERSION
#    agent/Cargo.toml: version = "0.2.0-preview.1"

# 2) 写发布说明（release job 缺此文件会失败，强制要求限制声明）
$EDITOR docs/release-notes/v0.2.0-preview.1.md

# 3) 更新 CHANGELOG.md（新增条目，不覆盖历史）

# 4) 本地验证
cd control-plane && GOWORK=off go build ./... && go vet ./... && go test ./...
cd ../agent && cargo test --all-targets
cd .. && bash scripts/m15-integration.sh all      # 或经 scripts/m15-wsl.sh all

# 5) 提交并推送（CI 必须绿）
git add -A && git commit -m "chore(release): v0.2.0-preview.1"
git push origin main
#    等 CI success 再打 tag，避免留下指向坏提交的 tag

# 6) 打 tag 触发发布
git tag -a v0.2.0-preview.1 -m "v0.2.0-preview.1"
git push origin v0.2.0-preview.1
```

tag push 后 CI 会自动：构建并推送 4 个镜像的 `:v0.2.0-preview.1` + `:latest` →
创建 GitHub Release（正文取 `docs/release-notes/<tag>.md`，版本串含 `-` 时自动标 pre-release）。

### 11.3 镜像标签策略

| 触发 | 镜像标签 |
|---|---|
| `main` 分支 push | `:sha-<short>` + `:latest` |
| `v*` tag push | `:vX.Y.Z` + `:latest` |
| PR | 仅构建，不推送 |

**生产/集成环境一律引用 `:vX.Y.Z`**。`:latest` 只用于本地 kind 与临时排查——它会被下一次
main push 覆盖，用 `:latest` 跑出来的结论无法复现。

### 11.4 回滚

- 镜像：改清单引用回上一个 `:vX.Y.Z`（不要用 `:latest` 回滚，它已指向新构建）。
- CRD：`NodeDisk` 已是 v1beta1 存储版本，降级要先切 storage 版本并清理
  `status.storedVersions`（顺序见 §10.7 的实测记录，顺序错会被 apiserver 拒绝）。
- 发布事故：`gh release delete <tag> --yes` + `git push --delete origin <tag>`；
  已推送的镜像标签不建议删（可能已被引用），发新补丁版。
