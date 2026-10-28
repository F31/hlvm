package controller

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func testScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(s)
	_ = storagev1alpha1.AddToScheme(s)
	return s
}

// fakeClient 构造带 status 子资源声明的 fake client（controller-runtime v0.20 要求显式声明，
// 否则 Status().Update 会报 not found）。
func fakeClient(objs ...client.Object) client.Client {
	return fake.NewClientBuilder().WithScheme(testScheme()).
		WithStatusSubresource(&storagev1alpha1.NodeVG{}, &storagev1alpha1.NodeDisk{}).
		WithObjects(objs...).Build()
}

func newDisk(name, node, byID string, adopt bool, phase storagev1alpha1.DiskPhase) storagev1alpha1.NodeDisk {
	return storagev1alpha1.NodeDisk{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: storagev1alpha1.DiskSpec{
			NodeName: node,
			Adopt:    adopt,
		},
		Status: storagev1alpha1.DiskStatus{
			Identity: storagev1alpha1.DiskIdentity{ByID: byID},
			Phase:    phase,
		},
	}
}

func objectMeta2(name string) metav1.ObjectMeta {
	return metav1.ObjectMeta{Name: name}
}

func TestDesiredStorageTasksForDisk_Pure(t *testing.T) {
	base := newDisk("d1", "n1", "by-id-x", true, storagev1alpha1.DiskPhaseDiscovered)
	if got := DesiredStorageTasksForDisk(base); got == nil || got.Spec.Type != storagev1alpha1.TaskPVCreate {
		t.Fatalf("adoptable disk should yield pvcreate task, got %+v", got)
	}
	if got := DesiredStorageTasksForDisk(newDisk("d2", "n1", "by-id-y", false, storagev1alpha1.DiskPhaseDiscovered)); got != nil {
		t.Fatalf("non-adopt disk should yield nil, got %+v", got)
	}
	if got := DesiredStorageTasksForDisk(newDisk("d3", "n1", "by-id-z", true, storagev1alpha1.DiskPhaseInVG)); got != nil {
		t.Fatalf("InVG disk should yield nil, got %+v", got)
	}
	if got := DesiredStorageTasksForDisk(newDisk("d4", "n1", "", true, storagev1alpha1.DiskPhaseDiscovered)); got != nil {
		t.Fatalf("disk without byId should yield nil, got %+v", got)
	}
	// 需要擦除：先发 wipe。
	wipe := newDisk("d5", "n1", "by-id-w", true, storagev1alpha1.DiskPhaseDiscovered)
	wipe.Spec.WipePolicy = storagev1alpha1.WipeZero
	if got := DesiredStorageTasksForDisk(wipe); got == nil || got.Spec.Type != storagev1alpha1.TaskWipe {
		t.Fatalf("wipe-policy disk should yield wipe task, got %+v", got)
	}
}

func TestDesiredStorageTasksForVG_Pure(t *testing.T) {
	vg := storagev1alpha1.NodeVG{
		ObjectMeta: objectMeta2("vg1"),
		Spec: storagev1alpha1.VGSpec{
			NodeName: "n1",
			Disks:    []string{"by-id-a", "by-id-b"},
		},
	}
	// 未存在 VG → 生成 vgcreate。
	tasks := DesiredStorageTasksForVG(vg, nil)
	if len(tasks) != 1 || tasks[0].Spec.Type != storagev1alpha1.TaskVGCreate {
		t.Fatalf("expected vgcreate task, got %+v", tasks)
	}
	// 已存在 + 已批准移除 → 生成 vgreduce。
	vg.Status.VGExists = true
	tasks = DesiredStorageTasksForVG(vg, []string{"by-id-a"})
	if len(tasks) != 1 || tasks[0].Spec.Type != storagev1alpha1.TaskVGReduce {
		t.Fatalf("expected vgreduce task, got %+v", tasks)
	}
}

func TestDiskReconciler_IssuesAdoptionTask(t *testing.T) {
	disk := newDisk("d1", "n1", "by-id-x", true, storagev1alpha1.DiskPhaseDiscovered)
	c := fakeClient(&disk)

	r := &DiskReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "d1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var list storagev1alpha1.StorageTaskList
	if err := c.List(context.Background(), &list); err != nil {
		t.Fatalf("list err: %v", err)
	}
	if len(list.Items) != 1 || list.Items[0].Name != "disk-d1-pvcreate" {
		t.Fatalf("expected exactly one pvcreate task, got %+v", list.Items)
	}
	// spec/status 分离：reconcile 不得修改 Spec。
	var got storagev1alpha1.NodeDisk
	_ = c.Get(context.Background(), client.ObjectKey{Name: "d1"}, &got)
	if got.Spec.Adopt != true || got.Spec.NodeName != "n1" {
		t.Fatalf("Spec was mutated by reconcile: %+v", got.Spec)
	}
}

func TestStorageTaskReconciler_MapsPvcreateResult(t *testing.T) {
	disk := newDisk("d1", "n1", "by-id-x", true, storagev1alpha1.DiskPhaseDiscovered)
	task := *DesiredStorageTasksForDisk(disk) // disk-d1-pvcreate
	task.Labels[LabelOwnerKind] = "NodeDisk"
	task.Labels[LabelOwnerName] = "d1"
	task.Status.Phase = storagev1alpha1.TaskSucceeded
	c := fakeClient(&disk, &task)

	r := &StorageTaskReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var gotDisk storagev1alpha1.NodeDisk
	_ = c.Get(context.Background(), client.ObjectKey{Name: "d1"}, &gotDisk)
	if gotDisk.Status.Phase != storagev1alpha1.DiskPhaseInVG {
		t.Fatalf("expected disk InVG after success, got %s", gotDisk.Status.Phase)
	}
	var gotTask storagev1alpha1.StorageTask
	_ = c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &gotTask)
	if gotTask.Labels[LabelResultApplied] != "true" {
		t.Fatalf("expected result-applied label, got %v", gotTask.Labels)
	}
	// 单写者：映射后不得改动 disk Spec。
	if gotDisk.Spec.Adopt != true {
		t.Fatalf("disk Spec was mutated: %+v", gotDisk.Spec)
	}
}

func TestVGReconciler_IssuesVgCreate(t *testing.T) {
	vg := storagev1alpha1.NodeVG{
		ObjectMeta: objectMeta2("vg1"),
		Spec: storagev1alpha1.VGSpec{
			NodeName: "n1",
			Disks:    []string{"by-id-a", "by-id-b"},
		},
	}
	c := fakeClient(&vg)

	r := &VGReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var list storagev1alpha1.StorageTaskList
	_ = c.List(context.Background(), &list)
	if len(list.Items) != 1 || list.Items[0].Spec.Type != storagev1alpha1.TaskVGCreate {
		t.Fatalf("expected vgcreate task, got %+v", list.Items)
	}
}

func TestVGReconciler_RemoveDiskProtection(t *testing.T) {
	// pooled + lvm-raid1，移除 1 块后剩余 1 块 < 2 → 冗余丧失，整体拒绝，不下发 vgreduce。
	vg := storagev1alpha1.NodeVG{
		ObjectMeta: objectMeta2("vg1"),
		Spec: storagev1alpha1.VGSpec{
			NodeName:   "n1",
			Layout:     storagev1alpha1.VGLayoutPooled,
			Redundancy: storagev1alpha1.RedundancyLVRAID1,
			Disks:      []string{"by-id-a", "by-id-b"},
			Operations: storagev1alpha1.VGOperations{RemoveDisks: []string{"by-id-a"}},
		},
		Status: storagev1alpha1.VGStatus{VGExists: true},
	}
	c := fakeClient(&vg)
	r := &VGReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)
	if len(got.Status.PendingOps) == 0 {
		t.Fatalf("expected redundancy-loss pendingOps, got %v", got.Status.PendingOps)
	}
	var list storagev1alpha1.StorageTaskList
	_ = c.List(context.Background(), &list)
	for _, tk := range list.Items {
		if tk.Spec.Type == storagev1alpha1.TaskVGReduce {
			t.Fatalf("redundancy-lost removal must NOT issue vgreduce, got %+v", list.Items)
		}
	}
}

func TestStorageTaskReconciler_MapsVgCreateResult(t *testing.T) {
	vg := storagev1alpha1.NodeVG{ObjectMeta: objectMeta2("vg1"), Spec: storagev1alpha1.VGSpec{NodeName: "n1"}}
	task := storagev1alpha1.StorageTask{
		ObjectMeta: objectMeta2("vg-vg1-vgcreate"),
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskVGCreate},
	}
	task.Labels = map[string]string{LabelOwnerKind: "NodeVG", LabelOwnerName: "vg1"}
	task.Status.Phase = storagev1alpha1.TaskSucceeded
	c := fakeClient(&vg, &task)
	r := &StorageTaskReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)
	if !got.Status.VGExists {
		t.Fatalf("expected VGExists=true after vgcreate success")
	}
}
