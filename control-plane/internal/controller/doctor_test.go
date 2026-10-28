package controller

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func TestCompileNodeDiagnostic(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "n1"},
		Status: corev1.NodeStatus{Conditions: []corev1.NodeCondition{
			{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
		}},
	}
	vg := storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-n1"},
		Spec:       storagev1alpha1.VGSpec{NodeName: "n1"},
		Status:     storagev1alpha1.VGStatus{CapacityStatus: storagev1alpha1.CapacityAvailable, FreeBytes: 100},
	}
	ops := []storagev1alpha1.StorageNodeOps{
		{Spec: storagev1alpha1.StorageNodeOpsSpec{NodeName: "n1"}, Status: storagev1alpha1.StorageNodeOpsStatus{Phase: storagev1alpha1.NodeOpsWipe}},
	}
	d := CompileNodeDiagnostic(node, []storagev1alpha1.NodeVG{vg}, ops, nil)
	if d.Node != "n1" || !d.Ready || d.VGCount != 1 || d.OpsOpen != 1 {
		t.Fatalf("诊断聚合不符：%+v", d)
	}
	if !strContains(d.Summary(), "ready=true") || !strContains(d.Summary(), "vg-n1") {
		t.Fatalf("诊断摘要应含节点与 VG 信息，got %q", d.Summary())
	}

	// 节点 NotReady 应进入 issues。
	nodeNotReady := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "n2"},
		Status: corev1.NodeStatus{Conditions: []corev1.NodeCondition{
			{Type: corev1.NodeReady, Status: corev1.ConditionFalse},
		}},
	}
	d2 := CompileNodeDiagnostic(nodeNotReady, nil, nil, nil)
	if d2.Ready || len(d2.Issues) == 0 {
		t.Fatalf("NotReady 节点应标记 issue，got %+v", d2)
	}
}
