package controller

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func nodeOpsScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(s)
	_ = storagev1alpha1.AddToScheme(s)
	return s
}

func newNodeForOps(name string, labels map[string]string, unschedulable bool) corev1.Node {
	return corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels},
		Spec:       corev1.NodeSpec{Unschedulable: unschedulable},
	}
}

func boundPV(name, node, ns, claim string) corev1.PersistentVolume {
	return corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{
			Name:        name,
			Annotations: map[string]string{PVNodeAnnotation: node},
		},
		Spec: corev1.PersistentVolumeSpec{
			ClaimRef: &corev1.ObjectReference{Namespace: ns, Name: claim},
		},
		Status: corev1.PersistentVolumeStatus{Phase: corev1.VolumeBound},
	}
}

func TestNextNodeOpsPhase(t *testing.T) {
	cases := []struct {
		name    string
		op      storagev1alpha1.NodeOperation
		phase   storagev1alpha1.NodeOpsPhase
		blocking int
		force   bool
		want    storagev1alpha1.NodeOpsPhase
	}{
		// isolate：validate 直收。
		{"isolate validate->done", storagev1alpha1.NodeOpIsolate, storagev1alpha1.NodeOpsValidate, 0, false, storagev1alpha1.NodeOpsDone},
		{"isolate empty->done", storagev1alpha1.NodeOpIsolate, "", 0, false, storagev1alpha1.NodeOpsDone},
		// recover-disk：无 force 停在 validate；force 收口。
		{"recover no-force stays validate", storagev1alpha1.NodeOpRecoverDisk, "", 0, false, storagev1alpha1.NodeOpsValidate},
		{"recover force->done", storagev1alpha1.NodeOpRecoverDisk, storagev1alpha1.NodeOpsValidate, 0, true, storagev1alpha1.NodeOpsDone},
		// retire：validate->drain->wait-pvc-cleanup。
		{"retire empty->drain", storagev1alpha1.NodeOpRetire, "", 0, false, storagev1alpha1.NodeOpsDrain},
		{"retire drain->wait", storagev1alpha1.NodeOpRetire, storagev1alpha1.NodeOpsDrain, 0, false, storagev1alpha1.NodeOpsWaitPVCCleanup},
		{"retire wait with blockers stays", storagev1alpha1.NodeOpRetire, storagev1alpha1.NodeOpsWaitPVCCleanup, 2, false, storagev1alpha1.NodeOpsWaitPVCCleanup},
		{"retire wait no blockers->wipe", storagev1alpha1.NodeOpRetire, storagev1alpha1.NodeOpsWaitPVCCleanup, 0, false, storagev1alpha1.NodeOpsWipe},
		{"retire wait force->wipe", storagev1alpha1.NodeOpRetire, storagev1alpha1.NodeOpsWaitPVCCleanup, 3, true, storagev1alpha1.NodeOpsWipe},
		{"retire wipe stays (M8b completes)", storagev1alpha1.NodeOpRetire, storagev1alpha1.NodeOpsWipe, 0, false, storagev1alpha1.NodeOpsWipe},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := NextNodeOpsPhase(c.op, c.phase, c.blocking, c.force); got != c.want {
				t.Fatalf("want %s got %s", c.want, got)
			}
		})
	}
}

func TestNodeOpsReconciler_IsolateLabelsAndDone(t *testing.T) {
	ops := newNodeForOps2("iso-1", "n1", storagev1alpha1.NodeOpIsolate, false, "")
	node := newNodeForOps("n1", nil, false)
	c := fake.NewClientBuilder().WithScheme(nodeOpsScheme()).
		WithStatusSubresource(&storagev1alpha1.StorageNodeOps{}).
		WithObjects(&ops, &node).Build()
	r := &NodeOpsReconciler{Client: c, Scheme: nodeOpsScheme()}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "iso-1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var got storagev1alpha1.StorageNodeOps
	_ = c.Get(context.Background(), client.ObjectKey{Name: "iso-1"}, &got)
	if got.Status.Phase != storagev1alpha1.NodeOpsDone {
		t.Fatalf("isolate 应到 done，got %s", got.Status.Phase)
	}
	var gotNode corev1.Node
	_ = c.Get(context.Background(), client.ObjectKey{Name: "n1"}, &gotNode)
	if gotNode.Labels[NodeIsolatedLabel] != "true" {
		t.Fatalf("isolate 应打节点故障标签，got %v", gotNode.Labels)
	}
}

func TestNodeOpsReconciler_RetireDrainCordons(t *testing.T) {
	// 起始空相位：一次 reconcile 推进到 drain 并 cordon 节点。
	ops := newNodeForOps2("ret-0", "n1", storagev1alpha1.NodeOpRetire, false, "")
	node := newNodeForOps("n1", nil, false)
	c := fake.NewClientBuilder().WithScheme(nodeOpsScheme()).
		WithStatusSubresource(&storagev1alpha1.StorageNodeOps{}).
		WithObjects(&ops, &node).Build()
	r := &NodeOpsReconciler{Client: c, Scheme: nodeOpsScheme()}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "ret-0"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var got storagev1alpha1.StorageNodeOps
	_ = c.Get(context.Background(), client.ObjectKey{Name: "ret-0"}, &got)
	if got.Status.Phase != storagev1alpha1.NodeOpsDrain {
		t.Fatalf("空相位应推进到 drain，got %s", got.Status.Phase)
	}
	var gotNode corev1.Node
	_ = c.Get(context.Background(), client.ObjectKey{Name: "n1"}, &gotNode)
	if !gotNode.Spec.Unschedulable {
		t.Fatalf("retire drain 阶段应 cordon 节点")
	}
}

func TestNodeOpsReconciler_RetireStaysAtWaitWithBlockers(t *testing.T) {
	// 起始 wait-pvc-cleanup 且有 Bound PV：停在 wait，阻塞 PVC 写入 status。
	ops := newNodeForOps2("ret-1", "n1", storagev1alpha1.NodeOpRetire, false, storagev1alpha1.NodeOpsWaitPVCCleanup)
	node := newNodeForOps("n1", nil, false)
	pv := boundPV("pv-1", "n1", "default", "mysql-data")
	c := fake.NewClientBuilder().WithScheme(nodeOpsScheme()).
		WithStatusSubresource(&storagev1alpha1.StorageNodeOps{}).
		WithObjects(&ops, &node, &pv).Build()
	r := &NodeOpsReconciler{Client: c, Scheme: nodeOpsScheme()}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "ret-1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var got storagev1alpha1.StorageNodeOps
	_ = c.Get(context.Background(), client.ObjectKey{Name: "ret-1"}, &got)
	if got.Status.Phase != storagev1alpha1.NodeOpsWaitPVCCleanup {
		t.Fatalf("有阻塞应停在 wait-pvc-cleanup，got %s", got.Status.Phase)
	}
	if len(got.Status.BlockingPVCs) != 1 || got.Status.BlockingPVCs[0] != "default/mysql-data" {
		t.Fatalf("阻塞 PVC 统计不符：%v", got.Status.BlockingPVCs)
	}
}

func TestNodeOpsReconciler_RetireNoBlockersToWipe(t *testing.T) {
	// 起始 wait-pvc-cleanup 且无 Bound PV：无阻塞 → 推进到 wipe。
	ops := newNodeForOps2("ret-2", "n1", storagev1alpha1.NodeOpRetire, false, storagev1alpha1.NodeOpsWaitPVCCleanup)
	node := newNodeForOps("n1", nil, false)
	c := fake.NewClientBuilder().WithScheme(nodeOpsScheme()).
		WithStatusSubresource(&storagev1alpha1.StorageNodeOps{}).
		WithObjects(&ops, &node).Build()
	r := &NodeOpsReconciler{Client: c, Scheme: nodeOpsScheme()}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "ret-2"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var got storagev1alpha1.StorageNodeOps
	_ = c.Get(context.Background(), client.ObjectKey{Name: "ret-2"}, &got)
	if got.Status.Phase != storagev1alpha1.NodeOpsWipe {
		t.Fatalf("无阻塞应到 wipe，got %s", got.Status.Phase)
	}
}

func TestNodeOpsReconciler_RetireFullProgression(t *testing.T) {
	// 无阻塞 retire：空相位多次 reconcile 推进到 wipe（drain→wait→wipe）。
	ops := newNodeForOps2("ret-3", "n1", storagev1alpha1.NodeOpRetire, false, "")
	node := newNodeForOps("n1", nil, false)
	c := fake.NewClientBuilder().WithScheme(nodeOpsScheme()).
		WithStatusSubresource(&storagev1alpha1.StorageNodeOps{}).
		WithObjects(&ops, &node).Build()
	r := &NodeOpsReconciler{Client: c, Scheme: nodeOpsScheme()}

	req := reconcile.Request{NamespacedName: client.ObjectKey{Name: "ret-3"}}
	for i := 0; i < 5; i++ {
		if _, err := r.Reconcile(context.Background(), req); err != nil {
			t.Fatalf("reconcile err: %v", err)
		}
	}
	var got storagev1alpha1.StorageNodeOps
	_ = c.Get(context.Background(), client.ObjectKey{Name: "ret-3"}, &got)
	if got.Status.Phase != storagev1alpha1.NodeOpsWipe {
		t.Fatalf("无阻塞 retire 应推进到 wipe，got %s", got.Status.Phase)
	}
}

func TestNodeOpsReconciler_RecoverDiskForceGate(t *testing.T) {
	// 无 force：停在 validate；有 force：到 done。
	opsNoForce := newNodeForOps2("rec-1", "n1", storagev1alpha1.NodeOpRecoverDisk, false, storagev1alpha1.NodeOpsValidate)
	opsForce := newNodeForOps2("rec-2", "n1", storagev1alpha1.NodeOpRecoverDisk, true, storagev1alpha1.NodeOpsValidate)
	c := fake.NewClientBuilder().WithScheme(nodeOpsScheme()).
		WithStatusSubresource(&storagev1alpha1.StorageNodeOps{}).
		WithObjects(&opsNoForce, &opsForce).Build()
	r := &NodeOpsReconciler{Client: c, Scheme: nodeOpsScheme()}

	_, _ = r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "rec-1"}})
	_, _ = r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "rec-2"}})

	var noF, f storagev1alpha1.StorageNodeOps
	_ = c.Get(context.Background(), client.ObjectKey{Name: "rec-1"}, &noF)
	_ = c.Get(context.Background(), client.ObjectKey{Name: "rec-2"}, &f)
	if noF.Status.Phase != storagev1alpha1.NodeOpsValidate {
		t.Fatalf("recover 无 force 应停在 validate，got %s", noF.Status.Phase)
	}
	if f.Status.Phase != storagev1alpha1.NodeOpsDone {
		t.Fatalf("recover 有 force 应到 done，got %s", f.Status.Phase)
	}
}

// newNodeForOps2 构造 StorageNodeOps 测试对象（避免与 lvmd 测试的同名函数冲突）。
func newNodeForOps2(name, node string, op storagev1alpha1.NodeOperation, force bool, phase storagev1alpha1.NodeOpsPhase) storagev1alpha1.StorageNodeOps {
	return storagev1alpha1.StorageNodeOps{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: storagev1alpha1.StorageNodeOpsSpec{
			NodeName:  node,
			Operation: op,
			Force:     force,
		},
		Status: storagev1alpha1.StorageNodeOpsStatus{Phase: phase},
	}
}
