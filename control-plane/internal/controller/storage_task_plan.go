package controller

import (
	"context"
	"fmt"

	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
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
func DesiredStorageTasksForDisk(disk storagev1alpha1.NodeDisk) *storagev1alpha1.StorageTask {
	if !disk.Spec.Adopt {
		return nil
	}
	switch disk.Status.Phase {
	case storagev1alpha1.DiskPhaseInVG, storagev1alpha1.DiskPhaseRemoved:
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
	if disk.Spec.WipePolicy == storagev1alpha1.WipeZero || disk.Spec.WipePolicy == storagev1alpha1.WipeSecureErase {
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
func ensureStorageTask(ctx context.Context, c client.Client, desired storagev1alpha1.StorageTask) (bool, error) {
	var existing storagev1alpha1.StorageTask
	err := c.Get(ctx, types.NamespacedName{Name: desired.Name}, &existing)
	if err == nil {
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

// ApplyTaskResultToDisk 将 StorageTask 终态结果回写到 NodeDisk 状态。
// 单写者原则：仅控制面写 CRD status，agent 只写 StorageTask 状态。返回 (更新后对象, 是否变化)。
func ApplyTaskResultToDisk(disk storagev1alpha1.NodeDisk, task storagev1alpha1.StorageTask) (storagev1alpha1.NodeDisk, bool) {
	switch task.Spec.Type {
	case storagev1alpha1.TaskPVCreate, storagev1alpha1.TaskWipe:
		switch task.Status.Phase {
		case storagev1alpha1.TaskSucceeded:
			if disk.Status.Phase != storagev1alpha1.DiskPhaseInVG {
				disk.Status.Phase = storagev1alpha1.DiskPhaseInVG
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
