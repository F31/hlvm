package controller

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

func lvmdScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(s)
	_ = storagev1alpha1.AddToScheme(s)
	_ = storagev1beta1.AddToScheme(s)
	return s
}

func newVGForLVMD(name, node, tier string, op float64) storagev1alpha1.NodeVG {
	return storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: name, UID: types.UID("uid-" + name)},
		Spec: storagev1alpha1.VGSpec{
			NodeName: node,
			Tier:     tier,
			ThinPool: storagev1alpha1.ThinPoolSpec{Name: "thinpool", OverprovisionRatio: op},
		},
		Status: storagev1alpha1.VGStatus{VGExists: true},
	}
}

func mustAggregate(t *testing.T, vgs ...storagev1alpha1.NodeVG) string {
	t.Helper()
	got, ok, err := AggregateLVMDConfig(vgs)
	if err != nil {
		t.Fatalf("聚合失败：%v", err)
	}
	if !ok {
		t.Fatal("期望存在可服务的 device-class，实际 ok=false")
	}
	return got
}

func TestAggregateLVMDConfig_SortedAndComplete(t *testing.T) {
	meta := newVGForLVMD("vg-a", "n1", "metadata", 0)
	data := newVGForLVMD("vg-b", "n1", "data", 5)

	got := mustAggregate(t, meta, data)

	want := "# hlvm lvmd config (aggregated from NodeVGs on this node)\n" +
		"device-classes:\n" +
		"  - name: data\n    volume-group: vg-b\n    spare-gb: 0\n    thin-pool:\n      name: thinpool\n      overprovision-ratio: 5.00\n" +
		"  - name: metadata\n    volume-group: vg-a\n    spare-gb: 0\n    thin-pool:\n      name: thinpool\n      overprovision-ratio: 1.00\n"
	if got != want {
		t.Fatalf("聚合结果不符预期：\n got=%q\nwant=%q", got, want)
	}

	// 输入顺序相反时必须得到相同输出（确定性渲染，逐字节漂移比对的前提）。
	if reversed := mustAggregate(t, data, meta); reversed != want {
		t.Fatalf("渲染不确定：输入顺序变化导致输出不同\n got=%q", reversed)
	}
}

func TestAggregateLVMDConfig_FiltersNotExistingVG(t *testing.T) {
	ready := newVGForLVMD("vg-ready", "n1", "data", 0)
	pending := newVGForLVMD("vg-pending", "n1", "cold", 0)
	pending.Status.VGExists = false

	got := mustAggregate(t, ready, pending)
	if !strings.Contains(got, "name: data") {
		t.Fatalf("应包含已存在的 VG：%q", got)
	}
	if strings.Contains(got, "cold") {
		t.Fatalf("vgExists=false 的 VG 不应出现在配置中：%q", got)
	}
}

func TestAggregateLVMDConfig_DeviceClassNameOverridesTier(t *testing.T) {
	vg := newVGForLVMD("vg-p1", "n1", "data", 0)
	vg.Spec.DeviceClassName = "data-p1"

	got := mustAggregate(t, vg)
	if !strings.Contains(got, "  - name: data-p1\n") {
		t.Fatalf("deviceClassName 未生效：%q", got)
	}
	if strings.Contains(got, "  - name: data\n") {
		t.Fatalf("不应再使用 tier 作为 device-class 名：%q", got)
	}
}

func TestAggregateLVMDConfig_DuplicateNameRejected(t *testing.T) {
	// per-disk 布局：同节点两个 VG 共用 tier 且未设 deviceClassName → 必须报错而非生成非法配置。
	a := newVGForLVMD("vg-p1", "n1", "data", 0)
	b := newVGForLVMD("vg-p2", "n1", "data", 0)

	if _, _, err := AggregateLVMDConfig([]storagev1alpha1.NodeVG{a, b}); err == nil {
		t.Fatal("device-class 重名应返回错误")
	}
}

func TestAggregateLVMDConfig_NoServableClass(t *testing.T) {
	// 无可服务 device-class 时不得产出配置：lvmd 的 ValidateDeviceClasses 拒绝空列表
	// （"should have at least one device-class"），写 `device-classes: []` 等于下发不可启动配置。
	got, ok, err := AggregateLVMDConfig(nil)
	if err != nil {
		t.Fatalf("聚合不应报错：%v", err)
	}
	if ok {
		t.Fatal("无 VG 时应返回 ok=false")
	}
	if got != "" {
		t.Fatalf("无 VG 时不应渲染配置，实际：%q", got)
	}

	// 仅含 vgExists=false 的 VG 同样视为不可服务。
	pending := newVGForLVMD("vg-pending", "n1", "data", 0)
	pending.Status.VGExists = false
	if got, ok, err = AggregateLVMDConfig([]storagev1alpha1.NodeVG{pending}); err != nil || ok || got != "" {
		t.Fatalf("vgExists=false 不应产出配置：got=%q ok=%v err=%v", got, ok, err)
	}
}

func TestLvmdConfigReconciler_CreatesConfigMap(t *testing.T) {
	vg := newVGForLVMD("vg-node1", "n1", "nvme", 5)
	c := fake.NewClientBuilder().WithScheme(lvmdScheme()).WithObjects(&vg).Build()
	r := &LvmdConfigReconciler{Client: c, Scheme: lvmdScheme(), Namespace: ManagedNamespace}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-node1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var cm corev1.ConfigMap
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: LvmdConfigName("n1")}, &cm); err != nil {
		t.Fatalf("ConfigMap 未创建：%v", err)
	}
	if want := mustAggregate(t, vg); cm.Data["lvmd.yaml"] != want {
		t.Fatalf("ConfigMap 内容不符渲染值：%q", cm.Data["lvmd.yaml"])
	}
	if cm.Annotations[ManagedAnnotation] != "true" {
		t.Fatalf("缺少 managed 注解：%v", cm.Annotations)
	}
	if len(cm.OwnerReferences) != 1 || cm.OwnerReferences[0].Name != "vg-node1" {
		t.Fatalf("ownerReference 不符预期：%v", cm.OwnerReferences)
	}
	if cm.OwnerReferences[0].Controller == nil || *cm.OwnerReferences[0].Controller {
		t.Fatal("ownerReference 必须是非 controller owner（同节点可有多个 VG）")
	}
}

func TestLvmdConfigReconciler_AggregatesSameNodeVGs(t *testing.T) {
	// 同节点两个 VG（不同 tier）应聚合进同一份 ConfigMap，且 owner 有两个。
	meta := newVGForLVMD("vg-meta", "n1", "metadata", 0)
	data := newVGForLVMD("vg-data", "n1", "data", 5)
	other := newVGForLVMD("vg-other", "n2", "data", 5) // 另一节点不应混入

	c := fake.NewClientBuilder().WithScheme(lvmdScheme()).WithObjects(&meta, &data, &other).Build()
	r := &LvmdConfigReconciler{Client: c, Scheme: lvmdScheme(), Namespace: ManagedNamespace}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-meta"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var cm corev1.ConfigMap
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: LvmdConfigName("n1")}, &cm); err != nil {
		t.Fatalf("ConfigMap 未创建：%v", err)
	}
	if want, _, err := AggregateLVMDConfig([]storagev1alpha1.NodeVG{meta, data}); err != nil || cm.Data["lvmd.yaml"] != want {
		t.Fatalf("聚合内容不符：\n got=%q\nwant=%q (err=%v)", cm.Data["lvmd.yaml"], want, err)
	}
	if len(cm.OwnerReferences) != 2 {
		t.Fatalf("应有 2 个 ownerReference（n1 的两个 VG），实际 %d", len(cm.OwnerReferences))
	}

	// 另一个节点的 ConfigMap 不应被创建（只有被 reconcile 的节点会写）。
	var otherCM corev1.ConfigMap
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: LvmdConfigName("n2")}, &otherCM); err == nil {
		t.Fatal("不应为未触发的节点创建 ConfigMap")
	}
}

func TestLvmdConfigReconciler_ShrinksAfterVGDeleted(t *testing.T) {
	meta := newVGForLVMD("vg-meta", "n1", "metadata", 0)
	data := newVGForLVMD("vg-data", "n1", "data", 5)

	c := fake.NewClientBuilder().WithScheme(lvmdScheme()).WithObjects(&meta, &data).Build()
	r := &LvmdConfigReconciler{Client: c, Scheme: lvmdScheme(), Namespace: ManagedNamespace}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-meta"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	// 删除 data VG 后再次 reconcile：配置应收缩为仅 metadata，owner 也应只剩一个。
	if err := c.Delete(context.Background(), &data); err != nil {
		t.Fatalf("delete vg: %v", err)
	}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-meta"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var cm corev1.ConfigMap
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: LvmdConfigName("n1")}, &cm); err != nil {
		t.Fatalf("ConfigMap 丢失：%v", err)
	}
	if strings.Contains(cm.Data["lvmd.yaml"], "name: data") {
		t.Fatalf("已删除 VG 的 device-class 仍残留：%q", cm.Data["lvmd.yaml"])
	}
	if len(cm.OwnerReferences) != 1 || cm.OwnerReferences[0].Name != "vg-meta" {
		t.Fatalf("ownerReference 未收敛：%v", cm.OwnerReferences)
	}
}

func TestLvmdConfigReconciler_CorrectsDrift(t *testing.T) {
	vg := newVGForLVMD("vg-node1", "n1", "nvme", 5)
	cmName := LvmdConfigName("n1")
	cm := corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Namespace: ManagedNamespace, Name: cmName, Annotations: map[string]string{ManagedAnnotation: "true"}},
		Data:       map[string]string{"lvmd.yaml": "# manually editted, drifted"},
	}
	c := fake.NewClientBuilder().WithScheme(lvmdScheme()).WithObjects(&vg, &cm).Build()
	r := &LvmdConfigReconciler{Client: c, Scheme: lvmdScheme(), Namespace: ManagedNamespace}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-node1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var got corev1.ConfigMap
	_ = c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: cmName}, &got)
	if want := mustAggregate(t, vg); got.Data["lvmd.yaml"] != want {
		t.Fatalf("漂移未纠正：%q", got.Data["lvmd.yaml"])
	}
}

func TestLvmdConfigReconciler_SkipsWhenNoNode(t *testing.T) {
	// 未绑定节点的 VG 不应创建 ConfigMap。
	vg := newVGForLVMD("vg-orphan", "", "nvme", 5)
	c := fake.NewClientBuilder().WithScheme(lvmdScheme()).WithObjects(&vg).Build()
	r := &LvmdConfigReconciler{Client: c, Scheme: lvmdScheme(), Namespace: ManagedNamespace}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-orphan"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var cm corev1.ConfigMap
	err := c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: LvmdConfigName("")}, &cm)
	if err == nil {
		t.Fatalf("未绑定节点不应创建 ConfigMap")
	}
}

func TestLvmdConfigReconciler_RemovesConfigMapWhenNoServableClass(t *testing.T) {
	// VG 已创建但尚未建成（vgExists=false）：不得写入 `device-classes: []`，
	// 且已有的托管 ConfigMap 必须撤销（lvmd 无法加载空列表配置）。
	vg := newVGForLVMD("vg-pending", "n1", "data", 0)
	vg.Status.VGExists = false
	cm := corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: ManagedNamespace, Name: LvmdConfigName("n1"),
			Annotations: map[string]string{ManagedAnnotation: "true"},
		},
		Data: map[string]string{"lvmd.yaml": "device-classes:\n  - name: data\n"},
	}
	c := fake.NewClientBuilder().WithScheme(lvmdScheme()).WithObjects(&vg, &cm).Build()
	r := &LvmdConfigReconciler{Client: c, Scheme: lvmdScheme(), Namespace: ManagedNamespace}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-pending"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var got corev1.ConfigMap
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: LvmdConfigName("n1")}, &got); err == nil {
		t.Fatalf("无可用 device-class 时应删除托管 ConfigMap，实际仍存在：%q", got.Data["lvmd.yaml"])
	}
}

func TestLvmdConfigReconciler_KeepsForeignConfigMapWhenNoServableClass(t *testing.T) {
	// 非平台托管的同名 ConfigMap 不得删除（避免误删他人资源）。
	vg := newVGForLVMD("vg-pending", "n2", "data", 0)
	vg.Status.VGExists = false
	cm := corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Namespace: ManagedNamespace, Name: LvmdConfigName("n2")},
		Data:       map[string]string{"lvmd.yaml": "device-classes:\n  - name: manual\n"},
	}
	c := fake.NewClientBuilder().WithScheme(lvmdScheme()).WithObjects(&vg, &cm).Build()
	r := &LvmdConfigReconciler{Client: c, Scheme: lvmdScheme(), Namespace: ManagedNamespace}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-pending"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var got corev1.ConfigMap
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: ManagedNamespace, Name: LvmdConfigName("n2")}, &got); err != nil {
		t.Fatalf("非托管 ConfigMap 不应被删除：%v", err)
	}
}
