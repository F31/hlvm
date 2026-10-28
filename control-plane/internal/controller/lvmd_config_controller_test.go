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

func lvmdScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(s)
	_ = storagev1alpha1.AddToScheme(s)
	return s
}

func newVGForLVMD(name, node, tier string, op float64) storagev1alpha1.NodeVG {
	return storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: storagev1alpha1.VGSpec{
			NodeName: node,
			Tier:     tier,
			ThinPool: storagev1alpha1.ThinPoolSpec{Name: "thinpool", OverprovisionRatio: op},
		},
	}
}

func TestRenderLVMDConfig(t *testing.T) {
	vg := newVGForLVMD("vg-node1", "n1", "nvme", 10)
	got := RenderLVMDConfig(vg)
	want := "# hlvm lvmd config (rendered from NodeVG vg-node1)\n" +
		"device-classes:\n  - name: nvme\n    volume-group: vg-node1\n    spare-gb: 0\n    thin-pool:\n      name: thinpool\n      overprovision-ratio: 10.00\n"
	if got != want {
		t.Fatalf("渲染不符预期：\n got=%q\nwant=%q", got, want)
	}

	// 零 overprovision 视为 1.00。
	vg0 := newVGForLVMD("vg-node2", "n2", "", 0)
	got0 := RenderLVMDConfig(vg0)
	if got0 == "" || !containsSubstr(got0, "overprovision-ratio: 1.00") || !containsSubstr(got0, "name: default") {
		t.Fatalf("零超分/缺省 tier 渲染不符预期：%q", got0)
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
	if cm.Data["lvmd.yaml"] != RenderLVMDConfig(vg) {
		t.Fatalf("ConfigMap 内容不符渲染值：%q", cm.Data["lvmd.yaml"])
	}
	if cm.Annotations[ManagedAnnotation] != "true" {
		t.Fatalf("缺少 managed 注解：%v", cm.Annotations)
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
	if got.Data["lvmd.yaml"] != RenderLVMDConfig(vg) {
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
