package webhook

import (
	"context"
	"fmt"
	"strconv"

	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	controller "github.com/F31/hlvm/control-plane/internal/controller"
)

// 本平台标识与静态规则相关常量（设计 §4 / §6）。
const (
	// PlatformProvisioner 标识本平台 StorageClass（TopoLVM provisioner）。
	PlatformProvisioner = "topolvm.io"
	// DeviceClassParam 是 SC 参数中 tier↔device-class 映射键（设计 §6）。
	DeviceClassParam = "topolvm.io/device-class"
	// ReplicasAnnotation 声明单副本业务的多副本评审留痕（设计 §6，默认只提示不强拦）。
	ReplicasAnnotation = "storage.example.io/replicas"
	// DefaultStorageClassAnnotation 标记默认 SC（PVC 未显式指定 storageClassName 时取默认）。
	DefaultStorageClassAnnotation = "storageclass.kubernetes.io/is-default-class"
)

// IsPlatformStorageClass 判定 SC 是否由本平台提供（provisioner = topolvm.io）。
func IsPlatformStorageClass(sc *storagev1.StorageClass) bool {
	return sc != nil && sc.Provisioner == PlatformProvisioner
}

// StorageClassTier 返回 SC 声明的 tier（device-class 参数）；非平台返回 ("", false)。
func StorageClassTier(sc *storagev1.StorageClass) (string, bool) {
	if !IsPlatformStorageClass(sc) {
		return "", false
	}
	tier := sc.Parameters[DeviceClassParam]
	if tier == "" {
		return "", false
	}
	return tier, true
}

// ResolvePVCStorageClass 按 PVC 的 storageClassName（含默认 SC）取 SC；nil 视为默认 SC。
func ResolvePVCStorageClass(ctx context.Context, r client.Reader, pvc *corev1.PersistentVolumeClaim) (*storagev1.StorageClass, error) {
	if pvc.Spec.StorageClassName != nil && *pvc.Spec.StorageClassName != "" {
		var sc storagev1.StorageClass
		if err := r.Get(ctx, client.ObjectKey{Name: *pvc.Spec.StorageClassName}, &sc); err != nil {
			return nil, err
		}
		return &sc, nil
	}
	// 默认 SC。
	var list storagev1.StorageClassList
	if err := r.List(ctx, &list); err != nil {
		return nil, err
	}
	for i := range list.Items {
		if list.Items[i].Annotations[DefaultStorageClassAnnotation] == "true" {
			return &list.Items[i], nil
		}
	}
	return nil, nil
}

// PVCTier 解析 PVC 所属 tier；非平台 PVC 返回 ("", false, nil)。
func PVCTier(ctx context.Context, r client.Reader, pvc *corev1.PersistentVolumeClaim) (string, bool, error) {
	sc, err := ResolvePVCStorageClass(ctx, r, pvc)
	if err != nil {
		return "", false, err
	}
	tier, ok := StorageClassTier(sc)
	return tier, ok, nil
}

// TierHasAvailableNode 判定 tier 是否存在至少一个非 locked 节点（available/pressure 均可用；locked 拦截新 PVC/扩容）。
func TierHasAvailableNode(nodeVGs []storagev1alpha1.NodeVG, tier string) bool {
	for i := range nodeVGs {
		vg := &nodeVGs[i]
		if vg.Spec.Tier != tier {
			continue
		}
		if vg.Status.CapacityStatus != storagev1alpha1.CapacityLocked {
			return true
		}
	}
	return false
}

// BuildLockedNodeAffinity 为给定 tier 构造排除 locked 节点的 requiredDuringScheduling nodeAffinity。
// 复用 controller.LockLabelName 保证与 capacity-ctrl 打的锁标签一致。
func BuildLockedNodeAffinity(tiers []string) *corev1.NodeAffinity {
	if len(tiers) == 0 {
		return nil
	}
	exprs := make([]corev1.NodeSelectorRequirement, 0, len(tiers))
	for _, t := range tiers {
		exprs = append(exprs, corev1.NodeSelectorRequirement{
			Key:      controller.LockLabelName(t),
			Operator: corev1.NodeSelectorOpNotIn,
			Values:   []string{"true"},
		})
	}
	return &corev1.NodeAffinity{
		RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
			NodeSelectorTerms: []corev1.NodeSelectorTerm{
				{MatchExpressions: exprs},
			},
		},
	}
}

// MergeNodeAffinity 将 locked 排除规则合并进 Pod 既有的 nodeAffinity（保留既有约束，不覆盖）。
// 语义：在每个既有 NodeSelectorTerm 的 MatchExpressions 追加 locked 排除（term 间为 OR，表达式间为 AND）。
func MergeNodeAffinity(pod *corev1.Pod, aff *corev1.NodeAffinity) {
	if aff == nil {
		return
	}
	lockedExprs := aff.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms[0].MatchExpressions

	if pod.Spec.Affinity == nil || pod.Spec.Affinity.NodeAffinity == nil ||
		pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution == nil {
		if pod.Spec.Affinity == nil {
			pod.Spec.Affinity = &corev1.Affinity{}
		}
		pod.Spec.Affinity.NodeAffinity = aff
		return
	}
	req := pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution
	for i := range req.NodeSelectorTerms {
		req.NodeSelectorTerms[i].MatchExpressions = append(req.NodeSelectorTerms[i].MatchExpressions, lockedExprs...)
	}
}

// PodReferencedPlatformTiers 返回 Pod 直接引用的本平台 PVC 所属 tier 集合（去重）。
// 仅处理直接引用（spec.volumes[].persistentVolumeClaim）；PVC 未就绪（WaitForFirstConsumer）时跳过，避免误阻塞。
func PodReferencedPlatformTiers(ctx context.Context, r client.Reader, pod *corev1.Pod) ([]string, error) {
	seen := make(map[string]struct{})
	var tiers []string
	for _, vol := range pod.Spec.Volumes {
		if vol.PersistentVolumeClaim == nil {
			continue
		}
		var pvc corev1.PersistentVolumeClaim
		if err := r.Get(ctx, client.ObjectKey{Namespace: pod.Namespace, Name: vol.PersistentVolumeClaim.ClaimName}, &pvc); err != nil {
			continue // PVC 未就绪等：跳过，不强注入。
		}
		tier, ok, err := PVCTier(ctx, r, &pvc)
		if err != nil || !ok {
			continue
		}
		if _, dup := seen[tier]; !dup {
			seen[tier] = struct{}{}
			tiers = append(tiers, tier)
		}
	}
	return tiers, nil
}

// IsExpand 判定 PVC 是否扩容（请求容量增大）。
func IsExpand(oldPVC, newPVC *corev1.PersistentVolumeClaim) bool {
	oldReq := oldPVC.Spec.Resources.Requests[corev1.ResourceStorage]
	newReq := newPVC.Spec.Resources.Requests[corev1.ResourceStorage]
	return newReq.Cmp(oldReq) > 0
}

// ReplicasDeclared 判定 PVC 是否带 replicas 声明标签（默认只提示不强拦）。
func ReplicasDeclared(pvc *corev1.PersistentVolumeClaim) bool {
	v, ok := pvc.Annotations[ReplicasAnnotation]
	if !ok {
		return false
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return false
	}
	return n >= 1
}

// SanitizedDenyMessage 生成面向租户的脱敏拒绝信息（不含节点/VG 名等内部细节）。
func SanitizedDenyMessage(tier string) string {
	return fmt.Sprintf("该存储等级（%s）当前暂无可用容量节点，请稍后重试或联系管理员", tier)
}

// RetireInFlight 判定 StorageNodeOps 是否处于 retire 流程进行中（validate→wipe 之间）。
func RetireInFlight(ops *storagev1alpha1.StorageNodeOps) bool {
	if ops.Spec.Operation != storagev1alpha1.NodeOpRetire {
		return false
	}
	switch ops.Status.Phase {
	case storagev1alpha1.NodeOpsValidate, storagev1alpha1.NodeOpsDrain,
		storagev1alpha1.NodeOpsWaitPVCCleanup, storagev1alpha1.NodeOpsWipe:
		return true
	}
	return false
}

// CountInUsePVs 统计某节点上仍 Bound 的 PV 数（按 controller.PVNodeAnnotation 注解）。
func CountInUsePVs(ctx context.Context, r client.Reader, nodeName string) (int, error) {
	var pvs corev1.PersistentVolumeList
	if err := r.List(ctx, &pvs); err != nil {
		return 0, err
	}
	n := 0
	for i := range pvs.Items {
		pv := &pvs.Items[i]
		if pv.Annotations[controller.PVNodeAnnotation] != nodeName {
			continue
		}
		if pv.Status.Phase == corev1.VolumeBound {
			n++
		}
	}
	return n, nil
}
