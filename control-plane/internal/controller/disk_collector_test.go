package controller

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

func testNodeDisk(node, name, device string) *storagev1beta1.NodeDisk {
	var dev *storagev1beta1.DiskDevice
	if device != "" {
		dev = &storagev1beta1.DiskDevice{Path: device}
	}
	return &storagev1beta1.NodeDisk{
		ObjectMeta: metav1.ObjectMeta{Name: name, UID: types.UID("uid-" + name)},
		Spec:       storagev1beta1.DiskSpec{NodeName: node, Device: dev},
	}
}

func testNode(name string, disks int64) *corev1.Node {
	alloc := corev1.ResourceList{}
	if disks > 0 {
		alloc[DiskResourceName] = *resource.NewQuantity(disks, resource.DecimalSI)
	}
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Status:     corev1.NodeStatus{Allocatable: alloc},
	}
}

// collector 的权限必须收敛：只保留读块设备所必需的部分，其余全部关闭。
// 这条断言是「用设备插件替代 privileged exporter」的价值所在，退化会直接失去意义。
func TestCollectorPodIsLeastPrivilege(t *testing.T) {
	pod := BuildCollectorPod(testNodeDisk("n1", "disk-a", "/dev/sda"), CollectorOptions{})
	if len(pod.Spec.Containers) != 1 {
		t.Fatalf("期望 1 个容器，实际 %d", len(pod.Spec.Containers))
	}
	sc := pod.Spec.Containers[0].SecurityContext
	if sc == nil {
		t.Fatal("缺少 securityContext")
	}
	if sc.Privileged == nil || *sc.Privileged {
		t.Error("collector 不得 privileged")
	}
	if sc.RunAsUser == nil || *sc.RunAsUser != 0 {
		t.Error("collector 需 uid 0：设备节点是 root:disk 0640，非 root 会 EACCES")
	}
	if sc.AllowPrivilegeEscalation == nil || *sc.AllowPrivilegeEscalation {
		t.Error("必须禁止提权")
	}
	if sc.ReadOnlyRootFilesystem == nil || !*sc.ReadOnlyRootFilesystem {
		t.Error("必须只读根文件系统")
	}
	drops := map[corev1.Capability]bool{}
	for _, c := range sc.Capabilities.Drop {
		drops[c] = true
	}
	if !drops["ALL"] {
		t.Error("必须 drop ALL")
	}
	// 只允许 SYS_RAWIO（smartctl 的 SG_IO ioctl），多一个都算权限回退。
	if len(sc.Capabilities.Add) != 1 || sc.Capabilities.Add[0] != "SYS_RAWIO" {
		t.Errorf("只应补回 SYS_RAWIO，实际 %v", sc.Capabilities.Add)
	}
	for _, v := range pod.Spec.Volumes {
		if v.HostPath != nil && v.HostPath.Path == "/dev" {
			t.Error("不得挂载宿主 /dev：设备必须由 device plugin 按盘下发")
		}
	}
	if pod.Spec.AutomountServiceAccountToken == nil || *pod.Spec.AutomountServiceAccountToken {
		t.Error("collector 不需要 API 访问，应关闭 SA token 挂载")
	}
}

func TestCollectorPodRequestsExactlyOneDisk(t *testing.T) {
	pod := BuildCollectorPod(testNodeDisk("n1", "disk-a", "/dev/sda"), CollectorOptions{})
	qty, ok := pod.Spec.Containers[0].Resources.Limits[DiskResourceName]
	if !ok {
		t.Fatalf("缺少 %s limit", DiskResourceName)
	}
	if qty.Value() != 1 {
		t.Errorf("应申请 1 块盘，实际 %d", qty.Value())
	}
}

func TestCollectorPodBindsNodeDeviceAndOwner(t *testing.T) {
	disk := testNodeDisk("n1", "disk-a", "/dev/sdb")
	pod := BuildCollectorPod(disk, CollectorOptions{Namespace: "hlvm-system", Image: "img:1"})

	if pod.Namespace != "hlvm-system" || pod.Spec.NodeName != "n1" {
		t.Errorf("命名空间/节点不符: ns=%q node=%q", pod.Namespace, pod.Spec.NodeName)
	}
	if pod.Spec.Containers[0].Image != "img:1" {
		t.Errorf("镜像未透传: %q", pod.Spec.Containers[0].Image)
	}
	// 采集器必须用 auto：分到哪块盘由 kubelet 决定，硬编码 deviceRef 会把读数标错盘。
	if got := envValue(pod.Spec.Containers[0].Env, "HLVM_EXPORTER_DEVICE"); got != "auto" {
		t.Errorf("设备环境变量应恒为 auto，实际 %q", got)
	}
	if got := pod.Annotations["hlvm.io/disk-device"]; got != "/dev/sdb" {
		t.Errorf("意图设备应记录在注解: %q", got)
	}
	// NodeDisk 是 Cluster-scoped：给 namespaced Pod 设这种 owner，GC 会判为跨作用域并删除
	// 该 Pod。归属必须走注解，回收由 cleanupOrphanCollectors 主动完成。
	if len(pod.OwnerReferences) != 0 {
		t.Errorf("不得设置 ownerReference（跨作用域 owner 会被 GC 删除）: %+v", pod.OwnerReferences)
	}
	if got := pod.Annotations["hlvm.io/disk-name"]; got != disk.Name {
		t.Errorf("归属注解不符: %q", got)
	}
	if got := pod.Labels["hlvm.io/disk"]; got != "disk-a" {
		t.Errorf("磁盘 label 不符: %q", got)
	}
}

func TestCollectorPodNameIsBoundedAndDistinct(t *testing.T) {
	longNode := strings.Repeat("node-with-a-very-long-name-", 4)
	longDisk := strings.Repeat("disk-with-a-very-long-name-", 4)
	name := CollectorPodName(longNode, longDisk)
	if len(name) > 63 {
		t.Errorf("Pod 名超过 63 字符: %d", len(name))
	}
	if !strings.HasPrefix(name, "hlvm-collector-") {
		t.Errorf("Pod 名前缀不符: %q", name)
	}
	if name != CollectorPodName(longNode, longDisk) {
		t.Error("同名输入应产生稳定结果（避免每次 reconcile 换名）")
	}
	if CollectorPodName(longNode, longDisk) == CollectorPodName(longNode, longDisk+"x") {
		t.Error("不同磁盘应产生不同 Pod 名")
	}
}

func TestCollectorPodNeedsRecreate(t *testing.T) {
	disk := testNodeDisk("n1", "disk-a", "/dev/sda")
	base := BuildCollectorPod(disk, CollectorOptions{Image: "img:1"})
	same := BuildCollectorPod(disk, CollectorOptions{Image: "img:1"})
	if CollectorPodNeedsRecreate(base, same) {
		t.Error("配置未变时不应重建")
	}
	if !CollectorPodNeedsRecreate(base, BuildCollectorPod(disk, CollectorOptions{Image: "img:2"})) {
		t.Error("镜像变化应触发重建")
	}
	moved := testNodeDisk("n1", "disk-a", "/dev/sdb")
	if !CollectorPodNeedsRecreate(base, BuildCollectorPod(moved, CollectorOptions{Image: "img:1"})) {
		t.Error("设备变化应触发重建")
	}
}

func TestReconcileCreatesCollectorWhenDevicePluginReady(t *testing.T) {
	disk := testNodeDisk("n1", "disk-a", "/dev/sda")
	c := fake.NewClientBuilder().
		WithScheme(lvmdScheme()).
		WithObjects(disk, testNode("n1", 2)).
		Build()
	r := &DiskCollectorReconciler{Client: c, Scheme: lvmdScheme(), Namespace: "hlvm-system"}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Name: "disk-a"},
	}); err != nil {
		t.Fatalf("reconcile 失败: %v", err)
	}

	var pod corev1.Pod
	err := c.Get(context.Background(), types.NamespacedName{
		Namespace: "hlvm-system", Name: CollectorPodName("n1", "disk-a"),
	}, &pod)
	if err != nil {
		t.Fatalf("未创建 collector Pod: %v", err)
	}
	if pod.Spec.NodeName != "n1" {
		t.Errorf("Pod 未固定到盘所在节点: %q", pod.Spec.NodeName)
	}
}

func TestReconcileSkipsWhenNodeHasNoDeviceResource(t *testing.T) {
	disk := testNodeDisk("n1", "disk-a", "/dev/sda")
	// 节点没有 hlvm.io/disk（设备插件未就绪）：创建只会留下永久 Pending 的 Pod。
	c := fake.NewClientBuilder().
		WithScheme(lvmdScheme()).
		WithObjects(disk, testNode("n1", 0)).
		Build()
	r := &DiskCollectorReconciler{Client: c, Scheme: lvmdScheme(), Namespace: "hlvm-system"}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Name: "disk-a"},
	}); err != nil {
		t.Fatalf("reconcile 失败: %v", err)
	}

	var pod corev1.Pod
	err := c.Get(context.Background(), types.NamespacedName{
		Namespace: "hlvm-system", Name: CollectorPodName("n1", "disk-a"),
	}, &pod)
	if !apierrors.IsNotFound(err) {
		t.Errorf("节点无设备资源时不应创建 Pod（err=%v）", err)
	}
}

// 扩展资源排他：盘位已用尽时再建 Pod 只会永久 Pending 并占住调度位。
func TestReconcileSkipsWhenDiskSlotsExhausted(t *testing.T) {
	diskC := testNodeDisk("n1", "disk-c", "/dev/sdc")
	podA := BuildCollectorPod(testNodeDisk("n1", "disk-a", "/dev/sda"), CollectorOptions{Namespace: "hlvm-system"})
	podB := BuildCollectorPod(testNodeDisk("n1", "disk-b", "/dev/sdb"), CollectorOptions{Namespace: "hlvm-system"})

	c := fake.NewClientBuilder().
		WithScheme(lvmdScheme()).
		WithObjects(diskC, testNode("n1", 2), podA, podB).
		Build()
	r := &DiskCollectorReconciler{Client: c, Scheme: lvmdScheme(), Namespace: "hlvm-system"}

	res, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Name: "disk-c"},
	})
	if err != nil {
		t.Fatalf("reconcile 失败: %v", err)
	}

	var pod corev1.Pod
	err = c.Get(context.Background(), types.NamespacedName{
		Namespace: "hlvm-system", Name: CollectorPodName("n1", "disk-c"),
	}, &pod)
	if !apierrors.IsNotFound(err) {
		t.Errorf("盘位用尽时不应创建 Pod（err=%v）", err)
	}

	// 必须定时重试：Pod 事件只映射到它自己的 NodeDisk，等待中的这块盘不会被别人的
	// Pod 删除事件唤醒；不重试就会一直饿着（盘位空了也不会有 collector）。
	if res.RequeueAfter <= 0 {
		t.Errorf("盘位不足时应设置 RequeueAfter，实际 %v", res.RequeueAfter)
	}
}

func TestReconcileDeletesCollectorWhenDeviceRefCleared(t *testing.T) {
	disk := testNodeDisk("n1", "disk-a", "")
	pod := BuildCollectorPod(testNodeDisk("n1", "disk-a", "/dev/sda"), CollectorOptions{Namespace: "hlvm-system"})
	c := fake.NewClientBuilder().
		WithScheme(lvmdScheme()).
		WithObjects(disk, testNode("n1", 2), pod).
		Build()
	r := &DiskCollectorReconciler{Client: c, Scheme: lvmdScheme(), Namespace: "hlvm-system"}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Name: "disk-a"},
	}); err != nil {
		t.Fatalf("reconcile 失败: %v", err)
	}

	var got corev1.Pod
	err := c.Get(context.Background(), types.NamespacedName{
		Namespace: "hlvm-system", Name: pod.Name,
	}, &got)
	if !apierrors.IsNotFound(err) {
		t.Errorf("设备引用清空后应删除 collector Pod（err=%v）", err)
	}
}

// 跨作用域 owner 不可用 ⇒ 删除 NodeDisk 后必须由控制器主动回收 Pod；
// 同时不能误删仍存在的磁盘的 Pod（全量扫描的边界）。
func TestReconcileCollectsOrphanCollectorAfterDiskDeleted(t *testing.T) {
	dropped := testNodeDisk("n1", "disk-a", "/dev/sda")
	kept := testNodeDisk("n1", "disk-b", "/dev/sdb")
	droppedPod := BuildCollectorPod(dropped, CollectorOptions{Namespace: "hlvm-system"})
	keptPod := BuildCollectorPod(kept, CollectorOptions{Namespace: "hlvm-system"})

	c := fake.NewClientBuilder().
		WithScheme(lvmdScheme()).
		WithObjects(dropped, kept, testNode("n1", 2), droppedPod, keptPod).
		Build()
	r := &DiskCollectorReconciler{Client: c, Scheme: lvmdScheme(), Namespace: "hlvm-system"}

	if err := c.Delete(context.Background(), dropped); err != nil {
		t.Fatalf("删除 NodeDisk 失败: %v", err)
	}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{
		NamespacedName: types.NamespacedName{Name: "disk-a"},
	}); err != nil {
		t.Fatalf("reconcile 失败: %v", err)
	}

	var got corev1.Pod
	err := c.Get(context.Background(), types.NamespacedName{
		Namespace: "hlvm-system", Name: droppedPod.Name,
	}, &got)
	if !apierrors.IsNotFound(err) {
		t.Errorf("NodeDisk 删除后其 collector Pod 应被回收（err=%v）", err)
	}

	err = c.Get(context.Background(), types.NamespacedName{
		Namespace: "hlvm-system", Name: keptPod.Name,
	}, &got)
	if err != nil {
		t.Errorf("仍存在的 NodeDisk 的 collector Pod 不应被删: %v", err)
	}
}
