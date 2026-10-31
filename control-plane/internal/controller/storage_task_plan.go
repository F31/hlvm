package controller

import (
	"context"
	"fmt"

	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// 标签键：建立 StorageTask 与拥有者（NodeDisk/NodeVG）的归属关系，并标记结果是否已回写。
const (
	// LabelOwnerKind 取值 NodeDisk | NodeVG，标识 StorageTask 由谁下发、结果回写给谁。
	LabelOwnerKind = "hlvm.storage/owner-kind"
	// LabelOwnerName 拥有者对象名。
	LabelOwnerName = "hlvm.storage/owner-name"
	// LabelVGRef 仅用于 disk pvcreate 任务：pvcreate 后盘归属的 VG（由 vg-ctrl 标注）。
	LabelVGRef = "hlvm.storage/vg-ref"
	// LabelResultApplied 标记 StorageTask 终态结果已回写拥有者状态，防止重复回写。
	LabelResultApplied = "hlvm.storage/result-applied"
	// LabelTaskOperator 标记下发/审批该破坏性任务的 operator（人工审批者或系统），用于审计（§4.1/§4.3）。
	LabelTaskOperator = "hlvm.storage/operator"
)

// DesiredStorageTasksForDisk 计算某 NodeDisk 应下发的 StorageTask（当前仅纳管路径：wipe→pvcreate）。
// 返回 nil 表示无需下发。任务名稳定（disk-<name>-<type>），配合 agent 的 taskID 幂等去重。
func DesiredStorageTasksForDisk(disk storagev1beta1.NodeDisk) *storagev1alpha1.StorageTask {
	if !disk.Spec.Adopt {
		return nil
	}
	switch disk.Status.Phase {
	case storagev1beta1.DiskPhaseInVG, storagev1beta1.DiskPhaseRemoved:
		return nil // 已纳管或已退役，不再下发
	}
	if disk.Status.Identity.ByID == "" {
		return nil // 身份尚未由 agent 采集，不下发（避免误选盘）
	}

	base := metav1.ObjectMeta{
		Labels: map[string]string{
			LabelOwnerKind: "NodeDisk",
			LabelOwnerName: disk.Name,
		},
	}
	task := storagev1alpha1.StorageTask{
		ObjectMeta: base,
		Spec: storagev1alpha1.StorageTaskSpec{
			NodeName:      disk.Spec.NodeName,
			Type:          storagev1alpha1.TaskPVCreate,
			Target:        storagev1alpha1.TaskTarget{DiskRef: disk.Name},
			ConfirmSerial: disk.Spec.ConfirmSerial,
		},
	}
	if disk.Spec.WipePolicy == storagev1beta1.WipeZero || disk.Spec.WipePolicy == storagev1beta1.WipeSecureErase {
		// 需要擦除时先发 wipe（破坏性，审批由 webhook 把关，这里仅构造指令）。
		task.Name = fmt.Sprintf("disk-%s-wipe", disk.Name)
		task.Spec.Type = storagev1alpha1.TaskWipe
	} else {
		task.Name = fmt.Sprintf("disk-%s-pvcreate", disk.Name)
	}
	return &task
}

// DesiredStorageTasksForVG 计算某 NodeVG 应下发的 StorageTask（vgcreate / vgreduce）。
// removeApproved 为删盘保护已批准的盘（由调用方传入，保证不下发被阻塞的盘）。
func DesiredStorageTasksForVG(vg storagev1alpha1.NodeVG, removeApproved []string) []storagev1alpha1.StorageTask {
	var tasks []storagev1alpha1.StorageTask
	base := metav1.ObjectMeta{
		Labels: map[string]string{
			LabelOwnerKind: "NodeVG",
			LabelOwnerName: vg.Name,
		},
	}

	if !vg.Status.VGExists && len(vg.Spec.Disks) > 0 {
		t := storagev1alpha1.StorageTask{
			ObjectMeta: metav1.ObjectMeta{
				Name:   fmt.Sprintf("vg-%s-vgcreate", vg.Name),
				Labels: base.Labels,
			},
			Spec: storagev1alpha1.StorageTaskSpec{
				NodeName: vg.Spec.NodeName,
				Type:     storagev1alpha1.TaskVGCreate,
				Disks:    append([]string(nil), vg.Spec.Disks...),
			},
		}
		tasks = append(tasks, t)
	}

	for i, d := range removeApproved {
		t := storagev1alpha1.StorageTask{
			ObjectMeta: metav1.ObjectMeta{
				Name:   fmt.Sprintf("vg-%s-vgreduce-%d", vg.Name, i),
				Labels: base.Labels,
			},
			Spec: storagev1alpha1.StorageTaskSpec{
				NodeName: vg.Spec.NodeName,
				Type:     storagev1alpha1.TaskVGReduce,
				Disks:    []string{d},
			},
		}
		tasks = append(tasks, t)
	}
	return tasks
}

// ensureStorageTask 幂等创建 StorageTask（按名 get-or-create），已存在则不动。
//
// 归属语义（ADR-006）：
//   - 任务持有拥有者（NodeVG / NodeDisk）的**非 controller** ownerReference，拥有者删除后由 K8s GC 回收。
//     这既避免孤儿任务堆积，也阻断误执行——指向已删除对象的 wipe / vgcreate 任务不应再被 agent 消费。
//   - 不使用 ttlSecondsAfterFinished 式清理：任务名稳定，desired-state 控制器在任务缺失时会立即重建同名任务，
//     删除→重建会形成抖动；终态任务的自然保留期等于拥有者生命周期。审计不依赖任务对象
//     （写操作审计经 Event + K8s audit log，见 audit.go 与设计 §4.1）。
//   - 已存在但缺 ownerReference 的旧任务就地补写一次（旧版本升级后的自愈，避免遗留孤儿）。
func ensureStorageTask(ctx context.Context, c client.Client, desired storagev1alpha1.StorageTask, owner client.Object) (bool, error) {
	var ref *metav1.OwnerReference
	if len(desired.OwnerReferences) == 0 {
		if r, ok := nonControllerOwnerRef(owner); ok {
			desired.OwnerReferences = []metav1.OwnerReference{r}
			ref = &desired.OwnerReferences[0]
		}
	}
	var existing storagev1alpha1.StorageTask
	err := c.Get(ctx, types.NamespacedName{Name: desired.Name}, &existing)
	if err == nil {
		// 旧版本创建的任务没有 ownerReference：就地补写（一次性自愈，避免升级后遗留孤儿）。
		if ref != nil && len(existing.OwnerReferences) == 0 {
			existing.OwnerReferences = []metav1.OwnerReference{*ref}
			if uerr := c.Update(ctx, &existing); uerr != nil {
				return false, uerr
			}
		}
		return false, nil
	}
	if client.IgnoreNotFound(err) != nil {
		return false, err
	}
	if err := c.Create(ctx, &desired); err != nil {
		if client.IgnoreAlreadyExists(err) != nil {
			return false, err
		}
		return false, nil
	}
	return true, nil
}

// nonControllerOwnerRef 构造拥有者的**非 controller** ownerReference。
//
// 非 controller 的理由：任务归属只用于 GC，不用于 controller-runtime 的 Owns 级联；
// 且 StorageTask 与拥有者是不同控制器各自的产物，不应抢占 controller 槽位（一个对象只能有一个 controller owner）。
// 无 UID 的对象（如 fake client 直接构造、或尚未持久化）无法作为合法 owner，返回 ok=false。
func nonControllerOwnerRef(owner client.Object) (metav1.OwnerReference, bool) {
	if owner == nil || owner.GetUID() == "" {
		return metav1.OwnerReference{}, false
	}
	var kind, apiVersion string
	switch owner.(type) {
	case *storagev1alpha1.NodeVG:
		kind = "NodeVG"
		apiVersion = storagev1alpha1.GroupVersion.String()
	case *storagev1beta1.NodeDisk:
		kind = "NodeDisk"
		// ownerReference 的 APIVersion 必须与拥有者实际落盘的存储版本一致：
		// NodeDisk 已收敛到 v1beta1(storage)，NodeVG 仍是 v1alpha1。K8s GC 依赖此字段定位 owner。
		apiVersion = storagev1beta1.GroupVersion.String()
	default:
		return metav1.OwnerReference{}, false
	}
	controller := false
	blockOwnerDeletion := false
	return metav1.OwnerReference{
		APIVersion:         apiVersion,
		Kind:               kind,
		Name:               owner.GetName(),
		UID:                owner.GetUID(),
		Controller:         &controller,
		BlockOwnerDeletion: &blockOwnerDeletion,
	}, true
}

// ApplyTaskResultToDisk 将 StorageTask 终态结果回写到 NodeDisk 状态。
// 单写者原则：仅控制面写 CRD status，agent 只写 StorageTask 状态。返回 (更新后对象, 是否变化)。
func ApplyTaskResultToDisk(disk storagev1beta1.NodeDisk, task storagev1alpha1.StorageTask) (storagev1beta1.NodeDisk, bool) {
	switch task.Spec.Type {
	case storagev1alpha1.TaskPVCreate, storagev1alpha1.TaskWipe:
		switch task.Status.Phase {
		case storagev1alpha1.TaskSucceeded:
			if disk.Status.Phase != storagev1beta1.DiskPhaseInVG {
				disk.Status.Phase = storagev1beta1.DiskPhaseInVG
				if vg := task.Labels[LabelVGRef]; vg != "" {
					disk.Status.VgRef = vg
				}
				apimeta.SetStatusCondition(&disk.Status.Conditions, metav1.Condition{
					Type: "Adoption", Status: metav1.ConditionTrue, Reason: "TaskSucceeded",
					Message: fmt.Sprintf("task %s succeeded", task.Name),
				})
				return disk, true
			}
		case storagev1alpha1.TaskFailed:
			if apimeta.SetStatusCondition(&disk.Status.Conditions, metav1.Condition{
				Type: "Adoption", Status: metav1.ConditionFalse, Reason: "TaskFailed",
				Message: fmt.Sprintf("task %s failed: %s", task.Name, task.Status.Result),
			}) {
				return disk, true
			}
		}
	}
	return disk, false
}

// ApplyTaskResultToVG 将 StorageTask 终态结果回写到 NodeVG 状态。返回 (更新后对象, 是否变化)。
func ApplyTaskResultToVG(vg storagev1alpha1.NodeVG, task storagev1alpha1.StorageTask) (storagev1alpha1.NodeVG, bool) {
	switch task.Spec.Type {
	case storagev1alpha1.TaskVGCreate:
		if task.Status.Phase == storagev1alpha1.TaskSucceeded {
			if !vg.Status.VGExists {
				vg.Status.VGExists = true
				apimeta.SetStatusCondition(&vg.Status.Conditions, metav1.Condition{
					Type: "VGReady", Status: metav1.ConditionTrue, Reason: "TaskSucceeded",
					Message: fmt.Sprintf("task %s succeeded", task.Name),
				})
				return vg, true
			}
		} else if task.Status.Phase == storagev1alpha1.TaskFailed {
			if apimeta.SetStatusCondition(&vg.Status.Conditions, metav1.Condition{
				Type: "VGReady", Status: metav1.ConditionFalse, Reason: "TaskFailed",
				Message: fmt.Sprintf("task %s failed: %s", task.Name, task.Status.Result),
			}) {
				return vg, true
			}
		}
	case storagev1alpha1.TaskVGReduce:
		if task.Status.Phase == storagev1alpha1.TaskSucceeded {
			// 成功移除后清掉该盘的 pendingOps 原因（若存在）。
			removed := task.Spec.Disks
			changed := false
			if len(removed) > 0 && len(vg.Status.PendingOps) > 0 {
				filtered := vg.Status.PendingOps[:0]
				for _, op := range vg.Status.PendingOps {
					hit := false
					for _, d := range removed {
						if contains(op, d) {
							hit = true
							break
						}
					}
					if !hit {
						filtered = append(filtered, op)
					}
				}
				if len(filtered) != len(vg.Status.PendingOps) {
					vg.Status.PendingOps = filtered
					changed = true
				}
			}
			return vg, changed
		}
	}
	return vg, false
}

func contains(s, sub string) bool {
	return len(sub) > 0 && len(s) >= len(sub) && (s == sub || indexOf(s, sub) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
