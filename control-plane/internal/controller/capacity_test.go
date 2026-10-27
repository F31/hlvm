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
