package controller

import (
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// 漂移检测与 break-glass 相关常量（设计 §3.5/§3.2/§3.3）。
const (
	// BreakGlassAnnotation 标记节点/命名空间处于授权窗口（窗口内允许手工操作并事后补录）。
	BreakGlassAnnotation = "storage.example.io/break-glass"
	// DefaultBreakGlassWindow 默认授权窗口时长。
	DefaultBreakGlassWindow = 2 * time.Hour
)

// DriftItem 是一条漂移发现（CR/PV/lvs 三方对账不一致，§3.2）。
type DriftItem struct {
	Node       string
	VG         string
	LV         string
	Kind       string // "unmanaged-lv"（人工 lvcreate 绕过）| "missing-lv"（人工 lvremove）
	Suggestion string // "reconcile"（补录）| "rollback"（回滚/核实）
	Detail     string
}

// DetectDrift 三方对账：找出实际 lvs 与平台 managed（PV/CR）的不一致（§3.2）。
//
// 返回需告警的漂移项及补录/回滚建议。平台 SHALL NOT 自动修复，仅告警 + 建议。
// managed 或 actual 为空时返回空（无 lvs 上报或无可对账账面时不误报）。
func DetectDrift(managed []ManagedLV, actual []ActualLV) []DriftItem {
	if len(managed) == 0 || len(actual) == 0 {
		return nil
	}
	managedSet := make(map[string]ManagedLV, len(managed))
	for _, m := range managed {
		managedSet[lvKey(m.Node, m.VG, m.Name)] = m
	}
	actualSet := make(map[string]ActualLV, len(actual))
	for _, a := range actual {
		actualSet[lvKey(a.Node, a.VG, a.Name)] = a
	}
	var items []DriftItem
	// 实际存在但平台未记录 → 疑似人工 lvcreate 绕过平台（补录建议）。
	for k, a := range actualSet {
		if _, ok := managedSet[k]; !ok {
			items = append(items, DriftItem{
				Node: a.Node, VG: a.VG, LV: a.Name, Kind: "unmanaged-lv",
				Suggestion: "reconcile", Detail: "实际 LV 无对应 PV/CR，疑似人工 lvcreate 绕过平台",
			})
		}
	}
	// 平台记录但实际不存在 → 疑似人工 lvremove（回滚/核实建议）。
	for k, m := range managedSet {
		if _, ok := actualSet[k]; !ok {
			items = append(items, DriftItem{
				Node: m.Node, VG: m.VG, LV: m.Name, Kind: "missing-lv",
				Suggestion: "rollback", Detail: "平台记录 LV 在实际 lvs 中缺失，疑似人工 lvremove 或盘丢失",
			})
		}
	}
	return items
}

// InBreakGlassWindow 判定当前是否处于 break-glass 授权窗口内（§3.3）。
//
// 窗口内允许手工操作，事后强制补录；窗口外手工操作将触发 drift 告警。
func InBreakGlassWindow(openedAt *metav1.Time, window time.Duration, now time.Time) bool {
	if openedAt == nil {
		return false
	}
	if window <= 0 {
		window = DefaultBreakGlassWindow
	}
	return now.Sub(openedAt.Time) <= window
}

// ParseBreakGlass 解析 break-glass 注解值（格式 "<openedAtRFC3339>|<duration>"，如 "2026-10-28T10:00:00Z|2h"）。
//
// 返回开启时间与窗口时长；格式非法返回零值 + false。
func ParseBreakGlass(value string) (openedAt time.Time, window time.Duration, ok bool) {
	parts := strings.SplitN(value, "|", 2)
	if len(parts) != 2 {
		return time.Time{}, 0, false
	}
	ot, err := time.Parse(time.RFC3339, parts[0])
	if err != nil {
		return time.Time{}, 0, false
	}
	d, err := time.ParseDuration(parts[1])
	if err != nil {
		return time.Time{}, 0, false
	}
	return ot, d, true
}
