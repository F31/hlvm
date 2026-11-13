// Package metrics 定义并注册 hlvm 控制面与 webhook 暴露的 Prometheus 指标（设计 §5.4 "控制面与 webhook 另有..."）。
//
// 平台存储指标（storage_*，§5.4 全表）分两类落点：
//   - disk / SMART 类由 storage-exporter（agent --mode=exporter）暴露；
//   - thin-pool 容量类（MetricThinPool*）**由本包在控制面暴露**：读 `data_percent` 需要
//     `lvs` 做 dm ioctl（root + CAP_SYS_ADMIN），而设备 cgroup 使非特权 Pod 拿不到 /dev，
//     exporter 因此采不到（ADR-006 §23.11 有实测）。数据链是
//     Agent 读宿主 lvs → `NodeVG.status.thinPool` → VGReconciler 同步到本包。
//
// 其余指标仅导出规范名常量（Metric*），作为告警规则与仪表盘引用的单一真相源，避免双口径。
//
// 指标注册到 controller-runtime 的 metrics.Registry，随 manager 的 /metrics 端点一并暴露。
package metrics

import (
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	crmetrics "sigs.k8s.io/controller-runtime/pkg/metrics"
)

// 控制器名（reconcile 错误/耗时指标的 controller 标签取值）。
const (
	ControllerCapacity   = "capacity"
	ControllerLvmdConfig = "lvmd-config"
	ControllerNodeOps    = "nodeops"
	ControllerOrphanGC   = "orphan-gc"
	ControllerDrift      = "drift"
	ControllerDisk       = "disk"
	// ControllerDiskCollector 为每个 NodeDisk 维护只采该盘 SMART 的 collector Pod。
	ControllerDiskCollector = "disk-collector"
	ControllerStorageTask   = "storage-task"
	ControllerVG            = "vg"
	ControllerBackup        = "backup"
	ControllerDrill         = "drill"
)

// webhook 名（准入/变更指标的 webhook 标签取值）。
const (
	WebhookPVCValidator    = "pvc-validator"
	WebhookPodMutator      = "pod-mutator"
	WebhookDeleteProtector = "delete-protector"
)

var (
	// ReconcileErrors 按控制器统计 reconcile 错误计数（设计 §5.4 "reconcile 错误数"）。
	ReconcileErrors = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "storage_controller_reconcile_errors_total",
		Help: "控制面 reconcile 错误计数（按 controller）",
	}, []string{"controller"})

	// ReconcileDuration 按控制器统计 reconcile 耗时（秒）。
	ReconcileDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "storage_controller_reconcile_duration_seconds",
		Help:    "控制面 reconcile 耗时（秒）",
		Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	}, []string{"controller"})

	// AdmissionDuration 按 webhook 统计准入/变更处理耗时（秒）。
	AdmissionDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "storage_webhook_admission_duration_seconds",
		Help:    "webhook 准入/变更处理耗时（秒）",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1},
	}, []string{"webhook"})

	// AdmissionsTotal 按 webhook + result（allowed/denied）统计处理总数。
	AdmissionsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "storage_webhook_admissions_total",
		Help: "webhook 准入/变更处理总数（按 webhook + result）",
	}, []string{"webhook", "result"})

	// RejectionsTotal 按 webhook + reason 统计拒绝计数；reason 脱敏，不含 tier 等内部信息（见 M9 SanitizedDenyMessage）。
	RejectionsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "storage_webhook_rejections_total",
		Help: "webhook 拒绝计数（按 webhook + reason）；reason 脱敏，不含内部信息",
	}, []string{"webhook", "reason"})

	// BackupLastSuccessTimestampSeconds 按 pvc+namespace 记录最近一次成功备份的时间戳（秒，Unix）。
	// 缺失标签即"从未成功备份"，配合 storage_backup_rpo_overdue 判定 RPO 达标。
	BackupLastSuccessTimestampSeconds = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "storage_backup_last_success_timestamp_seconds",
		Help: "最近一次成功备份的时间戳（秒）；缺失即从未成功备份",
	}, []string{"namespace", "pvc"})

	// BackupTotal 按 result（success/failed）统计备份次数（设计 §7 / add-backup-restore 4.1）。
	BackupTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "storage_backup_total",
		Help: "备份次数（按 result: success/failed）",
	}, []string{"result"})

	// BackupDurationSeconds 按 backup 记录单次备份耗时（秒，CompletionTime-StartTime）。
	BackupDurationSeconds = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "storage_backup_duration_seconds",
		Help:    "单次备份耗时（秒）",
		Buckets: []float64{10, 30, 60, 300, 900, 1800, 3600, 7200},
	}, []string{"backup"})

	// BackupRPOOverdue 按 pvc+namespace 标记 RPO 是否逾期（1=逾期，0=达标）；驱动 RPO 超限告警（设计 §7 / 4.2）。
	BackupRPOOverdue = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "storage_backup_rpo_overdue",
		Help: "RPO 是否逾期（1=逾期，0=达标）；按 pvc+namespace",
	}, []string{"namespace", "pvc"})

	// BackupDrillLastSuccessTimestampSeconds 记录最近一次通过（数据校验通过且 RTO/RPO 达标）恢复演练的时间戳（秒）。
	// 缺失或陈旧即"未被验证过的备份"，驱动发布门禁（设计 §7 / 3.1-3.3）。
	BackupDrillLastSuccessTimestampSeconds = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "storage_backup_drill_last_success_timestamp_seconds",
		Help: "最近一次通过的恢复演练时间戳（秒）；缺失或陈旧即未被验证",
	})

	// LVReportTimestampSeconds 按 node+vg 记录 Agent 最近一次 LV 上报的时间戳（秒，Unix）。
	//
	// 刻意用**时间戳**而不是「滞后秒数」：控制面只在 NodeVG/PV 变化时对账，Agent 挂掉后
	// 不再有触发，若暴露滞后秒数该值会冻结在挂掉前的瞬间，告警永远不响（静默停摆）。
	// 时间戳配合 `time() - ts > 180` 才能在无任何事件时暴露停摆（ADR-006 §17）。
	LVReportTimestampSeconds = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricLVReportTimestampSeconds,
		Help: "Agent 最近一次 LV 上报的时间戳（秒，Unix）；配合 time() 判定上报是否停摆",
	}, []string{"node", "vg"})

	// LVReportPresent 标记某 node+vg 是否有过 LV 上报（1=有，0=Agent 从未上报）。
	// 与时间戳分开是因为 Unix 0 无法区分「从未上报」与「上报时间异常」。
	LVReportPresent = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricLVReportPresent,
		Help: "是否存在 LV 上报（1=有，0=Agent 从未上报过）",
	}, []string{"node", "vg"})

	// DriftReconcileSkippedTotal 按 reason 统计「放弃三方对账」的轮次。
	// 非零即代表对账覆盖有洞：必须告警，不能只留在 Info 日志里（ADR-006 §17）。
	DriftReconcileSkippedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: MetricDriftReconcileSkippedTotal,
		Help: "放弃三方对账的轮次（按 reason：no_reporter/report_missing/report_stale/no_nodevg/list_failed/unknown）",
	}, []string{"reason"})

	// DriftItems 按 kind 记录当前一轮对账发现的漂移条目数。
	// 跳过轮次刻意不清零：宁可保留上次结论，也不把真实告警清成 0（ADR-006 §17）。
	DriftItems = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricDriftItems,
		Help: "当前一轮三方对账发现的漂移条目数（按 kind；跳过轮次保留上次结论）",
	}, []string{"kind"})

	// thin-pool 容量指标（ADR-006 §23.11）。数据源是 Agent 上报的 NodeVG.status.thinPool。
	//
	// **不经 storage-exporter**：读 thin-pool 的 data/metadata 百分比需要 `lvs` 打开
	// /dev/mapper/control 做 dm ioctl；真机实测非 root 直接 Permission denied，而 root
	// 缺少 CAP_SYS_ADMIN 时 `lvs` **仍退出 0**、百分比列返回空串（假绿陷阱）。
	// 设备 cgroup 又使非特权 Pod 拿不到 /dev 访问（见 agent DS securityContext 注释），
	// 而「用设备插件替代 privileged exporter」是既定决策（disk_collector_test.go），
	// 因此沿用「Agent 采集 → NodeVG.status → 控制面暴露」这条链。
	ThinPoolDataPercent = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricThinPoolDataPercent,
		Help: "thin-pool 数据区使用率（百分比，Agent 实测）",
	}, thinPoolLabels)

	ThinPoolMetadataPercent = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricThinPoolMetadataPercent,
		Help: "thin-pool 元数据区使用率（百分比，Agent 实测）",
	}, thinPoolLabels)

	ThinPoolOutOfSpace = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricThinPoolOutOfSpace,
		Help: "thin-pool 是否进入 out-of-data-space / needs_check / failed（1=是）",
	}, thinPoolLabels)

	ThinPoolProvisionedBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricThinPoolProvisionedBytes,
		Help: "thin-pool 上业务 thin LV 的虚拟容量之和（字节）",
	}, thinPoolLabels)

	ThinPoolOverprovisionRatio = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricThinPoolOverprovisionRatio,
		Help: "超分比例 = 已置备虚拟容量 / thin-pool 实际容量",
	}, thinPoolLabels)

	// ThinPoolCollectOK 是「本轮是否真的采到了池」的显式信号（ADR-006 §23.13）。
	//
	// 为什么必须有它：上面五个指标在采集失败时是**删除序列**而不是写 0（fail-closed，
	// 见 §23.11）。好处是不会把「采不到」伪装成「池很空」，代价是所有基于阈值的告警
	// 都变成「没有序列 ⇒ 不触发」——静默。`AgentHeartbeatLost` 兜不住这种情况：Agent
	// 进程还在、心跳照发，坏的只是 `lvs` 这一条读路径（权限被收、`/run/lvm` 变紧、
	// 池改名、LVM 卡在 dmeventd）。
	//
	// 所以需要一个「缺席也要能被看见」的序列。不用 `absent()` 的理由：Prometheus 不知道
	// 某个 NodeVG **本该**有池——`NodeVG.spec.thinPool` 是普通 struct（非指针，且
	// omitempty 对 struct 无效），没配池的 VG 同样会被 Agent 写成 `state: unreadable`，
	// 两者在指标侧无法区分。只有控制面同时握着 spec（该不该有池）与 status（采到没有），
	// 因此由它显式产出 0/1：**没有序列 = 该 VG 不涉及 thin-pool（不该告警）**，
	// **序列为 0 = 配了池但采不到（必须告警）**。
	ThinPoolCollectOK = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricThinPoolCollectOK,
		Help: "thin-pool 容量采集是否正常（1=采到，0=配了池但采集失败；无序列=该 VG 无 thin-pool）",
	}, thinPoolLabels)

	// VG 容量指标（ADR-006 §23.12）。数据源同样是 Agent 上报的 NodeVG.status
	// （`totalBytes` / `freeBytes`），理由与 thin-pool 一致：`vgs` 也走 dm/ioctl 与
	// /dev 访问，非特权 exporter 读不到，只能由宿主侧 Agent 采集。
	//
	// 这两个指标是 `capacity-ctrl` 与 `alert_eval` 的同一份事实的对外投影：
	// 兜底扩容上限 = thinPool.currentSizeBytes + freeBytes，空闲不足告警也读 freeBytes。
	// 在此之前 status 里这两个字段从未被写入（恒为 0），扩容上限因此永远等于池自身大小。
	VGTotalBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricVGTotalBytes,
		Help: "VG 总量（字节，Agent 实测）",
	}, vgCapacityLabels)

	VGFreeBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: MetricVGFreeBytes,
		Help: "VG 空闲量（字节，Agent 实测）；0 是合法的「VG 打满」，未知时不暴露序列",
	}, vgCapacityLabels)
)

// vgCapacityLabels 是 VG 容量指标的统一标签集（设计 §5.4）。
//
// 不含 `tier`：tier 是 spec 里的租户视角分组，同一 VG 改名换 tier 时不应让序列分叉；
// 需要按 tier 聚合时由 recording rule 关联 NodeVG 标签即可。
var vgCapacityLabels = []string{"node", "vg"}

// thinPoolLabels 是 thin-pool 容量指标的统一标签集。
// 告警 annotation 引用 $labels.node / $labels.vg，pool 用于区分同 VG 的多个池
// （当前 TopoLVM 一 VG 一池，但标签不能省略，否则将来多池会混成一条序列）。
var thinPoolLabels = []string{"node", "vg", "pool"}

func init() {
	crmetrics.Registry.MustRegister(
		ReconcileErrors,
		ReconcileDuration,
		AdmissionDuration,
		AdmissionsTotal,
		RejectionsTotal,
		BackupLastSuccessTimestampSeconds,
		BackupTotal,
		BackupDurationSeconds,
		BackupRPOOverdue,
		BackupDrillLastSuccessTimestampSeconds,
		LVReportTimestampSeconds,
		LVReportPresent,
		DriftReconcileSkippedTotal,
		DriftItems,
		ThinPoolDataPercent,
		ThinPoolMetadataPercent,
		ThinPoolOutOfSpace,
		ThinPoolProvisionedBytes,
		ThinPoolOverprovisionRatio,
		ThinPoolCollectOK,
		VGTotalBytes,
		VGFreeBytes,
	)
}

// ObserveReconcile 记录一次 reconcile 的耗时与错误（err != nil 时累加错误计数）。
// 在 Reconcile 入口以 defer 调用：defer func() { metrics.ObserveReconcile(ControllerX, start, err) }()。
func ObserveReconcile(controller string, start time.Time, err error) {
	ReconcileDuration.WithLabelValues(controller).Observe(time.Since(start).Seconds())
	if err != nil {
		ReconcileErrors.WithLabelValues(controller).Inc()
	}
}

// ObserveAdmission 记录一次 webhook 处理的耗时、总数与拒绝（denied 为 true 时累加拒绝计数与原因）。
// reason 仅允许脱敏取值（如 "tier-no-available-node"、"retire-in-flight-in-use-pv"），不得含 tier/PV 名等内部信息。
func ObserveAdmission(webhook string, start time.Time, denied bool, reason string) {
	AdmissionDuration.WithLabelValues(webhook).Observe(time.Since(start).Seconds())
	if denied {
		RejectionsTotal.WithLabelValues(webhook, reason).Inc()
		AdmissionsTotal.WithLabelValues(webhook, "denied").Inc()
	} else {
		AdmissionsTotal.WithLabelValues(webhook, "allowed").Inc()
	}
}

// ObserveBackup 记录一次备份的耗时、总数与最近成功时间戳（设计 §7 / add-backup-restore 4.1）。
// succeeded 为 true 时累加 success 计数并刷新 last-success 时间戳（按 namespace+pvc）；
// 失败累加 failed 计数。duration 为该次备份耗时（秒）。
func ObserveBackup(backup string, namespace, pvc string, duration time.Duration, succeeded bool) {
	BackupDurationSeconds.WithLabelValues(backup).Observe(duration.Seconds())
	if succeeded {
		BackupTotal.WithLabelValues("success").Inc()
		BackupLastSuccessTimestampSeconds.WithLabelValues(namespace, pvc).Set(float64(time.Now().Unix()))
	} else {
		BackupTotal.WithLabelValues("failed").Inc()
	}
}

// SetBackupRPOOverdue 标记某 pvc 的 RPO 是否逾期（overdue=true→1，否则 0），驱动 RPO 超限告警（设计 §7 / 4.2）。
func SetBackupRPOOverdue(namespace, pvc string, overdue bool) {
	v := 0.0
	if overdue {
		v = 1.0
	}
	BackupRPOOverdue.WithLabelValues(namespace, pvc).Set(v)
}

// SetBackupDrillLastSuccess 记录最近一次通过的恢复演练时间戳（秒），缺失/陈旧即"未被验证"（设计 §7 / 3.1-3.3）。
func SetBackupDrillLastSuccess(ts time.Time) {
	BackupDrillLastSuccessTimestampSeconds.Set(float64(ts.Unix()))
}

// LVReportFreshness 是一条 NodeVG 的 LV 上报新鲜度快照（ADR-006 §17）。
type LVReportFreshness struct {
	Node string
	VG   string
	// ReportedAt 为 nil 表示 Agent 从未上报过（present=0，不写时间戳）。
	ReportedAt *time.Time
}

var (
	lvFreshMu   sync.Mutex
	lvFreshSeen = map[[2]string]struct{}{}
)

// ReplaceLVReportFreshness 全量替换上报新鲜度序列。
//
// 必须全量替换而不是只 Set：NodeVG 被删后若继续 Set 别的 key，该节点的时间戳会永远
// 冻结在 /metrics 上，`time() - ts` 持续增长 → 永久误告警。这里对上一轮存在、本轮
// 消失的 (node,vg) 显式 Delete。
func ReplaceLVReportFreshness(items []LVReportFreshness) {
	lvFreshMu.Lock()
	defer lvFreshMu.Unlock()

	cur := make(map[[2]string]struct{}, len(items))
	for _, it := range items {
		key := [2]string{it.Node, it.VG}
		cur[key] = struct{}{}
		lvFreshSeen[key] = struct{}{}
		if it.ReportedAt == nil {
			LVReportPresent.WithLabelValues(it.Node, it.VG).Set(0)
			// 从未上报：必须删掉可能残留的时间戳，否则旧值会让停摆判据失效。
			LVReportTimestampSeconds.DeleteLabelValues(it.Node, it.VG)
			continue
		}
		LVReportPresent.WithLabelValues(it.Node, it.VG).Set(1)
		LVReportTimestampSeconds.WithLabelValues(it.Node, it.VG).Set(float64(it.ReportedAt.Unix()))
	}
	for key := range lvFreshSeen {
		if _, ok := cur[key]; ok {
			continue
		}
		LVReportPresent.DeleteLabelValues(key[0], key[1])
		LVReportTimestampSeconds.DeleteLabelValues(key[0], key[1])
		delete(lvFreshSeen, key)
	}
}

// IncDriftReconcileSkipped 记录一轮「放弃三方对账」（reason 取值见 DriftReconcileSkippedTotal）。
func IncDriftReconcileSkipped(reason string) {
	DriftReconcileSkippedTotal.WithLabelValues(reason).Inc()
}

var (
	driftItemsMu   sync.Mutex
	driftItemsSeen = map[string]struct{}{}
)

// ReplaceDriftItems 全量替换当前一轮的漂移条目计数（按 kind）。
//
// 消失的 kind 置 0 而非删除序列：`storage_controller_drift_items > 0` 这类按 kind 的
// 告警表达式在序列消失时会变成 no data（不是 0），容易被误当成「已恢复」。置 0 才是
// 明确的「本轮无此类漂移」。
func ReplaceDriftItems(byKind map[string]int) {
	driftItemsMu.Lock()
	defer driftItemsMu.Unlock()

	for kind, n := range byKind {
		driftItemsSeen[kind] = struct{}{}
		DriftItems.WithLabelValues(kind).Set(float64(n))
	}
	for kind := range driftItemsSeen {
		if _, ok := byKind[kind]; ok {
			continue
		}
		DriftItems.WithLabelValues(kind).Set(0)
	}
}

// ThinPoolSample 是一条 thin-pool 容量样本（ADR-006 §23.11）。
//
// 由 `NodeVG.status.thinPool`（Agent 独占写的字段）转成，字段与 Go 侧
// `VGThinPoolStatus` 一一对应。
type ThinPoolSample struct {
	Node, VG, Pool                     string
	DataPercent, MetadataPercent       float64
	OutOfSpace                         bool
	ProvisionedBytes, CurrentSizeBytes int64
}

var (
	thinPoolMu sync.Mutex
	// thinPoolSeen 记录已暴露的标签组合（VG → pool → labels），
	// 用于在 NodeVG 被删除时能反查出完整标签做 DeleteLabelValues。
	thinPoolSeen = map[string]map[string][3]string{}
	// thinPoolFailedSeen 记录「配了池但采不到」的标签组合，与 thinPoolSeen 分开维护：
	// 这一类只有 collect_ok 一条序列（数据序列已被删掉），混进 thinPoolSeen 会让
	// ForgetThinPool 以为数据序列还在，语义上也会把「失败」和「正常」混成一锅。
	thinPoolFailedSeen = map[string]map[string][3]string{}
)

// deleteThinPoolSeries 删除五个容量序列（不含 collect_ok）。
// labels 是 [node, vg, pool]，与 thinPoolLabels 顺序一致。
func deleteThinPoolSeries(labels [3]string) {
	ThinPoolDataPercent.DeleteLabelValues(labels[0], labels[1], labels[2])
	ThinPoolMetadataPercent.DeleteLabelValues(labels[0], labels[1], labels[2])
	ThinPoolOutOfSpace.DeleteLabelValues(labels[0], labels[1], labels[2])
	ThinPoolProvisionedBytes.DeleteLabelValues(labels[0], labels[1], labels[2])
	ThinPoolOverprovisionRatio.DeleteLabelValues(labels[0], labels[1], labels[2])
}

// pruneOtherPools 清掉某 NodeVG 名下除 keep 以外所有池的序列。
//
// 必要性：`NodeVG.spec.thinPool` 是单池（一个 NodeVG 只对应一个池名），所以同一时刻
// 该 VG 只该有一组 thin-pool 序列。池名被改（`spec.thinPool.name` 从 tp-old 改成
// tp-new）时，旧池名不会再有 Agent 上报，若不清扫就会永久留着「最后已知水位」——
// 看板上一个不存在的池显示 90%，而真池可能已经满了。
func pruneOtherPools(vg, keep string) {
	for p, labels := range thinPoolSeen[vg] {
		if p == keep {
			continue
		}
		deleteThinPoolSeries(labels)
		ThinPoolCollectOK.DeleteLabelValues(labels[0], labels[1], labels[2])
		delete(thinPoolSeen[vg], p)
	}
	if len(thinPoolSeen[vg]) == 0 {
		delete(thinPoolSeen, vg)
	}
	for p, labels := range thinPoolFailedSeen[vg] {
		if p == keep {
			continue
		}
		ThinPoolCollectOK.DeleteLabelValues(labels[0], labels[1], labels[2])
		delete(thinPoolFailedSeen[vg], p)
	}
	if len(thinPoolFailedSeen[vg]) == 0 {
		delete(thinPoolFailedSeen, vg)
	}
}

// SyncThinPool 幂等写入一条 thin-pool 容量序列，并把 collect_ok 置 1。
//
// 前提：调用方已确认该池可读（`state` 为 `ok`/`out-of-space`）。不可读时**必须**
// 走 MarkThinPoolCollectFailed：删掉容量序列（`storage_thinpool_data_percent >= 85`
// 在 0 上永远为假，会把「采不到」伪装成「池很空」），但留下 collect_ok=0 让告警能响。
func SyncThinPool(s ThinPoolSample) {
	if s.Node == "" || s.VG == "" || s.Pool == "" {
		return
	}
	thinPoolMu.Lock()
	defer thinPoolMu.Unlock()

	pruneOtherPools(s.VG, s.Pool)

	if thinPoolSeen[s.VG] == nil {
		thinPoolSeen[s.VG] = map[string][3]string{}
	}
	thinPoolSeen[s.VG][s.Pool] = [3]string{s.Node, s.VG, s.Pool}

	ThinPoolDataPercent.WithLabelValues(s.Node, s.VG, s.Pool).Set(s.DataPercent)
	ThinPoolMetadataPercent.WithLabelValues(s.Node, s.VG, s.Pool).Set(s.MetadataPercent)
	oob := 0.0
	if s.OutOfSpace {
		oob = 1.0
	}
	ThinPoolOutOfSpace.WithLabelValues(s.Node, s.VG, s.Pool).Set(oob)
	ThinPoolProvisionedBytes.WithLabelValues(s.Node, s.VG, s.Pool).Set(float64(s.ProvisionedBytes))
	ratio := 0.0
	if s.CurrentSizeBytes > 0 {
		ratio = float64(s.ProvisionedBytes) / float64(s.CurrentSizeBytes)
	}
	ThinPoolOverprovisionRatio.WithLabelValues(s.Node, s.VG, s.Pool).Set(ratio)

	// 恢复：本轮采到了，失败标记必须撤掉，否则 collect_ok 会一直停在 0。
	ThinPoolCollectOK.WithLabelValues(s.Node, s.VG, s.Pool).Set(1)
	if pools, ok := thinPoolFailedSeen[s.VG]; ok {
		delete(pools, s.Pool)
		if len(pools) == 0 {
			delete(thinPoolFailedSeen, s.VG)
		}
	}
}

// MarkThinPoolCollectFailed 记录「配了池但本轮采不到」（ADR-006 §23.13）。
//
// 与 ForgetThinPool 的区别是**保留一条 collect_ok=0**：删掉容量序列是对的
// （未知不能冒充数值），但如果什么都不留，基于这些序列的五条阈值告警会一起静默——
// 运维只能看到「很平静」，看不到「仪表坏了」。这条序列就是「仪表坏了」本身。
func MarkThinPoolCollectFailed(node, vg, pool string) {
	if node == "" || vg == "" || pool == "" {
		return
	}
	thinPoolMu.Lock()
	defer thinPoolMu.Unlock()

	labels := [3]string{node, vg, pool}
	pruneOtherPools(vg, pool)
	deleteThinPoolSeries(labels)
	ThinPoolCollectOK.WithLabelValues(node, vg, pool).Set(0)

	if thinPoolFailedSeen[vg] == nil {
		thinPoolFailedSeen[vg] = map[string][3]string{}
	}
	thinPoolFailedSeen[vg][pool] = labels
	// 数据序列已经删了，把它从「正常」表里摘掉，避免 ForgetThinPool 重复删除时
	// 与失败表产生两套记录（重复 DeleteLabelValues 本身无害，但两张表说法要一致）。
	if pools, ok := thinPoolSeen[vg]; ok {
		delete(pools, pool)
		if len(pools) == 0 {
			delete(thinPoolSeen, vg)
		}
	}
}

// ForgetThinPool 清理某 NodeVG 名下全部 thin-pool 序列（含 collect_ok）。
//
// 调用点：NodeVG 被删除、或该 NodeVG 的 spec 里根本没有池。后者必须**连 collect_ok
// 一起删**——不涉及 thin-pool 的 VG 一旦留下 collect_ok=0，会永久误报告警。
func ForgetThinPool(vg string) {
	thinPoolMu.Lock()
	defer thinPoolMu.Unlock()

	for _, seen := range []map[string]map[string][3]string{thinPoolSeen, thinPoolFailedSeen} {
		for pool, labels := range seen[vg] {
			deleteThinPoolSeries(labels)
			ThinPoolCollectOK.DeleteLabelValues(labels[0], labels[1], labels[2])
			delete(seen[vg], pool)
		}
		delete(seen, vg)
	}
}

var (
	vgCapacityMu sync.Mutex
	// vgCapacitySeen 记录已暴露的标签组合（VG → labels），用于 NodeVG 删除时反查。
	// 与 thinPoolSeen 分开维护：两者生命周期相同但标签集不同，混用会让 DeleteLabelValues
	// 拿到错误的标签个数（prometheus 不报错，序列静静残留）。
	vgCapacitySeen = map[string][2]string{}
)

// SyncVGCapacity 幂等写入某个 NodeVG 的 VG 容量序列（ADR-006 §23.12）。
//
// 前提：调用方已确认容量可读（`status.totalBytes > 0`）。读不到时**必须**走
// ForgetVGCapacity 删序列，绝不写 0：`storage_vg_free_bytes` 写 0 会被任何
// 「空闲不足」类表达式当成「VG 已满」，而 `storage_vg_total_bytes` 写 0 会让
// 使用率类表达式出现除零（+Inf/NaN），两种都比没有指标更难排查。
//
// 注意 `free == 0` 与「未知」语义不同：前者是真实的 VG 打满，必须原样写 0 并保留序列。
func SyncVGCapacity(node, vg string, total, free int64) {
	if node == "" || vg == "" {
		return
	}
	vgCapacityMu.Lock()
	defer vgCapacityMu.Unlock()

	vgCapacitySeen[vg] = [2]string{node, vg}
	VGTotalBytes.WithLabelValues(node, vg).Set(float64(total))
	VGFreeBytes.WithLabelValues(node, vg).Set(float64(free))
}

// ForgetVGCapacity 清理某 NodeVG 的容量序列。
//
// 两个调用点与 ForgetThinPool 完全对称：NodeVG 被删除、以及 Agent 上报的容量
// 不可读（字段被 null 清掉，等效于 totalBytes == 0）。
func ForgetVGCapacity(vg string) {
	vgCapacityMu.Lock()
	defer vgCapacityMu.Unlock()

	labels, ok := vgCapacitySeen[vg]
	if !ok {
		return
	}
	VGTotalBytes.DeleteLabelValues(labels[0], labels[1])
	VGFreeBytes.DeleteLabelValues(labels[0], labels[1])
	delete(vgCapacitySeen, vg)
}

// 平台存储指标规范名（设计 §5.4 全表）。告警规则与仪表盘统一引用本组常量，禁止自创命名。
const (
	MetricDiskSmartHealth            = "storage_disk_smart_health"
	MetricDiskSmartTemperature       = "storage_disk_smart_temperature_celsius"
	MetricDiskMediaErrorsTotal       = "storage_disk_media_errors_total"
	MetricDiskAvailableSparePercent  = "storage_disk_available_spare_percent"
	MetricDiskPercentUsed            = "storage_disk_percent_used"
	MetricVGTotalBytes               = "storage_vg_total_bytes"
	MetricVGFreeBytes                = "storage_vg_free_bytes"
	MetricThinPoolDataPercent        = "storage_thinpool_data_percent"
	MetricThinPoolMetadataPercent    = "storage_thinpool_metadata_percent"
	MetricThinPoolProvisionedBytes   = "storage_thinpool_provisioned_bytes"
	MetricThinPoolOverprovisionRatio = "storage_thinpool_overprovision_ratio"
	MetricThinPoolOutOfSpace         = "storage_thinpool_out_of_space"
	MetricThinPoolCollectOK          = "storage_thinpool_collect_ok"
	MetricRaidDegraded               = "storage_raid_degraded"
	MetricAgentLastScanTimestamp     = "storage_agent_last_scan_timestamp_seconds"
	MetricAgentTaskFailuresTotal     = "storage_agent_task_failures_total"
	MetricDriftDetected              = "storage_drift_detected"

	// 控制面三方对账指标规范名（ADR-006 §17）。alert-rules-drift.yaml 引用本组。
	MetricLVReportTimestampSeconds   = "storage_controller_lv_report_timestamp_seconds"
	MetricLVReportPresent            = "storage_controller_lv_report_present"
	MetricDriftReconcileSkippedTotal = "storage_controller_drift_reconcile_skipped_total"
	MetricDriftItems                 = "storage_controller_drift_items"
)
