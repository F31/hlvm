package controller

import (
	"context"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// VGReconciler 是 NodeVG 的控制器（add-crd-controller-skeleton 阶段）。
//
// 当前实现对账职责：
//   - 删盘保护：校验 removeDisks 候选无 LV 占用、移除不导致冗余丧失；失败则将原因写入
//     status.pendingOps 并拒绝下发 vgreduce（设计 §3.4 / 规格 vg-ctrl 删盘保护）。
//   - 依据 spec.disks 生成 StorageTask（vgcreate/vgextend/vgreduce）由后续 change 补全。
type VGReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=storage.example.io,resources=nodedisks,verbs=get;list;watch

// Reconcile 对 NodeVG 做对账：执行删盘保护校验并写入 status.pendingOps。
func (r *VGReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerVG, start, err) }()

	var vg storagev1beta1.NodeVG
	if err := r.Get(ctx, req.NamespacedName, &vg); err != nil {
		if apierrors.IsNotFound(err) {
			// 对象已删：清掉 thin-pool 与 VG 容量序列。否则 /metrics 上会永久留着
			// 「最后已知水位」，看起来池一切正常，实际这个 VG 已经不存在了
			// （ADR-006 §23.11 / §23.12）。
			metrics.ForgetThinPool(req.Name)
			metrics.ForgetVGCapacity(req.Name)
		}
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// thin-pool 容量序列：把 Agent 上报的实测值同步到指标（ADR-006 §23.11）。
	// `state` 为空（旧 agent 未上报）或 `unreadable`（采集失败）时删序列，而不是写 0。
	syncThinPoolMetrics(&vg)
	// VG 容量序列（ADR-006 §23.12）：`totalBytes` 为空/0（旧 agent 未上报或采集失败）
	// 时删序列，而不是写 0。
	syncVGCapacityMetrics(&vg)

	candidates := vg.Spec.Operations.RemoveDisks
	var plan RemovePlan
	if len(candidates) == 0 {
		// 无删盘意图时清空历史 pendingOps（保留其他来源需另计，此处为删盘保护专用）。
		if len(vg.Status.PendingOps) > 0 {
			vg.Status.PendingOps = nil
			if err := r.Status().Update(ctx, &vg); err != nil {
				return ctrl.Result{}, err
			}
		}
	} else {
		// 构建占用图：盘若仍被 LV 占用则阻塞。scaffold 阶段从 NodeDisk 状态推断——
		// 仍 phase=InVG 且 VgRef 指向本 VG 的盘视为"未 drain、占用中"。
		occupancy := make(map[string][]string)
		for _, d := range candidates {
			inUse, err := r.diskStillInUse(ctx, vg.Spec.NodeName, vg.Name, d)
			if err != nil {
				return ctrl.Result{}, err
			}
			if inUse {
				occupancy[d] = []string{"<still InVG, not drained>"}
			}
		}

		remainingAfterRemoval := len(vg.Spec.Disks) - len(candidates)
		redLost := RedundancyWouldBeLost(vg.Spec.Layout, vg.Spec.Redundancy, remainingAfterRemoval)
		plan = PlanRemoveDisks(candidates, occupancy, redLost)

		// 幂等：仅当 pendingOps 变化才写回 status（etcd 写放大控制，§7）。
		if !equalStringSlice(vg.Status.PendingOps, plan.PendingOps) {
			vg.Status.PendingOps = plan.PendingOps
			if err := r.Status().Update(ctx, &vg); err != nil {
				return ctrl.Result{}, err
			}
		}
		logger.Info("remove-disk protection evaluated",
			"vg", vg.Name, "approved", plan.Approved, "blocked", len(plan.Blocked), "pendingOps", plan.PendingOps)
	}

	// 下发 VG 任务（vgcreate 如需 + 已批准 vgreduce），幂等。被阻塞的盘不会进入下发。
	for _, t := range DesiredStorageTasksForVG(vg, plan.Approved) {
		if _, err := ensureStorageTask(ctx, r.Client, t, &vg); err != nil {
			return ctrl.Result{}, err
		}
	}

	return ctrl.Result{}, nil
}

// diskStillInUse 判定候选盘是否仍被 LV 占用（即仍 InVG 且归属于本 VG）。
func (r *VGReconciler) diskStillInUse(ctx context.Context, nodeName, vgName, diskByID string) (bool, error) {
	var list storagev1beta1.NodeDiskList
	if err := r.List(ctx, &list); err != nil {
		return false, err
	}
	for _, d := range list.Items {
		if d.Spec.NodeName != nodeName {
			continue
		}
		if d.Status.VgRef != vgName {
			continue
		}
		// 设备匹配：NodeDisk 的 by-id 与候选盘一致。
		if d.Status.Identity.ByID == diskByID || d.Status.CurrentDevice == diskByID {
			if d.Status.Phase == storagev1beta1.DiskPhaseInVG {
				return true, nil
			}
		}
	}
	return false, nil
}

func equalStringSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// SetupWithManager 注册控制器。
func (r *VGReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1beta1.NodeVG{}).
		Named("nodevg-vg").
		Complete(r)
}

// syncThinPoolMetrics 把 `NodeVG.status.thinPool` 同步到 `storage_thinpool_*`（ADR-006 §23.11）。
//
// 判定口径：
//   - `state` ∈ {ok, out-of-space} 才暴露序列；
//   - 空串按**不可读**处理。旧 agent（≤ preview.6）根本不写该字段，零值 0% 会让
//     `storage_thinpool_data_percent >= 85` 永远为假——这是最容易发生的假绿；
//   - `unreadable`（Agent 采不到数据/权限不足/LVM 版本过旧）删序列而不是写 0，
//     缺序列能被 `absent()` 类规则发现，写 0 则永久静默。
func syncThinPoolMetrics(vg *storagev1beta1.NodeVG) {
	pool := vg.Spec.ThinPool.Name
	if vg.Spec.NodeName == "" || pool == "" {
		metrics.ForgetThinPool(vg.Name)
		return
	}
	st := vg.Status.ThinPool
	if st.State != "ok" && st.State != "out-of-space" {
		metrics.ForgetThinPool(vg.Name)
		return
	}
	metrics.SyncThinPool(metrics.ThinPoolSample{
		Node:            vg.Spec.NodeName,
		VG:              vg.Name,
		Pool:            pool,
		DataPercent:     st.DataPercent,
		MetadataPercent: st.MetadataPercent,
		// `state` 是权威信号：即使 outOfSpace 布尔位没跟上（Agent 版本差异），
		// 只要 state=out-of-space 就必须报 1，否则打满时 critical 告警不响。
		OutOfSpace:       st.OutOfSpace || st.State == "out-of-space",
		ProvisionedBytes: st.ProvisionedBytes,
		CurrentSizeBytes: st.CurrentSizeBytes,
	})
}

// syncVGCapacityMetrics 把 `NodeVG.status.{totalBytes,freeBytes}` 同步到 `storage_vg_*`
// （ADR-006 §23.12）。
//
// 判定口径（刻意不引入新的 `state` 字段，也就不必改 CRD schema 与实际集群的 CRD）：
//   - `totalBytes > 0` 才认为容量已知。VG 存在时总量必然大于 0，所以它本身就是
//     「本轮采到了」的可靠判据；Agent 采不到时会把这两个字段置 null 删掉，
//     于是这里读到 0 → 撤销序列，与「从未上报」等价（都是「不知道」）。
//   - `freeBytes == 0` **不**视为未知：那是真实的「VG 打满」，必须原样暴露 0，
//     否则 `storage_vg_free_bytes` 在打满时消失，空闲告警永远不会响。
//   - `nodeName` 为空（spec 不完整）或 `freeBytes < 0`（上报侧异常）时不产出序列，
//     避免 `node=""` 的脏序列被 `sum by (node)` 聚成一个不存在的节点。
func syncVGCapacityMetrics(vg *storagev1beta1.NodeVG) {
	if vg.Spec.NodeName == "" || vg.Status.TotalBytes <= 0 || vg.Status.FreeBytes < 0 {
		metrics.ForgetVGCapacity(vg.Name)
		return
	}
	metrics.SyncVGCapacity(vg.Spec.NodeName, vg.Name, vg.Status.TotalBytes, vg.Status.FreeBytes)
}
