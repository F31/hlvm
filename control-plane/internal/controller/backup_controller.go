package controller

import (
	"context"
	"time"

	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// BackupInventory 提供备份记录的采集接口（设计 §7 / add-backup-restore）。
//
// 生产实现从 Velero Backup CRD（或 VolumeSnapshot 状态）读取；本模块不引入 Velero 依赖，
// 以接口为接缝。未接入（nil）时 BackupReconciler 跳过 RPO 核对，不误报。
type BackupInventory interface {
	ListBackups(ctx context.Context) ([]BackupRecord, error)
}

// BackupReconciler 落实"生产 PVC 默认备份"约定并核对 RPO 达标（设计 §6 第 4 条 + §7 / 1.3 + 4.1-4.2）。
//
// 监听 PersistentVolumeClaim：校验备份约定是否满足；经 BackupInventory 接口获取备份记录，
// 计算每个生产 PVC 的最近成功备份时间与 RPO 合规，刷新指标并告警。平台 SHALL NOT 执行备份本身。
type BackupReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
	// Inventory 备份记录采集器；nil 表示 Velero 未接入，跳过 RPO 核对。
	Inventory BackupInventory
	// RPO 恢复点目标；零值使用 DefaultRPO（24h）。
	RPO time.Duration
	// ManagedNamespace 演练/配置命名空间（预留；当前约定跨命名空间评估）。
	ManagedNamespace string
}

// +kubebuilder:rbac:groups="",resources=persistentvolumeclaims,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=namespaces,verbs=get;list;watch
// +kubebuilder:rbac:groups=storage.k8s.io,resources=storageclasses,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile 逐个 PVC 校验备份约定 + （若接入）RPO 合规，刷新指标并发事件。
func (r *BackupReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerBackup, start, err) }()

	rpo := r.RPO
	if rpo <= 0 {
		rpo = DefaultRPO
	}
	now := start

	var pvcs corev1.PersistentVolumeClaimList
	if err := r.List(ctx, &pvcs); err != nil {
		return ctrl.Result{}, err
	}

	rpoOverdueCount := 0
	backupFailedCount := 0

	for i := range pvcs.Items {
		pvc := &pvcs.Items[i]

		var ns *corev1.Namespace
		if got, err := r.getNamespace(ctx, pvc.Namespace); err != nil {
			logger.Error(err, "获取命名空间失败", "ns", pvc.Namespace)
			continue
		} else {
			ns = got
		}

		var sc *storagev1.StorageClass
		if pvc.Spec.StorageClassName != nil && *pvc.Spec.StorageClassName != "" {
			if got, err := r.getStorageClass(ctx, *pvc.Spec.StorageClassName); err != nil {
				logger.Error(err, "获取存储类失败", "sc", *pvc.Spec.StorageClassName)
			} else {
				sc = got
			}
		}

		enabled, reason := BackupEnabledFor(pvc, ns, sc)
		if !enabled {
			logger.Info("备份约定违例", "pvc", pvc.Name, "ns", pvc.Namespace, "reason", reason)
			if r.Recorder != nil {
				r.Recorder.Event(pvc, corev1.EventTypeWarning, "BackupConventionViolation", reason)
			}
			continue
		}

		if r.Inventory == nil {
			continue // Velero 未接入：仅做约定校验，RPO 核对移交集成。
		}

		records, err := r.Inventory.ListBackups(ctx)
		if err != nil {
			return ctrl.Result{}, err
		}
		var recs []BackupRecord
		for _, rec := range records {
			if rec.Namespace == pvc.Namespace && rec.SourcePVC == pvc.Name {
				recs = append(recs, rec)
				if rec.Phase == PhaseFailed {
					backupFailedCount++
					if r.Recorder != nil {
						r.Recorder.Event(pvc, corev1.EventTypeWarning, "BackupFailed",
							"该 PVC 存在失败的备份任务，检查备份链路")
					}
				}
			}
		}

		latest, ok := LatestSuccessfulBackup(recs)
		if !ok {
			metrics.SetBackupRPOOverdue(pvc.Namespace, pvc.Name, true)
			rpoOverdueCount++
			if r.Recorder != nil {
				r.Recorder.Event(pvc, corev1.EventTypeWarning, "BackupNeverSucceeded",
					"生产 PVC 从未成功备份，RPO 不达标（恢复点不存在）")
			}
			continue
		}

		metrics.BackupLastSuccessTimestampSeconds.WithLabelValues(pvc.Namespace, pvc.Name).
			Set(float64(latest.CompletionTime.Unix()))
		overdue := !RPOCompliant(latest.CompletionTime, rpo, now)
		metrics.SetBackupRPOOverdue(pvc.Namespace, pvc.Name, overdue)
		if overdue {
			rpoOverdueCount++
			if r.Recorder != nil {
				r.Recorder.Event(pvc, corev1.EventTypeWarning, "BackupRPOOverdue",
					"生产 PVC 最近成功备份超出 RPO 窗口，恢复点陈旧")
			}
		}
	}

	_ = backupFailedCount
	_ = rpoOverdueCount
	return ctrl.Result{}, nil
}

func (r *BackupReconciler) getNamespace(ctx context.Context, name string) (*corev1.Namespace, error) {
	var ns corev1.Namespace
	if err := r.Get(ctx, client.ObjectKey{Name: name}, &ns); err != nil {
		return nil, err
	}
	return &ns, nil
}

func (r *BackupReconciler) getStorageClass(ctx context.Context, name string) (*storagev1.StorageClass, error) {
	var sc storagev1.StorageClass
	if err := r.Get(ctx, client.ObjectKey{Name: name}, &sc); err != nil {
		return nil, err
	}
	return &sc, nil
}

// SetupWithManager 注册控制器：监听 PersistentVolumeClaim。
func (r *BackupReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.PersistentVolumeClaim{}).
		Complete(r)
}

// DrillReconciler 落实"恢复演练为发布门禁"（设计 §7 / add-backup-restore 3.1-3.3）。
//
// 监听演练结果 ConfigMap（DrillConfigMapName）：解析 DrillRecord，刷新最近通过演练时间戳指标，
// 若发布门禁阻断（无通过演练/超期/数据校验未过）则发事件提醒——"没有被验证过的备份不算备份"。
type DrillReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
	// ManagedNamespace 演练结果 ConfigMap 所在命名空间。
	ManagedNamespace string
	// GateMaxStale 门禁最大陈旧期；零值使用季度（90 天）。
	GateMaxStale time.Duration
}

// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile 解析演练结果 ConfigMap，刷新指标并核对发布门禁。
func (r *DrillReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerDrill, start, err) }()

	if req.Name != DrillConfigMapName {
		return ctrl.Result{}, nil
	}
	if r.ManagedNamespace != "" && req.Namespace != r.ManagedNamespace {
		return ctrl.Result{}, nil
	}

	var cm corev1.ConfigMap
	if err := r.Get(ctx, client.ObjectKey{Namespace: req.Namespace, Name: req.Name}, &cm); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	records, err := ParseDrillRecords(&cm)
	if err != nil {
		logger.Error(err, "解析演练记录失败")
		if r.Recorder != nil {
			r.Recorder.Event(&cm, corev1.EventTypeWarning, "BackupDrillParseFailed", err.Error())
		}
		return ctrl.Result{}, nil // 配置问题不重试循环
	}

	latest, ok := LatestPassedDrill(records)
	if !ok {
		logger.Info("无通过（或未达 SLO）的恢复演练")
		if r.Recorder != nil {
			r.Recorder.Event(&cm, corev1.EventTypeWarning, "BackupDrillGateBlocked",
				"无通过的恢复演练：发布门禁阻断，不得上线/升级")
		}
		return ctrl.Result{}, nil
	}

	metrics.SetBackupDrillLastSuccess(latest.CompletedAt)

	stale := r.GateMaxStale
	if stale <= 0 {
		stale = 24 * 90 * time.Hour
	}
	if DrillGateBlocked(&latest, start, stale) {
		logger.Info("恢复演练超期，发布门禁阻断", "lastPass", latest.CompletedAt)
		if r.Recorder != nil {
			r.Recorder.Event(&cm, corev1.EventTypeWarning, "BackupDrillGateBlocked",
				"恢复演练超过门禁陈旧期，发布门禁阻断，需重新演练")
		}
	}
	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器：监听 ConfigMap。
func (r *DrillReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.ConfigMap{}).
		Complete(r)
}
