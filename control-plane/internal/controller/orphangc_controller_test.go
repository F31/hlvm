package controller

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func strContains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestOrphanGCReconciler_FindsReleasedRetainPV(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = storagev1alpha1.AddToScheme(scheme)

	pv := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: "pv-orphan"},
		Spec: corev1.PersistentVolumeSpec{
			PersistentVolumeReclaimPolicy: corev1.PersistentVolumeReclaimRetain,
			Capacity: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("10Gi")},
		},
		Status: corev1.PersistentVolumeStatus{Phase: corev1.VolumeReleased},
	}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(pv).Build()
	r := &OrphanGCReconciler{Client: c, Scheme: scheme, Recorder: rec}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "pv-orphan"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case e := <-rec.Events:
		// 事件对象本身即 PV（recorder 自动带上 object 引用），消息含 reason=OrphanPV 与容量。
		if !strContains(e, "OrphanPV") || !strContains(e, "10Gi") {
			t.Fatalf("应产生 OrphanPV 告警事件并含容量，got %q", e)
		}
	default:
		t.Fatal("应产生孤儿 PV 告警事件")
	}
}

func TestOrphanGCReconciler_NoFalsePositive(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = storagev1alpha1.AddToScheme(scheme)

	// Bound PV（非 Released）不应触发告警。
	pv := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: "pv-bound"},
		Spec: corev1.PersistentVolumeSpec{
			PersistentVolumeReclaimPolicy: corev1.PersistentVolumeReclaimRetain,
			Capacity: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("10Gi")},
		},
		Status: corev1.PersistentVolumeStatus{Phase: corev1.VolumeBound},
	}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(pv).Build()
	r := &OrphanGCReconciler{Client: c, Scheme: scheme, Recorder: rec}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "pv-bound"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("Bound PV 不应产生孤儿告警，got %q", e)
	default:
		// 期望无事件。
	}
}
