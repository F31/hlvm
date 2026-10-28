package alerting

import "testing"

func has(events []AlertEvent, name string) bool {
	for _, e := range events {
		if e.Name == name {
			return true
		}
	}
	return false
}

func TestEvaluateCapacityAlerts(t *testing.T) {
	// data ≥85% → Critical；data 80% 持续 → Warning；不持续 → 无。
	cases := []struct {
		name    string
		in      CapacityInput
		want    []string
		notWant []string
	}{
		{"data-critical", CapacityInput{DataPercent: 90}, []string{"ThinPoolDataCritical"}, nil},
		{"data-warning-sustained", CapacityInput{DataPercent: 80, DataSustained: true}, []string{"ThinPoolDataWarning"}, nil},
		{"data-warning-not-sustained", CapacityInput{DataPercent: 80, DataSustained: false}, nil, []string{"ThinPoolDataWarning"}},
		{"metadata-critical", CapacityInput{MetadataPercent: 80}, []string{"ThinPoolMetadataCritical"}, nil},
		{"metadata-warning", CapacityInput{MetadataPercent: 60}, []string{"ThinPoolMetadataWarning"}, nil},
		{"out-of-space", CapacityInput{OutOfSpace: true}, []string{"ThinPoolOutOfSpace"}, nil},
		{"needs-check", CapacityInput{NeedsCheck: true}, []string{"ThinPoolOutOfSpace"}, nil},
		{"ttf-critical", CapacityInput{TimeToFullSeconds: ptrf(3 * 3600)}, []string{"ThinPoolTimeToFullCritical"}, []string{"ThinPoolTimeToFullWarning"}},
		{"ttf-warning", CapacityInput{TimeToFullSeconds: ptrf(10 * 3600)}, []string{"ThinPoolTimeToFullWarning"}, nil},
		{"ttf-none", CapacityInput{TimeToFullSeconds: ptrf(30 * 3600)}, nil, []string{"ThinPoolTimeToFullWarning", "ThinPoolTimeToFullCritical"}},
		{"vg-free-insufficient", CapacityInput{VGFreeBytes: 1, VGFreeMinBytes: 10, VGExpandable: false}, []string{"VGFreeInsufficient"}, nil},
		{"vg-free-ok", CapacityInput{VGFreeBytes: 100, VGFreeMinBytes: 10, VGExpandable: false}, nil, []string{"VGFreeInsufficient"}},
		{"vg-free-but-expandable", CapacityInput{VGFreeBytes: 1, VGFreeMinBytes: 10, VGExpandable: true}, nil, []string{"VGFreeInsufficient"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := EvaluateCapacityAlerts(c.in)
			for _, w := range c.want {
				if !has(got, w) {
					t.Fatalf("期望含告警 %s，实际 %+v", w, got)
				}
			}
			for _, nw := range c.notWant {
				if has(got, nw) {
					t.Fatalf("不应含告警 %s，实际 %+v", nw, got)
				}
			}
		})
	}
}

func TestEvaluateDiskAlerts(t *testing.T) {
	// 无 RAID 的 SMART 异常 → 明确数据风险文案。
	noRaid := EvaluateDiskAlerts(DiskInput{SmartHealth: SmartFailed, RaidProtected: false})
	if !has(noRaid, "DiskSmartCritical") {
		t.Fatal("SmartFailed 应触发 DiskSmartCritical")
	}
	for _, e := range noRaid {
		if e.Name == "DiskSmartCritical" && e.Level != LevelCritical {
			t.Fatalf("DiskSmartCritical 应为 critical，got %s", e.Level)
		}
	}

	// critical_warning≠0 → Critical。
	if !has(EvaluateDiskAlerts(DiskInput{CriticalWarning: 1}), "DiskSmartCritical") {
		t.Fatal("critical_warning≠0 应触发 DiskSmartCritical")
	}
	// available_spare 低于阈值 → Critical。
	if !has(EvaluateDiskAlerts(DiskInput{AvailableSparePercent: 1, AvailableSpareThreshold: 5}), "DiskSmartCritical") {
		t.Fatal("available_spare 低于阈值应触发 DiskSmartCritical")
	}
	// media_errors 增量 → Critical；累计非 0 无增量 → 不重复告警。
	if !has(EvaluateDiskAlerts(DiskInput{MediaErrorsPrev: 0, MediaErrorsCur: 1}), "DiskMediaErrorsCritical") {
		t.Fatal("media_errors 增量应触发 Critical")
	}
	if has(EvaluateDiskAlerts(DiskInput{MediaErrorsPrev: 5, MediaErrorsCur: 5}), "DiskMediaErrorsCritical") {
		t.Fatal("media_errors 累计非 0 无增量不应重复告警")
	}
	// 温度/寿命 Warning。
	if !has(EvaluateDiskAlerts(DiskInput{TemperatureCelsius: 70, TempWarningCelsius: 60}), "DiskTemperatureWarning") {
		t.Fatal("温度越界应触发 Warning")
	}
	if !has(EvaluateDiskAlerts(DiskInput{PercentUsed: 90, PercentUsedWarning: 80}), "DiskLifeWarning") {
		t.Fatal("寿命消耗越界应触发 Warning")
	}
}

func TestEvaluateStructuralAlerts(t *testing.T) {
	all := EvaluateStructuralAlerts(StructuralInput{PVMissing: true, RaidDegraded: true, DmesgIOError: true, DriftDetected: true})
	for _, w := range []string{"PVMissing", "RaidDegraded", "DmesgIOError", "DriftDetected"} {
		if !has(all, w) {
			t.Fatalf("应含 %s，实际 %+v", w, all)
		}
	}
	driftOnly := EvaluateStructuralAlerts(StructuralInput{DriftDetected: true})
	if len(driftOnly) != 1 || driftOnly[0].Level != LevelWarning {
		t.Fatalf("仅 drift 应为 1 条 Warning，got %+v", driftOnly)
	}
}

func TestEvaluateComponentAlerts(t *testing.T) {
	// agent 心跳丢失 >3min → Warning；控制面丢失 >2min → Warning。
	got := EvaluateComponentAlerts(ComponentInput{
		AgentHeartbeatAgeSeconds:       200,
		AgentHeartbeatThresholdSeconds: 180,
		ControlPlaneUnavailableSeconds: 130,
		ControlPlaneThresholdSeconds:   120,
	})
	if !has(got, "AgentHeartbeatLost") || !has(got, "ControlPlaneUnavailable") {
		t.Fatalf("应含两条组件告警，实际 %+v", got)
	}
	// 阈值内不触发。
	none := EvaluateComponentAlerts(ComponentInput{
		AgentHeartbeatAgeSeconds:       60,
		AgentHeartbeatThresholdSeconds: 180,
		ControlPlaneUnavailableSeconds: 30,
		ControlPlaneThresholdSeconds:   120,
	})
	if len(none) != 0 {
		t.Fatalf("阈值内不应触发组件告警，got %+v", none)
	}
}

func TestMediaErrorsIncremental(t *testing.T) {
	if MediaErrorsIncremental(0, 0) {
		t.Fatal("(0,0) 不应判定为增量")
	}
	if !MediaErrorsIncremental(0, 1) {
		t.Fatal("(0,1) 应判定为增量")
	}
	if MediaErrorsIncremental(5, 5) {
		t.Fatal("(5,5) 不应判定为增量")
	}
}

func ptrf(v float64) *float64 { return &v }

func TestEvaluateBackupAlerts(t *testing.T) {
	// 备份失败 → BackupFailed Critical。
	out := EvaluateBackupAlerts(BackupInput{BackupFailed: true})
	if !has(out, "BackupFailed") {
		t.Fatal("备份失败应产生 BackupFailed")
	}
	for _, e := range out {
		if e.Level != LevelCritical {
			t.Fatalf("BackupFailed 应为 Critical，got %s", e.Level)
		}
	}
	// RPO 逾期 → BackupRPOOverdue Critical。
	out = EvaluateBackupAlerts(BackupInput{RPOOverdueCount: 3})
	if !has(out, "BackupRPOOverdue") {
		t.Fatal("RPO 逾期应产生 BackupRPOOverdue")
	}
	// 全正常 → 无告警。
	if out := EvaluateBackupAlerts(BackupInput{}); len(out) != 0 {
		t.Fatalf("无异常应无告警，got %v", out)
	}
}
