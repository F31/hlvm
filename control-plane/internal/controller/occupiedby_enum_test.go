package controller

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// TestAgentOccupiedByLabelsMatchCRDEnum 防止跨语言枚举漂移。
//
// Agent 把观测到的占用类型写入 `NodeDisk.status.occupiedBy`，该字段是 CRD 枚举
// （`none;filesystem;lvm-pv;md;mpath;holder;unknown`）。若 Rust 侧多写或改名一个值，
// API Server 会以 enum 校验拒绝**整条** status patch，观测写回静默失败（只在 agent 日志里
// 留一行 error）。两侧取值集合因此必须逐项一致。
func TestAgentOccupiedByLabelsMatchCRDEnum(t *testing.T) {
	goOnly := occupiedByFromGoSource(t)
	rustOnly := occupiedByFromRustSource(t)

	if len(goOnly) == 0 || len(rustOnly) == 0 {
		t.Fatalf("枚举解析为空（解析规则失效）：go=%v rust=%v", goOnly, rustOnly)
	}

	goSet := toSet(goOnly)
	rustSet := toSet(rustOnly)

	for v := range rustSet {
		if !goSet[v] {
			t.Errorf("agent 写回值 %q 不在 CRD OccupiedBy 枚举 %v 内（status patch 会被拒绝）", v, goOnly)
		}
	}
	for v := range goSet {
		if !rustSet[v] {
			t.Errorf("CRD 枚举值 %q 在 agent 侧无对应常量（%v）", v, rustOnly)
		}
	}
}

func occupiedByFromGoSource(t *testing.T) []string {
	t.Helper()
	src, err := os.ReadFile("../../api/v1alpha1/nodedisk_types.go")
	if err != nil {
		t.Fatalf("读取 nodedisk_types.go 失败: %v", err)
	}
	re := regexp.MustCompile(`Occupied\w+\s+OccupiedBy\s*=\s*"([a-z-]+)"`)
	var out []string
	for _, m := range re.FindAllStringSubmatch(string(src), -1) {
		out = append(out, m[1])
	}
	sort.Strings(out)
	return out
}

func occupiedByFromRustSource(t *testing.T) []string {
	t.Helper()
	src, err := os.ReadFile("../../../agent/src/agent/mod.rs")
	if err != nil {
		t.Fatalf("读取 agent/src/agent/mod.rs 失败: %v", err)
	}
	// 仅取 OCC_* 常量定义：classify_occupied 的返回值必须是这些常量之一。
	re := regexp.MustCompile(`pub const (OCC_\w+): &str = "([a-z-]+)";`)
	var out []string
	for _, m := range re.FindAllStringSubmatch(string(src), -1) {
		out = append(out, m[2])
	}
	sort.Strings(out)
	return out
}

func toSet(vals []string) map[string]bool {
	m := make(map[string]bool, len(vals))
	for _, v := range vals {
		m[strings.TrimSpace(v)] = true
	}
	return m
}
