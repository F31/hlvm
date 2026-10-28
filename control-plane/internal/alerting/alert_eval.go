// Package alerting 实现设计 §8 监控告警矩阵评估与渠道路由（add-observability）。
//
// 评估函数均为纯函数（无外部依赖、无状态），输入即指标快照的派生值，便于单测与复用；
// 与 TopoLVM topolvm_* 指标并存时，本包仅引用本方案 storage_* 指标（见 internal/metrics 规范名常量），
// 保证口径单一。时间序列维度的"持续 5min"（data≥75% Warning）由 Prometheus `for:` 负责，
// 纯函数通过 DataSustained 接收该判断；media_errors 按增量判定（累计非 0 但无增量不重复告警）。
package alerting

import "fmt"

// Level 是告警级别（设计 §8 / §5.4 Critical ≤1min、Warning ≤5min）。
type Level string

const (
	LevelCritical = "critical"
	LevelWarning  = "warning"
	LevelInfo     = "info"
)

// AlertEvent 是一条已评估的告警事件。
type AlertEvent struct {
	Name    string
	Level   Level
	Message string
	// Channels 为可选显式渠道覆盖（如 VG 空闲不足转人工工单 "ticket"）；
	// 为空时由 AlertRouter 按 Level 默认渠道分发。
	Channels []string
}

// DiskSmartHealth 是 storage_disk_smart_health 的取值（设计 §5.4 注释 0/1/2/3）。
const (
	SmartHealthy  = 0
	SmartWarning  = 1
	SmartCritical = 2
	SmartFailed   = 3
)

// CapacityInput 是容量类告警评估输入（设计 §8 容量类全表）。
type CapacityInput struct {
	DataPercent      float64
	MetadataPercent  float64
	OutOfSpace       bool
	NeedsCheck       bool
	VGFreeBytes      int64
	VGFreeMinBytes   int64 // 阈值；0 表示未配置
	VGExpandable     bool
	TimeToFullSeconds *float64 // nil 表示增长速率未知
	DataSustained    bool      // data≥75% 是否持续（由 Prometheus for:5m 判定）
}

// EvaluateCapacityAlerts 评估容量类告警（§8 容量类）。返回事件列表，可能为空。
func EvaluateCapacityAlerts(in CapacityInput) []AlertEvent {
	var out []AlertEvent
	if in.DataPercent >= 85 {
		out = append(out, AlertEvent{
			Name:    "ThinPoolDataCritical",
			Level:   LevelCritical,
			Message: fmt.Sprintf("thinpool data 使用率 %.1f%% ≥ 85%%，立即置 locked 并通知", in.DataPercent),
		})
	} else if in.DataSustained && in.DataPercent >= 75 {
		out = append(out, AlertEvent{
			Name:    "ThinPoolDataWarning",
			Level:   LevelWarning,
			Message: fmt.Sprintf("thinpool data 使用率 %.1f%% ≥ 75%%（持续 5min），检查 autoextend 是否生效", in.DataPercent),
		})
	}

	if in.MetadataPercent >= 75 {
		out = append(out, AlertEvent{
			Name:    "ThinPoolMetadataCritical",
			Level:   LevelCritical,
			Message: fmt.Sprintf("thinpool metadata 使用率 %.1f%% ≥ 75%%，元数据扩容预案", in.MetadataPercent),
		})
	} else if in.MetadataPercent >= 50 {
		out = append(out, AlertEvent{
			Name:    "ThinPoolMetadataWarning",
			Level:   LevelWarning,
			Message: fmt.Sprintf("thinpool metadata 使用率 %.1f%% ≥ 50%%，关注元数据增长", in.MetadataPercent),
		})
	}

	if in.OutOfSpace || in.NeedsCheck {
		out = append(out, AlertEvent{
			Name:    "ThinPoolOutOfSpace",
			Level:   LevelCritical,
			Message: "thinpool 进入 out-of-space 或 needs_check，立即进入 Runbook §9.1",
		})
	}

	if ttf := in.TimeToFullSeconds; ttf != nil {
		switch {
		case *ttf < 4*3600:
			out = append(out, AlertEvent{
				Name:    "ThinPoolTimeToFullCritical",
				Level:   LevelCritical,
				Message: fmt.Sprintf("按增长速率预计 %.1f 小时内写满（<4h）", *ttf/3600),
			})
		case *ttf < 24*3600:
			out = append(out, AlertEvent{
				Name:    "ThinPoolTimeToFullWarning",
				Level:   LevelWarning,
				Message: fmt.Sprintf("按增长速率预计 %.1f 小时内写满（<24h）", *ttf/3600),
			})
		}
	}

	if in.VGFreeMinBytes > 0 && in.VGFreeBytes < in.VGFreeMinBytes && !in.VGExpandable {
		out = append(out, AlertEvent{
			Name:     "VGFreeInsufficient",
			Level:    LevelCritical,
			Message:  fmt.Sprintf("VG 空闲 %d 字节 < 阈值 %d 字节且无法扩容，转人工工单", in.VGFreeBytes, in.VGFreeMinBytes),
			Channels: []string{"ticket"},
		})
	}

	return out
}

// DiskInput 是磁盘类告警评估输入（设计 §8 磁盘类全表）。
type DiskInput struct {
	Node, Device, Media string
	SmartHealth         int     // 0/1/2/3
	CriticalWarning     uint64  // NVMe critical_warning 位图
	AvailableSparePercent float64
	AvailableSpareThreshold float64 // 低于则 Critical
	MediaErrorsPrev     uint64
	MediaErrorsCur      uint64
	TemperatureCelsius  float64
	TempWarningCelsius  float64
	PercentUsed         float64
	PercentUsedWarning  float64
	RaidProtected      bool // 无 RAID 时数据风险需明确告知
}

// EvaluateDiskAlerts 评估磁盘类告警（§8 磁盘类）。
func EvaluateDiskAlerts(in DiskInput) []AlertEvent {
	var out []AlertEvent

	smartCritical := in.SmartHealth >= SmartCritical // Critical(2) 或 Failed(3)
	if smartCritical || in.CriticalWarning != 0 || (in.AvailableSpareThreshold > 0 && in.AvailableSparePercent < in.AvailableSpareThreshold) {
		msg := "SMART Failed / critical_warning≠0 / available_spare 低于阈值，标记盘并启动换盘流程"
		if !in.RaidProtected {
			msg = "SMART 异常且无 RAID 保护：该盘数据存在丢失风险，明确告知业务并从其他副本重建"
		}
		out = append(out, AlertEvent{Name: "DiskSmartCritical", Level: LevelCritical, Message: msg})
	}

	// NVMe media_errors 按增量判定：累计非 0 但无增量不重复告警。
	if MediaErrorsIncremental(in.MediaErrorsPrev, in.MediaErrorsCur) {
		out = append(out, AlertEvent{
			Name:    "DiskMediaErrorsCritical",
			Level:   LevelCritical,
			Message: "NVMe media_errors 出现增量，标记盘并启动换盘流程",
		})
	}

	if in.TemperatureCelsius >= in.TempWarningCelsius && in.TempWarningCelsius > 0 {
		out = append(out, AlertEvent{
			Name:    "DiskTemperatureWarning",
			Level:   LevelWarning,
			Message: fmt.Sprintf("磁盘温度 %.1f℃ ≥ 阈值 %.1f℃，巡检", in.TemperatureCelsius, in.TempWarningCelsius),
		})
	}
	if in.PercentUsed >= in.PercentUsedWarning && in.PercentUsedWarning > 0 {
		out = append(out, AlertEvent{
			Name:    "DiskLifeWarning",
			Level:   LevelWarning,
			Message: fmt.Sprintf("磁盘寿命消耗 %.1f%% ≥ 阈值 %.1f%%，巡检", in.PercentUsed, in.PercentUsedWarning),
		})
	}

	return out
}

// MediaErrorsIncremental 判定 NVMe media_errors 是否出现增量（§8 "累计值非 0 但长期不变不重复告警"）。
func MediaErrorsIncremental(prev, cur uint64) bool {
	return cur > prev
}

// StructuralInput 是结构类告警评估输入（设计 §8 结构类全表）。
type StructuralInput struct {
	PVMissing     bool
	RaidDegraded  bool
	DmesgIOError  bool
	DriftDetected bool
}

// EvaluateStructuralAlerts 评估结构类告警（§8 结构类）。
func EvaluateStructuralAlerts(in StructuralInput) []AlertEvent {
	var out []AlertEvent
	if in.PVMissing {
		out = append(out, AlertEvent{Name: "PVMissing", Level: LevelCritical, Message: "检测到 PV missing，进入 §9.2 剧本"})
	}
	if in.RaidDegraded {
		out = append(out, AlertEvent{Name: "RaidDegraded", Level: LevelCritical, Message: "RAID 降级，进入 §9.3 剧本"})
	}
	if in.DmesgIOError {
		out = append(out, AlertEvent{Name: "DmesgIOError", Level: LevelCritical, Message: "内核/dmesg 出现 XFS 或 IO error，标记受影响 VG"})
	}
	if in.DriftDetected {
		out = append(out, AlertEvent{Name: "DriftDetected", Level: LevelWarning, Message: "CR/PV/LV 漂移，生成 drift 报告"})
	}
	return out
}

// ComponentInput 是组件类告警评估输入（设计 §8 组件类全表）。
// 数据面独立原则：agent 异常 ≠ 存储不可用，心跳丢失仅 Warning；webhook/控制面丢失 >2min 仅 Warning。
type ComponentInput struct {
	AgentHeartbeatAgeSeconds       float64
	AgentHeartbeatThresholdSeconds float64 // 默认 180（3min）
	ControlPlaneUnavailableSeconds float64
	ControlPlaneThresholdSeconds   float64 // 默认 120（2min）
}

// EvaluateComponentAlerts 评估组件类告警（§8 组件类）。
func EvaluateComponentAlerts(in ComponentInput) []AlertEvent {
	var out []AlertEvent
	if in.AgentHeartbeatThresholdSeconds > 0 && in.AgentHeartbeatAgeSeconds > in.AgentHeartbeatThresholdSeconds {
		out = append(out, AlertEvent{
			Name:    "AgentHeartbeatLost",
			Level:   LevelWarning,
			Message: "agent 心跳丢失 >3min（数据面不受影响，仅通知）",
		})
	}
	if in.ControlPlaneThresholdSeconds > 0 && in.ControlPlaneUnavailableSeconds > in.ControlPlaneThresholdSeconds {
		out = append(out, AlertEvent{
			Name:    "ControlPlaneUnavailable",
			Level:   LevelWarning,
			Message: "webhook/控制面 leader 丢失 >2min（数据面不受影响，仅通知）",
		})
	}
	return out
}
