package controller

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// DriftDetectorReconciler 通过 CR/PV/lvs 三方对账发现人工绕过平台的 LVM 变更，
// 告警并给出补录/回滚建议；并提供 break-glass 授权窗口（§3.2/§3.3）。
//
// 原则：平台 SHALL NOT 自动修复，仅告警 + 建议。lvs 实际侧由 Agent 采集后写入
// NodeVG.status（ADR-006 §16）；Reporter 为 nil 时跳过 lvs 一侧对账。
type DriftDetectorReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	// Recorder 告警事件记录器。
	Recorder record.EventRecorder
	// Reporter 提供节点实际 LV 列表（生产实现 NodeVGLVReporter，测试用 fake）。
	Reporter LVReporter
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=persistentvolumes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile 对账 PV（managed）与实际 LV（actual），发现漂移即告警并给出补录/回滚建议。
func (r *DriftDetectorReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerDrift, start, err) }()

	// managed：PV 侧账面。TopoLVM CSI PV 的 LV 名是 csi.volumeHandle（不是 pv.Name），
	// 节点来自 nodeAffinity、VG 按 NodeVG.spec.nodeName 反查（详见 ManagedLVsFromPVs）。
	// 字段不全的 PV 会被跳过 —— 宁可对账未覆盖，也不用错名字制造双向误报。
	var pvs corev1.PersistentVolumeList
	if err := r.List(ctx, &pvs); err != nil {
		return ctrl.Result{}, err
	}
	var nodeVGs storagev1beta1.NodeVGList
	if err := r.List(ctx, &nodeVGs); err != nil {
		return ctrl.Result{}, err
	}
	managed := ManagedLVsFromPVs(pvs.Items, nodeVGs.Items)
	nodes := map[string]struct{}{}
	for _, m := range managed {
		nodes[m.Node] = struct{}{}
	}

	// actual：来自 Agent 的宿主 lvs 上报（NodeVG.status，§16）。
	//
	// 失败关闭：任一节点采集失败或上报过期，整轮放弃对账。若只跳过该节点，
	// 其余节点的 actual 仍会让缺数据节点的所有 managed 变成 missing-lv 误报。
	var actual []ActualLV
	if r.Reporter != nil {
		for node := range nodes {
			lvs, err := r.Reporter.ListActualLVs(node)
			if err != nil {
				logger.Info("LV 上报不可用，本轮放弃三方对账（不产生误报）",
					"node", node, "reason", err.Error())
				return ctrl.Result{}, nil
			}
			actual = append(actual, lvs...)
		}
	}

	for _, it := range DetectDrift(managed, actual) {
		msg := fmt.Sprintf("漂移[%s] node=%s vg=%s lv=%s 建议=%s：%s", it.Kind, it.Node, it.VG, it.LV, it.Suggestion, it.Detail)
		logger.Info("drift-detector 告警", "kind", it.Kind, "node", it.Node, "lv", it.LV, "suggestion", it.Suggestion)
		if r.Recorder != nil {
			r.Recorder.Event(&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: it.Node}}, corev1.EventTypeWarning, "StorageDrift", msg)
		}
	}
	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器：监听 NodeVG（含 Agent LV 上报触发的 status 更新）与
// PV 增删改（账面变化必须对账）。Reconcile 是全量对账，故 PV 事件映射到所有 NodeVG。
func (r *DriftDetectorReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1beta1.NodeVG{}).
		Watches(&corev1.PersistentVolume{}, handler.EnqueueRequestsFromMapFunc(r.enqueueAllNodeVGs)).
		Named("nodevg-drift").
		Complete(r)
}

// enqueueAllNodeVGs 把任意 PV 事件映射为全量对账请求。
//
// Reconcile 不使用 req.Name（每次都 List 全部 PV/NodeVG），这里仍返回真实 NodeVG 名以便
// 日志与指标可读；无 NodeVG 时用一个哨兵请求，保证带注解兼容路径的 PV 也能触发对账。
func (r *DriftDetectorReconciler) enqueueAllNodeVGs(ctx context.Context, _ client.Object) []reconcile.Request {
	var list storagev1beta1.NodeVGList
	if err := r.List(ctx, &list); err != nil {
		log.FromContext(ctx).Error(err, "PV 事件映射 NodeVG 失败（本轮对账未触发）")
		return nil
	}
	reqs := make([]reconcile.Request, 0, len(list.Items))
	for i := range list.Items {
		reqs = append(reqs, reconcile.Request{
			NamespacedName: client.ObjectKey{Name: list.Items[i].Name},
		})
	}
	if len(reqs) == 0 {
		reqs = append(reqs, reconcile.Request{
			NamespacedName: client.ObjectKey{Name: "pv-change"},
		})
	}
	return reqs
}
