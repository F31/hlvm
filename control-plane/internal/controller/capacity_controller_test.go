package controller

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// fakeClientWithNodes 在共享 scheme 基础上额外容纳 Node（用于锁标签 patch 验证）。
func fakeClientWithNodes(objs ...client.Object) client.Client {
	return fake.NewClientBuilder().WithScheme(testScheme()).
		WithStatusSubresource(&storagev1alpha1.NodeVG{}, &storagev1alpha1.NodeDisk{}).
		WithObjects(objs...).Build()
}

func newVG(name, node, tier string, dataPct, metaPct float64, oos bool, cur storagev1alpha1.CapacityStatus) storagev1alpha1.NodeVG {
	return storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: storagev1alpha1.VGSpec{
			NodeName: node,
			Tier:     tier,
		},
		Status: storagev1alpha1.VGStatus{
			CapacityStatus: cur,
			ThinPool: storagev1alpha1.VGThinPoolStatus{
				DataPercent:      dataPct,
				MetadataPercent:  metaPct,
				OutOfSpace:       oos,
			},
		},
	}
}

func defaultPolicy() storagev1alpha1.ThinPoolPolicy {
	return storagev1alpha1.ThinPoolPolicy{
		ObjectMeta: metav1.ObjectMeta{Name: PolicySingletonName},
		Spec:       storagev1alpha1.ThinPoolPolicySpec{Thresholds: DefaultThresholds()},
	}
}

func newNode(name string, labels map[string]string) corev1.Node {
	return corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels}}
}

func TestCapacityReconciler_LocksAndLabelsNode(t *testing.T) {
	vg := newVG("vg1", "n1", "nvme", 90, 10, false, storagev1alpha1.CapacityAvailable)
	policy := defaultPolicy()
	node := newNode("n1", nil)
	c := fakeClientWithNodes(&vg, &policy, &node)

	r := &CapacityReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)
	if got.Status.CapacityStatus != storagev1alpha1.CapacityLocked {
		t.Fatalf("expected locked, got %s", got.Status.CapacityStatus)
	}
	var gotNode corev1.Node
	_ = c.Get(context.Background(), client.ObjectKey{Name: "n1"}, &gotNode)
	if gotNode.Labels[LockLabelName("nvme")] != "true" {
		t.Fatalf("expected node lock label, got %v", gotNode.Labels)
	}
}

func TestCapacityReconciler_HysteresisUnlock(t *testing.T) {
	// 当前已锁定，data 回落到 70（< unlock 80），metadata 10（< 75）→ 应解锁为 Available 并摘除标签。
	vg := newVG("vg1", "n1", "nvme", 70, 10, false, storagev1alpha1.CapacityLocked)
	policy := defaultPolicy()
	node := newNode("n1", map[string]string{LockLabelName("nvme"): "true"})
	c := fakeClientWithNodes(&vg, &policy, &node)

	r := &CapacityReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)
	if got.Status.CapacityStatus != storagev1alpha1.CapacityAvailable {
		t.Fatalf("expected available after unlock, got %s", got.Status.CapacityStatus)
	}
	var gotNode corev1.Node
	_ = c.Get(context.Background(), client.ObjectKey{Name: "n1"}, &gotNode)
	if _, ok := gotNode.Labels[LockLabelName("nvme")]; ok {
		t.Fatalf("expected lock label removed, got %v", gotNode.Labels)
	}
}

func TestCapacityReconciler_MissingPolicyUsesDefaults(t *testing.T) {
	// 无 ThinPoolPolicy：应回退默认阈值（data=90 → locked），且不报错。
	vg := newVG("vg1", "n1", "nvme", 90, 10, false, storagev1alpha1.CapacityAvailable)
	node := newNode("n1", nil)
	c := fakeClientWithNodes(&vg, &node)

	r := &CapacityReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err (missing policy should not fail): %v", err)
	}

	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)
	if got.Status.CapacityStatus != storagev1alpha1.CapacityLocked {
		t.Fatalf("expected locked with default thresholds, got %s", got.Status.CapacityStatus)
	}
}

func TestCapacityReconciler_NodeMissingIsNoOp(t *testing.T) {
	// 节点不存在时锁标签应静默跳过，不阻断容量状态落盘。
	vg := newVG("vg1", "n1", "nvme", 90, 10, false, storagev1alpha1.CapacityAvailable)
	policy := defaultPolicy()
	c := fakeClientWithNodes(&vg, &policy)

	r := &CapacityReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err (missing node should not fail): %v", err)
	}
	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)
	if got.Status.CapacityStatus != storagev1alpha1.CapacityLocked {
		t.Fatalf("expected locked, got %s", got.Status.CapacityStatus)
	}
}

func TestCapacityReconciler_NoStatusChangeWhenStable(t *testing.T) {
	// 稳态（data=50 → available，当前已 available）应无需写 status（幂等）。
	vg := newVG("vg1", "n1", "nvme", 50, 10, false, storagev1alpha1.CapacityAvailable)
	policy := defaultPolicy()
	node := newNode("n1", nil)
	c := fakeClientWithNodes(&vg, &policy, &node)

	r := &CapacityReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var gotNode corev1.Node
	_ = c.Get(context.Background(), client.ObjectKey{Name: "n1"}, &gotNode)
	if _, ok := gotNode.Labels[LockLabelName("nvme")]; ok {
		t.Fatalf("stable available should not set lock label, got %v", gotNode.Labels)
	}
}
