package controller

import (
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// NodeDiagnostic 是节点诊断快照（设计 §4.3 doctor，控制面聚合侧）。
//
// agent 侧负责打包 lvm 状态、agent 日志、任务历史与对账结果；
// 本结构汇总控制面已掌握的 CR 状态，供诊断报告与 UI 展示。
type NodeDiagnostic struct {
	Node      string
	Ready     bool
	VGCount   int
	VGSummary []string
	OpsOpen   int
	TasksOpen int
	Issues    []string
}

// CompileNodeDiagnostic 聚合节点相关的 CR 状态为诊断摘要。
func CompileNodeDiagnostic(node *corev1.Node, vgs []storagev1alpha1.NodeVG, ops []storagev1alpha1.StorageNodeOps, tasks []storagev1alpha1.StorageTask) NodeDiagnostic {
	d := NodeDiagnostic{}
	if node != nil {
		d.Node = node.Name
		for _, c := range node.Status.Conditions {
			if c.Type == corev1.NodeReady {
				d.Ready = c.Status == corev1.ConditionTrue
			}
		}
	}
	for _, vg := range vgs {
		if vg.Spec.NodeName != d.Node {
			continue
		}
		d.VGCount++
		st := "n/a"
		if vg.Status.CapacityStatus != "" {
			st = string(vg.Status.CapacityStatus)
		}
		d.VGSummary = append(d.VGSummary, fmt.Sprintf("%s:%s free=%d", vg.Name, st, vg.Status.FreeBytes))
	}
	for _, o := range ops {
		if o.Spec.NodeName == d.Node && o.Status.Phase != storagev1alpha1.NodeOpsDone {
			d.OpsOpen++
		}
	}
	for _, t := range tasks {
		if t.Spec.NodeName == d.Node && t.Status.Phase != storagev1alpha1.TaskSucceeded && t.Status.Phase != storagev1alpha1.TaskFailed {
			d.TasksOpen++
		}
	}
	if !d.Ready {
		d.Issues = append(d.Issues, "node not ready")
	}
	if d.OpsOpen > 0 {
		d.Issues = append(d.Issues, fmt.Sprintf("%d open node ops", d.OpsOpen))
	}
	if d.TasksOpen > 0 {
		d.Issues = append(d.Issues, fmt.Sprintf("%d open storage tasks", d.TasksOpen))
	}
	return d
}

// Summary 生成人类可读的诊断摘要文本。
func (d NodeDiagnostic) Summary() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Node %s ready=%v vgs=%d openOps=%d openTasks=%d\n", d.Node, d.Ready, d.VGCount, d.OpsOpen, d.TasksOpen)
	for _, s := range d.VGSummary {
		fmt.Fprintf(&b, "  vg %s\n", s)
	}
	if len(d.Issues) > 0 {
		fmt.Fprintf(&b, "issues: %s\n", strings.Join(d.Issues, "; "))
	} else {
		fmt.Fprintf(&b, "issues: none\n")
	}
	return b.String()
}
