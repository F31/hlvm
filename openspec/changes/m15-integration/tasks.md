# Tasks: m15-integration

> M15 集成里程碑跟踪变更。汇总 M14 收口时递延的 **19 项集成验证需求**（原分布于 6 个 M14 变更；observability / capacity-governance 已归档，其余 4 个仍活跃）。本变更不引入新 spec 能力，仅作跨能力集成验证的协调与跟踪载体。前置条件与诚实边界见 `proposal.md` 与 `docs/M14-closure.md`。
>
> 验收通过后，各 `[ ]` 项需回填至源变更 `tasks.md`：活跃变更（admission-scheduling / backup-restore / hardening-rollout / poc-decision-gate）原地 tick；已归档变更在其 `openspec/changes/archive/2026-10-29-*/tasks.md` 中 tick。
>
> 集成工具：`scripts/m15-integration.sh`（`check` / `bootstrap` / `build` / `verify-admission` /
> `verify-controller` / `verify-lvmd` / `verify-taskgc` / `verify-ttl` / `verify-agent` /
> `verify-device-plugin` / `verify-collector` / `verify-kubelet-restart` / `verify-conversion` /
> `verify-cert-rotation` / `verify-storage-migration` / `all`）；
> WSL 本地环境执行入口为 `scripts/m15-wsl.sh`（同步到 ext4 + 构建代理修正 + 转发子命令，见 1.8）；
> 诚实分流见 `docs/m15-integration-runbook.md`（§A kind 可自动化 vs §B 必须真实 LV / Velero / 评审灰度）。

## 1. 前置条件（M15 启动门槛）

- [ ] 1.1 测试集群就绪（K8s ≥ 1.36，与 envtest 版本对齐消版本差）
  - 进展（2026-10-29）：**envtest 版本差已消除**——`ENVTEST_K8S_VERSION` 由 1.33.0 升到 1.36.2
    （与 kind `kindest/node:v1.36.1` 同 minor），三个 envtest 全 PASS，并接入 CI 门禁
    （`make test-envtest`，此前 CI 完全不跑 envtest）。升级过程暴露并修复 2 类测试缺陷：
    ① controller 名称唯一性检查是**进程级全局集合**，多 envtest 同进程注册同名 controller 必失败
    （测试侧 `newEnvtestManager` 关闭该校验）；② 测试用缓存 client 写 status 触发 `not found` /
    `the object has been modified`（改直连 client + `RetryOnConflict`）。
  - 仍待：M15 要求的**目标测试集群**（真实硬件环境）尚未提供；本地 kind 仅为自动化验证载体。
- [ ] 1.2 真实 LV 硬件或可控仿真（thinpool 打满、拔盘、SMART 上报）
- [ ] 1.3 Velero 部署可用（backup-restore 5.1 闭环依赖）
- [x] 1.4 cert-manager + control-plane Dockerfile（admission 4.3 动态层 mutating webhook 的证书机制）
  - 已完成（2026-10-29 kind 实测）：Dockerfile 在 WSL docker 构建并 `kind load`；cert-manager v1.17.2
    三组件 Ready；Certificate 签发与 caBundle 注入正常；webhook（3/3）与 controller（2/2）均 Running；
    admission 4.3 注入链路验证 PASS（详见 §4.1）。
  - **生产默认运行态镜像已验证**：`gcr.io/distroless/static:nonroot`（sha256:18f4cc26…）经代理拉取成功，
    两个镜像均以 distroless 构建（`User=65532:65532`、`Entrypoint=/app`、14.3MB，对比 golang 基础镜像 1.31GB，
    镜像内无 shell）；`kind load` 后滚动更新成功，distroless 运行态下 `verify-ttl`(5) / `verify-controller`(4) /
    `verify-lvmd`(10) / `verify-taskgc`(6) / `verify-admission` **全部 PASS**。
  - **CI 已确认（2026-10-30）**：run `40888920900`（HEAD `1ffb629`）4 个 job 全 `success` ——
    `Go (control-plane)` / `Rust (agent)` / `Container images` / `Ready`。其中 Rust job
    即 `cargo test --all-targets` 的 CI 证据（agent 侧 TTL 复核 11 例单测），images job 在 main push 上
    `push: true`，两镜像已推送 GHCR。此前「本机无 `gh` 无法确认」的记录作废：仓库 Actions 可匿名只读
    （`curl api.github.com`，Windows 侧需 `--ssl-no-revoke`，否则代理下 schannel 报
    `CRYPT_E_REVOCATION_OFFLINE` 易被误判为代理不通）。
  - **补齐 agent 镜像构建（2026-10-30）**：核对发现 CI images job 此前**只**构建 controller/webhook，
    而 `agent/config/daemonset-agent.yaml` 与 exporter 清单都引用 agent 镜像 —— 该镜像从未被构建/推送，
    真实集群部署必然 `ImagePullBackOff`（本机无 Rust 链接器也无法本地补建）。现已：rust job 上传
    `hlvm-agent-bin` artifact（`if-no-files-found: error`），images job `needs: [go, rust]` 后下载并
    用 `agent/Dockerfile` 构建推送 `ghcr.io/f31/hlvm/storage-agent:latest`；同时统一 exporter 清单里
    的旧名 `ghcr.io/f31/hlvm/agent:latest`（原标注「占位」）为 `storage-agent`。
  - **CI 实测通过（2026-10-30，run `40970587925` / `45b7ea4`）**：4 job 全 success；`Rust (agent)` 的
    `Upload agent binary`、`Container images` 的 `Download agent binary` 与三个 `Build & push`
    （`storage-controller` / `storage-webhook` / **`storage-agent`**）均 success，即 agent 镜像已实际推送。
    因包为私有，无法用匿名 token 二次复核包内容，此处以 push step 成功为准。
  - 余项（不阻塞本项）：GHCR 包为**私有**（匿名 token 端点 401），真实集群部署须注入 `imagePullSecret`
    （见 runbook §6）；目标测试集群仍需自行安装 cert-manager 并注入 CA。
- [ ] 1.5 评审 / 灰度流程就位（hardening-rollout、poc-decision-gate）
- [x] 1.6 节点 Agent 真机部署验证（本轮补充，不在原 19 项内）
  - 背景：Agent **此前从未在集群中运行过**（镜像未构建、SA 错配、节点名未注入），三类缺陷因此长期不可见。
    `verify-agent` 首次真跑逐条暴露并修复（2026-10-30）：
    ① `hlvm-agent` SA 在 `kube-system`、DaemonSet 在 `hlvm-system` → Pod 因
       `serviceaccount "hlvm-agent" not found` 无法创建；已统一到 `hlvm-system`
       （`v2-chaos-kind.yaml` 同步）；
    ② 未读 Downward API 注入的 `HLVM_NODE_NAME`/`NODE_NAME`，缺省回退 `"unknown"`；而任务过滤是
       `spec.nodeName == node` → Agent 表面健康却**永不执行任何任务**。现按 命令行 > `HLVM_NODE_NAME`
       > `NODE_NAME` 解析，缺失即失败关闭；
    ③ `lsblk -J -b` 的 `size` 为 JSON 数字，模型却是 `Option<String>` → discovery 整体解析失败。
       现兼容数字/字符串（附 3 例单测）。
  - 首批实测（`verify-agent`，6 断言全 PASS；本轮扩至 7）：Pod 就绪 / 节点名注入正确 / kube 客户端与两条回写循环建立 /
    discovery 无错 / agent 自主回写 StorageTask 状态（`phase=Failed`，`message=No such file or directory
    (os error 2)`，证明 `storagetasks/status` 写权限可用）/ NodeDisk 观测写回（`health=healthy`，21s）。
  - **第二批缺陷（2026-10-30 同日暴露，均为「静态看起来对、真机跑不通」）**：
    ④ **「特权最小化」实际废掉了数据面**：按 hardening 4.1 改为 `privileged: false` + drop ALL +
      add `SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO` 后，容器内 uid=0 **仍读不了块设备**（`dd if=/dev/loop77`、
      `blkid`、`wipefs` 全部 `Operation not permitted`）。根因是 runc 的 **device cgroup** 过滤器，与
      capability 无关：非特权 Pod 的 device allowlist 为空。结论是 wipe/pvcreate（唯一写路径）与签名预检
      在生产环境必然失败。已按 spec（agent 特权、读写）回退 `privileged: true`，并加清单级防回归
      `deploy_manifests_test.go::TestAgentDaemonSetIsPrivileged`（负向验证：改回 false 即报错）。
      非特权的替代路径只有 device plugin 按盘分配（未实现）。
    ⑤ **`occupiedBy` 恒 `none`，签名规则从未生效**：观测路径硬编码 `occupied_by: None` / `is_pv: false` /
      `holders: []`；同时签名探测调 `blkid --json`——**blkid 没有 `--json` 选项**（那是 lsblk 的），
      命令必然失败 ⇒「存在 fs/LVM/md 签名即拦截纳管」在真实路径上从未执行（单测只喂解析函数，掩盖了它）。
      现改为 `blkid -o export` 取签名、lsblk `TYPE/FSTYPE` 辅助、`pvs` 确认 PV，按 CRD 枚举写
      `filesystem|lvm-pv|md|mpath|holder|none`；探测失败写 `unknown` 并失败关闭（关键坑：blkid 的
      EPERM 与「无签名」**同为退出码 2**，故「2 且 stderr 非空」判为失败）。跨语言枚举漂移由
      `occupiedby_enum_test.go` 直接比对 Go 枚举与 Rust 常量（负向验证有效）。
  - 断言增至 **7** 条（新增：节点内建 ext4 loop 设备 → 要求 `occupiedBy=filesystem` 且 phase 不推进到
    `PreChecked`）。全链 `all` 复跑：8 阶段 **32 PASS / 0 FAIL**；`cargo test --all-targets` 116 passed、
    `go vet/test` 全绿。
  - exporter 的 SMART 缺口：三条路中已选 **「引入 device plugin」**并落地（见 1.7）。但设备插件只能表达
    「申请 N 块」，表达不了 DaemonSet 需要的「本节点全部盘」，故 **exporter 清单未改、SMART 仍缺失**；
    正解是「每盘一个 collector Pod」，属后续变更（`add-disk-device-plugin` 6.1）。
  - 顺带修复：`agent/config/daemonset-agent.yaml` 中重复的 exporter DaemonSet 已删除（唯一来源为
    `control-plane/config/exporter/daemonset.yaml`），避免每节点跑两个 exporter。
  - 诚实边界：kind 无真实 LV，本项只验证「连 API / 按节点过滤 / 写回状态」，不覆盖 wipe、pvcreate 真实执行
    （需 1.2 硬件）；阶段结束会撤掉 DaemonSet（`verify-ttl` 依赖「无 agent」前提），不留常驻 Agent。

- [x] 1.7 磁盘设备插件（K8s Device Plugin v1beta1，`hlvm.io/disk`）—— 本轮补充，不在原 19 项内
  - 动机：1.6 的④（非特权 Pod 读不了块设备，根因是 devices cgroup）只登记为「需 device plugin 才能恢复
    非特权」，本次把它做出来。变更详情见 `openspec/changes/add-disk-device-plugin/`。
  - 实现：`--mode=device-plugin`（同一二进制）；v1beta1 gRPC over Unix socket；自注册 + `kubelet.sock`
    inode 变化自动重注册；`Allocate` 下发宿主真实节点路径；系统盘经宿主 `/proc/1/mountinfo` 剔除。
  - 清单：`agent/config/daemonset-device-plugin.yaml`（**非特权**，`drop ALL`，只读根；宿主 `/dev` 挂到
    `/host/dev` 而不是 `/dev`——runc 的 tmpfs 会盖住）。
  - 实测（`verify-device-plugin`，kind 1.36，2026-10-30）：**7 断言**全 PASS——插件 Pod 就绪 /
    `allocatable.hlvm.io/disk=2` / 非特权 Pod 申请后 `READ_OK` / **未申请的同条件 Pod `EPERM`** /
    盘位用满时全部 Running / 再申请一个被 `Insufficient hlvm.io/disk` 拒绝 / 释放后转 Running。
    两条对照是关键：EPERM 排除「环境本来就允许」，超发被拒排除「容量账其实没生效」。
  - 踩坑：① tonic 无内建 UDS connector，`Endpoint::try_from("unix:/...")` 直接 `invalid URI`；
    ② 宿主机 `/dev` 挂容器 `/dev` 无效（`/dev` 是 runc 建的 tmpfs，`/dev/disk/by-id` 不存在）；
    ③ kind 节点连 `/dev/disk` 都没有（无 udev），设备 ID 只能回退 `dev-<name>`；
    ④ 设备节点是 `brw-rw---- root:disk`，非 root 消费者会 EACCES（**不是** EPERM），故验证用 uid0+非特权；
    ⑤ 扩展资源的 `allocatable` 是**静态上限**（kubelet 不因分配扣减），用「allocatable 变小」判容量
    会得到错误结论——第一版就是这么写错的。
  - 诚实边界：**agent 仍 privileged**（需全部盘，插件表达不了全集）；插件不采 SMART（`Health` 恒
    `Healthy`）、不做纳管决策；真实节点的 by-id 分支未在 kind 覆盖。exporter 的 SMART 缺口已由 1.9
    的每盘 collector 关闭（形态改为「一个 NodeDisk 一个 Pod」）。

- [x] 1.8 WSL 部署测试入口（`scripts/m15-wsl.sh`）—— 本轮补充，不在原 19 项内
  - 动机：后端部署测试统一在 **WSL 本地环境**执行。Windows 侧与 WSL 是两个独立的 docker daemon
    与 kind 集群（`docker ps` 互不可见），此前在 Windows 侧验证的镜像/集群不能作为 WSL 结论；
    而直接在 `/mnt/e`（9p）上构建又慢一个量级。
  - 实现：入口脚本先 `rsync` 工作树到 WSL ext4（`~/hlvm`，排除 `.git`/`target`/构建产物），
    探测 docker0 网关上的代理转发器后修正构建代理，再原样转发子命令给 `m15-integration.sh`；
    不改变任何断言与阶段语义。
  - 实测（2026-10-30，WSL2 Ubuntu 24.04 / Docker 29.4.1 / kind 1.36.1）：
    `all` 连续 3 次 exit 0，**42 PASS / 0 FAIL**（13 个阶段标题齐全，含 10 个 m15 阶段）；
    设备插件阶段 `allocatable.hlvm.io/disk=2`、`READ_OK=/dev/sda`、对照组 `EPERM`。
  - 关键修复：`HTTP_PROXY` 被 WSL 自动注入为 `127.0.0.1:7890`，而构建容器内的 127.0.0.1 是
    **容器自身**——实测容器内直连外网超时（`wget: download timed out`），仅 `172.17.0.1:17890`
    可达。入口脚本探测成功才覆盖，并以 `--no-cache-filter=builder` 验证：`go mod download`
    真实联网 37.3s、编译 19.2s 成功。不修则只要依赖文件变更、缓存失效就会「网络错误」失败。
  - 踩坑：① Git Bash → `wsl.exe` 传参时 shell 变量会被中间层吞掉（`printf "%s" "$x"` 输出空），
    故全部逻辑落在脚本文件、Windows 侧只传子命令名；② `/mnt/e` 作为参数会被 MSYS 改写成
    `E:/...`，需 `MSYS_NO_PATHCONV=1`；③ 脚本 stdout 为块缓冲、docker build stderr 无缓冲，
    合并重定向后阶段标题会被插断（**不代表阶段没跑**），审计时应 `> out.log 2> err.log`。
  - 诚实边界：同步是**单向**的（Windows → WSL），WSL 内生成的 `agent/hlvm-agent` 不回写工作树；
    WSL 的 kind 节点盘片布局（`sda/sdb/sdc/sdd`，无 `by-id`）与真实节点不同。

- [x] 1.9 `verify-collector` 阶段：每盘一个 collector Pod 的端到端验证 —— 本轮补充，不在原 19 项内
  - 动机：设备插件解决「非特权 Pod 能按盘读设备」后，exporter 仍缺 SMART（DaemonSet 需要全部盘，
    而扩展资源只能申请静态数量）。正解是控制面按 NodeDisk 建**单盘** collector Pod。
  - 实现：`disk_collector_controller.go`（建/删/漂移重建/孤儿回收/盘位保护）+ `collector_role.yaml`
    + exporter 侧 `HLVM_EXPORTER_DEVICE=auto`（枚举容器内**实际可见**块设备）；脚本新增本阶段。
  - 实测（2026-10-30，WSL 内 kind 1.36）：**9 断言**全 PASS（申请 1 块盘 / `privileged:false` /
    未挂宿主 `/dev` / Ready / `/metrics` 有盘级 SMART 序列 / 删除 NodeDisk 后回收 /
    盘位保护：3 个 NodeDisk + 2 盘位只生成 2 个 Pod / 批量删除后无残留）；`all` 全链
    **84 PASS / 0 FAIL**、真实退出码 0（含 1.10 的 9 条、1.11 的 12 条与 1.12 的 15 条）。
  - 两个反直觉事实：① **分到哪块盘由 kubelet 决定**——实测声明 `deviceRef: /dev/sda` 却拿到 `sdb`，
    故采集侧必须按实际设备打标，硬编码 `deviceRef` 会把 A 盘读数标成 B 盘；
    ② NodeDisk 是 Cluster-scoped、Pod 是 namespaced，**设 ownerReference 会让 GC 立即删掉 Pod**，
    回收只能由控制器在 NodeDisk 删除的 NotFound 分支全量比对完成。
  - 踩坑：① 集群早于 `collector_role.yaml` 创建时控制器只看到 `pods is forbidden`、Pod 永不出现
    → 本阶段自带 apply RBAC 兜底（与其他 verify 阶段一致，可独立执行）；
    ② controller 默认镜像是 `ghcr.io/...:latest`，`:latest` 默认 `Always` 拉取 → GHCR 包私有直接 401，
    Pod 卡 `ImagePullBackOff` → 阶段内显式 `set env HLVM_AGENT_IMAGE` 指向本地 dev 镜像并等滚动完成；
    ③ port-forward 后 **curl 必须 `--noproxy "*"`**，否则 WSL 注入的 `HTTP_PROXY` 会把 127.0.0.1 也
    走代理，拿到的是代理错误页而非指标。
  - 边界：kind 的 virtio 盘不支持 SMART，健康值走文档化回退（`0`＝healthy，与真健康不可区分）；
    本阶段证明的是「授权链路 + 端点 + 生命周期」，**不是**「SMART 数值正确」。
- [x] 1.10 `verify-kubelet-restart` 阶段：kubelet 重启后的插件自愈与 checkpoint 恢复 —— 本轮补充
  - 动机：设备注册状态只存在 kubelet 内存里，而 kubelet 重启是常规运维。实测三处失败叠加后，
    节点 `hlvm.io/disk` 归零且**永不恢复**（只能删插件 Pod 救回）：kubelet 启动清空插件 socket /
    `kubelet.sock` 重建复用 inode / 注册 RPC 无超时挂死。修复见 add-disk-device-plugin 6.5a。
  - 实现：`agent/src/plugin/mod.rs`（mtime 签名、socket 重建监听、5s 注册超时 + 300s 兜底）；
    脚本新增本阶段（9 断言），并挂进 `all` 末尾。
  - 实测（2026-10-30，WSL 内 kind 1.36）：自愈 **2–4s**，`allocatable` 恢复 2，运行中容器
    `containerID` 不变，插件 Pod 未被重建，checkpoint 保留原分配，重启后新 Pod 拿到另一块盘
    （A=`sda` / B=`sdb`）。单测 139 → 141。
  - 判据坑：数注册次数不能用 `--tail`（重启前那次也在里面，恒判「已自愈」），必须
    `--since-time=<重启前 T0>`；也不能用「重启后立刻读 allocatable 是否掉零」判断是否掉零，
    node status 有上报延迟。
  - 边界：只用 `docker exec <cluster>-control-plane systemctl restart kubelet`，**仅 kind**；
    非本机容器集群打印「跳过……未覆盖」并 `return 0`，不计 PASS。调度器拓扑、扩缩容仍属 6.5b。
- [x] 1.11 `verify-conversion` 阶段：CRD 双版本 + conversion webhook（对应 add-hardening-rollout 3.1b）
  - 动机：3.1 只交付了骨架（无 `cmd/crd-conversion`、CI 不构建镜像、CRD 无 conversion 配置），
    清单还写着「请勿 apply」——属于"标了完成但不可用"。本轮把能力本体做出来并验证。
  - 实现：`control-plane/cmd/crd-conversion`（独立 HTTPS 服务，`conversion.NewWebhookHandler` +
    certwatcher 热加载 + 启动自检）；`control-plane/api/v1beta1`（NodeDisk 试点）+ v1alpha1 的
    hub/spoke 转换；清单拆为 `03-crd-conversion.yaml`（服务/证书）与
    `03b-nodedisk-dual-version.yaml`（双版本 CRD），CI 增加该镜像构建推送。
  - 实测（2026-10-30，WSL 内 kind 1.36）：**12 断言全 PASS**——服务 2 副本就绪 / cert-manager
    签发证书 / caBundle 注入（1504B）/ `strategy=Webhook` / `preferredVersion=v1beta1` /
    `deviceRef`→`device.path` 正向映射 / v1beta1 视图不含 `deviceRef` / 反向写入 v1alpha1 读回 /
    列表两版本条目数一致 / **webhook 缩到 0 后 v1beta1 读失败** / 同时 v1alpha1 仍可读 /
    恢复副本后自愈。单测 4 条（往返无损、JSON 全字段等价、空设备、列表）。
  - 判据坑：**裸资源名会被解析到 v1beta1**（preferredVersion 由版本优先级决定，与存储版本无关），
    `.spec.deviceRef` 直接读空，看起来像"转换丢字段"；脚本一律显式写
    `nodedisks.v1alpha1.storage.example.io`。另有 **kubectl discovery 缓存**约 10 分钟：
    重启服务/移除版本后裸资源名仍打到已移除版本，报 404 `could not find the requested resource`
    （实测把后续 `all` 的 verify-taskgc 跑挂），故 `conversion_cleanup` 里清
    `~/.kube/cache/discovery`。
  - 边界：storedVersions 切换见 1.12；其余 4 个 Kind 未版本化，
    证书轮换只验证了"会签发 + 会热加载"，没有真实过期演练。步骤与回滚路径见 runbook §10.5。
- [x] 1.12 `verify-storage-migration` 阶段：storedVersions 切换与回滚（对应 add-hardening-rollout 3.1c）
  - 动机：1.11 只做到"两个版本都能读"，v1beta1 还不是存储版本；而切换存储版本正是升级能力
    真正落地的那一步，也是唯一会**改数据落盘格式**的动作，不演练就等于没有。
  - 关键判据：**不看 API 返回值，看 etcd 里的原始字节**。CRD 的 `status.storedVersions` 表示
    「etcd 里可能存在的版本」，切存储的瞬间就写入新版本（实测），而对象字节此时还是旧版本；
    且它只增不减。直接用它判断"迁移完成"会得出错误结论。
    etcd 容器是 distroless（无 `sh`，`kubectl exec` 进不去），改从节点容器的 curl 走
    etcd v3 gateway（`/v3/kv/range`），取回的 value 是 base64 protobuf，解出来 grep 版本串。
  - **15 断言**（2026-10-30，WSL kind 1.36 全 PASS）：服务就绪 / schema 护栏 / 初始落盘 v1alpha1 /
    切存储 / **storedVersions 已含 v1beta1 而字节仍 v1alpha1**（判据陷阱）/ 迁移期老客户端可写且
    自动落盘 v1beta1 / 重写后落盘 v1beta1 / spec 规范化一致 + status 逐字段相等 /
    **webhook 下线后连 v1alpha1 也读不了**（爆炸半径扩大）/ 恢复自愈 /
    **K8s 拒绝在 storedVersions 未清时移除 v1beta1** / 清 storedVersions 后两版本仍可读写 /
    回滚 storage 后对象仍 v1beta1 落盘但两版本可读 / 回滚后重写才回到 v1alpha1 落盘 / 收尾干净。
  - schema 护栏：把「v1alpha1 的字段路径集 − v1beta1 − {spec.deviceRef}」断言为空。
    转换函数写对不代表不丢字段——apiserver 的 pruning 看的是 CRD schema，不是 Go 结构体；
    这条挡的是「以后给 v1alpha1 加字段、忘了映射到 v1beta1」导致的静默丢数据。
  - 实测结论（runbook §10.6）：① `storedVersions` 不能当判据；② 迁移期不必停写；
    ③ 切存储后爆炸半径扩大，**回滚不是 webhook 故障的逃生通道**；
    ④ 移除「曾是存储版本」的版本会被 K8s 拒绝，必须先清 `storedVersions`
    （第一次跑收尾就栽在这里，错误被 `|| true` 吞掉，改用 `--dry-run=server` 把护栏变成断言）。
  - 边界：控制器仍用 v1alpha1 读写（v1alpha1 不能下线）；演练仅 3 个对象，未验证批量重写耗时与
    中断续跑；kind 单控制面，多 apiserver 副本转换行为未观测。

- [x] 1.13 `verify-cert-rotation` 阶段：serving 证书轮换与固定 CA（对应 add-hardening-rollout 3.1d）
  - 动机：1.11 的边界写着「证书轮换只验证了会签发 + 会热加载，没有真实过期演练」。真去补这一步
    时发现的问题比「没演练」严重得多：原 `selfSigned` 方案在证书重建时会**换掉校验链的根**，
    而 caBundle 由 cainjector **异步**重注入 → 中间 8–45 次调用失败、服务端持续
    `tls: bad certificate`，而 Pod 全程 `Ready`、`restartCount=0`（假 Ready）。
  - 实现：清单改「固定根 CA（10 年、私钥不轮换）→ CA Issuer → serving 证书」，
    conversion 与 storage-webhook 各一套独立 CA（两份清单都能单独 apply）；
    脚本新增本阶段（16 断言），并把镜像构建抽成 `ensure_conversion_image` 复用。
  - 实测（2026-10-30，WSL 内 kind 1.36）：**16 条全 PASS**。服务端实际证书切换耗时 74s、
    根 CA 与 caBundle 全程不变；反证成立（改回 selfSigned 后两者都变）。
  - 判据坑（三条都会让人得出反向结论）：① 不能按 **长度** 判 caBundle 是否变化（自签证书重建后
    PEM 长度常一字不差）；② 不能读 **secret** 判证书是否生效（kubelet 同步 61–74s，
    secret 已新、进程仍旧）；③ 不能 grep **日志** 判热加载。
  - 顺带修复：`verify-admission` 对「未注入」原来只 `warn`、退出码仍 0，于是「证书失配 +
    `failurePolicy: Ignore` 静默不注入」会被判为通过（本轮切链时真撞上了）。现改为 `fail`，
    并新增「caBundle 能验证 serving 证书」断言。
  - 边界：真实到期续签未观察（cert-manager 最小 duration 1h）、根 CA 自身轮换未演练、
    一次性迁移到固定 CA 有约 1 分钟窗口（建议维护窗口执行）。

- [x] 1.14 修复「设备插件重建窗口」与「CP 镜像构建离线假失败」两处判据缺陷 —— 本轮补充
  - 触发：1.13 后跑全量 `all`，前 12 阶段全 PASS，`verify-device-plugin` 却出现两条 FAIL
    （`申请资源的 Pod phase=Failed` + `读不到设备`），且 `kubectl logs` 报
    `container "probe" is not available`。取证 kubelet 日志得到确切原因：
    `Pod admission denied ... UnexpectedAdmissionError: Allocate failed due to no healthy
    devices present`。时间线：上一阶段 `plugin_cleanup` 删掉 DaemonSet → 旧插件进程退出使 kubelet
    的 `ListAndWatch` 断开 → 脚本只等 `rollout status`（Pod Running）就立刻建申请设备的 Pod，
    而此时新插件**尚未完成 gRPC 注册**，设备 unhealthy，容器根本没被创建。
  - **判据缺陷**：`status.allocatable` 是 kubelet 的静态上限缓存，插件断开期间**不清零**，
    仍读到旧值 2；`rollout status` 也只保证 Pod Running。两者都不能证明「设备可分配」。
    这与 8.3 已记的「allocatable 是静态上限」认知一致，但在插件重启窗口下更具误导性。
  - 修复：抽 `deploy_plugin_and_wait` helper——先删旧 DS 保证 Pod 真的重建（必然产生新注册日志），
    等 rollout 后再等「**本次**（`--since-time`）注册日志」出现，最后留 3s 给 kubelet 把设备标为
    healthy。`verify-device-plugin` / `verify-collector` / `verify-kubelet-restart` 三处共用
    （此前 collector/restart 也各自只等 rollout 就申请盘，同样的坑）。三者单独重跑分别
    7 / 9 / 9 断言全 PASS。
  - **CP 镜像构建离线假失败**：全量 `all` 走到 `verify-conversion` 才炸——`docker build` 的
    `FROM gcr.io/distroless/static:nonroot` 触发 buildkit `load metadata` 重新解析，报
    `Head ... EOF`（本地 daemon 代理指向无监听的 7892）。此前要靠外部 `RUNTIME_IMAGE=scratch`
    规避，漏设就假失败。现加 `cp_build` 统一 helper：只在**明确的** manifest/front-end/授权类
    网络错误时自动回退 `RUNTIME_IMAGE=scratch`，并记住结论（`CP_RUNTIME_FALLBACK`）让本轮后续
    镜像直接走 scratch、不再逐个白等超时。
  - **三个验证陷阱（都实测过，别再踩）**：① 外部探测（`manifest inspect` /
    `buildx imagetools`）与 build 内 `load metadata` 走不同代理路径，imagetools 3s 可达但 build
    内仍 EOF，**不能用外部探测预判**；② 不要 `docker buildx prune -af` 清缓存做验证——它会连
    Dockerfile 第一行 `# syntax=docker/dockerfile:1` 的 front-end 一起清掉（front-end token EOF，
    与 RUNTIME_IMAGE 无关，回退 scratch 也救不了），还会清掉 `go mod` 的 buildkit cache mount；
    ③ 冷缓存下 `go mod download` 走容器代理（单请求约 5s、55 个直接依赖）要几分钟——**纯超时
    （rc=124）不该触发回退**（回退 scratch 一样要跑 go mod download，徒劳）。判据只认错误文本。
  - 环境恢复：`hlvm-gomod` 命名卷保有完整 Go 模块缓存；front-end 镜像 `docker/dockerfile:1`
    经 CLI 代理（`127.0.0.1:7890`）重试可恢复；`go mod` 的 buildkit cache mount 需一次完整
    联网下载重新预热（单次给 900s）。
- [x] 1.15 NodeDisk 收敛到 v1beta1 后的脚本适配（2026-10-31，对应 hardening 3.1e）
  - 改动范围：**NodeDisk 的存储版本从 v1alpha1 翻到 v1beta1**，因此凡是「以哪个 API 版本读写、
    以哪个版本落盘、webhook 挂了谁受影响」的判断都要跟着翻——不是换字符串，是重写判据。
  - 常规阶段的 NodeDisk manifest（5 处：taskgc / lvmd / collector ×2 / 容量）：改
    `apiVersion: storage.example.io/v1beta1` + `spec.device.path`。其余 Kind
    （NodeVG / StorageTask / StorageNodeOps / ThinPoolPolicy）仍 v1alpha1，**一处未动**。
    这里最容易误伤：grep `v1alpha1` 会得到几十处，绝大多数属于别的 Kind。
  - `verify-conversion`（仍是 12 断言）：
    - 第 5 条现在是**写入路径**转换（以 v1alpha1 写 → 经 webhook → 以 v1beta1 落盘），
      第 6 条是**读取路径**转换（以 v1beta1 写 → 读 v1alpha1 触发转换），方向性写进注释；
    - 第 8/9 条爆炸半径**反转**：webhook 下线后 **v1alpha1 读失败**（不再是 v1beta1），
      **v1beta1 仍可读**（它现在是存储版本）——这才是「控制器不受影响」的现代表述；
    - cleanup 顺序：先删对象（此刻双版本都 served）再 `apply` bases 单版本，反了会残留。
  - `verify-cert-rotation`（仍是 16 断言）：两条可用性判据从「读 v1beta1」改成「读 v1alpha1」。
    原因：v1beta1 现在是存储版本、读取**不经 webhook**，它能不能读证明不了 TLS 链路；
    只有读会触发转换的 v1alpha1 才是真判据。teardown 同理要先删对象再恢复 bases。
  - `verify-storage-migration`（仍是 15 断言，**方向整体反转**）：现在是
    v1beta1 →（切存储）→ v1alpha1 →（回滚）→ v1beta1。schema 护栏也随之反过来，
    断言「v1beta1 的字段路径（除 `spec.device.path`）在 v1alpha1 里都有对应」。
    storedVersions 时间线重新推演过，护栏仍会被触发（`--dry-run=server` 把它变成断言）。
  - **新增 `ensure_nodedisk_crd_baseline`（bootstrap 缺口）**：旧集群里 CRD 还是 v1alpha1 存储、
    `storedVersions=["v1alpha1"]`，直接 `apply` 新的单版本 bases 会被 K8s 护栏拒绝——
    不修的话切换后**任何人第一次跑 `all` 必挂**。处理按「有没有数据」分叉：
    无 NodeDisk 对象 ⇒ 删 CRD 重建（`storedVersions` 随 CRD 消失，唯一免迁移的归位路径）；
    有对象 ⇒ 直接 `die` 要求先走迁移流程，**不替使用者删数据**。
  - 环境变量传递：Windows 侧设的 `RUNTIME_IMAGE` 经 `wsl.exe` 会被中间层吞掉（实测
    `bash -c 'RUNTIME_IMAGE=scratch; echo $RUNTIME_IMAGE'` 输出为空），必须写进脚本文件里。
    本轮用临时 wrapper（已删除）把 `RUNTIME_IMAGE=scratch` 写死，跳过 distroless 的
    480s 超时探测，直接走热缓存路径。
  - 结果（2026-10-31，WSL kind 1.36）：**`all` 112 PASS / 0 FAIL、真实退出码 0**、
    19 个阶段标题全绿；Go `vet`+`test`+envtest、Rust `fmt`+`check`+141 测试均通过。
- [x] 1.16 `verify-device-hotplug`：设备热插拔与「设备节点就绪才暴露」（2026-10-31，
  闭环 `add-disk-device-plugin` 6.3，同步修掉一个 Pod 黑洞缺陷）
  - 原标注「需真实可插拔硬件」过于保守：kind 节点容器 privileged（`CapEff` 含
    `CAP_SYS_MODULE`），容器内 `modprobe scsi_debug` 能造出真整盘（`type=disk`、
    `/sys/block` 可见），与物理拔插在内核层是同一类事件。无此能力的环境（非 Linux 宿主 /
    docker-desktop / 无 `CAP_SYS_MODULE`）打印「跳过」并 `return 0`，**不计 PASS**，
    与 `verify-kubelet-restart` 的 kind 限定保持一致。
  - **沿途发现并修掉一个会静默吃掉 Pod 的缺陷**（`agent/src/plugin/mod.rs` 的 `rescan()`）：
    `lsblk` 读 sysfs，设备一注册到内核就出现在列表里，而 `/dev/<name>` 由 udev **稍后**
    建立 ⇒ 插件过早暴露 ⇒ `allocatable.hlvm\.io/disk` 虚高 ⇒ 调度器敢把「申请这块盘」
    的 Pod 放到该节点 ⇒ kubelet 注入设备时 `lstat /dev/sde: no such file or directory`，
    Pod 永久停在 `CreateContainerError` 并持续重试。
    修复：`select_disks` 之后再过一道 `host_node_ready`（宿主 `$HLVM_DEVICE_ROOT` 下必须是
    真实块设备），丢弃时打 warn 明示原因。宁可晚一轮暴露，也不让 Pod 掉进黑洞。
    Rust 单测 141 → **142**。
  - 阶段 8 条断言按生命周期排布，其中两条是「不只看数字」的关键：**插入前申请 `N+1`
    必 Pending**（对照组——没有它，就证明不了容量增量来自新盘而不是原本有余量）；
    **mknod 补上设备节点后同一个 Pod 真正 Running**（修复前此处正是 CreateContainerError）。
  - 两条交付纪律：① 内核模块是**宿主机全局可见**的，而本阶段多处 `die` 是 `exit`，
    故用 `trap hotplug_cleanup EXIT` 兜底，并在收尾断言「模块已卸载 + 盘集合还原」——
    断言通过却把副作用留在机器上等于没通过；② 修复不得变成「永不暴露」，
    断言 5/6 专门盯着这一半。
  - 结果：`verify-device-hotplug` 单独跑 **8 条全 PASS、exit 0**（事后用最终脚本复跑确认）。
    全量 `all` 首轮 **107 PASS / 0 FAIL 但退出码是 1**——断言全绿不代表通过，详见 1.17：
    storage-migration 的收尾缺陷让脚本在最后一个阶段之外崩掉，且错误信息被 trap 掩盖。
- [x] 1.17 修三处「把真实失败原因藏起来」的收尾缺陷（2026-10-31，第一轮 `all` 跑出 exit 1 后的查证成果）
  - 起因：`all` 跑出 **107 PASS / 0 FAIL 却 exit 1**，且 stderr 只有两句莫名其妙的
    `line 2971: crd: unbound variable`。没有任何一条断言失败，退出码却是 1——
    这类现象必须查到底，否则「看 PASS/FAIL 数量」就成了自欺欺人。
  - **根因 1（真正的故障）**：`stored_api` 里 `docker exec ... curl https://127.0.0.1:2379`
    被代理劫持。kind 节点容器会继承宿主的 `https_proxy`（本项目为给容器构建配的
    `172.17.0.1:17890`），curl 于是 `CONNECT 127.0.0.1:2379` ⇒ `TLS connect error:
    handshake failure` ⇒ 响应为空。etcd 直读是整个迁移阶段唯一的判据来源，它一空，
    后续判断全部崩塌。修复：本地回环请求一律加 `--noproxy '*'`。
  - **根因 2（放大故障）**：`stored_api` 末尾 `grep -ao ... | head -1` 在无匹配时返回 1，
    而脚本是 `set -e` + `pipefail` ⇒ `api="$(stored_api ...)"` 这条赋值直接让脚本退出，
    连 fail_msg 都来不及打。修复：末尾补 `|| true`，让「读不到存储版本」落成一条
    明确的 FAIL 断言，而不是静默崩脚本。
  - **根因 3（掩盖线索）**：`migration_cleanup` 是 `trap ... EXIT` 的目标，却引用了
    函数级 `local` 变量（`crd`/`beta`/`bases`/`na`/`nc`）。阶段正常返回后变量已销毁，
    trap 在脚本退出时才跑 ⇒ `set -u` 报 unbound ⇒ **真正的失败原因被这一句替代**。
    修复：cleanup 开头 `[ -n "${crd:-}" ] || return 0`——变量还在说明是阶段中途失败
    （正是需要兜底清理的时刻），已销毁说明清理点已过。
  - **同类隐患一并处理**：`collector_cleanup`（`${disk}`/`${pf_pid}`）与
    `conversion_cleanup`（`${name}`）是同一个模式，同样会在未来掩盖失败原因，
    一并加了兜底。项目里第 2651 行早就写明这条约定，只有这三处没跟上。
  - 结果：`verify-storage-migration` 单独跑 **15 条全 PASS、exit 0**；
    etcd 直读恢复后，「对象以哪个版本落盘」这个判据重新可用。
  - 详见 `openspec/changes/add-disk-device-plugin/tasks.md` 6.3 与 runbook §8.6。

## 2. add-observability（已归档，2 项）

- [ ] 2.1 4.1 告警延迟演练：触发 thinpool 打满、拔盘、kill agent，核对 Critical ≤1min / Warning ≤5min（依赖真实 LV 硬件）
- [ ] 2.2 4.2 指标口径核对：与 lvs/vgs 实测值对账（口径冲突以实测为准；依赖真实 LV 硬件）

## 3. add-capacity-governance（已归档，4 项）

- [ ] 3.1 2.2 变更灰度 + 滚动重载机制（热加载与否按 POC 结论；依赖测试集群）
- [ ] 3.2 3.1 dmeventd 第一防线验证：autoextend 配置在测试节点生效，越线后 ≤30s 完成扩容（对照非功能指标；依赖测试集群）
- [ ] 3.3 4.3 测试集群复测 thinpool 打满演练，验证锁与告警链路（依赖测试集群）
- [ ] 3.4 V.2 打满演练通过（依赖测试集群；见 §4.3）

## 4. add-admission-scheduling（活跃，1 项）

- [ ] 4.1 4.3 动态层：单节点 locked → 新 Pod 调度排除该节点、已有 Pod 不受影响（依赖 mutating webhook server 部署 + 真实节点 locked 标签 + cert-manager）
  - 进展（2026-10-29 kind 实测）：cert-manager caBundle 注入正常；mutator 已对引用平台 PVC 的新建 Pod 注入
    `storage.example.io/data-locked NotIn ["true"]` 的 nodeAffinity（PASS）；PVC 校验 webhook 亦被真实调用
    （返回 replicas 提示）。kind 无 TopoLVM CSI，Pod 未真正调度；「新 Pod 排除 locked 节点、已有 Pod 不受影响」
    的**调度级**结论仍需真 CSI/LV 复验，故保留 `[ ]`。
  - 本次实测发现并修复 3 个真实缺陷：①VG/Capacity/Drift/LvmdConfig 四个 controller 同名（controller-runtime
    v0.20 唯一性校验致启动崩溃）→ 各加 `.Named()`；②webhook manifests 缺 `rules`（API Server 从不调用）
    → 四个 webhook 补 `rules` 并加单测 `TestManifestsWebhooksHaveRules` 防回归；③controller ClusterRole 缺
    PV/PVC/ConfigMap/Pod/Namespace 读取与 Node patch → 补齐。（后续 TTL 验证又发现 2 个：
    `storagetasks/status` RBAC 与 StorageTask CRD 的 `subresources.status`，见本节末尾。）
  - 进展（2026-10-29 kind 复验修复有效性）：`scripts/m15-integration.sh verify-controller` 在真实集群端到端 PASS——
    创建 `pooled + md-raid1 + 2 盘` 的 NodeVG 并请求移除 1 盘 → controller 写入
    `status.pendingOps=["移除候选盘将导致 VG 冗余丧失，整体拒绝下发 vgreduce"]`、下发 `vgcreate` StorageTask、
    **不**下发 `vgreduce`；解除 `removeDisks` 后 `pendingOps` 清空。该结果同时反证 ①注册名修复（controller 正常启动并
    reconcile）与 ③RBAC 修复（`nodedisks` list 权限缺失会使 Reconcile 直接失败、pendingOps 不会写入）均已生效。
    仍**不含**真实 `vgcreate/vgreduce` 执行（需 agent + 真实 LV），故本条整体仍保留 `[ ]`。
  - 追加取证（2026-10-29，lvmd ConfigMap 链路）：`hlmd-lvmd-<node>` 在真实集群正确渲染（device-class=tier、
    volume-group=NodeVG 名、thin-pool 正确）；人工篡改内容后，**由 NodeVG 事件触发**可在 1×2s 内纠正并输出
    "漂移已纠正"日志，证明 `configmaps` create/update RBAC 有效。
  - **已决策并修复（ADR-005，2026-10-29）**：原实现存在 ① 未设 `ownerReference` → `.Owns()` 永不触发、篡改不自愈、
    VG 删除后 CM 残留；② CM 按 node 唯一却由单 VG 渲染 → 同节点多 VG 互相覆盖；③ device-class 名取 tier →
    per-disk 同 tier 重名。现改为**一节点一份聚合渲染**（TopoLVM 原生形态）：`device-classes` 数组按名稳定升序、
    仅含 `vgExists=true`、新增 `spec.deviceClassName` 显式命名、重名返回 error 不写非法配置；CM 持有每个同节点
    VG 的**非 controller** ownerRef，控制器改用 `Owns(&ConfigMap{}, builder.MatchEveryOwner)`
    （v0.20 默认 `OnlyControllerOwner()`，不传则多 owner 不触发），GC 自然回收孤儿。
    决策与业界参考见 `docs/poc/adr/005-lvmd-config-aggregation.md`；单测
    `TestAggregateLVMDConfig_*` / `TestLvmdConfigReconciler_*` 覆盖排序、过滤、重名、聚合、收敛、漂移。
  - **kind 真实集群验证（`scripts/m15-integration.sh verify-lvmd`，全 PASS）**：同节点两 VG 聚合为两个
    device-class 且 data<metadata 升序、两个非 controller ownerRef；篡改后 **1s** 自愈（owner watch 生效）；
    `deviceClassName=cold` 生效；删一个 VG **2s** 内收敛；删最后一个 VG 后 **2s** CM 被 GC。
    仍待真实 lvmd 环境验证：`device-classes: []`（节点尚无 VG）与缺失 class 的热加载行为。
  - **已决策并修复（ADR-006，2026-10-29）**：原实现 `StorageTask` 无 ownerReference、无 TTL 清理，删除 NodeVG 后
    残留（实测 4 条孤儿），且存在对已删除对象继续执行 wipe/vgcreate 的误执行风险。现改为任务持有拥有者的
    **非 controller** ownerReference（`controller=false`、`blockOwnerDeletion=false`），由 K8s GC 回收；
    未采用 TTL-after-finished（稳定任务名 + desired-state 重建会抖动，且审计走 Event + audit log 而非任务对象）。
    决策与备选方案见 `docs/poc/adr/006-storagetask-lifecycle.md`；单测 `TestEnsureStorageTask_*` 覆盖
    NodeVG/NodeDisk 归属、非 controller、无 UID 不写引用、幂等。kind 实测（`verify-taskgc`）：
    ownerReference UID 与 NodeVG 一致，删除 NodeVG 后任务数秒内被 GC。
    遗留（未实现，不假装完成）：`StorageTaskSpec.TTL`（"过期不执行"）在 Go/Rust 两侧均未被消费，属执行窗口
    控制而非保留期，需 agent 侧实现。
  - **已定案并修复（ADR-005 补遗，2026-10-29，源码证据）**：上游 TopoLVM `ValidateDeviceClasses` 对空列表
    直接返回错误 `should have at least one device-class`，且在 lvmd 启动路径上 `return err`；lvmd 自身无配置
    热加载（仅 SIGTERM/Interrupt，`loadConfFile` 只在启动时调用）。原实现「无可用 VG 时写
    `device-classes: []`」等于下发 lvmd 无法启动的配置。现改为：聚合无可用 class 时返回 `ok=false`，控制器
    **删除托管 ConfigMap**（仅限带 `hlvm.dev/managed` 注解），使「CM 存在」等价于「该节点可服务」。
    `verify-lvmd` 新增断言：`vgExists=false` 窗口期不写空列表、已有 CM 被撤销、恢复后重建。
    **kind 内以真实 lvmd 0.42.0 运行验证**：配置 `device-classes: []` → 加载后立即
    `Error: should have at least one device-class`，exitCode=1（运行态确认，非仅源码推断）。
    仍待真实环境验证：删除 CM 后 agent/lvmd 的实际表现、「class 指向不存在 VG」的运行态行为
    （kind 内 lvmd 因 nsenter 权限在 ListVolumeGroups 阶段即退出）、配置热加载。
  - **TTL 已落地（ADR-006 补遗，2026-10-29）**：`spec.ttl` 对齐 K8s Job `activeDeadlineSeconds`——自
    `creationTimestamp` 起算，仅拦截尚未开始（phase 空/Pending）的任务；到期标 `Failed`
    （`DeadlineExceeded:` 前缀）并保留对象、不自动重试；非法/`<=0` 失败关闭；`Running`/`Unknown` 不改写
    （单写者）。kind 实测（`verify-ttl`）：`ttl=2s` 3s 内标 Failed、`ttl=1h` 8s 内未改写、`ttl=nonsense`
    失败关闭。**残余竞态已关闭（同日）**：agent 在执行前复核 `creationTimestamp + spec.ttl`
    （`agent/src/common/ttl.rs` + `reporter::kube_rw::expired_reason`），命中即回写 `Failed` 并跳过执行器；
    语义与控制面逐条对齐（仅拦未开始任务、非法 TTL/缺时间戳失败关闭）。`cargo test` 99 项通过（新增 11 例），
    `cargo fmt --check` 通过；CI `rust` job 以 `cargo test --all-targets` 作为门禁。仍未覆盖两侧时钟偏差。
  - **本轮验证暴露并修复 2 个部署期缺陷**（envtest 与单测均不覆盖，仅真实集群可暴露）：
    ① ClusterRole 缺 `storagetasks/status` 更新 → TTL 标记与结果回写持续 403，任务永远 Pending；
    ② StorageTask CRD 缺 `subresources.status` → `/status` 404，**agent 的 patch_status 回执链路实际不可用**
    （此前无 agent、无状态写入故未暴露）。均已在 `config/rbac/role.yaml` 与 CRD 修复，并新增
    `internal/controller/deploy_manifests_test.go` 做清单级防回归。

## 5. add-backup-restore（活跃，2 项）

- [ ] 5.1 2.2 块/文件系统一致性验证用例（有 pre-hook vs 无 pre-hook 的恢复结果对比）—— 移交集成验证
- [ ] 5.2 5.1 完整闭环演练：备份 → 删除 PVC/PV → 恢复 → 应用侧数据校验 → 记录 RTO/RPO —— 移交集成验证（需测试集群 + Velero）

## 6. add-hardening-rollout（活跃，5 项）

- [ ] 6.1 1.4 演练报告与问题闭环（**移交集成**：需测试集群执行并归档报告）
- [ ] 6.2 2.2 报告评审通过（**移交集成**：需测试集群 fio 实测 + 评审）
- [ ] 6.3 5.2 灰度期问题闭环与放量决策（**移交集成**：需真实灰度执行）
- [ ] 6.4 5.3 上线评审门禁（**移交集成**：需全部门禁逐项通过）
- [ ] 6.5 V.1-b 全部演练与评审通过形成上线报告（**移交集成**）

## 7. add-poc-decision-gate（活跃，5 项）

- [ ] 7.1 实测执行（POC 项一）—— 移交集成
- [ ] 7.2 实测执行（POC 项二）—— 移交集成
- [ ] 7.3 实测与结论 —— 移交集成
- [ ] 7.4 实测与评审 —— 移交集成
- [ ] 7.5 V.1-b 决策门评审通过（POC 报告 + ADR 评审）—— 移交集成

## 验证回路

- [ ] V.1 前置条件 1.1–1.5 全部就绪
- [ ] V.2 19 项集成验证在测试集群逐项通过，并回填各源变更 `tasks.md` 的对应 `[ ]` 项（活跃变更 + 已归档变更 archive tasks.md）
- [ ] V.3 本变更 `tasks.md` 全绿后 `openspec archive m15-integration` 收口
