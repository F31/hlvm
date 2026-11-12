package metrics

import (
	"fmt"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestObserveReconcile(t *testing.T) {
	ctrl := ControllerCapacity
	before := testutil.ToFloat64(ReconcileErrors.WithLabelValues(ctrl))
	// 无错误：错误计数不增加，但不 panic。
	ObserveReconcile(ctrl, time.Now().Add(-10*time.Millisecond), nil)
	if got := testutil.ToFloat64(ReconcileErrors.WithLabelValues(ctrl)); got != before {
		t.Fatalf("无错误时错误计数应不变，got %v want %v", got, before)
	}
	// 有错误：错误计数 +1。
	ObserveReconcile(ctrl, time.Now().Add(-10*time.Millisecond), fmt.Errorf("boom"))
	if got := testutil.ToFloat64(ReconcileErrors.WithLabelValues(ctrl)); got != before+1 {
		t.Fatalf("有错误时错误计数应 +1，got %v want %v", got, before+1)
	}
	// 耗时被记录（histogram 不抛错即可，此处仅验证可观测调用路径）。
	if testutil.CollectAndCount(ReconcileDuration) < 1 {
		t.Fatal("reconcile 耗时 histogram 应已有样本")
	}
}

func TestObserveAdmission(t *testing.T) {
	wh := WebhookPVCValidator
	reason := "tier-no-available-node"
	rejBefore := testutil.ToFloat64(RejectionsTotal.WithLabelValues(wh, reason))
	admBefore := testutil.ToFloat64(AdmissionsTotal.WithLabelValues(wh, "denied"))

	ObserveAdmission(wh, time.Now().Add(-5*time.Millisecond), true, reason)

	if got := testutil.ToFloat64(RejectionsTotal.WithLabelValues(wh, reason)); got != rejBefore+1 {
		t.Fatalf("拒绝计数应 +1，got %v want %v", got, rejBefore+1)
	}
	if got := testutil.ToFloat64(AdmissionsTotal.WithLabelValues(wh, "denied")); got != admBefore+1 {
		t.Fatalf("denied 总数应 +1，got %v want %v", got, admBefore+1)
	}

	// 未拒绝：rejections 不变，admissions allowed +1。
	allowedBefore := testutil.ToFloat64(AdmissionsTotal.WithLabelValues(wh, "allowed"))
	ObserveAdmission(wh, time.Now().Add(-5*time.Millisecond), false, "")
	if got := testutil.ToFloat64(RejectionsTotal.WithLabelValues(wh, reason)); got != rejBefore+1 {
		t.Fatalf("未拒绝时拒绝计数不应变化，got %v", got)
	}
	if got := testutil.ToFloat64(AdmissionsTotal.WithLabelValues(wh, "allowed")); got != allowedBefore+1 {
		t.Fatalf("allowed 总数应 +1，got %v want %v", got, allowedBefore+1)
	}
}

func TestObserveBackup(t *testing.T) {
	ns, pvc := "prod", "p"
	// 成功：success 计数 +1，last-success 时间戳 >0。
	succBefore := testutil.ToFloat64(BackupTotal.WithLabelValues("success"))
	ObserveBackup("b1", ns, pvc, 100*time.Second, true)
	if got := testutil.ToFloat64(BackupTotal.WithLabelValues("success")); got != succBefore+1 {
		t.Fatalf("success 计数应 +1，got %v", got)
	}
	if got := testutil.ToFloat64(BackupLastSuccessTimestampSeconds.WithLabelValues(ns, pvc)); got <= 0 {
		t.Fatalf("last-success 时间戳应 >0，got %v", got)
	}
	// 失败：failed 计数 +1，last-success 不变。
	failBefore := testutil.ToFloat64(BackupTotal.WithLabelValues("failed"))
	ObserveBackup("b2", ns, pvc, 50*time.Second, false)
	if got := testutil.ToFloat64(BackupTotal.WithLabelValues("failed")); got != failBefore+1 {
		t.Fatalf("failed 计数应 +1，got %v", got)
	}
}

func TestSetBackupRPOOverdue(t *testing.T) {
	ns, pvc := "prod", "q"
	SetBackupRPOOverdue(ns, pvc, true)
	if got := testutil.ToFloat64(BackupRPOOverdue.WithLabelValues(ns, pvc)); got != 1 {
		t.Fatalf("逾期应置 1，got %v", got)
	}
	SetBackupRPOOverdue(ns, pvc, false)
	if got := testutil.ToFloat64(BackupRPOOverdue.WithLabelValues(ns, pvc)); got != 0 {
		t.Fatalf("达标应置 0，got %v", got)
	}
}

func TestSetBackupDrillLastSuccess(t *testing.T) {
	SetBackupDrillLastSuccess(time.Unix(1700000000, 0))
	if got := testutil.ToFloat64(BackupDrillLastSuccessTimestampSeconds); got != 1700000000 {
		t.Fatalf("演练时间戳应被设置，got %v", got)
	}
}

// 上报新鲜度必须「全量替换」：只 Set 不 Delete 会让已删节点的旧时间戳永远冻结在
// /metrics 上，`time() - ts` 持续增长 → 永久误告警（ADR-006 §17）。
func TestReplaceLVReportFreshness(t *testing.T) {
	ts := time.Unix(1700000000, 0)
	ReplaceLVReportFreshness([]LVReportFreshness{
		{Node: "utf-n1", VG: "vg-a", ReportedAt: &ts},
		{Node: "utf-n2", VG: "vg-b"}, // 从未上报
	})
	if got := testutil.ToFloat64(LVReportPresent.WithLabelValues("utf-n1", "vg-a")); got != 1 {
		t.Fatalf("有上报应 present=1，got %v", got)
	}
	if got := testutil.ToFloat64(LVReportTimestampSeconds.WithLabelValues("utf-n1", "vg-a")); got != 1700000000 {
		t.Fatalf("时间戳应为 1700000000，got %v", got)
	}
	if got := testutil.ToFloat64(LVReportPresent.WithLabelValues("utf-n2", "vg-b")); got != 0 {
		t.Fatalf("从未上报应 present=0，got %v", got)
	}
	// 从未上报不得留下时间戳序列：Unix 0 无法与「真的在 1970 上报过」区分。
	if n := testutil.CollectAndCount(LVReportTimestampSeconds); n != 1 {
		t.Fatalf("从未上报不应留下时间戳序列，got %d 条", n)
	}

	// 第二轮只保留 n2：n1 的两条序列都必须消失。
	ReplaceLVReportFreshness([]LVReportFreshness{{Node: "utf-n2", VG: "vg-b", ReportedAt: &ts}})
	if n := testutil.CollectAndCount(LVReportPresent); n != 1 {
		t.Fatalf("消失的 NodeVG 应被删除，present 应只剩 1 条，got %d", n)
	}
	if n := testutil.CollectAndCount(LVReportTimestampSeconds); n != 1 {
		t.Fatalf("消失的 NodeVG 应被删除，时间戳应只剩 1 条，got %d", n)
	}
}

func TestIncDriftReconcileSkipped(t *testing.T) {
	reason := "utf-reason"
	before := testutil.ToFloat64(DriftReconcileSkippedTotal.WithLabelValues(reason))
	IncDriftReconcileSkipped(reason)
	if got := testutil.ToFloat64(DriftReconcileSkippedTotal.WithLabelValues(reason)); got != before+1 {
		t.Fatalf("跳过计数应 +1，got %v want %v", got, before+1)
	}
}

// 消失的 kind 必须置 0 而不是删除序列：序列消失会让 `drift_items{kind="..."} > 0`
// 变成 no data，容易被告警系统当成「已恢复」（ADR-006 §17）。
func TestReplaceDriftItems(t *testing.T) {
	ReplaceDriftItems(map[string]int{"unmanaged-lv": 2, "missing-lv": 1})
	if got := testutil.ToFloat64(DriftItems.WithLabelValues("unmanaged-lv")); got != 2 {
		t.Fatalf("unmanaged-lv 应为 2，got %v", got)
	}
	if n := testutil.CollectAndCount(DriftItems); n != 2 {
		t.Fatalf("应有 2 条序列，got %d", n)
	}

	ReplaceDriftItems(map[string]int{"unmanaged-lv": 0})
	if n := testutil.CollectAndCount(DriftItems); n != 2 {
		t.Fatalf("消失的 kind 应置 0 而非删除，got %d 条", n)
	}
	if got := testutil.ToFloat64(DriftItems.WithLabelValues("missing-lv")); got != 0 {
		t.Fatalf("missing-lv 应归零，got %v", got)
	}
}
