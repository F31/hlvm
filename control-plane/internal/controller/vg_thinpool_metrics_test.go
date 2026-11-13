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
	// 但必须留下「采不到」的显式信号，否则五条阈值告警会一起静默。
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-legacy", "thinpool")); got != 0 {
		t.Fatalf("state 为空时 collect_ok 应为 0，got %v", got)
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

// ---- collect_ok：让「采不到」不再等于「静默」（ADR-006 §23.13） --------------

func thinPoolCollectCount() int {
	return testutil.CollectAndCount(metrics.ThinPoolCollectOK)
}

// 可读时 collect_ok=1，转不可读时数据序列消失但 collect_ok=0 留着。
// 这是本轮的核心判据：容量告警在不可读时会静默，必须有一条序列替它说话。
func TestSyncThinPoolMetricsExposesCollectOK(t *testing.T) {
	vg := nodeVGWithThinPool("vg-ok-flag", "n1", "thinpool", "ok", 42.5)
	defer metrics.ForgetThinPool("vg-ok-flag")

	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-ok-flag", "thinpool")); got != 1 {
		t.Fatalf("可读时 collect_ok 应为 1，got %v", got)
	}

	vg.Status.ThinPool.State = "unreadable"
	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-ok-flag", "thinpool")); got != 0 {
		t.Fatalf("不可读时 collect_ok 应为 0，got %v", got)
	}
	// 数据序列必须同时消失：0% 会被 `>= 85` 判为安全。
	if got := testutil.ToFloat64(metrics.ThinPoolDataPercent.WithLabelValues("n1", "vg-ok-flag", "thinpool")); got != 0 {
		t.Fatalf("不可读时 data_percent 序列应已删除（读回 0），got %v", got)
	}
}

// 恢复后 collect_ok 必须回 1，不能是单向门闩（否则告警永久挂着）。
func TestSyncThinPoolMetricsRecoversCollectOK(t *testing.T) {
	vg := nodeVGWithThinPool("vg-recover", "n1", "thinpool", "unreadable", 0)
	defer metrics.ForgetThinPool("vg-recover")

	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-recover", "thinpool")); got != 0 {
		t.Fatalf("前置条件：collect_ok 应为 0，got %v", got)
	}

	vg.Status.ThinPool.State = "ok"
	vg.Status.ThinPool.DataPercent = 55
	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-recover", "thinpool")); got != 1 {
		t.Fatalf("恢复后 collect_ok 应为 1，got %v", got)
	}
	if got := testutil.ToFloat64(metrics.ThinPoolDataPercent.WithLabelValues("n1", "vg-recover", "thinpool")); got != 55 {
		t.Fatalf("恢复后 data_percent 应为 55，got %v", got)
	}
}

// 不涉及 thin-pool 的 VG（A 链路设备直通）绝不能产生 collect_ok 序列：
// 否则 `collect_ok == 0` 会对每个无池 VG 常亮，把真故障淹掉。
func TestSyncThinPoolMetricsNoCollectOKForThickVG(t *testing.T) {
	vg := nodeVGWithThinPool("vg-no-pool", "n1", "", "unreadable", 0)
	defer metrics.ForgetThinPool("vg-no-pool")

	before := thinPoolCollectCount()
	syncThinPoolMetrics(vg)
	if after := thinPoolCollectCount(); after != before {
		t.Fatalf("无池 VG 不得产生 collect_ok 序列，before=%d after=%d", before, after)
	}
}

// spec 改名（tp-old → tp-new）后旧池名的数据序列必须被清掉并转成 collect_ok=0：
// 否则看板上一个不存在的池会一直显示最后已知水位。
func TestMarkThinPoolCollectFailedPrunesRenamedPool(t *testing.T) {
	vg := nodeVGWithThinPool("vg-rename", "n1", "tp-old", "ok", 90)
	defer metrics.ForgetThinPool("vg-rename")

	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolDataPercent.WithLabelValues("n1", "vg-rename", "tp-old")); got != 90 {
		t.Fatalf("前置条件：旧池应暴露 90，got %v", got)
	}

	vg.Spec.ThinPool.Name = "tp-new"
	vg.Status.ThinPool.State = "unreadable"
	syncThinPoolMetrics(vg)

	if got := testutil.ToFloat64(metrics.ThinPoolDataPercent.WithLabelValues("n1", "vg-rename", "tp-old")); got != 0 {
		t.Fatalf("改名后旧池数据序列应已删除，got %v", got)
	}
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-rename", "tp-new")); got != 0 {
		t.Fatalf("新池 collect_ok 应为 0，got %v", got)
	}
	// 旧池的 collect_ok 也必须清掉，否则会留下两条互斥的 collect_ok。
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-rename", "tp-old")); got != 0 {
		t.Fatalf("旧池 collect_ok 应已删除，got %v", got)
	}
}

// NodeVG 删除后 collect_ok 必须一起消失（无对象还在被告警）。
func TestForgetThinPoolRemovesCollectOK(t *testing.T) {
	vg := nodeVGWithThinPool("vg-del", "n1", "thinpool", "unreadable", 0)
	syncThinPoolMetrics(vg)
	if got := testutil.ToFloat64(metrics.ThinPoolCollectOK.WithLabelValues("n1", "vg-del", "thinpool")); got != 0 {
		t.Fatalf("前置条件：collect_ok 应为 0，got %v", got)
	}

	before := thinPoolCollectCount()
	metrics.ForgetThinPool("vg-del")
	if after := thinPoolCollectCount(); after != before-1 {
		t.Fatalf("删除后 collect_ok 序列应减少 1，before=%d after=%d", before, after)
	}
	metrics.ForgetThinPool("vg-del") // 幂等
}
