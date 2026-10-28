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
)

func init() {
	crmetrics.Registry.MustRegister(
		ReconcileErrors,
		ReconcileDuration,
		AdmissionDuration,
		AdmissionsTotal,
		RejectionsTotal,
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
