package controller

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// nodeVGWithCapacity 构造一个带 VG 容量状态的 NodeVG（ADR-006 §23.12）。
func nodeVGWithCapacity(name, node string, total, free int64) *storagev1beta1.NodeVG {
	vg := &storagev1beta1.NodeVG{}
	vg.Name = name
	vg.Spec.NodeName = node
	vg.Status.TotalBytes = total
	vg.Status.FreeBytes = free
	return vg
}

func vgCapacitySeriesCount() int {
	return testutil.CollectAndCount(metrics.VGTotalBytes)
}

// Agent 上报可读容量时必须落地两条序列，且 node/vg 标签可用于告警 annotation。
func TestSyncVGCapacityMetricsExposesWhenReadable(t *testing.T) {
	vg := nodeVGWithCapacity("vg-cap", "n1", 1<<40, 400<<30)
	defer metrics.ForgetVGCapacity("vg-cap")

	before := vgCapacitySeriesCount()
	syncVGCapacityMetrics(vg)
	if after := vgCapacitySeriesCount(); after != before+1 {
		t.Fatalf("可读时应新增 1 条序列，before=%d after=%d", before, after)
	}
	if got := testutil.ToFloat64(metrics.VGTotalBytes.WithLabelValues("n1", "vg-cap")); got != float64(1<<40) {
		t.Fatalf("total_bytes 应为 %d，got %v", int64(1<<40), got)
	}
	if got := testutil.ToFloat64(metrics.VGFreeBytes.WithLabelValues("n1", "vg-cap")); got != float64(400<<30) {
		t.Fatalf("free_bytes 应为 %d，got %v", int64(400<<30), got)
	}
}

// freeBytes == 0 是合法的「VG 打满」：必须照常暴露 0，而不是当成未知删序列。
// 若这里删了序列，`storage_vg_free_bytes == 0` 类规则在打满时永远不会触发。
func TestSyncVGCapacityMetricsKeepsZeroFreeAsMeasured(t *testing.T) {
	vg := nodeVGWithCapacity("vg-full", "n1", 1<<40, 0)
	defer metrics.ForgetVGCapacity("vg-full")

	syncVGCapacityMetrics(vg)
	if got := testutil.ToFloat64(metrics.VGFreeBytes.WithLabelValues("n1", "vg-full")); got != 0 {
		t.Fatalf("打满时 free_bytes 应为 0，got %v", got)
	}
	if got := testutil.ToFloat64(metrics.VGTotalBytes.WithLabelValues("n1", "vg-full")); got != float64(1<<40) {
		t.Fatalf("打满不影响 total_bytes，got %v", got)
	}
}

// 假绿防线的核心用例：采集失败（Agent 把字段置 null → 读回 0）必须删序列，
// 不能留着上一轮的总量/空闲冒充当前水位。
func TestSyncVGCapacityMetricsDropsWhenUnknown(t *testing.T) {
	vg := nodeVGWithCapacity("vg-flip", "n1", 1<<40, 100<<30)
	syncVGCapacityMetrics(vg)
	if got := testutil.ToFloat64(metrics.VGTotalBytes.WithLabelValues("n1", "vg-flip")); got != float64(1<<40) {
		t.Fatalf("前置条件：应先暴露总量，got %v", got)
	}

	// Agent 采不到 → merge patch null 删掉两个字段 → Go 侧读回零值。
	vg.Status.TotalBytes = 0
	vg.Status.FreeBytes = 0
	syncVGCapacityMetrics(vg)

	if got := testutil.ToFloat64(metrics.VGTotalBytes.WithLabelValues("n1", "vg-flip")); got != 0 {
		t.Fatalf("未知后序列应已删除（读回 0），got %v", got)
	}
	// ToFloat64 对已删除序列同样返回 0，必须再用序列总数确认真的删掉了。
	countAfter := vgCapacitySeriesCount()
	syncVGCapacityMetrics(vg)
	if again := vgCapacitySeriesCount(); again != countAfter {
		t.Fatalf("重复未知不应反复增减序列，before=%d after=%d", countAfter, again)
	}
}

// spec.nodeName 为空时不产出序列：否则会生成 {node=""} 的脏序列，
// 被 `sum by (node)` 聚成一个不存在的节点，且永远不会自己消失。
func TestSyncVGCapacityMetricsSkipsWhenNodeNameEmpty(t *testing.T) {
	vg := nodeVGWithCapacity("vg-nonode", "", 1<<40, 1<<30)
	defer metrics.ForgetVGCapacity("vg-nonode")

	before := vgCapacitySeriesCount()
	syncVGCapacityMetrics(vg)
	if after := vgCapacitySeriesCount(); after != before {
		t.Fatalf("nodeName 为空时不得暴露序列，before=%d after=%d", before, after)
	}
}

// 负空闲量无物理意义（上报侧数据异常）：宁可不报，也不要把 -1 当成「几乎空」。
func TestSyncVGCapacityMetricsDropsNegativeFree(t *testing.T) {
	vg := nodeVGWithCapacity("vg-neg", "n1", 1<<40, -1)
	defer metrics.ForgetVGCapacity("vg-neg")

	before := vgCapacitySeriesCount()
	syncVGCapacityMetrics(vg)
	if after := vgCapacitySeriesCount(); after != before {
		t.Fatalf("空闲量为负时不得暴露序列，before=%d after=%d", before, after)
	}
}
