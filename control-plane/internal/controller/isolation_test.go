package controller

import (
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestIsolationExpired(t *testing.T) {
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	started := metav1.Time{Time: now.Add(-3 * 24 * time.Hour)} // 3 天前

	// nil 起始 → 不过期。
	if IsolationExpired(nil, DefaultIsolationTTL, now) {
		t.Fatal("nil 起始不应判过期")
	}
	// 默认 7 天窗口内（3 天）→ 未过期。
	if IsolationExpired(&started, 0, now) {
		t.Fatal("3 天应在 7 天隔离期内")
	}
	// 超过默认 7 天 → 过期。
	old := metav1.Time{Time: now.Add(-8 * 24 * time.Hour)}
	if !IsolationExpired(&old, 0, now) {
		t.Fatal("8 天应超过 7 天隔离期")
	}
	// 自定义 2 天窗口，3 天前 → 过期。
	if !IsolationExpired(&started, 2*24*time.Hour, now) {
		t.Fatal("自定义 2 天窗口下 3 天前应过期")
	}
}
