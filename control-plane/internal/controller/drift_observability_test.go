package controller

import (
	"context"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// 三方对账的可观测性判据（ADR-006 §17）：对账「静默停摆」必须能从指标看出来，
// 不能只留一条 Info 日志。

func obsScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := storagev1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := storagev1beta1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func obsRequest(name string) reconcile.Request {
	return reconcile.Request{NamespacedName: client.ObjectKey{Name: name}}
}

// 上报过期时整轮放弃对账：即使清单里真的有人工 LV 也不能报（否则 stale 清单会制造
// 大量误报），同时必须把原因计入 skipped 指标。
func TestDriftDetector_StaleReportSkipsRoundWithReason(t *testing.T) {
	scheme := obsScheme(t)
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	stale := metav1.NewTime(now.Add(-10 * time.Minute))

	pv := boundPV("pv-obs-stale", "n-obs-stale", "default", "claim")
	vg := nodeVGWithLVReport("vg-obs-stale", "n-obs-stale", "thinpool", &stale)
	vg.Status.LogicalVolumes = []storagev1beta1.LVReport{{Name: "manual-lv"}}

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&pv, vg).Build()
	rec := record.NewFakeRecorder(10)
	r := &DriftDetectorReconciler{
		Client: c, Scheme: scheme, Recorder: rec,
		Reporter: &NodeVGLVReporter{Client: c, Now: func() time.Time { return now }},
	}

	before := testutil.ToFloat64(metrics.DriftReconcileSkippedTotal.WithLabelValues(LVReportReasonStale))
	if _, err := r.Reconcile(context.Background(), obsRequest("vg-obs-stale")); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if got := testutil.ToFloat64(metrics.DriftReconcileSkippedTotal.WithLabelValues(LVReportReasonStale)); got != before+1 {
		t.Fatalf("过期上报应计入 skipped{report_stale}，got %v want %v", got, before+1)
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("过期上报不应产生任何漂移告警（假报），got %q", e)
	default:
	}
}

// 上报新鲜度指标必须覆盖「没有任何 PV 的 NodeVG」：空集群时 managed 为空，一次
// reporter 调用都不会发生，若指标跟随对账走，Agent 挂掉将完全不可观测。
func TestDriftDetector_FreshnessMetricCoversNodeVGWithoutPV(t *testing.T) {
	scheme := obsScheme(t)
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	at := metav1.NewTime(now.Add(-30 * time.Second))

	vg := nodeVGWithLVReport("vg-obs-nopv", "n-obs-nopv", "thinpool", &at)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(vg).Build()
	r := &DriftDetectorReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(4)}

	if _, err := r.Reconcile(context.Background(), obsRequest("vg-obs-nopv")); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if got := testutil.ToFloat64(metrics.LVReportPresent.WithLabelValues("n-obs-nopv", "vg-obs-nopv")); got != 1 {
		t.Fatalf("无 PV 的 NodeVG 也必须 present=1，got %v", got)
	}
	if got := testutil.ToFloat64(metrics.LVReportTimestampSeconds.WithLabelValues("n-obs-nopv", "vg-obs-nopv")); got != float64(at.Unix()) {
		t.Fatalf("时间戳应为 %d，got %v", at.Unix(), got)
	}
}

// NodeVG 删除后序列必须消失，否则旧时间戳永远冻结、`time() - ts` 持续增长 → 永久误告警。
func TestDriftDetector_FreshnessSeriesRemovedWhenNodeVGDeleted(t *testing.T) {
	scheme := obsScheme(t)
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	at := metav1.NewTime(now.Add(-10 * time.Second))

	vgA := nodeVGWithLVReport("vg-obs-keep", "n-obs-keep", "thinpool", &at)
	vgB := nodeVGWithLVReport("vg-obs-gone", "n-obs-gone", "thinpool", &at)

	c1 := fake.NewClientBuilder().WithScheme(scheme).WithObjects(vgA, vgB).Build()
	r1 := &DriftDetectorReconciler{Client: c1, Scheme: scheme, Recorder: record.NewFakeRecorder(4)}
	if _, err := r1.Reconcile(context.Background(), obsRequest("vg-obs-keep")); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if n := testutil.CollectAndCount(metrics.LVReportPresent); n != 2 {
		t.Fatalf("两个 NodeVG 应有 2 条序列，got %d", n)
	}

	// 第二轮只保留 A（模拟 B 被删）。
	c2 := fake.NewClientBuilder().WithScheme(scheme).WithObjects(vgA).Build()
	r2 := &DriftDetectorReconciler{Client: c2, Scheme: scheme, Recorder: record.NewFakeRecorder(4)}
	if _, err := r2.Reconcile(context.Background(), obsRequest("vg-obs-keep")); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if n := testutil.CollectAndCount(metrics.LVReportPresent); n != 1 {
		t.Fatalf("已删 NodeVG 的序列应被清除，got %d 条", n)
	}
	if n := testutil.CollectAndCount(metrics.LVReportTimestampSeconds); n != 1 {
		t.Fatalf("已删 NodeVG 的时间戳序列应被清除，got %d 条", n)
	}
}

// 跳过轮次不得把已有的漂移条目清零：Agent 抖动会把真实告警瞬间伪装成「已恢复」。
func TestDriftDetector_DriftItemsRetainedWhenReportGoesStale(t *testing.T) {
	scheme := obsScheme(t)
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	fresh := metav1.NewTime(now.Add(-10 * time.Second))
	stale := metav1.NewTime(now.Add(-10 * time.Minute))

	pv := boundPV("pv-obs-ret", "n-obs-ret", "default", "claim")
	vgFresh := nodeVGWithLVReport("vg-obs-ret", "n-obs-ret", "thinpool", &fresh)
	c1 := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&pv, vgFresh).Build()
	r1 := &DriftDetectorReconciler{
		Client: c1, Scheme: scheme, Recorder: record.NewFakeRecorder(4),
		// 账面只有 pv-obs-ret，实际多出 manual-lv ⇒ 1 条 unmanaged-lv。
		Reporter: &fakeLVReporter{lvs: []ActualLV{
			{Node: "n-obs-ret", Name: "pv-obs-ret"},
			{Node: "n-obs-ret", Name: "manual-lv"},
		}},
	}
	if _, err := r1.Reconcile(context.Background(), obsRequest("vg-obs-ret")); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if got := testutil.ToFloat64(metrics.DriftItems.WithLabelValues("unmanaged-lv")); got != 1 {
		t.Fatalf("首轮应发现 1 条 unmanaged-lv，got %v", got)
	}

	vgStale := nodeVGWithLVReport("vg-obs-ret", "n-obs-ret", "thinpool", &stale)
	c2 := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&pv, vgStale).Build()
	r2 := &DriftDetectorReconciler{
		Client: c2, Scheme: scheme, Recorder: record.NewFakeRecorder(4),
		Reporter: &NodeVGLVReporter{Client: c2, Now: func() time.Time { return now }},
	}
	if _, err := r2.Reconcile(context.Background(), obsRequest("vg-obs-ret")); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if got := testutil.ToFloat64(metrics.DriftItems.WithLabelValues("unmanaged-lv")); got != 1 {
		t.Fatalf("跳过轮次不得清零漂移条目，got %v want 1", got)
	}
}

// 未装配 Reporter 时也要留痕：否则「对账根本没在跑」与「跑了但没漂移」无法区分。
func TestDriftDetector_NoReporterCountsSkip(t *testing.T) {
	scheme := obsScheme(t)
	pv := boundPV("pv-obs-norep", "n-obs-norep", "default", "claim")
	vg := &storagev1beta1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-obs-norep"},
		Spec:       storagev1beta1.VGSpec{NodeName: "n-obs-norep"},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&pv, vg).Build()
	r := &DriftDetectorReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(4)}

	before := testutil.ToFloat64(metrics.DriftReconcileSkippedTotal.WithLabelValues(driftSkipNoReporter))
	if _, err := r.Reconcile(context.Background(), obsRequest("vg-obs-norep")); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if got := testutil.ToFloat64(metrics.DriftReconcileSkippedTotal.WithLabelValues(driftSkipNoReporter)); got != before+1 {
		t.Fatalf("Reporter=nil 应计入 skipped{no_reporter}，got %v want %v", got, before+1)
	}
}

// reason 标签必须是闭集：任意错误串会打爆指标基数，也会把内部拓扑泄漏到 /metrics。
func TestDriftSkipReasonIsClosedSet(t *testing.T) {
	if got := driftSkipReason(&LVReportUnavailableError{Reason: LVReportReasonMissing}); got != LVReportReasonMissing {
		t.Fatalf("应取类型化 reason，got %q", got)
	}
	if got := driftSkipReason(context.DeadlineExceeded); got != "unknown" {
		t.Fatalf("非类型化错误应归为 unknown，got %q", got)
	}
	if got := driftSkipReason(&LVReportUnavailableError{Reason: ""}); got != "unknown" {
		t.Fatalf("空 reason 应归为 unknown，got %q", got)
	}
}
