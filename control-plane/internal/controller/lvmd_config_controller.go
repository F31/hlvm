package controller

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// LvmdConfigReconciler 是 lvmd 配置控制器（add-capacity-governance §2 lvmd-config-ctrl）。
//
// 职责（设计 §2.1 / §2.3）：
//   - 由 NodeVG 渲染各节点 lvmd ConfigMap（device-class、thin-pool、overprovision-ratio）；
//   - 漂移检测：ConfigMap 被人工改动（内容偏离渲染值）时纠正回控制面口径，并记录告警级日志。
//
// 单写者：lvmd ConfigMap 的本侧写者。Agent 仅读取该 ConfigMap 应用，不反向写（§1.4 数据面独立）。
// 不写 NodeVG.status（避免与 VGReconciler/CapacityReconciler 的 status 写竞争）；漂移以日志审计。
type LvmdConfigReconciler struct {
	client.Client
	Scheme    *runtime.Scheme
	Namespace string
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch;create;update;patch

// Reconcile 渲染并确保节点 lvmd ConfigMap 与期望一致。
func (r *LvmdConfigReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var vg storagev1alpha1.NodeVG
	if err := r.Get(ctx, req.NamespacedName, &vg); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if vg.Spec.NodeName == "" {
		// 未绑定节点（早期纳管前）跳过渲染。
		return ctrl.Result{}, nil
	}

	ns := r.Namespace
	if ns == "" {
		ns = ManagedNamespace
	}
	cmName := LvmdConfigName(vg.Spec.NodeName)
	rendered := RenderLVMDConfig(vg)

	var cm corev1.ConfigMap
	err := r.Get(ctx, client.ObjectKey{Namespace: ns, Name: cmName}, &cm)
	if apierrors.IsNotFound(err) {
		cm = corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{
				Namespace:   ns,
				Name:        cmName,
				Annotations: map[string]string{ManagedAnnotation: "true"},
			},
			Data: map[string]string{"lvmd.yaml": rendered},
		}
		if err := r.Create(ctx, &cm); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("创建 lvmd ConfigMap", "node", vg.Spec.NodeName, "configmap", cmName)
		return ctrl.Result{}, nil
	} else if err != nil {
		return ctrl.Result{}, err
	}

	// 漂移检测：内容偏离渲染值（人工改动）则纠正。
	if cm.Data == nil {
		cm.Data = map[string]string{}
	}
	if cm.Data["lvmd.yaml"] != rendered {
		cm.Data["lvmd.yaml"] = rendered
		if cm.Annotations == nil {
			cm.Annotations = map[string]string{}
		}
		cm.Annotations[ManagedAnnotation] = "true"
		if err := r.Update(ctx, &cm); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("lvmd ConfigMap 漂移已纠正", "node", vg.Spec.NodeName, "configmap", cmName)
	}

	return ctrl.Result{}, nil
}

// SetupWithManager 注册控制器。
func (r *LvmdConfigReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeVG{}).
		Owns(&corev1.ConfigMap{}).
		Complete(r)
}
