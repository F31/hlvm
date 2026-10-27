package controller

import (
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func tp(t time.Time) *metav1.Time { tt := metav1.NewTime(t); return &tt }

func TestDecideStaleAction(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	th := 30 * time.Minute

	cases := []struct {
		name        string
		nodeReady   bool
		lastReady   *metav1.Time
		wantStale   bool
		wantIsolate bool
	}{
		{"ready node", true, tp(now.Add(-1 * time.Hour)), false, false},
		{"never ready", false, nil, false, false},
		{"not ready within threshold", false, tp(now.Add(-10 * time.Minute)), false, false},
		{"not ready beyond threshold", false, tp(now.Add(-40 * time.Minute)), true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := DecideStaleAction(c.nodeReady, c.lastReady, th, now)
			if d.Stale != c.wantStale {
				t.Errorf("Stale = %v, want %v", d.Stale, c.wantStale)
			}
			if d.ShouldIsolate != c.wantIsolate {
				t.Errorf("ShouldIsolate = %v, want %v", d.ShouldIsolate, c.wantIsolate)
			}
		})
	}
}
