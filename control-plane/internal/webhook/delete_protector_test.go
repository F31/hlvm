package webhook

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	controller "github.com/F31/hlvm/control-plane/internal/controller"
)

func newDeleteProtectorWith(objs ...client.Object) *DeleteProtector {
	scheme := testScheme()
	b := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...)
	return &DeleteProtector{Reader: b.Build()}
}

func retireOps(nodeName string, phase storagev1alpha1.NodeOpsPhase) *storagev1alpha1.StorageNodeOps {
	return &storagev1alpha1.StorageNodeOps{
		ObjectMeta: metav1.ObjectMeta{Name: "retire-" + nodeName},
		Spec:       storagev1alpha1.StorageNodeOpsSpec{NodeName: nodeName, Operation: storagev1alpha1.NodeOpRetire},
		Status:     storagev1alpha1.StorageNodeOpsStatus{Phase: phase},
	}
}

func boundPVOnNode(name, node string) *corev1.PersistentVolume {
	return &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: name, Annotations: map[string]string{controller.PVNodeAnnotation: node}},
		Status:     corev1.PersistentVolumeStatus{Phase: corev1.VolumeBound},
	}
}

func TestDeleteProtector_DenyWhenRetireInFlightWithPV(t *testing.T) {
	ops := retireOps("n1", storagev1alpha1.NodeOpsWaitPVCCleanup)
	pv := boundPVOnNode("pv-1", "n1")
	// 被删对象：n1 的 NodeVG。
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityAvailable)
	vg.Spec.NodeName = "n1"
	v := newDeleteProtectorWith(ops, pv, &vg)

	if _, err := v.ValidateDelete(context.Background(), &vg); err == nil {
		t.Fatal("retire 在飞且节点有在用 PV 应拒绝删除 NodeVG")
	}
}

func TestDeleteProtector_AllowWhenNoInUsePV(t *testing.T) {
	ops := retireOps("n1", storagev1alpha1.NodeOpsWaitPVCCleanup)
	// PV 已 Released（不在用）。
	pv := boundPVOnNode("pv-1", "n1")
	pv.Status.Phase = corev1.VolumeReleased
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityAvailable)
	vg.Spec.NodeName = "n1"
	v := newDeleteProtectorWith(ops, pv, &vg)

	if _, err := v.ValidateDelete(context.Background(), &vg); err != nil {
		t.Fatalf("retire 在飞但无在用 PV 应允许删除，got %v", err)
	}
}

func TestDeleteProtector_AllowWhenRetireDone(t *testing.T) {
	ops := retireOps("n1", storagev1alpha1.NodeOpsDone)
	pv := boundPVOnNode("pv-1", "n1")
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityAvailable)
	vg.Spec.NodeName = "n1"
	v := newDeleteProtectorWith(ops, pv, &vg)

	if _, err := v.ValidateDelete(context.Background(), &vg); err != nil {
		t.Fatalf("retire 已完成应允许删除，got %v", err)
	}
}

func TestDeleteProtector_DenyStorageNodeOpsDelete(t *testing.T) {
	ops := retireOps("n1", storagev1alpha1.NodeOpsWaitPVCCleanup)
	pv := boundPVOnNode("pv-1", "n1")
	v := newDeleteProtectorWith(ops, pv)

	if _, err := v.ValidateDelete(context.Background(), ops); err == nil {
		t.Fatal("retire 在飞且有在用 PV 时删除 StorageNodeOps 应被拒绝（丢失保护）")
	}
}
