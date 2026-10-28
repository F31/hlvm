package controller

import "testing"

func TestValidateForeignVGCorrespondence(t *testing.T) {
	// 空 VG → 安全（无数据可丢），但仍提示人工确认。
	c := ValidateForeignVGCorrespondence("vg1", nil, []string{"pv1"})
	if !c.Safe {
		t.Fatalf("空 VG 应判为安全，got %+v", c)
	}
	// 有 LV 无 PV → 不安全。
	c = ValidateForeignVGCorrespondence("vg1", []string{"lv1"}, nil)
	if c.Safe {
		t.Fatalf("有 LV 无 PV 应判为不安全，got %+v", c)
	}
	// LV 与 PV 均在 → 安全（交由人工复核）。
	c = ValidateForeignVGCorrespondence("vg1", []string{"lv1"}, []string{"pv1"})
	if !c.Safe {
		t.Fatalf("LV/PV 均在应判为安全，got %+v", c)
	}
}

func TestPlanRecoverDisk(t *testing.T) {
	// 无 force → 阻塞，不导入。
	if ok, _ := PlanRecoverDisk("vg1", []string{"lv1"}, []string{"pv1"}, false); ok {
		t.Fatal("无人工确认不应允许导入")
	}
	// 有 force 且对应关系安全 → 允许。
	if ok, _ := PlanRecoverDisk("vg1", []string{"lv1"}, []string{"pv1"}, true); !ok {
		t.Fatal("force + 安全对应关系应允许导入")
	}
	// 有 force 但对应关系不安全 → 仍阻塞。
	if ok, _ := PlanRecoverDisk("vg1", []string{"lv1"}, nil, true); ok {
		t.Fatal("force 但对应关系不安全不应允许导入")
	}
}
