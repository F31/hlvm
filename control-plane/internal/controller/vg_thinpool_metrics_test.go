package controller

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

// nodeVGWithThinPool 构造一个带 thin-pool 状态的 NodeVG（ADR-006 §23.11）。
func nodeVGWithThinPool(name, node, pool, state string, data float64) *storagev1beta1.NodeVG {
	vg := &storagev1beta1.NodeVG{}
	vg.Name = name
	vg.Spec.NodeName = node
	vg.Spec.ThinPool.Name = pool
	vg.Status.ThinPool.State = state
	vg.Status.ThinPool.DataPercent = data
	vg.Status.ThinPool.MetadataPercent = 10
	vg.Status.ThinPool.ProvisionedBytes = 8 << 30
	vg.Status.ThinPool.CurrentSizeBytes = 36 << 30
	return vg
}

func thinPoolSeriesCount() int {
	return testutil.CollectAndCount(metrics.ThinPoolDataPercent)
}

// Agent 上报 ok 时，指标必须落地（含告警 annotation 引用的 node/vg 标签）。
func TestSyncThinPoolMetricsExposesWhenReadable(t *testing.T) {
	vg := nodeVGWithThinPool("vg-readable", "n1", "thinpool", "ok", 42.5)
	defer metrics.ForgetThinPool("vg-readable")

	before := thinPoolSeriesCount()
	syncThinPoolMetrics(vg)
	if after := thinPoolSeriesCount(); after != before+1 {
		t.Fatalf("可读时应新增 1 条序列，before=%d after=%d", before, after)
	}
	if got := testutil.ToFloat64(metrics.ThinPoolDataPercent.WithLabelValues("n1", "vg-readable", "thinpool")); got != 42.5 {
		t.Fatalf("data_percent 应为 42.5，got %v", got)
	}
	if got := testutil.ToFloat64(metrics.ThinPoolOutOfSpace.WithLabelValues("n1", "vg-readable", "thinpool")); got != 0 {
		t.Fatalf("out_of_space 应为 0，got %v", got)
	}
}

// out-of-space 状态同样要暴露（否则 99% 打满时告警拿不到 data 值）。
func TestSyncThinPoolMetricsExposesOutOfSpace(t *testing.T) {
	vg := nodeVGWithThinPool("vg-oom", "n1", "thinpool", "out-of-space", 100)
	defer metrics.ForgetThinPool("vg-oom")

	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolOutOfSpace.WithLabelValues("n1", "vg-oom", "thinpool")); got != 1 {
		t.Fatalf("out_of_space 应为 1，got %v", got)
	}
}

// 假绿防线的核心用例：unreadable 必须把已有序列删掉，而不是留着最后已知水位。
func TestSyncThinPoolMetricsDropsWhenUnreadable(t *testing.T) {
	vg := nodeVGWithThinPool("vg-flip", "n1", "thinpool", "ok", 90)
	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolDataPercent.WithLabelValues("n1", "vg-flip", "thinpool")); got != 90 {
		t.Fatalf("前置条件：应先暴露 90，got %v", got)
	}

	vg.Status.ThinPool.State = "unreadable"
	syncThinPoolMetrics(vg)
	// ToFloat64 对不存在的序列返回 0，单看它分不清「删了」与「值是 0」，
	// 因此同时用序列总数断言确实被删除。
	before := thinPoolSeriesCount()
	syncThinPoolMetrics(vg)
	if after := thinPoolSeriesCount(); after != before {
		t.Fatalf("重复 unreadable 不应再新增序列，before=%d after=%d", before, after)
	}
	if got := testutil.ToFloat64(metrics.ThinPoolDataPercent.WithLabelValues("n1", "vg-flip", "thinpool")); got != 0 {
		t.Fatalf("unreadable 后序列应已删除（读回 0），got %v", got)
	}
}

// 旧 agent（≤ preview.6）不写 state，零值 "" 必须按不可读处理：
// 否则 0% 会让 `storage_thinpool_data_percent >= 85` 永远为假。
func TestSyncThinPoolMetricsTreatsEmptyStateAsUnreadable(t *testing.T) {
	vg := nodeVGWithThinPool("vg-legacy", "n1", "thinpool", "", 0)
	defer metrics.ForgetThinPool("vg-legacy")

	before := thinPoolSeriesCount()
	syncThinPoolMetrics(vg)
	if after := thinPoolSeriesCount(); after != before {
		t.Fatalf("state 为空时不得暴露序列，before=%d after=%d", before, after)
	}
}

// spec.thinPool.name 缺失（thick-only VG）时不应产生 {pool=""} 脏序列。
func TestSyncThinPoolMetricsSkipsWhenPoolNameEmpty(t *testing.T) {
	vg := nodeVGWithThinPool("vg-thick", "n1", "", "ok", 10)
	defer metrics.ForgetThinPool("vg-thick")

	before := thinPoolSeriesCount()
	syncThinPoolMetrics(vg)
	if after := thinPoolSeriesCount(); after != before {
		t.Fatalf("pool 名为空时不得暴露序列，before=%d after=%d", before, after)
	}
}
