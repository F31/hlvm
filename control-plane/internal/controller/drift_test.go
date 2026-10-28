package controller

import (
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestDetectDrift(t *testing.T) {
	managed := []ManagedLV{
		{Node: "n1", VG: "vg1", Name: "lv-a"},
	}
	actual := []ActualLV{
		{Node: "n1", VG: "vg1", Name: "lv-a"},     // 一致
		{Node: "n1", VG: "vg1", Name: "lv-manual"}, // 人工 lvcreate
	}
	items := DetectDrift(managed, actual)
	if len(items) != 1 || items[0].Kind != "unmanaged-lv" || items[0].Suggestion != "reconcile" {
		t.Fatalf("应发现 1 条 unmanaged 漂移且建议补录，got %+v", items)
	}

	// 平台记录缺失（人工 lvremove）→ missing-lv + rollback。
	// 注意：actual 非空（含 lv-a），以区分“采集失败”与“真实缺失”；actual 为空时 DetectDrift 按设计返回空避免误报。
	missing := DetectDrift(
		[]ManagedLV{{Node: "n1", VG: "vg1", Name: "lv-a"}, {Node: "n1", VG: "vg1", Name: "lv-gone"}},
		[]ActualLV{{Node: "n1", VG: "vg1", Name: "lv-a"}},
	)
	var gotMissing *DriftItem
	for i := range missing {
		if missing[i].Kind == "missing-lv" {
			gotMissing = &missing[i]
		}
	}
	if gotMissing == nil || gotMissing.Suggestion != "rollback" {
		t.Fatalf("应发现 1 条 missing 漂移且建议回滚/核实，got %+v", missing)
	}

	// 任一侧为空 → 不误报。
	if got := DetectDrift(nil, actual); len(got) != 0 {
		t.Fatalf("managed 为空不应误报，got %+v", got)
	}
}

func TestInBreakGlassWindow(t *testing.T) {
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	opened := metav1.Time{Time: now.Add(-1 * time.Hour)} // 1 小时前

	if InBreakGlassWindow(nil, DefaultBreakGlassWindow, now) {
		t.Fatal("nil 开启时间不应在窗口内")
	}
	// 默认 2h 窗口内（1h 前开启）→ 在窗口内。
	if !InBreakGlassWindow(&opened, 0, now) {
		t.Fatal("1 小时前开启应在 2 小时窗口内")
	}
	// 超过默认窗口（3h 前开启）→ 不在窗口内。
	old := metav1.Time{Time: now.Add(-3 * time.Hour)}
	if InBreakGlassWindow(&old, 0, now) {
		t.Fatal("3 小时前开启应超过 2 小时窗口")
	}
}

func TestParseBreakGlass(t *testing.T) {
	ot, w, ok := ParseBreakGlass("2026-10-28T10:00:00Z|2h")
	if !ok || w != 2*time.Hour {
		t.Fatalf("合法注解应解析成功，got %v %v %v", ot, w, ok)
	}
	if _, _, ok := ParseBreakGlass("bad-format"); ok {
		t.Fatal("非法格式应解析失败")
	}
	if _, _, ok := ParseBreakGlass("2026-10-28T10:00:00Z|notadur"); ok {
		t.Fatal("非法时长应解析失败")
	}
}
