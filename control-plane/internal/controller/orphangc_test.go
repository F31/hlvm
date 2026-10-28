package controller

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
)

func TestFindReleasedRetainPVs(t *testing.T) {
	pvs := []corev1.PersistentVolume{
		{Status: corev1.PersistentVolumeStatus{Phase: corev1.VolumeReleased}, Spec: corev1.PersistentVolumeSpec{PersistentVolumeReclaimPolicy: corev1.PersistentVolumeReclaimRetain}},
		{Status: corev1.PersistentVolumeStatus{Phase: corev1.VolumeReleased}, Spec: corev1.PersistentVolumeSpec{PersistentVolumeReclaimPolicy: corev1.PersistentVolumeReclaimDelete}},
		{Status: corev1.PersistentVolumeStatus{Phase: corev1.VolumeBound}, Spec: corev1.PersistentVolumeSpec{PersistentVolumeReclaimPolicy: corev1.PersistentVolumeReclaimRetain}},
	}
	got := FindReleasedRetainPVs(pvs)
	if len(got) != 1 {
		t.Fatalf("应仅 1 个 Retain+Released PV，got %d", len(got))
	}
}

func TestFindOrphanLVs(t *testing.T) {
	managed := []ManagedLV{
		{Node: "n1", VG: "vg1", Name: "lv-a"},
		{Node: "n1", VG: "vg1", Name: "lv-b"},
	}
	actual := []ActualLV{
		{Node: "n1", VG: "vg1", Name: "lv-a"},     // 有账面
		{Node: "n1", VG: "vg1", Name: "lv-manual"}, // 孤儿
	}
	got := FindOrphanLVs(managed, actual)
	if len(got) != 1 || got[0].Name != "lv-manual" {
		t.Fatalf("应发现 1 个孤儿 LV lv-manual，got %+v", got)
	}
	// managed 为空时不误报。
	if got := FindOrphanLVs(nil, actual); len(got) != 0 {
		t.Fatalf("managed 为空不应误报，got %+v", got)
	}
}
