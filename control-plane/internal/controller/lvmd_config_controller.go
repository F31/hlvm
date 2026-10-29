package controller

import (
	"context"
	"sort"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"

	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// LvmdConfigReconciler 由 NodeVG 渲染节点级 lvmd ConfigMap（capacity-governance §2.1 / ADR-005）。
//
// 语义：**一节点一份** ConfigMap，内容聚合该节点全部 NodeVG 的 device-class；
// 单写者：lvmd ConfigMap 的本侧写者。Agent 仅读取该 ConfigMap 应用，不反向写（§1.4 数据面独立）。
// 不写 NodeVG.status（避免与 VGReconciler/CapacityReconciler 的 status 写竞争）；漂移以日志审计。
type LvmdConfigReconciler struct {
	client.Client
	Scheme    *runtime.Scheme
	Namespace string
}

// +kubebuilder:rbac:groups=storage.example.io,resources=nodevgs,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch;create;update;patch;delete

// Reconcile 渲染并确保节点 lvmd ConfigMap 与期望一致。
func (r *LvmdConfigReconciler) Reconcile(ctx context.Context, req ctrl.Request) (result ctrl.Result, err error) {
	logger := log.FromContext(ctx)
	start := time.Now()
	defer func() { metrics.ObserveReconcile(metrics.ControllerLvmdConfig, start, err) }()

	var vg storagev1alpha1.NodeVG
	if err := r.Get(ctx, req.NamespacedName, &vg); err != nil {
		// 已删除：ConfigMap 由 ownerReference GC 回收（全部 owner 删除后），此处无需处理。
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

	// 聚合该节点全部 NodeVG（ADR-005：一节点一份配置，而非单 VG 覆盖）。
	var list storagev1alpha1.NodeVGList
	if err := r.List(ctx, &list); err != nil {
		return ctrl.Result{}, err
	}
	sameNode := make([]storagev1alpha1.NodeVG, 0, len(list.Items))
	for i := range list.Items {
		if list.Items[i].Spec.NodeName == vg.Spec.NodeName {
			sameNode = append(sameNode, list.Items[i])
		}
	}

	rendered, ok, err := AggregateLVMDConfig(sameNode)
	if err != nil {
		// 配置非法（如 device-class 重名）：保持现状并重试，绝不写入 lvmd 会拒绝的文件。
		logger.Error(err, "聚合 lvmd 配置失败，保留现有 ConfigMap", "node", vg.Spec.NodeName)
		return ctrl.Result{}, err
	}
	if !ok {
		// 该节点没有可服务的 device-class（无 vgExists=true 的 VG）。
		// lvmd 的 ValidateDeviceClasses 拒绝空列表，写 `device-classes: []` 等于下发无法启动的配置；
		// 因此撤销托管 ConfigMap，使「ConfigMap 是否存在」等价于「该节点是否可服务」。
		if err := r.removeManagedConfigMap(ctx, ns, cmName, vg.Spec.NodeName); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}
	owners := ownerReferencesForVGs(sameNode)

	var cm corev1.ConfigMap
	err = r.Get(ctx, client.ObjectKey{Namespace: ns, Name: cmName}, &cm)
	if apierrors.IsNotFound(err) {
		cm = corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{
				Namespace:       ns,
				Name:            cmName,
				Annotations:     map[string]string{ManagedAnnotation: "true"},
				OwnerReferences: owners,
			},
			Data: map[string]string{"lvmd.yaml": rendered},
		}
		if err := r.Create(ctx, &cm); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("创建 lvmd ConfigMap", "node", vg.Spec.NodeName, "configmap", cmName,
			"nodeVGs", len(sameNode))
		return ctrl.Result{}, nil
	} else if err != nil {
		return ctrl.Result{}, err
	}

	changed := false
	if cm.Data == nil {
		cm.Data = map[string]string{}
	}
	if cm.Data["lvmd.yaml"] != rendered {
		cm.Data["lvmd.yaml"] = rendered
		changed = true
	}
	if cm.Annotations == nil {
		cm.Annotations = map[string]string{}
	}
	if cm.Annotations[ManagedAnnotation] != "true" {
		cm.Annotations[ManagedAnnotation] = "true"
		changed = true
	}
	// ownerReference 随同节点 VG 集合变化（新增/删除 VG）而更新；GC 语义见 ADR-005。
	if !equalOwnerReferences(cm.OwnerReferences, owners) {
		cm.OwnerReferences = owners
		changed = true
	}
	if changed {
		if err := r.Update(ctx, &cm); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("lvmd ConfigMap 已纠正", "node", vg.Spec.NodeName, "configmap", cmName)
	}

	return ctrl.Result{}, nil
}

// removeManagedConfigMap 删除本控制器渲染的 ConfigMap（仅当带 managed 注解）。
//
// 触发条件：该节点已没有可服务的 device-class。此时：
//   - 写 `device-classes: []` 会被 lvmd 拒绝（应至少有一个 device-class），等于下发不可启动配置；
//   - 保留旧配置指向已消失的 VG，lvmd 重启时仍会以 "volume group not found" 失败。
//
// 因此撤销 ConfigMap，使「ConfigMap 存在」等价于「该节点有 lvmd 可服务的 VG」。
func (r *LvmdConfigReconciler) removeManagedConfigMap(ctx context.Context, ns, cmName, node string) error {
	logger := log.FromContext(ctx)
	var cm corev1.ConfigMap
	if err := r.Get(ctx, client.ObjectKey{Namespace: ns, Name: cmName}, &cm); err != nil {
		return client.IgnoreNotFound(err)
	}
	if cm.Annotations[ManagedAnnotation] != "true" {
		logger.Info("lvmd ConfigMap 非平台托管，跳过删除", "node", node, "configmap", cmName)
		return nil
	}
	if err := r.Delete(ctx, &cm); err != nil {
		return client.IgnoreNotFound(err)
	}
	logger.Info("节点已无可用 device-class，删除 lvmd ConfigMap", "node", node, "configmap", cmName)
	return nil
}

// ownerReferencesForVGs 为同节点每个 NodeVG 生成**非 controller** ownerReference。
//
// 多个 owner 时，K8s GC 只有在全部 owner 删除后才回收 dependent，
// 因此删除最后一个 NodeVG 会自然清理 ConfigMap（无需 finalizer）。
func ownerReferencesForVGs(vgs []storagev1alpha1.NodeVG) []metav1.OwnerReference {
	refs := make([]metav1.OwnerReference, 0, len(vgs))
	for _, vg := range vgs {
		if vg.UID == "" {
			// 无 UID 的对象（如 fake client 构造）不能作为合法 owner。
			continue
		}
		controller := false
		blockOwnerDeletion := false
		refs = append(refs, metav1.OwnerReference{
			APIVersion:         storagev1alpha1.GroupVersion.String(),
			Kind:               "NodeVG",
			Name:               vg.Name,
			UID:                vg.UID,
			Controller:         &controller,
			BlockOwnerDeletion: &blockOwnerDeletion,
		})
	}
	sort.Slice(refs, func(i, j int) bool { return refs[i].Name < refs[j].Name })
	return refs
}

// equalOwnerReferences 比较两组 ownerReference 的名称与 UID 集合（忽略顺序）。
func equalOwnerReferences(a, b []metav1.OwnerReference) bool {
	if len(a) != len(b) {
		return false
	}
	index := make(map[string]string, len(a))
	for _, ref := range a {
		index[ref.Name] = string(ref.UID)
	}
	for _, ref := range b {
		uid, ok := index[ref.Name]
		if !ok || uid != string(ref.UID) {
			return false
		}
	}
	return true
}

// SetupWithManager 注册控制器。
//
// MatchEveryOwner 必需：controller-runtime v0.20 的 Owns() 默认 OnlyControllerOwner()，
// 本控制器的 ownerReference 均为非 controller（同节点可能有多个 VG），不传则永不触发。
func (r *LvmdConfigReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&storagev1alpha1.NodeVG{}).
		Named("nodevg-lvmd").
		Owns(&corev1.ConfigMap{}, builder.MatchEveryOwner).
		Complete(r)
}
