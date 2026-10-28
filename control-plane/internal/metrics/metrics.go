// Package metrics 定义并注册 hlvm 控制面与 webhook 暴露的 Prometheus 指标（设计 §5.4 "控制面与 webhook 另有..."）。
//
// 平台存储指标（storage_*，§5.4 全表）由 storage-exporter（agent --mode=exporter）暴露，
// 本包仅导出其规范名常量（Metric*），作为告警规则与仪表盘引用的单一真相源，避免双口径。
//
// 指标注册到 controller-runtime 的 metrics.Registry，随 manager 的 /metrics 端点一并暴露。
package metrics

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
	crmetrics "sigs.k8s.io/controller-runtime/pkg/metrics"
)

// 控制器名（reconcile 错误/耗时指标的 controller 标签取值）。
const (
	ControllerCapacity    = "capacity"
	ControllerLvmdConfig  = "lvmd-config"
	ControllerNodeOps     = "nodeops"
	ControllerOrphanGC    = "orphan-gc"
	ControllerDrift       = "drift"
	ControllerDisk        = "disk"
	ControllerStorageTask = "storage-task"
	ControllerVG          = "vg"
	ControllerBackup      = "backup"
	ControllerDrill       = "drill"
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
)

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

// 平台存储指标规范名（设计 §5.4 全表）。告警规则与仪表盘统一引用本组常量，禁止自创命名。
const (
	MetricDiskSmartHealth           = "storage_disk_smart_health"
	MetricDiskSmartTemperature      = "storage_disk_smart_temperature_celsius"
	MetricDiskMediaErrorsTotal      = "storage_disk_media_errors_total"
	MetricDiskAvailableSparePercent = "storage_disk_available_spare_percent"
	MetricDiskPercentUsed           = "storage_disk_percent_used"
	MetricVGTotalBytes              = "storage_vg_total_bytes"
	MetricVGFreeBytes               = "storage_vg_free_bytes"
	MetricThinPoolDataPercent       = "storage_thinpool_data_percent"
	MetricThinPoolMetadataPercent   = "storage_thinpool_metadata_percent"
	MetricThinPoolProvisionedBytes  = "storage_thinpool_provisioned_bytes"
	MetricThinPoolOverprovisionRatio = "storage_thinpool_overprovision_ratio"
	MetricThinPoolOutOfSpace        = "storage_thinpool_out_of_space"
	MetricRaidDegraded              = "storage_raid_degraded"
	MetricAgentLastScanTimestamp    = "storage_agent_last_scan_timestamp_seconds"
	MetricAgentTaskFailuresTotal    = "storage_agent_task_failures_total"
	MetricDriftDetected             = "storage_drift_detected"
)
