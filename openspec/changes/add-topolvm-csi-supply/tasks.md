# Tasks: add-topolvm-csi-supply

> 全部任务为**待实施**（`[ ]`）。阶段 0 未签核前不得开始阶段 1；
> 每个里程碑 = 一次 commit + push + 全量验证（Go build/vet/test、Rust test/fmt、m15 相位）。

## 0. 决策门与前置核实（不写代码）

- [ ] 0.1 核实 chart 17.3.0 / TopoLVM 0.42.0 的 `lvmd.managed=true` 能否从
      `hlmd-lvmd-<node>` ConfigMap 读 `lvmd.yaml`，以及配置变更是热加载还是需滚动重启
      （设计 §2.1 `【待核实】`）
- [ ] 0.2 核实 `topolvm.io/device-class` 渲染后落在 SC `parameters`，与
      `config/webhook/validatingadmissionpolicy.yaml` 的 CEL 一致
- [ ] 0.3 核实 TopoLVM 0.42.0 `LogicalVolume` CR 的 group/version/字段、
      `CSIStorageCapacity` 在 K8s 1.36 的行为、`WaitForFirstConsumer` 与
      webhook locked nodeAffinity 是否冲突
- [ ] 0.4 **LVM 并发门禁**：复用 `docs/poc/scripts/concurrency-lvmd-test.sh`，
      实测 `nsenter/chroot /host` + `/run/lock/lvm` 共享锁下 agent 与 lvmd 并发操作同一 VG
      （设计 §5.3、§12）；未通过则禁止真机阶段
- [ ] 0.5 核实上游镜像可达性与 digest 固定策略、GHCR 私有凭据、real 模式 `IMG_TAG` 纪律
- [ ] 0.6 核对 `config/backup/03-drill-job.yaml` 的 `topolvm-provisioner` 与
      `00-velero-install.yaml` 的 `config.driver: topolvm.io`，确定真实 SC 名对齐方案
- [ ] 0.7 书面决策两项并写入 runbook：① lvmd 形态（跟随 hnb `lvmdEmbedded + values`
      vs 设计 §2.1 的 ConfigMap 下发）；② thinpool 取舍（阶段 1 跟随 hnb thick，
      hlvm thinpool 治理留阶段 3）
- [ ] 0.8 **验证**：7 项核实记录逐条可复现（命令 + 输出 + 结论），立项评审签核；
      任一 `【待核实】` 未闭环则本 change 保持 blocked，不进入阶段 1

## 1. 上游 CSI 部署相位（kind 优先）

- [ ] 1.1 新增 `control-plane/config/csi/` 入口：固定 chart 版本 17.3.0 / app 0.42.0
      与镜像 digest，记录 `helm template --include-crds` 的渲染方式（仓库不 vendor chart）
- [ ] 1.2 `scripts/m15-integration.sh` 新增 `bootstrap-csi`，纳入 `all` 链的
      `bootstrap` 之后、`verify-admission` 之前；real 模式跳过镜像装载、只做部署
- [ ] 1.3 真实 StorageClass：provisioner `topolvm.io`、`WaitForFirstConsumer`、
      `allowVolumeExpansion=true`、`topolvm.io/device-class`，与 hlvm VAP 一致
- [ ] 1.4 kind 侧用 loop 设备预建 VG（复刻 hnb `prepare-loop-storage.sh` 口径），
      real 侧用未格式化裸数据盘，明确两者拓扑差异不得混用
- [ ] 1.5 移除/替换 M15 里的假 SC `topolvm-${LOCK_TIER}`，或显式标注其仅用于
      webhook 单测，避免相位之间互相误判
- [ ] 1.6 **验证**：`CSIDriver` / `LogicalVolume` CRD / controller / node 就绪断言；
      `bash -n` + 单相位 `bootstrap-csi` exit 0 + 收尾不残留临时对象

## 2. 供给链路验收（`verify-csi-supply`）

- [ ] 2.1 新增 `verify-csi-supply` 并接入 `all`：PVC 1Gi → **Bound**（不以 Deployment
      Available 或 SC 存在代替），Pod 内读写 marker
- [ ] 2.2 在线扩容 1Gi→4Gi：`FileSystemResizeSuccessful`、**不重建 Pod**、marker 保留
- [ ] 2.3 Pod 重建 / 节点重启后同一 PVC 挂载与数据保留（对齐 hnb S2/S3 报告口径）
- [ ] 2.4 **数据面独立**：hlvm 控制面 Deployment 缩到 0 后，已挂载卷 IO 不受影响
      （设计 §1 底线，M15 现有相位未覆盖）
- [ ] 2.5 破坏性路径：VG 变更必须 `confirmSerial` + `dryRun` + 人工审批；
      断言「未审批时 StorageTask 不产生 wipe/pvcreate」与「dryRun 不落盘」
- [ ] 2.6 **验证**：单相位 exit 0、无 FAIL / `[error]`、收尾汇总行；
      断言「PVC Bound」与「扩容不重建 Pod」不得被 SKIP 吞掉；相位结束后
      CRD / SC / 命名空间状态与 `m15-joint.sh` 收尾断言一致

## 3. 宿主机 LVM 入口与单写者（真机前必须完成）

- [ ] 3.1 `agent/src/lvm/mod.rs` 把 `Command::new("lvm")` 改为经
      `HLVM_HOST_WRAPPER`（`nsenter -t 1 -m -- chroot /host`）调用宿主机 lvm，
      `--reportformat json` 解析失败一律视为「未知」
- [ ] 3.2 与 lvmd 共享 `/run/lock/lvm` 锁目录、统一 `lvm.conf devices {}` /
      devices file 限定只扫描纳管盘（设计 §5.3）
- [ ] 3.3 明确单写者分层并加防回归：LV 级只由 lvmd 写、PV/VG/thinpool 级只由
      agent executor 写；agent 不得 `lvcreate`（现有 executor 已无该动作，需断言保持）
- [ ] 3.4 破坏性操作（wipe / vgreduce / LV 删除 / 数据迁移）保留人工确认链路：
      断言 `confirmSerial`、`approvedBy`、`dryRun` 三个字段在真机相位均被校验
- [ ] 3.5 **验证**：`cargo test --all-targets` + `cargo fmt --check`；
      0.4 的并发脚本在真机重跑；`go vet ./... && go test ./... -count=1`

## 4. 接线与观测

- [ ] 4.1 按 0.7 决策把 `hlmd-lvmd-<node>` ConfigMap 接到真实 lvmd；若走 values 渲染，
      需说明 `LvmdConfigReconciler` 的定位（保留为审计/预检，或停用并防双写）
- [ ] 4.2 注册 TopoLVM `LogicalVolume` 到 scheme + 补 RBAC，实现 `LVReporter`
      （激活 `lv_model.go` 目前默认 nil 的 lvs 一侧）
- [ ] 4.3 `LogicalVolume` CR / PV / 节点实际 LV 三方对账；人工 `lvcreate` 触发 drift 告警
- [ ] 4.4 `CSIStorageCapacity` 观测与 `NodeVG.status.freeBytes` 对账，
      口径冲突时以实测 `lvs/vgs` 为准（设计 §2.1）
- [ ] 4.5 **验证**：新增对账单测 + envtest（若可用）+ `verify-csi-supply` 扩展断言；
      全量 `go vet ./... && go test ./... -count=1`、CI 绿

## 5. 端到端联调与治理（阶段 1/2 全绿后）

- [ ] 5.1 经 `scripts/m15-joint.sh` 错峰跑 hlvm `all` + hnb 相位，禁止并行；
      hnb 用 hlvm 的真实 SC 交付带 PVC 应用（补齐 `hnbctl cluster import` 所需的
      HTTPS platform-url / token / kubeconfig credential / agent enrollment）
- [ ] 5.2 thinpool / `ThinPoolPolicy` / dmeventd autoextend 按 0.7 决策接线
- [ ] 5.3 Velero 快照闭环：SC 名对齐后重跑 `verify-velero`，不得再以「SKIP」当绿
- [ ] 5.4 M17 真机端到端：真实 VG/thinpool、`/dev/disk/by-id` 多别名、节点扩缩容
      （依赖用户提供云主机与凭据，见 `scripts/real-cluster/README.md`）
- [ ] 5.5 **验证**：分文件日志 + 收尾断言 + 两侧 commit 锁定；
      诚实登记「哪些相位仍 SKIP」与「kind 结论不可外推到真机」

## 6. 文档、发布与回归

- [ ] 6.1 runbook 新增相位章节，更新 §10.13 真机前置、§10.19 错峰编排、
      §10.2/§10.3 相位清单引用
- [ ] 6.2 `scripts/real-cluster/README.md` §7 在阶段 1 落地后把「B 链路未部署」
      改为「已部署，验收边界见 verify-csi-supply」
- [ ] 6.3 下一版发布说明把「CSI 供给链路」纳入未验证清单或已验证项
      （不追溯改写 `v0.1.0-preview.2` 的发布说明）
- [ ] 6.4 **验证回路**：`go build ./... && go vet ./... && go test ./... -count=1`、
      `cargo test --all-targets && cargo fmt --check`、`bash -n` 全部脚本、
      kind 单节点 `m15 all` exit 0 + 收尾断言 PASS、push 后 CI 全绿；
      每个里程碑一次 commit + push，不夹带无关改动
