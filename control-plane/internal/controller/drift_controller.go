package controller

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// DriftDetectorReconciler 通过 CR/PV/lvs 三方对账发现人工绕过平台的 LVM 变更，
// 告警并给出补录/回滚建议；并提供 break-glass 授权窗口（§3.2/§3.3）。
//
// 原则：平台 SHALL NOT 自动修复，仅告警 + 建议。lvs 实际侧经 agent 上报，未接入时为 nil。
type DriftDetectorReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	// Recorder 告警事件记录器。
	Recorder record.EventRecorder
	// Reporter 提供节点实际 LV 列表（agent lvs 采集）。未接入时为 nil，跳过 lvs 一侧对账。
	Reporter LVReporter
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=persistentvolumes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile 对账 PV（managed）与实际 LV（actual），发现漂移即告警并给出补录/回滚建议。
func (r *DriftDetectorReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// managed：来自 PV（每个 PV 对应一个平台 LV），以 hlvm.dev/node 注解归属节点。
	var pvs corev1.PersistentVolumeList
	if err := r.List(ctx, &pvs); err != nil {
		return ctrl.Result{}, err
	}
	var managed []ManagedLV
	nodes := map[string]struct{}{}
	for _, pv := range pvs.Items {
		node := pv.Annotations[PVNodeAnnotation]
		if node == "" {
			continue
		}
		managed = append(managed, ManagedLV{Node: node, VG: pv.Annotations["hlvm.dev/vg"], Name: pv.Name})
		nodes[node] = struct{}{}
	}

	// actual：来自 agent lvs 上报（未接入时跳过）。
	var actual []ActualLV
	if r.Reporter != nil {
		for node := range nodes {
			lvs, err := r.Reporter.ListActualLVs(node)
			if err != nil {
				logger.Error(err, "采集实际 LV 失败", "node", node)
				continue
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

// SetupWithManager 注册控制器：监听 NodeVG（容量/拓扑变化即触发对账）。
func (r *DriftDetectorReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeVG{}).
		Complete(r)
}
