# 变更日志

本文件记录 hlvm 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **0.x 阶段说明**：1.0 之前 CRD schema 与可选字段仍可能不兼容变更；每次升级前先读对应版本的
> 「升级注意」。`preview` 后缀表示**未通过真实硬件与生产环境验证**，不得用于生产。

## [Unreleased]

### fix(m15): 修正 kubelet 重启相位的「重启完成」等待条件（2026-11-13）

隔离 kind 集群 `hlvm-m15-20261113` 的 `all` 在 `verify-kubelet-restart` 中止：
旧逻辑用「节点 Ready」当重启完成信号，但 `systemctl restart kubelet` 是异步的，
重启窗口内 Node 始终 Ready，循环第一次就退出，在 socket 重建前读走旧签名 ⇒
误判「kubelet 未真正重启」。实测 `t+0s` 签名与 PID 均未变且 `Ready=True`，
`t+1s` 才变。修法：轮询 `kubelet.sock` 签名本身（最多 60s），节点 Ready 只作
恢复兜底；**「签名必须变」的判据一字未放宽**。

- 正例：修正后单独重跑该相位 9 条断言全 PASS（签名 `1324660:… → 1235778:…`）。
- 反例（变异校验）：把重启命令换成 `true` 后相位 `rc=1`，报
  `FAIL: kubelet.sock 签名未变`，证明等待逻辑不会自己等出假绿。
- 验证：`bash -n`、`git diff --check`、Linux 容器 `go vet ./... && go test ./...` 全绿。

### 项目状态声明：模块先行、决策门未过（ADR-006 §23，2026-11-13）

只改文档，无产品源码 / 部署清单 / 判据脚本变更。在 ADR-006 头部与 §23、
`m15-integration-runbook.md` 顶部、`docs/poc/README.md` 顶部写明当前状态，
避免把「`m15 all` 零 FAIL / CI 全绿 / 已发 `v0.1.0-preview.6`」误读成设计已验收：

- 设计 v1.1 §10 阶段 0 的 10 项通过标准仍全部 `☐ 移交集成`；`poc-report.md`
  为空模板，ADR-001 / 002 仍「提议（POC 决策门评审中）」、003 / 004 仍「框架」。
- `runbook §4` 的 §B 可辨识 17 行中 **15 未验 / 2 部分**，无一项达到 §B 验收通过；
  `docs/M14-closure.md` 风险 #3「不能视为 production-ready」结论不变。
- `m15 all` 16 相位零 FAIL 属 §A 自动化覆盖，不能替代 §B 真实验收。
- §23.3 登记闭合顺序；流程评审项与 hnb 纳管凭据属外部依赖，不因本声明而闭合。

### 执行路径调整：隔离环境优先 + 真机升级 preview.6（ADR-006 §23.5，2026-11-13）

复核发现真机集群已承载 hnb 平台业务：`hnb-system` 35 个 Running Pod、**11 个 PVC
全部挂在 `hlvm-b`**（PostgreSQL×3 / NATS×4 / agent-state / demo-live-data）。
`m15 all` 与阶段 0 故障演练会动这些数据，按「两侧禁并行」纪律暂停真机破坏性相位：

- 真机只做只读验收 + 非破坏升级：controller / webhook / `hlvm-storage-agent` DS /
  `hlvm-disk-plugin` DS 滚动到 `:v0.1.0-preview.6`，rollout 全 OK；11 PVC 全 Bound、
  3 NodeVG `vgExists=true`、0 非终态 StorageTask。3 个每盘 collector Pod 仍 `.5`，
  属控制器创建的独立 Pod，不随 DS 滚动，待窗口统一处理。
- 破坏性全量回归移到独立 kind 集群（新集群名 `hlvm-m15-20261113`，避开残留
  `kind-hlvm-kind` context 造成的首跑假阳性）；kind 结果属 §A，不外推为真机验收。
- §23.5 登记阶段 0 能力矩阵与 8 项外部依赖（D1–D8）：真机错峰窗口、snapshot
  CRD/controller/VolumeSnapshotClass、POC 脚本判据化、Velero 镜像、常驻可观测性栈、
  hnb 凭据、评审签字、Go/Rust 依赖代差。
- 能力缺失一律 SKIP 且不计 PASS：kind 无 lvm / udev / `dm_thin_pool`，真机无
  `snapshot.storage.k8s.io` CRD ⇒ 快照 / 克隆 / fio / 打满 / 拔盘 / 断电本轮均不可验。

### 真机 `m15 all` 收口与记账对齐（ADR-006 §22，2026-11-12 夜）／发布 `v0.1.0-preview.6`

发布 `v0.1.0-preview.6`。**本版无 Go / Rust 产品源码变更**：`preview.5` 之后的 11 个
commit 只改部署清单、判据脚本、告警配置、测试与文档。本版的作用是固化配置与版本串，
并把「代码全绿、记账落后」的偏差收口。发布说明见
`docs/release-notes/v0.1.0-preview.6.md`。

- **扩 CP 使对账有效域 D 从 2 → 3**（`26a5cba` / `2c2cf6a`）：新增 CP
  `10-60-131-187` 的 NodeVG seed；三 DS 加 control-plane 容忍；`expand-lvmd-nodes.sh`
  默认三节点与显式 VG MAP；`pvc-supply-e2e.sh` 增 `TOLERATE_CONTROL_PLANE` 修 CP taint
  假红。验收：3 个 NodeVG `vgExists=true`、三 DS 三节点全 Ready、3 条独立
  `CSIStorageCapacity`、逐节点 PVC→LV→写入→回收 E2E 全 PASS。
- **CRD 存储版本迁移收口**：bootstrap 守卫报「仍有 2 个 NodeDisk（v1alpha1 v1beta1）」；
  实测 5 个 CRD 均双版本 served 但 `storedVersions=["v1beta1"]` 已干净、真实对象只有
  1 nodedisk + 3 nodevg —— 守卫的「2」是按 served 版本计数。先 `--dry-run=server` 再执行
  忠实的 `restore_single_version_crds`（apply bases + 清 discovery 缓存），5 CRD 收回单
  `v1beta1`、`conversion=None`，4 个对象无损，未删数据也未放宽守卫。
- **`verify-lvmd` 假红修复**：相位用 `get nodes` 首节点放测试 NodeVG，扩域后该节点
  （CP 187）已有真实生产 `hlvm-lvmd-vg-187`，控制器把两者聚合进同一 CM 并**正确地**
  保留它，「不撤销 / 不 GC」两条断言因前提被破坏而 FAIL。隔离到专用假节点
  `m15-lvmd-fake-node`；可逆探针确认控制器对任意节点名建 / GC CM；单独跑该相位全 PASS。
- **`verify-cert-rotation` 死锁与假红修复**：四个根因叠加 —— 探针转发到具体 Pod
  （证书轮换删 secret 后 Pod 重建成幽灵 Pod）；`$(...)` 子 shell 丢弃 `pf_rebuilds`
  自增致重建上限失效（曾卡死 2h+，57 次「第 1 次」）；Service 实际暴露
  `port:443 → targetPort:9444`，写成 `19443:9444` 建不起来；最终真凶是本地 `19443`
  被 `hnb-system` 的 `svc/tunnel-server` 常驻 port-forward 永久占用
  （`bind: address already in use`）。修：端口改 `19499`、转发 `svc` 的 443、
  `pf_rebuilds` 落盘、`start_pf` 前 `fuser -k 19499` 兜底（只清 19499，不碰 hnb）。
  用手动探针 `GOT_CERT` 先验证再重跑。**纪律印证**：相位内大量 PASS 始终证明证书轮换
  功能本身成功，失败的只是探针手段 —— 读不到证书 ≠ 证书没轮换，修探针而非放宽判据。
- **真机 `m15 all` 全绿**（第五遍，日志 `/tmp/m15-all-real-20261112-222225.log`）：
  16 个 verify 相位**零 FAIL**；cert-rotation 16 条证书链断言 + 4 条 conversion smoke
  全 PASS、`TLS 探针无响应` 告警 0 次。`all` 分支 for 循环后无汇总行是脚本设计，
  日志停在 `verify-velero` 属正常 exit 0。修复提交 `20c3783`，CI run 131 五个必需
  job 全 success。
- **常驻 agent DS 已恢复 3 节点**：`verify-agent` 结尾会主动 `agent_cleanup` 删 DS
  （避免影响 `verify-ttl` 前提），跑完用 `deploy-agent-real.sh` 逐节点恢复，
  153 / 166 / 187(CP) 各 `PASS=17 / FAIL=0` + 真实写门禁 `REAL_WRITE_OK`；
  终态 `hlvm-storage-agent` 3/3 Ready、`:v0.1.0-preview.5`。
- **记账对齐**：ADR-006 新增 §22 记录扩域与全绿，并给 §20.8 / §21.5 的
  「未跑 `m15 all`」加注更正；runbook §6 补第五遍结果、§10.7 更正「只有 NodeDisk
  版本化」、§10.19 更正「未部署 CSI / real 首版未验证」、新增 §10.20 复跑要点、
  §4 加 §B 逐项状态表。历史快照一律加注，不改写。
- **诚实边界**：三个 SKIP 未覆盖（Velero 因 docker.io 镜像不可达、热插拔因无
  `M15_DISK_ATTACH_CMD`、kubelet checkpoint 因不落盘 `PodDeviceEntries`）；
  真机二进制仍 `:v0.1.0-preview.5`，**未在新 tag 上重跑 `m15 all`**；
  §B 19 项递延仍未逐项验收，`m15 all` 零 FAIL 不能代替，`M14-closure` 风险 #3
  「不视为 production-ready」结论不变；无常驻真实 Prometheus / Alertmanager / Grafana，
  接收器仍是形状示例，hnb 平台级纳管仍缺四项凭据。

### 用真实 Alertmanager 实例验抑制与路由（ADR-006 §21，2026-11-12）

§20 的路由与抑制只经过离线校验（`amtool check-config` + 语义守卫），证明不了**运行时真的按
预期抑制**。新增 `docs/poc/scripts/alertmanager-inhibit-e2e.sh`：起一个真实 Alertmanager 容器、
挂仓库里那份配置、用 `amtool alert add` 注入告警，8 组 27 条断言全部「正例+反例」成对
（含 `equal` 的跨 node/跨 vg/跨 device 反例、跨子系统不压制的反例、未知 severity 仍可见）。

实测推翻了三处原本写在纸上的判断：

- **`status.inhibitedBy` 只回报一个抑制者指纹**（按规则顺序取第一个匹配），所以「被几条规则
  压住」无法从数量判断 —— 判据改成断言「抑制者是谁」。
- **抑制是逐 target 按当前活跃根因实时计算的**：解析一个根因只会解除它覆盖的 target，
  其余继续被别的根因压着（抑制者字段随之交接）。
- **路由顺序在互斥 matcher 下没有行为差异**：`severity="critical"` 与 `="warning"` 互斥时
  对调顺序，27 条断言仍全绿。§20.3「顺序错了 critical 被降级成工单」已加注更正为
  **防御性约束**（只在 matcher 可重叠时成立），并刻意不给脚本补一条测不出东西的假断言。

配套 `TestInhibitRulesHaveRuntimeE2ECase`（不需要 docker，进 `go test ./...`）：每条抑制规则的
source 告警必须真的出现在脚本的 `am_add` 行里，脚本必须带 `SUMMARY`/`VERDICT="FAIL"` 判定路径
——新加规则不补实测用例会红。变异校验 6 处：5 处如期转红，第 6 处（路由顺序）不该红，
原因即上面第三条。

### 告警的落点：Alertmanager 路由/抑制 + Grafana 面板（ADR-006 §20，2026-11-12）

§17–§19 把「什么时候算告警」做到了可求值，但**告警算出来之后去哪儿**在仓库里是空的：
没有路由（值班人收不到）、没有抑制（同源告警成串刷屏）、抑制/路由写错时**不报错**只是安静地
不再生效。三者共同点仍是「出错与一切正常不可区分」。

- **`config/alertmanager/alertmanager.yaml`**：路由树 `critical→pager` / `warning→ticket`，
  默认接收器为「只记录不投递」的黑洞；**critical 必须排在 warning 之前**（第一条匹配的叶子
  路由胜出，否则 critical 被降级成工单）。3 条抑制规则只压「同一根因的派生信号」：
  thin-pool Critical ⇒ 压对应 Warning；`ThinPoolOutOfSpace` ⇒ 压全部 thin-pool 容量告警；
  `DiskSmartCritical` ⇒ 压同盘的温度/寿命/spare/media。
  **刻意不加**「任意 critical ⇒ 同节点所有 warning」（会压掉 `StorageDriftDetected` /
  `DriftLVReportStalled` —— 它们正是「看起来一切正常」时唯一的信号），理由写进配置注释。
- **`config/grafana/dashboards/hlvm-storage-drift.json`**：8 panel，覆盖 §17 四族指标
  （上报年龄 / 上报存在性 / 漂移条数 / 被放弃的对账轮次）+ 容量 + 控制面错误速率 + agent 心跳。
- **`scripts/observability-config-check.sh` + `dashboard_lint.py`**：`amtool check-config`、
  仪表盘结构、以及把每条面板 `expr` 包成 recording rule 交给 `promtool check rules` 解析。
  Grafana 模板变量按显式表替换（内建变量→字面量，仪表盘声明变量→`.*`），表外出现 `$` 直接失败
  ——否则笔误会被报成 promtool 的语法错误，或更糟：面板静默空图。
- **`internal/metrics/observability_config_test.go`**（不需要 docker）：抑制规则两侧的
  alertname 必须存在、两侧都必须由 alertname 限定、`equal` 非空且 ∈ 闭集；每条 severity 都有
  路由且接收器**真配有 `*_configs`**；面板引用的 `storage_*` 必须存在（与告警守卫共用
  `knownMetricNames`）；脚本进了 CI 且 `ready.needs` 覆盖。
- **写法约束**：抑制规则的 alertname 只能是字面量或其 `|` 分支（`ThinPool(Data|Metadata)Critical`
  这类分组正则无法静态展开，等于放弃「引用必须存在」的检查）。
- **变异校验 7 处**（alertname 拼错 / severity 拼错 / 路由顺序对调 / receiver 未定义 /
  面板 expr 语法坏 / 摘掉 `ready.needs` / `equal` 置空）全部如期转红，恢复后全绿。
- **CI job 改名** `prometheus-rules` → `observability`（现在同时管规则、Alertmanager、仪表盘），
  两个 step 分别调两个脚本，整体仍进 `ready.needs`。**若分支保护把旧 job 名配成了必需检查，
  改名会静默失效**——本仓库的必需检查是 `Ready`，故安全。
- 本地 `observability-config-check.sh` **PASS=5 / FAIL=0 / SKIP=0**，`go vet` + `go test` 全通过。
  无二进制变更，不涉发版。
- 诚实边界：无真实 Alertmanager/Grafana 实例（延迟、分组、模板渲染未验证）；`equal` 标签在
  真实序列上是否存在未验证；接收器地址是形状示例；仪表盘不校验数据源与阈值一致性。

### 求值覆盖扩到全部 22 条告警 + 4 条记录规则（ADR-006 §19，2026-11-12）

§18 只强制覆盖了三方对账的 4 条告警，其余 14 + 4 条只做「能解析」的检查，记录规则连解析都没试过。
没有求值断言就等于「从来没被触发过」。本轮补齐，并把覆盖守卫的默认范围改成全部规则文件。

- **`tests/alert-rules_test.yml`**（14 条）：阈值边界（`>=`/`<`/`>` 两侧各取一点）、
  `for: 5m` 边界、`increase` 的「**累计非 0 但无增量不重复告警**」（media_errors 双序列对照）、
  心跳的时间戳语义（同一表达式下停跳节点触发、正常节点静默）。
- **`tests/alert-rules-backup_test.yml`**（4 条）：24h `increase`、RPO 的 `for: 5m`、
  90 天窗口（`interval: 1h` 把时钟推到 2161h）、`> 0` 守卫（ts=0 时只能报「从未演练」，
  不得改口报「过期」）。
- **`tests/recording-rules_test.yml`**（4 条记录规则）：过滤型聚合 `count(... >= 2)` /
  `count(... > 0)` 的数值，以及 `rate` 的期望值。
- **覆盖守卫**默认扫全部 `alert-rules*.yaml`；Go 守卫扩到全部告警文件，并新增
  「告警名全局唯一」「每个含告警的规则文件都被某用例 `rule_files` 引用」两项。
- **三个 promtool 陷阱**（实测）：`'1x5'` 是 **6** 个样本（`x` 是步数）；`increase()` 在增量
  首次出现的那次求值读到 0（firing 比手算晚 1 个 interval）；`max(...) by ()` 丢全部标签
  ⇒ `BackupDrillNever` 的「记录为 0」分支没有 `pvc`。
- **修掉一处判据假红**：工作区 `*.yaml` 是 CRLF，awk 取出的告警名带 `\r` ⇒ grep 永远不匹配，
  报「告警没有用例」。awk 内 `sub(/\r$/, "")` + `tr -d '\r'`。
- **变异校验**：阈值改动 / 记录规则 `max→min` / 去掉 `> 0` 守卫 → 三个用例文件各自 rc=1；
  删掉 backup 用例文件 → Go 守卫报「没有任何用例声明 rule_files」。恢复后全部 rc=0。
- 本地 **PASS=34 / FAIL=0 / SKIP=0**；无二进制变更，不涉发版。

### 告警规则的真实求值：用 promtool 替代「只有清单」（ADR-006 §18，2026-11-12）

§17 交付的四条对账告警此前只有静态守卫（校验引用的指标名存在），证明不了表达式可解析、
`for:` 会在预期时刻触发、健康态不误报。规则写错时 Prometheus 静默不触发，与「一切正常」
不可区分 —— 与 §17 要治的是同一种病。本轮把它补成引擎级门禁。**无二进制变更，不涉及发版。**

- **`scripts/prometheus-rules-check.sh`**：把 PrometheusRule 的 `spec.groups` 去缩进转成纯规则文件，
  然后 `check rules`（全部 4 个规则文件：22 条告警 + 4 条记录规则）+ `test rules`（求值用例）+ 覆盖守卫
  （强制覆盖文件里每条告警都必须有用例）。promtool 走本机二进制或 docker（`PROM_IMAGE`），
  两者都缺则 SKIP 并写明未覆盖，绝不计 PASS；但 `CI` 环境不允许 SKIP（CI 里跳过等于门禁开洞），
  此时判 FAIL / exit 1。
- **`config/prometheus/tests/drift_rules_test.yml`**：五组用例，每条告警都有**正例 + 反例**。
  其中 Stalled 用两个节点区分语义：`w1` 时间戳冻结（100）→ 4m 静默 / 5m 静默（`for` 未满）/
  7m 触发；`w2` 时间戳跟着 `time()` 走（健康上报）→ 同表达式下始终静默。
  Missing 另有 `present=1` 恒静默反例（挡住 `== 0` 写成 `>= 0`）。注解逐字断言，
  连 `{{ $value }}` 渲染一起钉住。
- **变异校验**：`for: 2m→0m`、`> 180→> 30`、`present == 0→>= 0` 三处注入均如期转红。
- **`internal/metrics/promtool_tests_test.go`**（不需要 docker，跑在 `go test ./...`）：
  守「用例还在」「`rule_files` 指向真实规则文件（否则 promtool 空规则集空转）」
  「每条告警同时有应触发/应静默断言」「脚本有可执行位、ci.yml 真的调用它且进了 `ready.needs`」。
  注入验证：删反例 / 告警改名 / 从 `ready.needs` 移除 job，三种情况均报红。
- **CI**：新增 `prometheus-rules` job 并纳入 `ready.needs`（此前规则求值完全不在门禁里）。
- **CI 首跑红了两次，两处都是真缺陷**：① 脚本在 git 里是 `100644`（Windows `core.fileMode=false`，
  本地 `chmod +x` 不进索引）⇒ CI 里 permission denied，被本轮新增的可执行位守卫当场抓到；
  ② `ready` 汇总 job 只有 `if: always()` + 一句 echo，**上游三个 job 全红时 Ready 仍绿** ——
  分支保护看的是它，等于整条门禁失效。改为读 `toJSON(needs)` 逐项断言，非 success 即 `exit 1`
  （`images` 的 skipped 例外），并新增 `TestCIFinalGateAssertsResults` 钉住。
- **顺带修正**：引入 `sigs.k8s.io/yaml` 直接依赖后 `go mod tidy` 纠正了几处过期的 `// indirect`
  标记（`k8s.io/utils` 等其实一直是直接 import），`TestK8sDependencyBaseline` 因此要求登记；
  **版本未变**，已把 `k8s.io/utils` 同版本登记进基线并注明原因。
- **诚实边界**：离线求值，未连真实 Prometheus（抓取间隔/staleness/external_labels 未覆盖）；
  promtool 3.1.0 与生产版本未必一致；`alert-rules.yaml` 的 14 条与 backup 的 4 条只做可解析校验、
  无求值用例；无 Grafana 面板、无 Alertmanager 路由验证。

### 对账可观测性：把「静默停摆」变成可告警（ADR-006 §17，2026-11-12）

发布 `v0.1.0-preview.5`。§16 的失败关闭语义（上报过期即整轮放弃对账）是刻意取舍，
但它只留一条 Info 日志：Agent 长挂期间平台看起来一切正常，且 Agent 停写后不再有
reconcile 触发，连日志都不再产生。本轮把这条链路补成可观测 + 可告警。

- **四族指标**（`internal/metrics`，名字登记进规范名常量块）：
  `storage_controller_lv_report_timestamp_seconds{node,vg}`、
  `storage_controller_lv_report_present{node,vg}`、
  `storage_controller_drift_reconcile_skipped_total{reason}`、
  `storage_controller_drift_items{kind}`。
- **时间戳而非滞后秒数**：滞后秒数由 reconcile 计算，Agent 停写后不再有触发，会冻结在
  挂掉前的瞬间、永远不越阈值；时间戳冻结后 `time() - ts` 仍随墙钟增长。
- **全量替换语义**：NodeVG 删除后必须 `DeleteLabelValues`，否则旧时间戳永冻 → 永久误告警。
- **跳过轮次不清零漂移条目**：否则 Agent 抖动一次就把「有漂移」改写成 0，伪装成已恢复；
  消失的 kind 置 0 而非删序列（序列消失会变 no data，被当成恢复）。
- **新鲜度覆盖全部 NodeVG**（不只含 PV 的节点）：空集群时一次 reporter 调用都不发生，
  若指标跟随对账走，Agent 挂掉完全不可观测。
- **失败原因类型化**：`LVReportUnavailableError.Reason` 取闭集
  （`no_reporter`/`report_missing`/`report_stale`/`no_nodevg`/`list_failed`/`unknown`），
  错误串不进指标标签（避免基数爆炸与拓扑泄漏）。
- **告警规则** `config/prometheus/alert-rules-drift.yaml`：`DriftLVReportStalled`
  （>`180s` + `for: 2m`）、`DriftLVReportMissing`（`present==0` + `for: 15m`）、
  `DriftReconcileSkipped`、`StorageDriftDetected`，全部 `warning`。
- **守卫**：`TestAlertRulesReferenceKnownMetrics` 从 collector 的 `Describe` 取真实
  fqName 校验规则引用，拼错指标名即失败（已用注入 `..._itemz` 验证会红）；
  `drift_observability_test.go` 钉死「过期不告警但计数」「无 PV 也有新鲜度指标」
  「删 NodeVG 清序列」「跳过不清零」（已用变异验证会红）。
- **真机验收**（`docs/poc/scripts/drift-metrics-verify.sh`，2026-11-12）：控制器升到
  `.preview.5` 后 **PASS=13 / FAIL=0 / SKIP=0**，只读复跑 PASS=4 / SKIP=1。
  证据：两节点 age 32s/31s 且 `present=1`；停写后时间戳自然增长到 203s（未伪造 status）；
  `skipped_total{reason="report_stale"}` 0 → 5；停摆期间 `StorageDrift` 事件 3 → 3
  （不给假告警）；移除 taint 后 age 回到 0s。
  首跑两处红均为判据自身缺陷：`DaemonSet` 没有 `spec.replicas`（`scale` 子资源 NotFound）
  ⇒ 改用「节点 taint + 删该节点 Pod」，只停一个 worker；Prometheus 文本格式对大数用
  科学计数法 ⇒ 取值改 `printf "%.0f"`。另登记：无 PV 时 reporter 不被调用，
  `report_stale` 分支需 fixture PV 才可达（脚本内已实现并在恢复前删除）。
  agent 无功能变更，真机 agent 仍 `.preview.4`。

### LVReporter 接线：三方对账的 lvs 一侧上线（ADR-006 §16，2026-11-12）

发布 `v0.1.0-preview.4`。清掉 §15.6 登记的全部剩余前置，把「CR / PV / lvs」
三方对账从「Reporter=nil、actual 恒空、从不生效」变成有真实数据通路的闭环。

- **承载对象与单写者**：`NodeVG.status` 新增 `logicalVolumes[]` 与
  `lastLVReportTime`，节点 agent 用 `patch_status` 独占写这两个字段，控制面只读。
  Go 类型与 deepcopy 必须同步声明——`VGReconciler` 用 `Status().Update` 全量写回，
  类型里缺字段会把 agent 上报静默抹掉。`agent_role.yaml` 补 `nodevgs/status` 权限。
- **采集与过滤**：`lvs` 显式取 `lv_attr` / `pool_lv`（真机实证 thin-pool 是
  `twi-aotz--`、业务 thin LV 是 `Vwi-aotz--`）；agent 排除 thin-pool 自身、
  `[` 开头的内部 LV、类型未知的项，但**保留手工普通 LV**（漂移检测目标）。
  控制面再加一层同名兜底过滤，兼容滚动升级窗口。读路径经 `HLVM_HOST_WRAPPER`
  与写路径锁同源。
- **新鲜度与失败关闭**：agent 30s 采样、变化即写、60s 保活写、采集失败不写；
  控制面 `MaxAge=3min`，任一节点上报缺失/过期即**整轮放弃对账**（旧实现
  `continue` 会让缺数据节点的所有账面 LV 变成 `missing-lv` 误报）。
- **触发**：`SetupWithManager` 补 PV watch（映射到全部 NodeVG），`main.go` 装配
  `NodeVGLVReporter`，Reporter 不再为 nil；平台仍只告警不自动修复。
- **顺带修掉一个长期存在的读路径缺陷**：真机只读验证发现
  `lvm lvs ... --reportformat json --reportformat json` 直接 exit 3
  （`Option --reportformat may not be repeated.`）。`report_vg/lv/pv` 自带该 flag，
  `lvm_argv_with` 又无条件追加一次 ⇒ **所有 LVM 读路径一直失败**，只是
  `build_host_state` 里 `report_pv()` 的失败被静默忽略。改为幂等注入（args 已带
  则不追加）并去掉 `report_*` 的重复 flag；新增两个 argv 单测真机形状断言。
  不修就发版会让 LV 上报永远失败、对账因新鲜度门禁静默跳过（假绿）。
- **判据**：新增 `drift-reconcile-e2e.sh`（正常态零误报 → 手工 `lvcreate` 命中
  `unmanaged-lv` 且无 `missing-lv` → 清理后告警停止 → PVC/LV 回收无残留）；
  `TestLVReporterWiringDiscipline` 跨语言钉死接线，`TestVGStatusDecodesAgentPatch`
  校验 Rust patch 能被 Go 无损解码。
- **真机验收（镜像产出后，2026-11-12）**：控制器 2 副本 + 两 worker agent 均切
  `:v0.1.0-preview.4`（`deploy-agent-real.sh` 两节点各 PASS=17/FAIL=0，含 nsenter
  真实写门禁）。`drift-reconcile-e2e.sh` 在 `10-60-153-100` 与 `10-60-166-202`
  各 **PASS=19 / FAIL=0 / SKIP=0**：上报新鲜、thin-pool 未上报、业务 LV 按
  `volumeHandle` 上报、正常态零告警、手工 `lvcreate` 命中 `unmanaged-lv` 且无
  `missing-lv`、清理后计数 3→3 / 4→4 停止增长、回收后无残留。
- **首跑抓到一处判据假红**（已在脚本中修）：`awk ... <<< ""` 会把空集变成一行空行，
  被计成「1 条告警」，导致正常态误报 FAIL 而证据串为空。`NEW_COUNT` 与
  `event_count_sum` 均加 `length($0)==0 { next }`。
- **运维事实**：云主机直连 GHCR 仅 ~27 KB/s（agent 压缩 376 MiB 不可行）；
  `certs.d` 未配 `ghcr.io`，用 `ctr images pull --hosts-dir` + `ghcr.nju.edu.cn`
  临时镜像源（仅拉 10.6 MiB 差异层，秒级），不改全局 containerd 配置。
- **诚实边界**：`DetectDrift` 的「任一侧为空即返回」契约未改 ⇒ 空集群（无 PV）
  手工 `lvcreate` 检不出，真机注入必须在 PVC 存在期间；NodeVG 仍手工 seed、
  agent 不创建 CR；`freeBytes` 仍是 VG 物理 free 2 GiB（与 CSI 36 Gi 不同维度）；
  聚合 CM 脚本同步、CP 未扩、A 链路单节点、未跑 `m15 all`；真机 CRD `status` 靠
  `preserve-unknown-fields` 才容纳新字段，仓库 bases 是空 schema，换集群时不可
  直接 apply；只有 `lastLVReportTime` 停滞可观测，本轮未做该指标告警。

### 判据收尾与三方对账前置修复（ADR-006 §15，2026-11-12）

**不发版**；本轮是判据与代码正确性收尾，真机控制面二进制仍为
`storage-controller:v0.1.0-preview.3`。

- 真机实证坐实 TopoLVM PV 字段：`pv.name=pvc-<uid>`，宿主 `lvs` 的 LV 名是
  `spec.csi.volumeHandle`（= `LogicalVolume.status.volumeID`），节点只在
  `nodeAffinity` 的 `topology.topolvm.io/node`，PV 上**没有** `hlvm.dev/node` /
  `hlvm.dev/vg` 注解，VG 名需按 `NodeVG.spec.nodeName` 反查。旧
  `DriftDetectorReconciler` 因此跳过所有真机 PV（managed 恒空、三方对账从不生效），
  即使补注解也会因用 `pv.Name` 产生双向误报。
- 新增 `ManagedLVsFromPVs` 纯函数按真实字段构造账面侧（字段不全宁可跳过），
  保留带注解的 hlvm 自研/envtest 兼容路径；`Reconcile` 装配 `NodeVG` 列表。
  `drift_pv_test.go` 用真机真实值钉死三元组，并验证「用 pv.Name 必产生 2 条误报」
  与「未过滤的 thin-pool 会产生 1 条 unmanaged-lv」两个反例。
- `pvc-supply-e2e.sh` 新增 `kc_get` 三次重试：严格区分「读取失败」与「值确实为空」，
  覆盖 CSINode 驱动 / 节点拓扑标签 / 容量注解 / PVC volumeName / PV 容量·亲和·driver。
  修掉 §14 复验第二轮的偶发假红。
- 4 个 POC 脚本默认 `AGENT_IMAGE` 从仓库根 `VERSION` 推导发布版 `:v<VERSION>`，
  不再写死 `sha-52bda85`；`expand-lvmd-nodes.sh` 门禁同时接受 `:v<VERSION>` 与
  `:sha-<commit>`，修掉 §14 复验首跑「未显式传参即镜像不符」的假红。
- 真机：两节点预拉 `storage-agent:v0.1.0-preview.3`（同 digest，3.6s）；
  `deploy` PASS=12/FAIL=0，`verify` 连续 4 次 PASS=23/FAIL=0/SKIP=0；
  终态控制器与 agent 均 `:v0.1.0-preview.3`、容量两条 36Gi、无残留 CR/PVC/PV。
- **诚实边界**：`LVReporter` 仍 nil，本轮 Go 修复在 `main` 但未发布到真机（Reporter=nil
  时无可观测行为），不得声称三方对账已上线。接线剩余前置：agent 上报侧过滤
  thin-pool/内部 LV、补 PV watch、agent 侧 lvs 采集回写通道。详见 ADR-006 §15.6。

### 修复 B 链路 device-class 缺 `type: thin` 的供给假绿（ADR-006 §14，2026-11-12）

发布 `v0.1.0-preview.3`。这是**产品缺陷修复**，不是容量调优：控制面渲染的
lvmd device-class 只有 `thin-pool:` 段、缺 `type: thin`，TopoLVM v0.42.0 会把
class 归一为 **thick**，导致按 `vg_free` 上报容量（2 GiB）并创建 thick LV，
36G thin-pool 完全不参与供给。§13 的 E2E 只查「VG 内新增 1 颗 LV + 尺寸」，
无法区分 thick/thin，因此上一轮「thin LV 验收 PASS」是判据假绿。

- 真机可逆 A/B 实证（控制器临时 scale 0、3 份 ConfigMap 全量备份、实验后恢复）：
  加 `type: thin` 后两节点容量注解 `2143289344 → 38654705664`（2 GiB → 36 GiB）、
  两条 `CSIStorageCapacity` `2044Mi → 36Gi`、新建 LV 从「`pool_lv` 空 / thick」
  变为「`pool_lv=thinpool` / `Attr=Vwi-aotz--`」，回收后无残留。
- `AggregateLVMDConfig` 每个 device-class 显式渲染 `type: thin`，注释钉死上游行为；
  `TestAggregateLVMDConfig_SortedAndComplete` 期望串同步。
- 三份 ConfigMap 快照同步（`configmap-lvmd-all` / `-153` / `-202`），由
  `TestLvmdPOCArtifactsConsistent` 逐字节锁定「快照 == 渲染结果」。
- `pvc-supply-e2e.sh` 新增 `lv_pool_of()` 判据：新增 LV 的 `pool_lv` 必须指向
  thin-pool，否则 FAIL 并提示 thick 退化，堵住假绿回归。
- 控制器 `Owns(ConfigMap, MatchEveryOwner)` 会覆盖手工 CM 修改 ⇒ 修复必须随
  控制器二进制上线；按「集成/生产一律 `:vX.Y.Z`」纪律发版，而非临时 sha tag。
- 文档：ADR-006 §14、ADR-007 §5 容量边界更正、发布说明
  `docs/release-notes/v0.1.0-preview.3.md`。

版本三元（`VERSION` / `agent/Cargo.toml` / `agent/Cargo.lock`）同步到
`0.1.0-preview.3`；本轮**未改 agent 的 Rust 源码**，只改版本串。
`LVReporter` 仍未接（接线前置：managed 侧目前把 `pv.Name` 当 LV 名，而 TopoLVM
实际 LV 名是另一个 UUID，直接接会双向误报），见 §14.5。

### 多节点扩容：双 worker + CI 镜像上线（ADR-006 §13，2026-11-12）

承接上一条，把「只覆盖单 worker」与「镜像是节点缓存旧产物」两个边界一起收窄。
真机复查发现三台节点各有两块 40G 空白盘 ⇒ 单 worker 是软件限制而非资源限制。
本轮**不改 Rust / Go 产品代码**（`git diff 52bda85 -- agent/src agent/Cargo.toml
agent/Cargo.lock` 为空），改动面是清单、POC 判据脚本、Go 一致性测试与文档。

- 新增 `control-plane/config/lvmd/nodevg-seed-202.yaml` 与
  `configmap-lvmd-10-60-166-202.yaml`：第二 worker `10-60-166-202` 的
  `hlvm-lvmd-vg-202`（空白 `vdb` + 36G thinpool）。控制器**自动**渲染出
  `hlmd-lvmd-10-60-166-202`，无需改控制器代码。
- 新增 `configmap-lvmd-all.yaml`、改写 `daemonset.yaml`：一份 ConfigMap 以节点名为
  key 承载各节点 `lvmd.yaml`，initContainer 用 Downward API 的 `NODE_NAME` 投影到
  emptyDir `/etc/topolvm/lvmd.yaml`；lvmd / topolvm-node / storage-agent 三个 DS
  统一改用 `hlvm.io/lvmd=true` 标签选择器，**一个 lvmd DS 服务任意节点**。
- 新增 `docs/poc/scripts/expand-lvmd-nodes.sh`：按「建 VG → seed + patch status →
  清窗口期 Task → 生成聚合 CM → 打标签 → apply → 判就绪」编排，支持
  `STEP=prepare|deploy|verify|all` 逐相位、`DRY_RUN=1` 只读前置、
  `CONFIRM_WRITE=1` 才允许写盘（VG 已存在则幂等跳过）；窗口期 Task 默认 FAIL，
  必须 `PURGE_WINDOW_TASKS=1` 且逐条核验「目标节点 + `vgcreate` + 无审批」才清理。
- **判据纪律修正**：多节点下 `kubectl exec ds/...` 任取 Pod 会读到另一节点的 VG，
  得出无据结论。`pvc-supply-e2e.sh`、`deploy-agent-real.sh`、
  `agent-lvmd-lock-verify.sh` 全部改为按 `spec.nodeName` 定点取 Ready Pod；
  `m15-integration.sh` 灰度相位 3 处 `logs ds/hlvm-storage-agent` 改用已定点取到的
  `agent_pod`。早期 `concurrency-lvmd-test.sh` 未适配多节点，已在头部标注边界。
- `deploy-agent-real.sh` 补「等 DS generation/updated/ready 收敛 + 门禁前重新定点
  取 Pod」，修掉滚动更新时拿旧 Pod 去 exec 的竞态；默认镜像与两个门禁脚本统一
  改为 CI 产物 `ghcr.io/f31/hlvm/storage-agent:sha-52bda85`（两节点均实测可从
  GHCR 匿名拉取），不再是只缓存在节点上的 `sha-87d9160` / `sha-7e76f95`。
- `TestLvmdPOCArtifactsConsistent` 扩成表驱动：钉死两个 seed ↔ per-node CM ↔
  聚合 CM（逐字节）↔ DS 标签选择器/initContainer/emptyDir ↔ 判据脚本不得再出现
  `exec "ds/$LVMD_DS"`。

**真机实测（逐相位 → all）**：`prepare` PASS=8、`deploy` PASS=12、
`verify` PASS=21、`all` **PASS=35 / FAIL=0 / SKIP=0**。两节点容量注解各
`2143289344B`、`CSIStorageCapacity` 两条分别指向一个节点（各 2044Mi）；
两个 agent Pod 的 `MODE=pod` 真实写门禁各 PASS；**两个节点各跑通一次**
1Gi PVC → thin LV → ext4 写 16 MiB → PV/LV 回收；终态 Task/PVC/残留 LV 全 0。
两次首跑 FAIL 都是判据脚本自身缺陷（窗口 Task 重跑闸门、DS 滚动更新竞态），
已修并复跑全绿，不是产品缺陷。

验证：Go `vet ./...` + `test ./... -count=1` 全绿；WSL `rust:slim` 容器
`cargo test --all-targets` **155 passed**；全部脚本 `bash -n`、`git diff --check` 通过。

诚实边界：只扩到 2 个 worker（CP 未扩、A 链路设备插件仍只在 153）；聚合 CM 由
脚本从 per-node CM 同步而非控制器直接渲染；NodeVG 仍手工 seed、`LVReporter` 未接、
容量按 VG free 2 GiB 而非 thin-pool 36G；`sha-52bda85` 是上一轮 CI 产物，本轮
未改 agent 产品代码故二进制与当前 HEAD 等价，但 **tag 不等于本轮最终 HEAD**；
**未跑 `m15 all`**（`verify-agent` 相位会删除常驻 DS 并起临时单节点 DS，且若干
相位仍假设单节点 DS）。

### 常驻 agent DS 上线：补齐主循环与 MODE=pod 空白（ADR-006 §12，2026-11-12）

承接上一条，把 §11.7 记下的「验的是调用栈、不是 agent 主循环」补上。本轮**不改产品代码**，
只新增 POC 脚本与文档。

- 新增 `docs/poc/scripts/deploy-agent-real.sh`：真机部署单 worker 常驻
  `hlvm-storage-agent` DS（hostPID + privileged + `/host,/dev,/run/lock/lvm`
  + nsenter wrapper），判据含「目标节点存在 Ready Pod」而非 rollout status、
  DS env 逐字校验、`MODE=pod` 真实写门禁、主循环日志与 `RESTARTS=0`；
  `--cleanup` 可撤掉 DS。
- **上线前发现并处置孤儿 StorageTask**：手工 seed NodeVG 时控制面下发的
  `vg-…-vgcreate` 从未被消费（`status` 缺失、`ttl` 空、无 `approvedBy`），
  agent 一旦上线会在首轮 10s 轮询里取走它。先确认 `NodeVG.vgExists=true`
  （控制器只在 `!vgExists` 时下发，删后不重建）再显式删除，观察 35s 未重建；
  VG 与容量状态不变。该风险固化为脚本的默认 FAIL 前置扫描，
  只有 `PURGE_ORPHAN_TASKS=1` 才显式清理，**绝不静默删任务**。
- 真机完整灰度相位 `M15_TARGET=real M15_HOST_WRAPPER=1 verify-agent`
  **rc=0 / 全 PASS 无 SKIP**：`MODE=pod` 门禁从真实 agent Pod 读到 nsenter
  wrapper 并 `CREATE_RC=0 / REMAIN=0`；节点名注入、kube 客户端/回写循环、
  任务状态回写（错误文本来自宿主 lvm，反证 wrapper 生效）、NodeDisk 观测写回、
  ext4 占用判定全部通过。相位自动清场干净。
- 常驻 DS 部署脚本真机 `PASS=16 / FAIL=0 / SKIP=0`；**agent 常驻状态下**
  `pvc-supply-e2e.sh` 复跑 **PASS**（1Gi PVC → thin LV → 写 16 MiB → PV/LV 回收）。
  终态 3 节点 Ready、4 个 DS、VG 只剩 thinpool、`orphan_lvm=0`、
  PVC/PV/CR 全 0、容量注解回到 2143289344。
- ADR-006 新增 §12 并更正 §11.6/§11.7 的过时边界；ADR-007 §5 加二次更正标注。

诚实边界：常驻 DS 限定单 worker（非三节点全量）；镜像用节点已缓存的
`sha-87d9160` 而非当前 HEAD 产物；NodeVG 仍手工 seed、`LVReporter` 未接、
容量按 VG free 2 GiB 上报；孤儿 Task 的破坏性是静态代码分析 + 状态核查推断，
未让它真的被消费。

### 落地 nsenter 修法并把 §5.3 门禁升级为真实写（ADR-006 §11.6，2026-11-12）

承接上一条发现的缺陷，把修法从「判据脚本里的可行方向」变成产品侧默认配置与硬门禁。

- 新增 `docs/poc/scripts/host-wrapper-gate.sh`：从 Pod 内读 `HLVM_HOST_WRAPPER`，
  按 `lvm_argv_with` 的 `split_whitespace` 语义现场拼命令，做一次真实写
  `lvcreate -> lvs 核对 -> lvremove -> 残留 0`；`timeout` 置于 wrapper **之后**
  （宿主命名空间侧）并带 `-k`，杀的是宿主 lvm 进程本身；输出
  `GATE_RESULT=PASS|FAIL|SKIP`，能力缺失 SKIP 且不计 PASS，wrapper 未注入判 FAIL。
  支持 `MODE=probe`（自起一次性 Pod）与 `MODE=pod`（指向已部署的 agent Pod）；
  所有失败分支都会清场并打印 `CLEANUP_REMAIN`。
- `scripts/m15-integration.sh`：`M15_HOST_WRAPPER=1` 注入值从 `chroot /host` 改为
  `nsenter -t 1 -m -u -i -n -p --`；删掉只读 `lvm version` 的假绿断言，改为调用
  `host-wrapper-gate.sh` 并按 `GATE_RESULT` 判 PASS/FAIL/SKIP；新增可选
  `M15_GATE_VG` 指定判据 VG（默认自动发现 free >= 64 MiB 的 VG）。默认仍不注入。
- `agent/config/daemonset-agent.yaml`、`agent/src/lvm/mod.rs`、
  `agent/src/executor/mod.rs`、`control-plane/config/lvmd/daemonset.yaml`、
  设计方案 §5.3、两个 POC 并发判据脚本：同步更正把 `chroot /host` 当有效示例的描述，
  写明必须 `hostPID: true` + `privileged` 且须进入宿主 IPC NS；
  `agent-lvmd-lock-verify.sh` 默认 `WRAPPER` 改为 nsenter，`chroot /host` 变为显式负向对照。
- 新增 Rust 单测 `lvm_argv_matches_recommended_nsenter_wrapper` 钉死 argv 形态；
  新增 Go 测试 `TestHostWrapperGateConfigConsistent` 防注入值 / 门禁调用 / 脚本默认值回退。

真机复验（节点 `10-60-153-100`，VG `hlvm-lvmd-vg-153`）：

- 默认 nsenter：**GATE_RESULT=PASS / rc=0**（`CREATE_RC=0`、宿主 lvs 可见测试 LV、
  `REMAIN=0`），清场后 VG 只剩 thinpool。
- `WRAPPER='chroot /host'` 负向对照：**GATE_RESULT=FAIL / rc=1**（`CREATE_RC=137`，
  宿主 timeout 截断挂死的 lvcreate），证明新门禁确实抓住旧缺陷；宿主 lvs 仍可读、
  孤儿 lvm 0、probe Pod 已清、测试 LV 清理残留 0。
- 负向对照第一轮曾暴露脚本自身缺陷：timeout 在 LV 落盘后才杀进程，FAIL 分支直接退出
  留下测试 LV。已加 `trap cleanup_lv EXIT` + 各失败分支 `CLEANUP_REMAIN` 证据并重跑验证。

**诚实边界**：本轮未部署常驻 agent DaemonSet，验的是 agent 的 lvm 调用栈而非主循环；
`MODE=pod`（m15 灰度相位内指向真实 agent Pod）未在真机跑完整相位；
NodeVG 仍手工 seed，只覆盖单 worker、单 VG。

### 进程级锁同源复验：发现 §5.3 默认 wrapper 的真实缺陷（ADR-006 §11，2026-11-11 续）

真机重启恢复后，先复验 B 链路自愈：三节点 Ready，lvmd DS / topolvm controller / node
在 kubelet 恢复后约 40s 全部 Running，VG `hlvm-lvmd-vg-153` 与 36G thin-pool 随宿主重启
存活、`thin_count=0`，`pvc-supply-e2e.sh` 重跑 **PASS**（PVC Bound → 1Gi thin LV →
写 16 MiB → PV/LV 全回收）。

随后补 ADR-006 §1 列的最后一公里「agent 与 lvmd 并发写同一 VG」，**结论是发现缺陷**：

- 新增 `docs/poc/scripts/agent-lvmd-lock-verify.sh`：一次性 probe Pod 复用
  `storage-agent:sha-7e76f95` + `HLVM_HOST_WRAPPER` + `/host`,`/dev`,`/run/lock/lvm`
  挂载，按 `lvm_argv_with` 的 `split_whitespace` 语义现场拼命令；全走 `kubectl exec`
  （节点 22 端口被 Clash TUN 劫持，判据不架在 SSH 上）。不部署常驻 agent DS，
  避免主循环 reconcile 干扰判据。
- **静态身份全 PASS**：容器内裸 lvm 不存在（rc=127）、wrapper 调到宿主
  `LVM version: 2.03.16(2)`、读到宿主 VG；`/run/lock/lvm` dev+inode `27 2` 与
  `/sbin/lvm` sha256 `7e2299bed497407342a72d00099598e3` 在 agent / lvmd 双侧一致。
- **动态并发默认配置 FAIL**：`chroot /host` 下 10 路 `lvcreate` 全部挂起、`lvs` 也被堵住；
  `lslocks` 显示一个进程持 `WRITE` 锁、其余 `WRITE*` 等待，持锁者
  `wchan=__do_semtimedop`。单路对照实验证实与并发无关：
  `chroot /host lvm lvcreate` rc=124（30s 超时、无输出），同一 Pod 内
  `nsenter -t 1 -m -u -i -n -p -- lvm lvcreate` rc=0（LV 67108864B 创建并清场成功）。
  根因是 **chroot 只切文件系统根、不切 IPC 命名空间**，lvm/libdm 的 udev 同步
  用 SysV 信号量，宿主 udev 与容器 IPC NS 互不可见 ⇒ 持 VG flock 永久等待。
  「同二进制 + 同锁目录」必要但不充分；§5.3 门禁此前只验 `lvm version`（不取锁），漏了写路径。
- **修法已验证但本轮不改产品代码**：`WRAPPER='nsenter -t 1 -m -u -i -n -p --'` 下
  完整判据 **PASS**（预检 rc=0、10/10 路 rc=0、无锁冲突日志、清场 `REMAIN=0`、
  VG 只剩 thinpool）。落地需另立变更：`m15-integration.sh` 的
  `M15_HOST_WRAPPER=1` 注入值、`daemonset-agent.yaml` 注释、以及把门禁断言从
  `lvm version` 升级为一次真实写操作。
- **文档更正**：ADR-006 §10.6 / ADR-007 §5 / 本文件曾写「§5.3 `chroot /host`
  改造未落地、agent 仍调镜像内 lvm」，与代码不符——wrapper 改造与单测早已落地，
  agent 镜像内本就无 lvm 二进制。真正缺的是真机无常驻 agent DS 与进程级并发实测。
- **判据脚本自身三坑（已修）**：`kubectl exec -i ... sh -s` + 容器内后台子进程会
  因 stdout 管道未 EOF 无限挂起（改 WSL 侧 10 路独立短 exec）；未加引号 heredoc
  注释里的反引号触发命令替换并污染 ERR trap（heredoc 一律 `<<'EOS'`）；增加
  4.0 单路写能力预检，失败即 FAIL + 诊断 + 清理孤儿 lvm，不再锁死 VG。

### B 链路真正供给 PVC：TopoLVM CSI 上线并端到端验证（ADR-007，2026-11-11）

ADR-006 之后 lvmd 已经有消费者，但 B 链路仍**不提供 PVC 供给**——没有 CSI
controller / node 插件，PV 无从创建。本次把 TopoLVM 0.42.0 的 CSI 栈部署到真机，
并用脚本把「PVC → PV → Pod 挂载 → LV 落 VG → 回收」全链路钉成判据。

- **新增 `control-plane/config/csi/`**（由上游 chart v0.42.0 渲染 + 最小元数据归一化，
  渲染命令与 values 覆盖点见目录 `README.md`）
  - `00-crd-logicalvolume.yaml`：`logicalvolumes.topolvm.io`（node 侧
    LogicalVolumeReconciler 依赖，缺了起不来）
  - `10-rbac-controller.yaml` / `11-rbac-node.yaml`：controller 的 PV/PVC/SC/CSINode
    /CSIStorageCapacity 权限，node 的 `nodes` patch（写拓扑标签与容量注解）
  - `20-csidriver.yaml`：`topolvm.io`，`attachRequired: false`、`storageCapacity: true`
  - `30-controller.yaml` / `40-node.yaml`：controller Deployment（provisioner/resizer/
    livenessprobe）与 node DaemonSet（registrar/livenessprobe）
  - `50-storageclass.yaml`：`hlvm-b`，`topolvm.io/device-class=hlvm-lvmd`、
    `WaitForFirstConsumer`、`allowVolumeExpansion`
- **单镜像方案**：所有容器都用 `topolvm-with-sidecar:0.42.0`（内含全部 sidecar 二进制），
  弱网下只需预热一个镜像；该镜像 210.1 MiB 中 5 层与已导入的 plain 镜像相同，
  实际只补了 36 MiB 新层。
- **`lvmd.managed=false`**：复用 `config/lvmd/` 的 lvmd，避免同节点两个 lvmd 抢同一批 VG。
- **capacity tracking**（`CSIStorageCapacity` + `storageCapacity: true`）而非
  scheduler extender：不需要改 kube-scheduler 配置。
- **新增 `docs/poc/scripts/pvc-supply-e2e.sh`**：端到端判据脚本。两个实现细节值得记：
  LV 名不是 `pvc-<uid>` 而是另一个 UUID（改用「基线集合差 + 尺寸核对」）；
  宿主 lvs 走 `kubectl exec ds/hlvm-lvmd -- nsenter -t 1`，避开 WSL→云主机 22 端口
  被 Clash TUN 劫持导致的「读不到 lvs 就当成 LV 不存在」假绿。
- **新增 `docs/poc/adr/007-topolvm-csi-supply.md`**：决策与实测证据、诚实边界
  （容量上报的是 VG 剩余 2 GiB 而非 thin-pool 36G、只覆盖单节点、NodeVG 仍手工 seed、
  agent 未参与进程级互斥）。

真机验证结论：PVC 1Gi → Bound，PV 带 `topology.topolvm.io/node` 亲和，Pod 挂载
ext4 并写入 16 MiB，VG 内新增 1 颗 1073741824B 的 thin LV，删除后 PV 与 LV 均回收。

### 真机落地 lvmd 消费者 + 锁同源验证（ADR-006 路线 A，2026-11-11）

此前 B 链路（TopoLVM CSI 供给）只补了 agent 侧读路径 wrapper 门禁，**没有 lvmd 消费者**，
NodeVG 也只由控制面渲染 ConfigMap、无人消费。本次在真实集群（CP `10-60-131-187` +
worker `10-60-153-100`/`10-60-166-202`，k8s v1.36.6）走路线 A 把 lvmd 真正跑起来，
并把「agent 与 lvmd 并发写 VG」的锁同源门禁从机制推断推进到实测证据。

- **新增 `control-plane/config/lvmd/`**
  - `daemonset.yaml`：`hlvm-lvmd` DaemonSet + 独立 SA（无 RBAC —— lvmd 不访问 API）。
    `hostPID: true` + `privileged` + 宿主 `/dev`、ConfigMap `hlmd-lvmd-<node>` 挂到
    `/etc/topolvm/lvmd.yaml`、socket 宿主 `/run/topolvm`、livenessProbe `/lvmd health`。
    POC 用 `nodeSelector` 只落有专用 VG 的 worker。
  - `nodevg-seed-153.yaml`：手工 seed 的 NodeVG（**对象名 == 真实 LVM VG 名**，
    因为 `AggregateLVMDConfig` 渲染的 `volume-group` 取的就是 NodeVG 的 `metadata.name`）。
- **镜像选型修正**：`topolvm-with-sidecar:0.42.0`（amd64 层 210.1 MiB）里的 sidecar 层
  对 lvmd 无用，改用 plain `topolvm:0.42.0`（73.3 MiB，前 5 层与前者完全相同），弱网下拉取代价约 1/3。
- **新增 `docs/poc/scripts/`**
  - `fetch-oci-parallel.py`：弱网下拉旁路（HTTP Range 2 MiB 分块 + 8 并发 → 组装 OCI layout）；
    真机实测单连接仅 90–500 KiB/s 且抖动，分块并行后提升到 ~1 MiB/s 量级。
  - `lvmd-lock-verify.sh`：不需要 agent 在位的锁同源判据（锁目录身份 / lvm 二进制身份 / 并发 lvcreate）。
- **验证结果**（详见 `docs/poc/adr/006-lvmd-deployment.md` §10.5–§10.6）
  - lvmd DS `1/1 Ready`、`RESTARTS=0`，启动即接受渲染出的 device-class
    （`hlvm-lvmd` → `hlvm-lvmd-vg-153` → `thinpool`，overprovision 1.0）。
  - 锁同源：`/run/lock/lvm` 的 `dev+inode` 在宿主视图与容器内 `nsenter -t 1` 视图完全一致，
    `/sbin/lvm` sha256 一致；宿主 5 路 + 容器内 5 路并发 `lvcreate` 全部成功、无锁冲突日志。
- **诚实边界**：本次**没有**让 agent 真实进程参与并发，故门禁结论只覆盖「宿主 lvm 视图」；
  NodeVG 仍是手工 seed，生产闭环需路线 B（agent VG-reporter）。
  > 更正（2026-11-11 续）：此处原写「设计 §5.3 的 `chroot /host` 改造未落地、agent 仍调镜像内
  > lvm」，与代码不符——读写路径统一经 `HLVM_HOST_WRAPPER` 的改造见下方「B 链路硬门禁（§5.3）」，
  > 且 agent 镜像（kindest/node）内本就没有 lvm 二进制，裸调用必然失败。真正缺的是
  > **真机上没有常驻 agent DaemonSet** 与 **agent×lvmd 进程级并发实测**；
  > 后者已由 `docs/poc/scripts/agent-lvmd-lock-verify.sh` 补上（ADR-006 §11）。

### B 链路硬门禁（§5.3）：读路径对齐宿主 lvm + 共享锁（2026-11-11）

为后续 TopoLVM CSI 供给（B 链路）落地，先补齐设计 §5.3 的硬门禁——agent 与 lvmd 并发写同一 VG
前必须共用宿主 lvm 二进制与 `/run/lock/lvm` 锁。此前只有 `executor::execute`（写路径：
pvcreate/vgcreate/wipefs/…）尊重 `HLVM_HOST_WRAPPER`，而 `lvm::lvm_json`（读路径：vgs/lvs/pvs
三方对账、漂移检测）仍是裸 `Command::new("lvm")`，**绕过** wrapper ⇒ 只读路径走容器内 lvm、与 lvmd
不共享锁，锁一致性只读满足不算数。

- `agent/src/lvm/mod.rs`：抽出纯函数 `lvm_argv_with(wrapper, args)`，读写路径统一经
  `HLVM_HOST_WRAPPER`（默认空，等价直接 `lvm`）构造命令行，并补 3 个单测（plain / 加前缀 / 空白忽略）。
- `agent/config/daemonset-agent.yaml`：确认 `/host`（`hostPath: /`）与 `/run/lock/lvm` 挂载已就位；
  仅加注释级指引——启用 B 链路时给 agent 注入 `HLVM_HOST_WRAPPER=chroot /host` 即可，默认不设
  （设了但宿主无 lvm 会破坏 kind 集成）。
- 本提交**只补门禁不部署 lvmd**：B 链路仍 stage-0 阻塞（缺 lvmd 消费者、未过 openspec 决策门、
  真实镜像/私有 registry 未就绪）。这是无外部依赖、可在 CI 验证的第一刀。

### B 链路灰度门禁：可灰度开启与运行时验证（2026-11-11 续）

在 `scripts/m15-integration.sh` 的 `phase_verify_agent` 中补齐门禁的「灰度开关 + 运行时验证」：

- 新增 `M15_HOST_WRAPPER=1` 开关：仅当显式置 1 时，给 `hlvm-storage-agent` DaemonSet 注入
  `HLVM_HOST_WRAPPER=chroot /host`（经 `kubectl set env`）。默认不注入，kind 集成不受影响。
- 新增门禁验证断言：注入后从 agent Pod 内执行 `chroot /host lvm version`，成功且含 `LVM version`
  即判 PASS（证明 agent 经 chroot 调通**宿主** lvm）；失败即 FAIL 并附诊断（宿主 lvm 路径 / PATH）。
  该断言只在 `M15_HOST_WRAPPER=1` 时执行，非灰度默认 SKIP。

**关键事实（影响 B 验证目标）**：agent 镜像基于 `kindest/node:v1.36.1`，**不含 `lvm` 二进制**
（已用 `docker run --rm kindest/node:v1.36.1 ... command -v lvm` 验证为 `not found`；`chroot`
在镜像内存在）。因此：
- 当前 agent（默认不设 wrapper）在**任何**目标上都无法直接跑 `lvm`——必须靠 `chroot /host` 调宿主
  lvm；门禁（§5.3）正是让 agent 与 lvmd 共用宿主 lvm + 宿主 `/run/lock/lvm` 锁的关键，比原先认知
  更不可或缺。
- `chroot /host lvm` 能否调通**取决于宿主是否装了 lvm2**：真实节点默认有 lvm2 ⇒ 真机可验证；
  kind 节点（kindest/node）同样无 lvm ⇒ **kind 无法验证 B 的 lvm 路径**，B 的运行时验证只能在真机做。

### 真机 `all` 端到端：4 处判据把环境差异报成缺陷（2026-11-11 续）

`M15_TARGET=real` 首次端到端跑 `all`。前 10 个相位全绿，第 11 个（`verify-kubelet-restart`）
与第 15 个（`verify-cert-rotation`）各有判据问题。四处都属「kind 下成立的真机假设」，
不是产品缺陷；修法统一为「用能区分原因的证据重新表达断言」，没有放宽任何一条。

- **`verify-ttl` 把 agent 正常执行报成「提前判定为 Failed」**：窗口内用例（ttl=1h）原来要求
  `phase` 为空或 `Pending`——这隐含「没有 agent 消费任务」。真机上 agent 存活、盘可用，8s 内
  就会接手任务并置 `Running`，这是**正确行为**。判据改为「不得为 `Failed` 且 `result` 不含
  `DeadlineExceeded`」，即只断言「没被 ttl 误杀」，不要求 phase 停在初始态。
- **`verify-kubelet-restart` 的 checkpoint 证据链有两条不稳**：
  ① 原证据「文件 mtime 早于 Pod 创建」在真机随机翻转——kubelet 会周期性改写该文件，mtime 可能
  恰好落在 Pod 创建后 1 秒（第三轮实测 `mtime=…840 > podCreated=…839`），把环境差异报成缺陷。
  改用「**Pod 创建之前** `podDeviceEntries` 就已无条目」（absent/empty）+ 插件确有分配日志 +
  分配后仍无条目，三条同时成立才 SKIP。
  ② 「重启后必须出现新注册日志」也不成立：真机 kubelet 1.36.6 重启**不**清空 `device-plugins`
  目录，插件 socket 仍在，kubelet 直接连回旧 socket 复用注册，`allocatable` 已恢复但日志里不会
  出现新注册。现允许两条等价路径（新注册日志 / socket 在位 + 容量恢复 + 插件 Pod 未重建），
  同时新增 `kubelet.sock` 的 `(inode, mtime)` 签名断言，证明重启**确实发生**——否则「重启命令
  静默失败」会让「什么都没变」这组观察全部假绿。
- **`verify-cert-rotation` 把探针失效误诊成「certwatcher 未生效」**：`port-forward` 在 180s
  等待里会静默失效（apiserver 回收空闲连接），表现为服务端证书取到空串 `''`，于是「服务端证书
  未更新」与「新证书与 caBundle 不匹配」两条同时 FAIL。实测同代码同集群上一轮 PASS、下一轮 FAIL，
  复跑 40s 内正常换证。现：取样为空即重建 port-forward（限 3 次），基线取不到直接判 FAIL
  （否则 `srv1 != srv0` 恒真会假绿），FAIL 文案区分「探针取不到证书（未判定）」与「证书确实没变」。
- **`verify-velero` 的失败文案写死 kind/WSL 代理**：真机拉不到 `docker.io` 镜像时也打印
  「kind 节点容器运行时经 WSL 代理…」，指向一个不存在的环境。文案按 `M15_TARGET` 分流；
  另把「见到 `ImagePullBackOff` 立即放弃」改为**宽限 45s**——真机首次拉大镜像会先
  `ErrImagePull → ImagePullBackOff →` 重试成功，立刻判定会把可用环境误判为不可用。
  真机结论仍为 SKIP（镜像确实拉不到），但输出如实说明「端到端备份/恢复未验证」。

### 真机 `all` 收敛（同日晚些时候）：3 个「假绿/静默退出」缺陷

跑 `all` 的过程中又暴露三个与业务逻辑无关、但会让结论失真的脚手架缺陷：

- **`verify-agent` 的 `rollout status` 假绿**：DaemonSet 刚创建、`status.desiredNumberScheduled`
  还是 0 时，`kubectl rollout status` 会**立即返回成功**（Pod 一个都还没被调度），于是打印
  「agent Pod 就绪」，紧接着按目标节点取 Pod 得到空 → 「被测节点上无 agent Pod」FAIL +
  两条 `logs: unbound variable`（`logs` 只在 else 分支赋值）。修：以「目标节点上真有 Ready 的
  agent Pod（90s）」为硬判据，`logs` 声明时初始化为空。
- **`set -euo pipefail` + 无兜底的命令替换 ⇒ 相位静默 rc=1**：`agent_ready="$(kc … | awk …)"`
  在 kubectl 偶发非零（stderr 被 `2>/dev/null` 吞掉）时，赋值语句继承失败状态，脚本直接退出，
  **日志里连一行 error 都没有**。同一现象在 `verify-topology-scale` 上也复现过（单跑却全 PASS）。
  修：该赋值补 `|| true`；`all` 的相位调用改为**子 shell 隔离**（相位内的 `trap ... EXIT` 不再
  污染后续相位），并在子 shell 里装 `set -E` + ERR trap，失败时打印 `BASH_COMMAND`——
  下次静默退出能直接定位到命令，而不是靠 `bash -x` 复跑。
- **`verify-velero` 把 DaemonSet 名写死成 `velero-node-agent`**：新版本 velero CLI 创建的名字是
  `node-agent`，这条断言在任何环境都恒 FAIL（真机实测 node-agent 已 2/2 Ready 仍报「未就绪」）。
  改为按存在性择名。另修 `ensure_minio`：「Deployment 对象存在」被当成「minio 可用」，
  而真机 minio Pod 一直 `ImagePullBackOff` ⇒ BSL 必然 Unavailable，却被报成栈缺陷。
  现在「已存在」也要过「Available 或明确 ImagePull 失败」这一关。
- **预检的 GHCR 探测把网络抖动报成结构性缺失**：`M15_GHCR_PUBLIC=1` 分支对每个包只探一次
  匿名 token，控制面偶发一次 curl 无响应就 FAIL「包仍私有」。同一时刻从 WSL 侧测四个包均 200。
  改为每包重试 3 次（间隔 2s、`-m 20` 超时），三次都失败才判 FAIL。

### 真机 M17 首跑暴露的脚手架缺陷（2026-11-11）

- **`apply` 写死 `:latest` 的清单后再 `set image` ⇒ 真机拉镜像超时**：`apply` 那一刻 kubelet 就按
  `:latest` 开始拉（`storage-agent` 单层约 396MB，真机实测 2m59s），DaemonSet 没有 Deployment 的
  滚动缓冲，旧 Pod 未退场时 `rollout status --timeout=180s` 必然超时，表现得像「设备插件起不来」的
  产品缺陷。kind 因已 `kind load` 过 `:latest`，永远暴露不到。新增 `apply_manifest_with_image()`：
  apply 前用 `sed` 把清单里的 hlvm 镜像行渲染成目标 tag，覆盖 agent / device-plugin 两个
  DaemonSet 与 3 处 `03-crd-conversion.yaml`。
- **设备探测 glob 缺 virtio `/dev/vd*`**：`verify-device-plugin` 的两个探针只 glob `/dev/sd*`、
  `/dev/nvme*`，而云主机数据盘是 `/dev/vdb`（virtio）⇒ `dd` 根本不执行，「申请者读不到设备」与
  「对照组无 EPERM」同时误报成「该环境设备 cgroup 未生效」。补 `/dev/vd*` 后实测
  `READ_OK=/dev/vdc` + 对照组 `EPERM`，证明真机 cgroup v2 下 devices 隔离有效。
- **`set -u` 下热插拔钩子变量未定义导致相位崩溃**：`disk_inject` / `disk_eject` /
  `disk_inject_available` 直接引用 `M15_DISK_ATTACH_CMD` / `M15_DISK_DETACH_CMD`，未提供钩子时
  `verify-device-hotplug` 以 `unbound variable` 崩溃而不是按约定 SKIP。统一改 `${VAR:-}`。
- **`verify-kubelet-restart` 判据过紧**：checkpoint 读取改为轮询 30s（kubelet 异步落盘，读一次
  必然为空），注册检测窗口 60s → 120s（真机实测 227s 内完成重建监听并重注册）。
- **checkpoint 判据改为「环境能力判定」而不是放水（同日第二轮）**：真机 kubelet 1.36.6 在分配
  设备后不写 `kubelet_internal_checkpoint` 的 `podDeviceEntries`（字段恒 `null`，文件 mtime 停在
  kubelet 启动后 7s）。现做法：该断言失败时先验证三条证据——① 文件 mtime 早于 Pod 创建时间；
  ② 插件日志在该 Pod 创建后确有「分配磁盘设备」；③ 全文没有任何 `podDeviceEntries` 条目——
  三条同时成立才 **SKIP 两项 checkpoint 断言**并打印 `[warn]` 与全部证据值，缺一即 FAIL。
  **SKIP 不写成 PASS**，汇总行显式标注。同时修两处会让结论失真的采集缺陷：Pod 探针 `ls` 补
  `/dev/vd*`（virtio 云盘），容器侧取不到设备路径时回退插件 `Allocate` 日志的 `host=<path>`；
  「不重复分配」在 A 的设备路径未知时改判 **FAIL**（原判据 `b_dev != a_dev` 在 a_dev 为空时恒真，
  会把「无法比对」伪装成「未重复分配」）。
  **仍是已知缺口**：checkpoint 缺失 ⇒ kubelet 重启后 device manager 无分配记忆，当前由插件进程
  内存表兜住；kubelet 与插件进程**同时**重启时无持久兜底，见 runbook §8.5。

### 集成脚本 / 真机前置（2026-11-11）

- **新增 `M15_GHCR_PUBLIC=1` 显式开关**（默认 0，不做静默检测）：4 个 GHCR 包改为 public 后，
  `preflight` 跳过 `hlvm-system/ghcr-pull` 检查，改为从控制面节点**逐个**实测 4 个包的匿名
  `ghcr.io/token?scope=repository:f31/hlvm/<pkg>:pull` = 200 才 PASS，任一失败列出具体包名并
  FAIL；汇总 WARN「不覆盖 registry 鉴权链路」。不设开关且缺 secret 一律 FAIL。
  `phase_check` 的提示同步条件化，避免公开模式下输出误导性的「私有包会 ImagePullBackOff」。
  **判据选 token 而非 manifest**：公开包匿名 GET manifest 同样 401（OCI Bearer challenge），
  已用已知公开包 `topolvm/topolvm` 对照实测；上一版「manifest 期望 200」会在包公开后误判 FAIL。
- **文档同步**：`scripts/real-cluster/README.md` §2/§3/§5/§6 改为公开包默认路径（不再要求
  `GHCR_USER/GHCR_TOKEN`、不跑 `post-install.sh`），`docs/m15-integration-runbook.md` §7 更正
  「`storage-agent` 从未推送」的过时记录并写明两条路径与结论边界。
- **真机 `preflight` 首次跑通**：3 节点集群（v1.36.6，1 CP + 2 worker）上
  PASS=10 / WARN=2 / FAIL=0 / RC=0；WARN 为「不覆盖 registry 鉴权链路」与
  「未提供 `M15_DISK_ATTACH_CMD` → `verify-device-hotplug` SKIP」。`all` 结论另行记录。
- **已知风险（登记，未修 `post-install.sh`）**：私有包路径下该脚本只把 `ghcr-pull` 挂到
  `hlvm-system/default` SA，而全部工作负载用具名 SA ⇒ 节点仍 ImagePullBackOff，
  但 `preflight` 只断言 secret 存在 ⇒ 结构性假绿。本轮走公开包路径，未实跑也未修复该路径。
- **仓库结构（2026-11-11 远端提交 `5b54463`）**：整个 `openspec/` 目录（46 文件、2790 行）
  已从 `main` 删除，含 `add-topolvm-csi-supply` 立项与全部归档 spec/tasks。下方历史版本条目里
  出现的 `openspec/...` 路径是**当时的记录**，当前文件已不存在；验收回填改以本文件与
  `docs/m15-integration-runbook.md` 为准，不再 tick 已删除的任务清单。
- **修 real 模式「声明精确版本、实跑 latest」假绿（真机首跑发现）**：静态清单把
  controller/webhook 写成 `:latest`（kind 靠 `cp_build` + `image_load` 命中本地镜像），但 real
  不构建不 load，`IMG_TAG` 只作用于动态创建的 agent/conversion 镜像 ⇒ preflight 打印
  「精确版本引用，结论可复现」而集群实际拉 `latest`（会被下一次 main 推送覆盖）。现
  `phase_bootstrap` 在 real 模式把两个静态 Deployment 的 `containers/0/image` 显式 patch 为
  `${IMG_REGISTRY}/...:${IMG_TAG}`；`phase_preflight` 在已部署时核对实际镜像引用，不一致即 FAIL
  并要求重跑 bootstrap。`all` 里的 `phase_build` 只改 `imagePullPolicy`，不会覆盖 tag。
  **验证闭环**：修复前 preflight FAIL（列出 `controller/webhook=:latest`）→ bootstrap 对齐 RC=0
  → preflight PASS=11 / WARN=2 / FAIL=0 / RC=0；实际镜像为
  `storage-controller:v0.1.0-preview.2` / `storage-webhook:v0.1.0-preview.2`。

### 已知风险 / 评估

- **`verify-cert-rotation` 遗留 `kubectl port-forward` 孤儿进程（本轮发现，未修 m15 脚本）**：
  TLS 探针起的 `port-forward ... 19443:9444` 在相位结束后仍存活（PPID=1）。它本身不阻塞测试，
  但会继承 joint 脚本 `exec 9>` 的锁 fd；本轮已通过 `flock -n -o` 重构规避，并在验收前
  kill 该进程释放 19443。m15 脚本自身的探针进程清理待单独立项。
- **Go 侧 k8s 依赖代差（登记，不在本版修复）**：`k8s.io/api` / `apimachinery` 为 v0.33.0，
  `client-go` / `apiextensions-apiserver` 为 v0.32.1，`controller-runtime` 为 v0.20.4
  （官方绑定 k8s v0.32.x）；MVS 会让 client-go 0.32.1 链接到 apimachinery 0.33.0，
  属上游未验证搭配。Rust 侧 `k8s-openapi 0.28 / v1_36` 与 kind 1.36.x 实测集群对齐。
  当前 `go build/vet/test`、envtest 1.36.2 与 kind 1.36.4 集成全通过，**没有实际失败证据**，
  但升到 k8s 0.36 需 controller-runtime 0.22+，牵连 webhook decoder / cache /
  CRD conversion 接线，须单独立项并在真实集群回归后评估——不借「顺手统一版本」夹带。
  已新增 `internal/version/deps_test.go` 基线锁定 + CI 显式 `Verify k8s dependency baseline`
  步骤，防止 `go get -u` 之类的无意识漂移；详细理由见该测试文件顶部注释与 runbook §10.18。

### 文档 / 架构澄清

- 修 `scripts/real-cluster/README.md` 的文档漂移：① 新增 §7「两条消费链路」，明确
  A（设备插件 `hlvm.io/disk` 按块直通裸设备）与 B（TopoLVM CSI 按 VG 剩余 GiB 供给 PVC）
  **并存不互斥**，且 **B 链路尚未部署、当前不提供 PVC 供给**（M15 的 `topolvm-${LOCK_TIER}`
  是验证 mutating webhook 的假 SC，PVC 不绑定）；② §1 把「每 worker 2 块」从硬性要求改为
  **device plugin 模式的推荐配置**，补上 `verify-topology-scale` 第 6 步「部分占用」判据与
  降配到 1 块时的诚实边界，并说明「系统盘 / 分区 / loop 文件不可用」是
  「自动发现 + 自动 `wipefs`/`pvcreate`」的安全边界；③ §2 把 `virtio` 由硬性前置改为
  「最常见驱动类型」，硬性条件改为存在 `/dev/disk/by-id` 条目，补云盘默认裸状态、
  「不要初始化 / 勾选自动挂载」与 `common::by_id_alias_rank` 前缀优先级；④ §6 的 by-id
  描述由「取目录第一项」更正为已实现的择优规则（真机首跑目的改为验证择优在真实 udev
  多别名下稳定）。§4 检查点不再限定 `grep virtio`，并补「无自动挂载」断言；拓扑表数据盘
  由 `2 × 100 GiB（virtio 云盘）` 改为 `2 × 20~50 GiB 裸数据盘`。
- **登记架构风险**：设计文档把「规划中的 TopoLVM 底座」写成既成事实、把两条链路写成一层，
  已导致外部评审误判为「底层已是标准 TopoLVM，配置切换即可走容量模式」。
  让容量调度成为生产主路径是方向，但需独立里程碑（上游部署 / device-class 映射 /
  容量上报 / `LogicalVolume` 对账 / 与 agent 共享 LVM 锁），不是配置优化。
  **本轮不改代码**：不删设备插件、不把真机降配到 1 块盘、不按「直接走标准 TopoLVM」重构；
  `v0.1.0-preview.2` 的发布说明已写明「禁止生产使用」，**但未单列 CSI 缺口**——该缺口由
  `real-cluster/README.md` §7 与本节补充说明，已发布 tag 对应的发布说明不追溯改写，
  下一个版本发布时应纳入「未验证清单」。
- **同轮复核更正**：上一节把 `lvmd-config-ctrl` 列为「完全不存在」不准确。
  `control-plane/internal/controller/lvmd_config_controller.go` 已由 NodeVG 渲染一节点一份
  `hlmd-lvmd-<node>` ConfigMap 的 `lvmd.yaml`，`lvmd_config.go` 已实现 device-class ↔ VG /
  thin-pool / 超分比映射，M15 `verify-lvmd` 已验收聚合、排序、自愈、GC 语义；缺的是
  **消费侧**（无任何 lvmd 进程挂载该 ConfigMap）与上游 CSI 部署。`lv_model.go` 的
  `LVReporter` 默认 nil，三方对账的 lvs 一侧跳过，且没有读 TopoLVM `LogicalVolume` CR
  的客户端。README §7 表格与措辞已同步更正。
- **独立立项（仅方案，不含实现）**：新增
  `openspec/changes/add-topolvm-csi-supply/{proposal,tasks}.md`，按设计 §1 / §2.1 /
  §5.3 / §12 / §13 定义阶段 0 决策门（7 项 `【待核实】`）、阶段 1 上游 CSI 部署、
  阶段 2 接线与观测、阶段 3 hlvm × hnb 端到端；核对 hnb 已验证基线后明确
  **容量调度走 `CSIStorageCapacity`（`scheduler.enabled=false`），不引入
  `topolvm-scheduler` extender 或 `capacity.topolvm.io/*` 注解**（后者在 hnb 全仓 0 命中，
  外部评审的该假设不成立）。硬门禁：真机 agent 与 lvmd 同机写同一 VG 前必须完成
  `chroot /host` + `/run/lock/lvm` 共享锁实测。所有任务保持 `[ ]`，实施须另行批准。

### 集成验证 / 修复

- 修 `scripts/m15-joint.sh` 互斥锁：原 `exec 9> /mnt/e/.../.joint.lock` 的 fd 会被子进程继承，
  `verify-cert-rotation` 遗留的 `kubectl port-forward` 孤儿进程在脚本退出后仍持锁，导致
  hnb 相位误报「另一个实例正在运行」；9p 挂载上的 flock 也不可靠。改为
  `flock -n -o "$HOME/.hlvm-joint.lock" bash <script>` 命令模式（子进程不继承 fd、锁在 ext4），
  外层保留以明确报错；新增 `HLVM_JOINT_LOCK_FILE` 可配置
- 完成首轮 hlvm × hnb 错峰验收：hlvm `m15 all` exit 0（单节点，Velero 按环境 SKIP）+
  内置收尾断言 PASS，随后 hnb 相位 17 个 Deployment 全部 Available、exit 0；轻量联调探针
  验证 5 个 CRD 单版本 v1beta1 / 外部标准客户端可发现 NodeDisk / hnb 侧无命名冲突 /
  hnb 节点容器内访问 hlvm API 返回 200。证据在 `joint-logs/`（已忽略），
  结论边界见 runbook §10.19
- 修 `scripts/m15-joint.sh` 基线快照的跨侧 git 误判：Windows git 设 `core.autocrlf=true`
  而 WSL git 未设时，同一 `/mnt/e` 工作树在 WSL 会把 8 个文件的行尾差异报成改动；
  改用 `--ignore-space-at-eol` 判真实改动，并对真实未提交改动直接 FAIL（结论须对应 HEAD）
- 新增 `scripts/m15-joint.sh`：hlvm × hnb 联合测试的错峰编排（`flock` 互斥、环境基线快照、
  hlvm 收尾断言、hnb 相位显式配置或显式 SKIP、分文件日志），把「两套测试不能并行」
  固化为机制而不是靠人记；runbook 新增 §10.19 记录产品分层、冲突面与环境实测
- 修正 runbook 章节编号重复：Go / Rust 依赖代差一节由 §10.17 改为 §10.18（by-id 一节保留 §10.17）
- `verify-conversion` / `verify-cert-rotation` / `verify-storage-migration` 现在统一 apply
  `03b~03f` 五份双版本清单，并在收尾恢复 **5 份** `bases` 单版本 CRD（此前只 apply/恢复 `03b`，
  另外 4 个 Kind 的 conversion 链路从未在集群里验证过）
- `verify-conversion` 新增 4 个 Kind 的双向转换往返 + 列表转换断言，以及 5 个 CRD 的
  `conversion.strategy` / caBundle 接线断言；NodeDisk 原有 12 条结构映射深度断言保持不变
- `verify-cert-rotation` / `verify-storage-migration` 各补一轮 4 Kind 的 conversion smoke
  （v1alpha1 写 → v1beta1 读回，前置先等齐 5 个 CRD 的 caBundle），并在两个相位的清理路径
  按 label 兜底删探针对象；避免「只验 NodeDisk 就宣布 5 份清单全绿」
- 修复 delete-protector 准入规则仍监听 `v1alpha1` DELETE 的问题：消费者已全迁 v1beta1、
  裸资源名解析到 v1beta1，旧规则会让 `NodeVG` / `StorageNodeOps` 的删除保护被静默绕过。
  **已知边界**：规则只列 `v1beta1`；双版本叠加期间老客户端显式用 `v1alpha1` 发起 DELETE
  不受保护——解码侧 `nodeNameOf` 只识别 v1beta1 类型，把 v1alpha1 列进规则反而会静默跳过

## [0.1.0-preview.2] - 2026-11-10

第二个技术预览版：把 `main` 上自 preview.1 以来的 7 个提交收敛为**可复现的显式版本标签**，
重点是 CRD 版本化覆盖与集成脚手架的可信度。**仍未在真实 LV 硬件与生产集群验证，禁止用于生产。**
定位与完整风险清单见 `docs/release-notes/v0.1.0-preview.2.md`。

### 新增 / 变更

**CRD 版本化（5 个 Kind 全部双版本）**
- `NodeVG` 升级为 v1beta1(storage) + v1alpha1(served)，补 hub/spoke 双向转换与往返测试
- `StorageTask` / `StorageNodeOps` / `ThinPoolPolicy` 同样双版本化；新增 `03d/03e/03f` 三份
  hardening 叠加清单（必须在 conversion webhook 就绪后 apply）
- 全部 Go 消费者（控制器 / webhook / dashboard）与 Rust agent 迁到 **v1beta1**，
  conversion 不再位于控制面关键路径；`AddToScheme` 仍双版本注册
- `crd-conversion` 启动自检覆盖全部 5 个双版本 Kind；新增 9 个 conversion 往返测试

**集成脚手架可信度**
- 新增 `preflight` 相位：ssh 可达性 / 私有镜像凭据 / 云盘 / udev / 造盘钩子的只读体检；
  **结构性缺失判 FAIL、能力缺失只 WARN**；`real` 模式 `IMG_TAG=latest` 判 FAIL
- 新增单节点模式 `M15_SINGLE_NODE=1`（显式开关，禁止因「少一台机器」静默降级）；
  修 `all` 在全新集群上 `check → preflight → bootstrap` 必挂的顺序缺陷
- `verify-topology-scale` 跨节点拓扑 / 容量账；修正 8 类脚手架静默失败（见 runbook §10.12）
- **修复版本化遗留的集成回归**：7 处普通相位仍以 `v1alpha1` 创建 `NodeVG` / `StorageTask`、
  1 处 `ownerReference.apiVersion` 断言仍期望 `v1alpha1`；在 `bases` 单版本 v1beta1 下会让
  `all` 在 `verify-admission` 直接失败（conversion 相位里刻意使用 v1alpha1 的断言保持不变）

**Agent 与调度**
- `/dev/disk/by-id` 多别名按前缀优先级择优（`virtio- > scsi- > nvme- > wwn- > ata-`），
  消除同一块盘两次枚举得到不同设备 ID 导致的身份漂移
- 控制面三组件改用 `topologySpreadConstraints` 软约束；PDB 改为 `maxUnavailable: 1`，
  随副本数缩放，避免 R=2 时 `minAvailable: 2` 让 `kubectl drain` 永久阻塞

### 已知限制（相对 preview.1 的变化）

- preview.1「已知限制」第 3 条「4 个 Kind 仍为 v1alpha1」**本版已消除**；其余各条仍未闭合
- 5 个 Kind 的 v1alpha1 兼容层与 conversion webhook **仅在 NodeDisk 上做过集群验收**：
  集成脚本的 `verify-conversion` 只 apply `03b`，`03c~03f` 尚未被任何相位消费
- Go 侧 K8s 客户端版本错配：`api`/`apimachinery` v0.33.0 但 `client-go`/
  `apiextensions-apiserver` v0.32.1；Rust 侧 `k8s-openapi 0.28 / v1_36`；实测集群 1.36

### 升级注意

- 从 preview.1 升级时，先确认 `config/hardening/03-crd-conversion.yaml` 的 webhook 就绪，
  再 apply `03b~03f`；顺序反了会出现「CRD 要求转换、webhook 还不存在」的不可用窗口
- 消费者已全迁 v1beta1；显式使用 v1alpha1 的老客户端现在依赖 conversion webhook 的可用性
- 镜像请使用显式版本标签 `ghcr.io/f31/hlvm/<component>:v0.1.0-preview.2`，不要引用 `:latest`

## [0.1.0-preview.1] - 2026-11-02

首个技术预览版：控制面 + 节点 Agent 的可部署形态已经闭环，可在 kind 1.36 上完整复现，
**未在真实 LV 硬件与生产集群验证**。定位与限制见 `docs/release-notes/v0.1.0-preview.1.md`。

### 新增

**CRD 与控制面**
- 5 个 CRD：`NodeDisk` / `NodeVG` / `StorageTask` / `StorageNodeOps` / `ThinPoolPolicy`
- 磁盘/VG 控制器对账：纳管状态机、Stale 条件、删盘保护（pendingOps）、孤儿 GC
- `NodeDisk` 收敛到 **v1beta1 存储版本**；v1alpha1 作为 served 版本经 conversion webhook 转换
- 容量治理：data% ≥85 或 metadata% ≥75 → `Locked` + 节点 `<tier>-locked=true` 标签，降压滞回自动解锁
- 生命周期运维：Node NotReady 超阈值自动创建 `auto-isolate-<node>`（isolate）+ Stale=True
- 只读大盘（`GET /`）与纳管入口（`POST /api/v1/adopt`，仅 Candidate、双确认、生成待审批 StorageTask）
- 准入控制：VAP 静态层（K8s 1.34+ 修正 `validationActions` 与 CEL null 防御）+ mutating webhook 动态层
- StorageTask 执行窗口 `spec.ttl`；归属交 K8s GC；lvmd ConfigMap 按节点聚合渲染

**节点 Agent（Rust，单二进制）**
- 4 种模式：`agent` / `exporter` / `device-plugin` / `doctor`
- 磁盘发现、SMART/NVMe 健康、预检规则引擎、LVM 写路径（唯一写者）、低频状态写回
- 读写分离部署：exporter 独立非特权 DaemonSet；每盘一个 collector Pod 承担 SMART 采集
- **device plugin**：按盘暴露 `hlvm.io/disk`，非特权 Pod 可按盘授权（kubelet 重启后自愈重注册）
- 版本可追溯：启动日志打印 Cargo 版本与构建提交号

**可观测性**
- Prometheus 指标（容量/告警/心跳）+ 告警评估；指标口径与阈值见 `openspec/specs/observability`
- CRD conversion / 证书轮换 / storedVersions 切换与回滚的演练脚本

**交付与验证**
- 集成脚手架 `scripts/m15-integration.sh`：23 个相位、约 120 条断言，覆盖 bootstrap → 构建 →
  准入 → 控制器 → agent → 热插拔 → 拓扑容量账 → 备份
- `scripts/real-cluster/`：真实集群（kubeadm + 云主机）部署脚本与只读云盘预检
- 适配层 `M15_TARGET=kind|real`：节点执行、镜像加载、设备注入、测试节点选择等 7 个抽象
- CI：Go（build/vet/test/envtest）、Rust（test/release build）、4 个容器镜像、tag 发布流水线

### 已知限制

- 真实 LV / thinpool / `/dev/disk/by-id`（udev）路径**未验证**；kind 无 udev，只覆盖 `dev-<name>` 回退分支
- Velero 灾备闭环**未验证**（本地 kind 无法拉取所需镜像，相位 SKIP）
- `NodeVG` / `StorageTask` / `StorageNodeOps` / `ThinPoolPolicy` 仍为 **v1alpha1**，尚未版本化
- 节点扩缩容与调度器重平衡（原 6.5b-2）未验证
- 灰度放量与上线评审门禁未执行（hardening 5.2/5.3、poc V.1-b）

### 升级注意

首个版本，无升级路径。镜像请使用显式版本标签（`ghcr.io/f31/hlvm/<component>:v0.1.0-preview.1`），
不要在生产链路上引用 `:latest`。
