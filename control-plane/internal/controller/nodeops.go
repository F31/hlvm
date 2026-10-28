package controller

import (
	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// NodeIsolatedLabel 是 isolate 操作打的"存储故障"节点标签（非 NoSchedule 污点，§1.3）。
// 由 add-admission-scheduling 的调度约束消费，排除被隔离节点的新 Pod 调度。
const NodeIsolatedLabel = "storage.example.io/storage-isolated"

// PVNodeAnnotation 标记 PV 所属节点（由动态供给/agent 写入），供 retire 阻塞判定（§3.5/§9.2）。
const PVNodeAnnotation = "hlvm.dev/node"

// NextNodeOpsPhase 推进 StorageNodeOps 状态机（设计 §3.5 / §9）。
//
// 线性推进：validate → drain → wait-pvc-cleanup → wipe → done。
//   - retire：drain 后进入 wait-pvc-cleanup；存在未清理 PVC（blockingCount>0）时停在 wait-pvc-cleanup
//     （除非 force）；无阻塞后进入 wipe（wipe 经 StorageTask 下发，由 M8b 完成后推进到 done）。
//   - isolate：validate 后即 done（仅打节点标签，无 PVC 阻塞概念）。
//   - recover-disk：需人工确认（force）才推进到 done，否则停在 validate（不自动迁移数据）。
func NextNodeOpsPhase(op storagev1alpha1.NodeOperation, phase storagev1alpha1.NodeOpsPhase, blockingCount int, force bool) storagev1alpha1.NodeOpsPhase {
	switch op {
	case storagev1alpha1.NodeOpIsolate:
		if phase == "" || phase == storagev1alpha1.NodeOpsValidate {
			return storagev1alpha1.NodeOpsDone
		}
		return phase
	case storagev1alpha1.NodeOpRecoverDisk:
		if phase == "" {
			return storagev1alpha1.NodeOpsValidate
		}
		if force {
			return storagev1alpha1.NodeOpsDone
		}
		return phase
	case storagev1alpha1.NodeOpRetire:
		switch phase {
		case "", storagev1alpha1.NodeOpsValidate:
			return storagev1alpha1.NodeOpsDrain
		case storagev1alpha1.NodeOpsDrain:
			return storagev1alpha1.NodeOpsWaitPVCCleanup
		case storagev1alpha1.NodeOpsWaitPVCCleanup:
			if blockingCount == 0 || force {
				return storagev1alpha1.NodeOpsWipe
			}
			return storagev1alpha1.NodeOpsWaitPVCCleanup
		case storagev1alpha1.NodeOpsWipe:
			// M8：wipe 由 StorageTask 执行；M8b 完成后推进到 done。
			return storagev1alpha1.NodeOpsWipe
		case storagev1alpha1.NodeOpsDone:
			return storagev1alpha1.NodeOpsDone
		default:
			return phase
		}
	default:
		return phase
	}
}
