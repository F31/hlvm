package controller

import (
	"context"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
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
		WithStatusSubresource(&storagev1alpha1.NodeVG{}, &storagev1alpha1.NodeDisk{}, &storagev1alpha1.StorageTask{}).
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

// TestStorageTaskReconciler_AuditsDestructiveWipe 验证破坏性擦除任务完成时写审计（§4.1/§4.3）。
func TestStorageTaskReconciler_AuditsDestructiveWipe(t *testing.T) {
	disk := newDisk("d1", "n1", "by-id-x", true, storagev1alpha1.DiskPhaseDiscovered)
	disk.Spec.WipePolicy = storagev1alpha1.WipeSecureErase
	task := storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{Name: "disk-d1-wipe"},
		Spec: storagev1alpha1.StorageTaskSpec{
			NodeName:      "n1",
			Type:          storagev1alpha1.TaskWipe,
			Target:        storagev1alpha1.TaskTarget{DiskRef: "d1"},
			ConfirmSerial: "by-id-x",
		},
	}
	task.Labels = map[string]string{LabelOwnerKind: "NodeDisk", LabelOwnerName: "d1", LabelTaskOperator: "alice"}
	task.Status.Phase = storagev1alpha1.TaskSucceeded
	c := fakeClient(&disk, &task)
	rec := record.NewFakeRecorder(10)
	r := &StorageTaskReconciler{Client: c, Scheme: testScheme(), Recorder: rec}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var gotDisk storagev1alpha1.NodeDisk
	_ = c.Get(context.Background(), client.ObjectKey{Name: "d1"}, &gotDisk)
	if gotDisk.Status.Phase != storagev1alpha1.DiskPhaseInVG {
		t.Fatalf("expected disk InVG, got %s", gotDisk.Status.Phase)
	}
	select {
	case ev := <-rec.Events:
		if !strings.Contains(ev, "StorageAudit") {
			t.Fatalf("expected StorageAudit reason, got %q", ev)
		}
		if !strings.Contains(ev, "wipe:secure-erase") {
			t.Fatalf("audit must record erase method, got %q", ev)
		}
		if !strings.Contains(ev, "alice") {
			t.Fatalf("audit must record operator, got %q", ev)
		}
	default:
		t.Fatalf("expected an audit event for destructive wipe")
	}
}

// TestStorageTaskReconciler_AuditsVGReduce 验证 vgreduce（盘退役）完成时写审计（§4.1/§4.3）。
func TestStorageTaskReconciler_AuditsVGReduce(t *testing.T) {
	vg := storagev1alpha1.NodeVG{ObjectMeta: objectMeta2("vg1"), Spec: storagev1alpha1.VGSpec{NodeName: "n1"}}
	task := storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-vg1-vgreduce-0"},
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskVGReduce, Disks: []string{"by-id-a"}},
	}
	task.Labels = map[string]string{LabelOwnerKind: "NodeVG", LabelOwnerName: "vg1", LabelTaskOperator: "bob"}
	task.Status.Phase = storagev1alpha1.TaskSucceeded
	c := fakeClient(&vg, &task)
	rec := record.NewFakeRecorder(10)
	r := &StorageTaskReconciler{Client: c, Scheme: testScheme(), Recorder: rec}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case ev := <-rec.Events:
		if !strings.Contains(ev, "StorageAudit") || !strings.Contains(ev, "vgreduce:by-id-a") || !strings.Contains(ev, "bob") {
			t.Fatalf("audit event missing expected fields: %q", ev)
		}
	default:
		t.Fatalf("expected an audit event for vgreduce")
	}
}

// TestStorageTaskReconciler_NoAuditForNonDestructive 验证非破坏性任务不写审计。
func TestStorageTaskReconciler_NoAuditForNonDestructive(t *testing.T) {
	vg := storagev1alpha1.NodeVG{ObjectMeta: objectMeta2("vg1"), Spec: storagev1alpha1.VGSpec{NodeName: "n1"}}
	task := storagev1alpha1.StorageTask{
		ObjectMeta: objectMeta2("vg-vg1-vgcreate"),
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskVGCreate},
	}
	task.Labels = map[string]string{LabelOwnerKind: "NodeVG", LabelOwnerName: "vg1"}
	task.Status.Phase = storagev1alpha1.TaskSucceeded
	c := fakeClient(&vg, &task)
	rec := record.NewFakeRecorder(10)
	r := &StorageTaskReconciler{Client: c, Scheme: testScheme(), Recorder: rec}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: task.Name}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case ev := <-rec.Events:
		t.Fatalf("non-destructive vgcreate must NOT emit audit, got %q", ev)
	default:
		// 符合预期：无审计事件。
	}
}

// TestEnsureStorageTask_SetsNonControllerOwnerRef 验证任务归属（ADR-006）：
// 任务持有 NodeVG/NodeDisk 的非 controller ownerReference，拥有者删除后由 K8s GC 回收，
// 避免孤儿任务堆积与对已删除对象的误执行。
func TestEnsureStorageTask_SetsNonControllerOwnerRef(t *testing.T) {
	vg := &storagev1alpha1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg1", UID: types.UID("uid-vg1")}}
	c := fake.NewClientBuilder().WithScheme(testScheme()).Build()
	task := storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-vg1-vgcreate"},
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskVGCreate},
	}

	created, err := ensureStorageTask(context.Background(), c, task, vg)
	if err != nil {
		t.Fatalf("ensure err: %v", err)
	}
	if !created {
		t.Fatal("首次应创建任务")
	}

	var got storagev1alpha1.StorageTask
	if err := c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &got); err != nil {
		t.Fatalf("任务未创建：%v", err)
	}
	if len(got.OwnerReferences) != 1 {
		t.Fatalf("应恰好 1 个 ownerReference，实际 %d: %v", len(got.OwnerReferences), got.OwnerReferences)
	}
	ref := got.OwnerReferences[0]
	if ref.Kind != "NodeVG" || ref.Name != "vg1" || ref.UID != types.UID("uid-vg1") {
		t.Fatalf("ownerReference 不符：%+v", ref)
	}
	if ref.APIVersion != storagev1alpha1.GroupVersion.String() {
		t.Fatalf("ownerReference apiVersion 应为 %s，实际 %s", storagev1alpha1.GroupVersion.String(), ref.APIVersion)
	}
	if ref.Controller == nil || *ref.Controller {
		t.Fatal("ownerReference 必须是非 controller（任务只借 GC 归属，不参与 Owns 级联）")
	}
	if ref.BlockOwnerDeletion == nil || *ref.BlockOwnerDeletion {
		t.Fatal("BlockOwnerDeletion 必须为 false（不阻塞拥有者删除）")
	}

	// 幂等：已存在则不重建、不改写。
	again, err := ensureStorageTask(context.Background(), c, task, vg)
	if err != nil || again {
		t.Fatalf("重复调用应幂等跳过：created=%v err=%v", again, err)
	}
}

// TestEnsureStorageTask_DiskOwner 验证 NodeDisk 拥有者同样写入归属。
func TestEnsureStorageTask_DiskOwner(t *testing.T) {
	disk := &storagev1alpha1.NodeDisk{ObjectMeta: metav1.ObjectMeta{Name: "d1", UID: types.UID("uid-d1")}}
	c := fake.NewClientBuilder().WithScheme(testScheme()).Build()
	task := storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{Name: "disk-d1-wipe"},
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskWipe},
	}
	if _, err := ensureStorageTask(context.Background(), c, task, disk); err != nil {
		t.Fatalf("ensure err: %v", err)
	}
	var got storagev1alpha1.StorageTask
	if err := c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &got); err != nil {
		t.Fatalf("任务未创建：%v", err)
	}
	if len(got.OwnerReferences) != 1 || got.OwnerReferences[0].Kind != "NodeDisk" || got.OwnerReferences[0].UID != types.UID("uid-d1") {
		t.Fatalf("NodeDisk 归属不符：%v", got.OwnerReferences)
	}
}

// TestEnsureStorageTask_NoUIDNoOwnerRef 验证无 UID 的对象不能作为合法 owner（避免写入非法 ownerReference）。
func TestEnsureStorageTask_NoUIDNoOwnerRef(t *testing.T) {
	vg := &storagev1alpha1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg1"}} // 无 UID
	c := fake.NewClientBuilder().WithScheme(testScheme()).Build()
	task := storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-vg1-vgcreate"},
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskVGCreate},
	}
	if _, err := ensureStorageTask(context.Background(), c, task, vg); err != nil {
		t.Fatalf("ensure err: %v", err)
	}
	var got storagev1alpha1.StorageTask
	if err := c.Get(context.Background(), client.ObjectKey{Name: task.Name}, &got); err != nil {
		t.Fatalf("任务未创建：%v", err)
	}
	if len(got.OwnerReferences) != 0 {
		t.Fatalf("无 UID 不应写 ownerReference：%v", got.OwnerReferences)
	}
}

// TestEnsureStorageTask_RepairsLegacyTaskWithoutOwnerRef 验证升级自愈：
// 旧版本创建的任务没有 ownerReference，再次 reconcile 时就地补写，不再新建任务。
func TestEnsureStorageTask_RepairsLegacyTaskWithoutOwnerRef(t *testing.T) {
	vg := &storagev1alpha1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg1", UID: types.UID("uid-vg1")}}
	legacy := &storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-vg1-vgcreate"},
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskVGCreate},
	}
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(legacy).Build()
	desired := storagev1alpha1.StorageTask{
		ObjectMeta: metav1.ObjectMeta{Name: legacy.Name},
		Spec:       storagev1alpha1.StorageTaskSpec{NodeName: "n1", Type: storagev1alpha1.TaskVGCreate},
	}

	created, err := ensureStorageTask(context.Background(), c, desired, vg)
	if err != nil {
		t.Fatalf("ensure err: %v", err)
	}
	if created {
		t.Fatal("已存在的任务不应被重建")
	}

	var got storagev1alpha1.StorageTask
	if err := c.Get(context.Background(), client.ObjectKey{Name: legacy.Name}, &got); err != nil {
		t.Fatalf("get task: %v", err)
	}
	if len(got.OwnerReferences) != 1 || got.OwnerReferences[0].UID != types.UID("uid-vg1") {
		t.Fatalf("旧任务未补写 ownerReference：%v", got.OwnerReferences)
	}
}
