package controller

import (
	corev1 "k8s.io/api/core/v1"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

const (
	// topoLVMDriver 是 B 链路 CSI 驱动名；只有该驱动的动态 PV 属于本平台账面。
	topoLVMDriver = "topolvm.io"
	// topoLVMTopologyKey 是 TopoLVM 写在 PV nodeAffinity 上的节点拓扑键。
	topoLVMTopologyKey = "topology.topolvm.io/node"
	// PVVGAnnotation 标记 PV 所属 VG（由动态供给/agent 写入）。
	PVVGAnnotation = "hlvm.dev/vg"
)

// ManagedLVsFromPVs 由 PV 列表与 NodeVG 列表构造三方对账的「平台账面」侧。
//
// 真机实证（ADR-006 §15，2026-11-12，SC hlvm-b / TopoLVM v0.42.0）：
//   - PV 名是 pvc-<uid>，但宿主 lvs 里的 LV 名是 csi.volumeHandle
//     （如 9e639840-23de-403e-aebe-2335b9505816），也等于 LogicalVolume.status.volumeID；
//   - PV 上**没有** hlvm.dev/node / hlvm.dev/vg 注解，节点只在
//     spec.nodeAffinity 的 topology.topolvm.io/node=In[<node>]；
//   - VG 名 = NodeVG.metadata.name，需按 spec.nodeName 反查。
//
// 旧实现把 pv.Name 当 LV 名、把注解当唯一归属来源，后果有两层：真机上所有
// TopoLVM PV 都被跳过（managed 恒空，对账从不生效）；即使补上注解，也会同时产生
// unmanaged-lv + missing-lv 的双向误报。这里按真实字段解析，字段不全时宁可跳过，
// 绝不拿不完整信息构造账面项去制造误报。
//
// 兼容路径：非 TopoLVM CSI、但带 hlvm.dev/node 注解的 PV（hlvm 自研供给 / envtest）
// 保持历史语义 —— 账面 LV 名就是 pv.Name，VG 取 hlvm.dev/vg 注解。
func ManagedLVsFromPVs(pvs []corev1.PersistentVolume, nodeVGs []storagev1beta1.NodeVG) []ManagedLV {
	vgByNode := make(map[string]string, len(nodeVGs))
	for i := range nodeVGs {
		if n := nodeVGs[i].Spec.NodeName; n != "" {
			vgByNode[n] = nodeVGs[i].Name
		}
	}

	out := make([]ManagedLV, 0, len(pvs))
	for i := range pvs {
		pv := &pvs[i]
		csi := pv.Spec.PersistentVolumeSource.CSI
		if csi != nil && csi.Driver == topoLVMDriver && csi.VolumeHandle != "" {
			node := firstNonEmpty(pv.Annotations[PVNodeAnnotation], nodeFromTopoLVMTopology(pv))
			vg := firstNonEmpty(pv.Annotations[PVVGAnnotation], vgByNode[node])
			if node == "" || vg == "" {
				// 无节点或无可反查的 VG：lvKey 会与 actual 侧错配，跳过而不是误报。
				continue
			}
			out = append(out, ManagedLV{
				Node: node, VG: vg, Name: csi.VolumeHandle, Bytes: pvBytes(pv),
			})
			continue
		}
		if node := pv.Annotations[PVNodeAnnotation]; node != "" {
			out = append(out, ManagedLV{
				Node: node, VG: pv.Annotations[PVVGAnnotation], Name: pv.Name, Bytes: pvBytes(pv),
			})
		}
	}
	return out
}

// nodeFromTopoLVMTopology 从 PV 的 nodeAffinity 取 TopoLVM 拓扑节点。
func nodeFromTopoLVMTopology(pv *corev1.PersistentVolume) string {
	if pv.Spec.NodeAffinity == nil || pv.Spec.NodeAffinity.Required == nil {
		return ""
	}
	for _, term := range pv.Spec.NodeAffinity.Required.NodeSelectorTerms {
		for _, exp := range term.MatchExpressions {
			if exp.Key == topoLVMTopologyKey && len(exp.Values) > 0 {
				return exp.Values[0]
			}
		}
	}
	return ""
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func pvBytes(pv *corev1.PersistentVolume) int64 {
	q, ok := pv.Spec.Capacity[corev1.ResourceStorage]
	if !ok {
		return 0
	}
	return q.Value()
}
