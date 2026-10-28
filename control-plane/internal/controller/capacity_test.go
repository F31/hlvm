package controller

import (
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func defaultThresholds() storagev1alpha1.ThinPoolThresholds {
	return storagev1alpha1.ThinPoolThresholds{
		WarningPercent:         75,
		CriticalPercent:        85,
		UnlockPercent:          80,
		MetadataCriticalPercent: 75,
	}
}

func TestEvaluateCapacityStatus(t *testing.T) {
	p := defaultThresholds()
	cases := []struct {
		name     string
		data     float64
		meta     float64
		oos      bool
		want     storagev1alpha1.CapacityStatus
	}{
		{"available", 50, 10, false, storagev1alpha1.CapacityAvailable},
		{"pressure", 76, 10, false, storagev1alpha1.CapacityPressure},
		{"locked by data", 85, 10, false, storagev1alpha1.CapacityLocked},
		{"locked by metadata", 50, 75, false, storagev1alpha1.CapacityLocked},
		{"locked by oos", 50, 10, true, storagev1alpha1.CapacityLocked},
		// 瞬态判定：data 位于 warning(75) 与 critical(85) 之间 => Pressure。
		// 滞回解锁（回落到 unlockPercent=80 以下才解锁）由调用方持状态处理，不在此纯函数内。
		{"pressure between warning and critical", 83, 10, false, storagev1alpha1.CapacityPressure},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := EvaluateCapacityStatus(c.data, c.meta, c.oos, p)
			if got != c.want {
				t.Fatalf("data=%.0f meta=%.0f oos=%v want %s got %s", c.data, c.meta, c.oos, c.want, got)
			}
		})
	}
}

func TestIsNodeStale(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	threshold := 30 * time.Minute
	cases := []struct {
		name  string
		ready *metav1.Time
		want  bool
	}{
		{"never ready", nil, false},
		{"just now", &metav1.Time{Time: now.Add(-1 * time.Minute)}, false},
		{"exactly threshold not stale", &metav1.Time{Time: now.Add(-threshold)}, false},
		{"beyond threshold stale", &metav1.Time{Time: now.Add(-threshold - time.Second)}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := IsNodeStale(c.ready, threshold, now); got != c.want {
				t.Fatalf("want %v got %v", c.want, got)
			}
		})
	}
}

// --- capacity-ctrl（add-capacity-governance）纯函数测试 ---

func TestDefaultThresholds(t *testing.T) {
	d := DefaultThresholds()
	if d.WarningPercent != 75 || d.CriticalPercent != 85 || d.UnlockPercent != 80 || d.MetadataCriticalPercent != 75 {
		t.Fatalf("默认阈值不符设计 §3.3：%+v", d)
	}
}

func TestResolveThresholds(t *testing.T) {
	// nil 策略 → 默认阈值。
	if got := ResolveThresholds(nil, ""); got != DefaultThresholds() {
		t.Fatalf("nil 策略应回退默认阈值，got %+v", got)
	}
	// 策略阈值 + tier 覆盖（仅覆盖非零字段）。
	policy := &storagev1alpha1.ThinPoolPolicy{
		Spec: storagev1alpha1.ThinPoolPolicySpec{
			Thresholds: storagev1alpha1.ThinPoolThresholds{
				WarningPercent: 70, CriticalPercent: 90, UnlockPercent: 85, MetadataCriticalPercent: 80,
			},
			TierOverrides: map[string]storagev1alpha1.ThinPoolThresholds{
				"hdd": {CriticalPercent: 95, UnlockPercent: 90},
			},
		},
	}
	base := ResolveThresholds(policy, "nvme")
	if base.WarningPercent != 70 || base.CriticalPercent != 90 || base.UnlockPercent != 85 || base.MetadataCriticalPercent != 80 {
		t.Fatalf("基础阈值覆盖失败：%+v", base)
	}
	hdd := ResolveThresholds(policy, "hdd")
	if hdd.CriticalPercent != 95 || hdd.UnlockPercent != 90 {
		t.Fatalf("tier 覆盖失败：%+v", hdd)
	}
	// tier 覆盖不得破坏继承字段。
	if hdd.WarningPercent != 70 || hdd.MetadataCriticalPercent != 80 {
		t.Fatalf("tier 覆盖错误继承：%+v", hdd)
	}
}

func TestNextCapacityStatus_Hysteresis(t *testing.T) {
	p := DefaultThresholds()
	cases := []struct {
		name  string
		cur   storagev1alpha1.CapacityStatus
		data  float64
		meta  float64
		oos   bool
		want  storagev1alpha1.CapacityStatus
	}{
		// 非锁定态自由升级。
		{"avail->pressure", storagev1alpha1.CapacityAvailable, 76, 10, false, storagev1alpha1.CapacityPressure},
		{"avail->locked by data", storagev1alpha1.CapacityAvailable, 85, 10, false, storagev1alpha1.CapacityLocked},
		{"avail->locked by meta", storagev1alpha1.CapacityAvailable, 50, 75, false, storagev1alpha1.CapacityLocked},
		// 锁定态：data 84 位于 critical(85) 与 unlock(80) 之间 → 保持锁定（滞回）。
		{"locked stays (84)", storagev1alpha1.CapacityLocked, 84, 10, false, storagev1alpha1.CapacityLocked},
		// 锁定态：data 70 < unlock(80) 且 meta 10 < 75 且未 oos → 解锁为 Available。
		{"locked->avail (70)", storagev1alpha1.CapacityLocked, 70, 10, false, storagev1alpha1.CapacityAvailable},
		// 锁定态：data 79 仍 >= warning(75) → 解锁为 Pressure（未低于 warning）。
		{"locked->pressure (79)", storagev1alpha1.CapacityLocked, 79, 10, false, storagev1alpha1.CapacityPressure},
		// 锁定态：meta 76 >= 75 → 即使 data 70 也不解锁。
		{"locked stays (meta 76)", storagev1alpha1.CapacityLocked, 70, 76, false, storagev1alpha1.CapacityLocked},
		// 锁定态：oos 为真 → 保持锁定。
		{"locked stays (oos)", storagev1alpha1.CapacityLocked, 70, 10, true, storagev1alpha1.CapacityLocked},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := NextCapacityStatus(c.cur, c.data, c.meta, c.oos, p); got != c.want {
				t.Fatalf("cur=%s data=%.0f meta=%.0f oos=%v want %s got %s", c.cur, c.data, c.meta, c.oos, c.want, got)
			}
		})
	}
}

func TestLockLabelName(t *testing.T) {
	if got := LockLabelName("nvme"); got != "storage.example.io/nvme-locked" {
		t.Fatalf("锁标签命名不符设计 §2.2：%s", got)
	}
}

func TestForecastCapacityAlert(t *testing.T) {
	// 容量 1TiB，data=80%，growth=10GiB/h → 剩余 ~200GiB → timeToFull≈20h（<24h → Warning）。
	capacity := int64(1) << 40 // 1 TiB
	cases := []struct {
		name    string
		data    float64
		growth  float64
		warn    time.Duration
		crit    time.Duration
		want    AlertLevel
		wantTTF bool
	}{
		{"no growth -> None", 80, 0, 24 * time.Hour, 4 * time.Hour, AlertNone, false},
		{"fast fill < crit", 80, 100 << 30, 24 * time.Hour, 4 * time.Hour, AlertCritical, true}, // 200GiB/100GiB/h=2h
		{"medium fill < warn", 80, 10 << 30, 24 * time.Hour, 4 * time.Hour, AlertWarning, true},  // ~20h
		{"slow fill > warn", 80, 1 << 30, 24 * time.Hour, 4 * time.Hour, AlertNone, true},        // ~200h
		{"already full -> Critical", 100, 10 << 30, 24 * time.Hour, 4 * time.Hour, AlertCritical, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			lvl, ttf := ForecastCapacityAlert(c.data, capacity, c.growth, c.warn, c.crit)
			if lvl != c.want {
				t.Fatalf("want %s got %s", c.want, lvl)
			}
			if (ttf != nil) != c.wantTTF {
				t.Fatalf("ttf presence want %v got %v", c.wantTTF, ttf != nil)
			}
		})
	}
}

func TestParseSize(t *testing.T) {
	cases := []struct {
		in   string
		want int64
	}{
		{"1073741824", 1 << 30},
		{"1Gi", 1 << 30},
		{"50Gi", 50 * (1 << 30)},
		{"1Ti", 1 << 40},
	}
	for _, c := range cases {
		t.Run(c.in, func(t *testing.T) {
			got, err := ParseSize(c.in)
			if err != nil {
				t.Fatalf("err: %v", err)
			}
			if got != c.want {
				t.Fatalf("want %d got %d", c.want, got)
			}
		})
	}
	if _, err := ParseSize("not-a-size"); err == nil {
		t.Fatalf("expected parse error for invalid size")
	}
}

func TestCheckFreeVGSpace(t *testing.T) {
	// 空闲 30GiB。
	free := int64(30) * (1 << 30)
	if ok, _, err := CheckFreeVGSpace(free, ""); err != nil || !ok {
		t.Fatalf("空要求应通过：ok=%v err=%v", ok, err)
	}
	if ok, req, err := CheckFreeVGSpace(free, "50Gi"); err != nil || ok {
		t.Fatalf("30GiB < 50GiB 应不通过：ok=%v req=%d err=%v", ok, req, err)
	}
	if ok, req, err := CheckFreeVGSpace(free, "20Gi"); err != nil || !ok {
		t.Fatalf("30GiB >= 20GiB 应通过：ok=%v req=%d err=%v", ok, req, err)
	}
	if _, _, err := CheckFreeVGSpace(free, "bad"); err == nil {
		t.Fatalf("非法要求应报错")
	}
}

func TestRenderLVMConfAutoExtend(t *testing.T) {
	if got := RenderLVMConfAutoExtend(storagev1alpha1.ThinPoolThresholds{}); got != "" {
		t.Fatalf("无配置应返回空串，got %q", got)
	}
	got := RenderLVMConfAutoExtend(storagev1alpha1.ThinPoolThresholds{AutoExtendPercent: 80, AutoExtendStepPercent: 20})
	if got == "" || !containsSubstr(got, "thin_pool_autoextend_threshold = 80") || !containsSubstr(got, "thin_pool_autoextend_percent = 20") {
		t.Fatalf("渲染片段不符预期：%q", got)
	}
}

func TestPlanThinPoolExtend(t *testing.T) {
	cur := int64(100) * (1 << 30) // 100GiB
	free := int64(900) * (1 << 30)
	maxBytes := cur + free // 1TiB
	// 步长 20% → +20GiB，未超限。
	tgt, capped := PlanThinPoolExtend(cur, maxBytes, 20)
	if capped || tgt != cur+20*(1<<30) {
		t.Fatalf("常规扩容应 +20GiB 不超限：tgt=%d capped=%v", tgt, capped)
	}
	// 步长远超剩余 → 截断为 maxBytes 并标记 capped。
	tgt, capped = PlanThinPoolExtend(cur, maxBytes, 2000)
	if !capped || tgt != maxBytes {
		t.Fatalf("超额应截断为 maxBytes：tgt=%d capped=%v", tgt, capped)
	}
	// 无剩余空间 → 不扩容。
	if tgt, capped := PlanThinPoolExtend(cur, cur, 20); tgt != cur || capped {
		t.Fatalf("无剩余空间不应扩容：tgt=%d capped=%v", tgt, capped)
	}
}

func containsSubstr(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
