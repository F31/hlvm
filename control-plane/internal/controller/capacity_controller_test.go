package controller

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// fakeClientWithNodes 在共享 scheme 基础上额外容纳 Node（用于锁标签 patch 验证）。
func fakeClientWithNodes(objs ...client.Object) client.Client {
	return fake.NewClientBuilder().WithScheme(testScheme()).
		WithStatusSubresource(&storagev1alpha1.NodeVG{}, &storagev1beta1.NodeDisk{}).
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

// fullThresholdsPolicy 返回带 autoextend/forecast/requireFreeVGSpace 的完整策略，用于 M7b 条件断言。
func fullThresholdsPolicy() storagev1alpha1.ThinPoolPolicy {
	return storagev1alpha1.ThinPoolPolicy{
		ObjectMeta: metav1.ObjectMeta{Name: PolicySingletonName},
		Spec: storagev1alpha1.ThinPoolPolicySpec{
			Thresholds: storagev1alpha1.ThinPoolThresholds{
				WarningPercent: 75, CriticalPercent: 85, UnlockPercent: 80, MetadataCriticalPercent: 75,
				AutoExtendPercent: 80, AutoExtendStepPercent: 20,
			},
			Forecast:           storagev1alpha1.ThinPoolForecast{TimeToFullWarning: "24h", TimeToFullCritical: "4h"},
			RequireFreeVGSpace: "50Gi",
		},
	}
}

func TestCapacityReconciler_ForecastFreeVGAndAutoExtend(t *testing.T) {
	// data=80% + growth 100GiB/h（100GiB 容量 → ~0.2h 写满）→ 预测 Critical；
	// 空闲 40GiB < 50GiB → FreeVGInsufficient=True；
	// AutoExtendPercent=80 且 data>=80 且 +20% 步长(20GiB) 未超出 VG 上限(140GiB) → ThinPoolAutoExtend=True；
	// LvmdConfig 渲染出 autoextend 片段。
	vg := storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg1"},
		Spec:       storagev1alpha1.VGSpec{NodeName: "n1", Tier: "nvme"},
		Status: storagev1alpha1.VGStatus{
			CapacityStatus:     storagev1alpha1.CapacityAvailable,
			GrowthBytesPerHour: 100 * (1 << 30),
			FreeBytes:          40 * (1 << 30),
			ThinPool: storagev1alpha1.VGThinPoolStatus{
				DataPercent:      80,
				MetadataPercent:  10,
				CurrentSizeBytes: 100 * (1 << 30), // 100 GiB
			},
		},
	}
	policy := fullThresholdsPolicy()
	node := newNode("n1", nil)
	c := fakeClientWithNodes(&vg, &policy, &node)

	r := &CapacityReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)

	fc := meta.FindStatusCondition(got.Status.Conditions, CondCapacityForecast)
	if fc == nil || fc.Status != metav1.ConditionTrue || fc.Reason != "CapacityForecastCritical" {
		t.Fatalf("期望 CapacityForecast=True/Critical，got %+v", fc)
	}
	free := meta.FindStatusCondition(got.Status.Conditions, CondFreeVGInsufficient)
	if free == nil || free.Status != metav1.ConditionTrue {
		t.Fatalf("期望 FreeVGInsufficient=True，got %+v", free)
	}
	ae := meta.FindStatusCondition(got.Status.Conditions, CondThinPoolAutoExtend)
	if ae == nil || ae.Status != metav1.ConditionTrue {
		t.Fatalf("期望 ThinPoolAutoExtend=True，got %+v", ae)
	}
	if got.Status.LvmdConfig == "" || !strings.Contains(got.Status.LvmdConfig, "thin_pool_autoextend_threshold = 80") {
		t.Fatalf("期望渲染 lvm.conf 片段，got %q", got.Status.LvmdConfig)
	}
}

func TestCapacityReconciler_AutoExtendCappedWhenOverMax(t *testing.T) {
	// data>=AutoExtendPercent 但剩余空间极小，兜底扩容目标超过 VG 上限 → ThinPoolExtendCapped=True（转人工）。
	vg := storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg1"},
		Spec:       storagev1alpha1.VGSpec{NodeName: "n1", Tier: "nvme"},
		Status: storagev1alpha1.VGStatus{
			CapacityStatus: storagev1alpha1.CapacityAvailable,
			FreeBytes:      1 << 20, // 仅 1MiB 剩余
			ThinPool: storagev1alpha1.VGThinPoolStatus{
				DataPercent:      90,
				CurrentSizeBytes: 100 * (1 << 30),
			},
		},
	}
	policy := fullThresholdsPolicy()
	c := fakeClientWithNodes(&vg, &policy)

	r := &CapacityReconciler{Client: c, Scheme: testScheme()}
	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	var got storagev1alpha1.NodeVG
	_ = c.Get(context.Background(), client.ObjectKey{Name: "vg1"}, &got)
	capped := meta.FindStatusCondition(got.Status.Conditions, CondThinPoolExtendCapped)
	if capped == nil || capped.Status != metav1.ConditionTrue {
		t.Fatalf("期望 ThinPoolExtendCapped=True，got %+v", capped)
	}
}
