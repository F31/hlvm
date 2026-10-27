package controller

import (
	"testing"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func TestRedundancyWouldBeLost(t *testing.T) {
	cases := []struct {
		name       string
		layout     storagev1alpha1.VGLayout
		redundancy storagev1alpha1.Redundancy
		remaining  int
		want       bool
	}{
		{"per-disk none", storagev1alpha1.VGLayoutPerDisk, storagev1alpha1.RedundancyNone, 0, false},
		{"pooled none", storagev1alpha1.VGLayoutPooled, storagev1alpha1.RedundancyNone, 0, false},
		{"pooled raid1 remaining 2", storagev1alpha1.VGLayoutPooled, storagev1alpha1.RedundancyMDRAID1, 2, false},
		{"pooled raid1 remaining 1", storagev1alpha1.VGLayoutPooled, storagev1alpha1.RedundancyMDRAID1, 1, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := RedundancyWouldBeLost(c.layout, c.redundancy, c.remaining); got != c.want {
				t.Errorf("got %v want %v", got, c.want)
			}
		})
	}
}

func TestPlanRemoveDisks(t *testing.T) {
	// 盘 d1 被 LV 占用；d2 空闲；d3 空闲。
	occupancy := map[string][]string{
		"d1": {"lv-root"},
	}
	candidates := []string{"d1", "d2", "d3"}

	t.Run("no redundancy loss", func(t *testing.T) {
		plan := PlanRemoveDisks(candidates, occupancy, false)
		if len(plan.Approved) != 2 {
			t.Fatalf("approved = %v, want 2", plan.Approved)
		}
		if len(plan.Blocked) != 1 || plan.Blocked[0].Disk != "d1" {
			t.Fatalf("blocked = %v, want d1", plan.Blocked)
		}
		if len(plan.PendingOps) != 1 {
			t.Fatalf("pendingOps = %v, want 1", plan.PendingOps)
		}
	})

	t.Run("redundancy loss blocks all", func(t *testing.T) {
		// remaining = spec.disks(3) - approved(2) = 1 < 2 → 冗余丧失，整体拒绝。
		// 此时 d1 既被 LV 占用（保留其阻塞原因），d2/d3 因冗余丧失被整体拒绝。
		plan := PlanRemoveDisks(candidates, occupancy, true)
		if len(plan.Approved) != 0 {
			t.Fatalf("approved should be empty, got %v", plan.Approved)
		}
		if len(plan.Blocked) != 3 {
			t.Fatalf("blocked should be 3, got %v", plan.Blocked)
		}
		// pendingOps: 1 条 LV 占用原因 + 1 条整体冗余丧失原因。
		if len(plan.PendingOps) != 2 {
			t.Fatalf("pendingOps should be 2, got %v", plan.PendingOps)
		}
	})

	t.Run("empty candidates", func(t *testing.T) {
		plan := PlanRemoveDisks(nil, occupancy, false)
		if len(plan.Approved) != 0 || len(plan.Blocked) != 0 || len(plan.PendingOps) != 0 {
			t.Fatalf("empty plan expected, got %+v", plan)
		}
	})
}
