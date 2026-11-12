package controller

import (
	"context"
	"fmt"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

func lvReporterScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := storagev1beta1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func nodeVGWithLVReport(name, node, pool string, at *metav1.Time, lvs ...storagev1beta1.LVReport) *storagev1beta1.NodeVG {
	return &storagev1beta1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: storagev1beta1.VGSpec{
			NodeName: node,
			ThinPool: storagev1beta1.ThinPoolSpec{Name: pool},
		},
		Status: storagev1beta1.VGStatus{
			LogicalVolumes:   lvs,
			LastLVReportTime: at,
		},
	}
}

func TestNodeVGLVReporter_ReadsReportAndFiltersThinPool(t *testing.T) {
	now := time.Date(2026, 11, 12, 10, 0, 0, 0, time.UTC)
	at := &metav1.Time{Time: now.Add(-20 * time.Second)}
	// 真机形状：业务 thin LV + Agent 旧版漏过滤的 thinpool + 内部 LV。
	vg := nodeVGWithLVReport("hlvm-lvmd-vg-153", "10-60-153-100", "thinpool", at,
		storagev1beta1.LVReport{Name: "9e639840-23de-403e-aebe-2335b9505816", Bytes: 1073741824},
		storagev1beta1.LVReport{Name: "thinpool", Bytes: 38654705664},
		storagev1beta1.LVReport{Name: "[thinpool_tdata]", Bytes: 1},
		storagev1beta1.LVReport{Name: "manual-lv", Bytes: 67108864},
	)
	c := fake.NewClientBuilder().WithScheme(lvReporterScheme(t)).WithObjects(vg).Build()
	r := &NodeVGLVReporter{Client: c, Now: func() time.Time { return now }}

	got, err := r.ListActualLVs("10-60-153-100")
	if err != nil {
		t.Fatalf("读取 LV 上报失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("应只保留 2 条业务 LV（业务 thin + 手工），got %+v", got)
	}
	byName := map[string]ActualLV{}
	for _, a := range got {
		byName[a.Name] = a
	}
	biz, ok := byName["9e639840-23de-403e-aebe-2335b9505816"]
	if !ok {
		t.Fatalf("业务 LV 丢失: %+v", got)
	}
	if biz.Node != "10-60-153-100" || biz.VG != "hlvm-lvmd-vg-153" || biz.Bytes != 1073741824 {
		t.Fatalf("三元组错配: %+v", biz)
	}
	if _, ok := byName["manual-lv"]; !ok {
		t.Fatal("手工 LV 必须保留，否则漂移检测永远检不出人工 lvcreate")
	}
}

func TestNodeVGLVReporter_FailsClosedOnStaleOrMissingReport(t *testing.T) {
	now := time.Date(2026, 11, 12, 10, 0, 0, 0, time.UTC)
	cases := []struct {
		name string
		vg   *storagev1beta1.NodeVG
		want string
	}{
		{
			name: "无上报时间",
			vg:   nodeVGWithLVReport("vg1", "n1", "thinpool", nil, storagev1beta1.LVReport{Name: "lv-a"}),
			want: "尚无 LV 上报",
		},
		{
			name: "上报过期",
			vg: nodeVGWithLVReport("vg1", "n1", "thinpool",
				&metav1.Time{Time: now.Add(-5 * time.Minute)}, storagev1beta1.LVReport{Name: "lv-a"}),
			want: "已过期",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := fake.NewClientBuilder().WithScheme(lvReporterScheme(t)).WithObjects(tc.vg).Build()
			r := &NodeVGLVReporter{Client: c, Now: func() time.Time { return now }}
			_, err := r.ListActualLVs("n1")
			if err == nil || !contains(err.Error(), tc.want) {
				t.Fatalf("应失败关闭且说明原因，got %v", err)
			}
		})
	}

	// 节点没有 NodeVG：同样失败关闭，不能返回空清单冒充「实际无 LV」。
	c := fake.NewClientBuilder().WithScheme(lvReporterScheme(t)).Build()
	r := &NodeVGLVReporter{Client: c, Now: func() time.Time { return now }}
	if _, err := r.ListActualLVs("n1"); err == nil || !contains(err.Error(), "没有对应") {
		t.Fatalf("无 NodeVG 应失败关闭，got %v", err)
	}
}

func TestNodeVGLVReporter_CustomMaxAgeAndMultipleVGs(t *testing.T) {
	now := time.Date(2026, 11, 12, 10, 0, 0, 0, time.UTC)
	at := &metav1.Time{Time: now.Add(-10 * time.Second)}
	vg1 := nodeVGWithLVReport("vg-a", "n1", "thinpool", at, storagev1beta1.LVReport{Name: "lv-a"})
	vg2 := nodeVGWithLVReport("vg-b", "n1", "thinpool", at, storagev1beta1.LVReport{Name: "lv-b"})
	other := nodeVGWithLVReport("vg-c", "n2", "thinpool", at, storagev1beta1.LVReport{Name: "lv-c"})
	c := fake.NewClientBuilder().WithScheme(lvReporterScheme(t)).WithObjects(vg1, vg2, other).Build()
	r := &NodeVGLVReporter{Client: c, MaxAge: 5 * time.Second, Now: func() time.Time { return now }}
	if _, err := r.ListActualLVs("n1"); err == nil || !contains(err.Error(), "已过期") {
		t.Fatalf("自定义 MaxAge=5s 应判 10s 前的上报过期，got %v", err)
	}

	r.MaxAge = time.Minute
	got, err := r.ListActualLVs("n1")
	if err != nil {
		t.Fatalf("放宽 MaxAge 后应成功: %v", err)
	}
	if len(got) != 2 || got[0].VG == "vg-c" || got[1].VG == "vg-c" {
		t.Fatalf("应只返回本节点两个 VG 的 LV，got %+v", got)
	}
}

// partialReporter 模拟「一个节点上报成功、另一个节点 stale」；用于验证整轮失败关闭。
type partialReporter struct{}

func (partialReporter) ListActualLVs(node string) ([]ActualLV, error) {
	if node == "n2" {
		return nil, fmt.Errorf("stale report")
	}
	return []ActualLV{{Node: "n1", VG: "vg-n1", Name: "lv-a"}}, nil
}

func TestDriftDetector_FailClosedWhenAnyNodeReportMissing(t *testing.T) {
	s := lvReporterScheme(t)
	pv1 := boundPV("pv-1", "n1", "default", "claim-1")
	pv2 := boundPV("pv-2", "n2", "default", "claim-2")
	vg1 := &storagev1beta1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg-n1"}, Spec: storagev1beta1.VGSpec{NodeName: "n1"}}
	vg2 := &storagev1beta1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg-n2"}, Spec: storagev1beta1.VGSpec{NodeName: "n2"}}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(s).WithObjects(&pv1, &pv2, vg1, vg2).Build()
	r := &DriftDetectorReconciler{Client: c, Scheme: s, Recorder: rec, Reporter: partialReporter{}}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("n2 上报缺失时整轮必须放弃对账（否则 n2 全部 missing-lv 误报），got %q", e)
	default:
	}
}

func TestDriftDetector_PVEventEnqueuesAllNodeVGs(t *testing.T) {
	s := lvReporterScheme(t)
	vg1 := &storagev1beta1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg-n1"}, Spec: storagev1beta1.VGSpec{NodeName: "n1"}}
	vg2 := &storagev1beta1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg-n2"}, Spec: storagev1beta1.VGSpec{NodeName: "n2"}}
	c := fake.NewClientBuilder().WithScheme(s).WithObjects(vg1, vg2).Build()
	r := &DriftDetectorReconciler{Client: c, Scheme: s}

	reqs := r.enqueueAllNodeVGs(context.Background(), &corev1.PersistentVolume{})
	if len(reqs) != 2 {
		t.Fatalf("PV 事件应映射到 2 个 NodeVG，got %+v", reqs)
	}

	empty := fake.NewClientBuilder().WithScheme(s).Build()
	r2 := &DriftDetectorReconciler{Client: empty, Scheme: s}
	reqs = r2.enqueueAllNodeVGs(context.Background(), &corev1.PersistentVolume{})
	if len(reqs) != 1 || reqs[0].Name != "pv-change" {
		t.Fatalf("无 NodeVG 时仍需一个哨兵请求触发全量对账，got %+v", reqs)
	}
}

func TestVGStatusDeepCopyPreservesLVReport(t *testing.T) {
	now := metav1.Now()
	in := &storagev1beta1.VGStatus{
		LogicalVolumes:   []storagev1beta1.LVReport{{Name: "lv-a", Bytes: 42}},
		LastLVReportTime: &now,
		PendingOps:       []string{"op"},
		Conditions:       []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue, Reason: "x"}},
		CapacityStatus:   storagev1beta1.CapacityAvailable,
	}
	out := in.DeepCopy()
	if len(out.LogicalVolumes) != 1 || out.LogicalVolumes[0].Name != "lv-a" || out.LastLVReportTime == nil {
		t.Fatalf("deepcopy 丢失 LV 上报字段: %+v", out)
	}
	// 必须是深拷贝：改副本不影响原件（Status().Update 用 DeepCopy 构造 base）。
	out.LogicalVolumes[0].Name = "changed"
	out.LastLVReportTime.Time = now.Add(time.Hour)
	if in.LogicalVolumes[0].Name != "lv-a" || !in.LastLVReportTime.Time.Equal(now.Time) {
		t.Fatal("deepcopy 与原件共享内存")
	}
}
