package controller

import (
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// StaleDecision 是 disk-ctrl 对节点失联的处置决策（设计 §7 disk-ctrl）。
type StaleDecision struct {
	// Stale 表示节点已失联超过阈值。
	Stale bool
	// ShouldIsolate 表示应触发节点隔离流程入口（创建 StorageNodeOps(isolate)）。
	ShouldIsolate bool
	// Reason 说明判定依据。
	Reason string
}

// DecideStaleAction 依据节点 Ready 条件与最后就绪时间判定是否失联（纯函数，便于单测）。
//
// 规则：
//   - nodeReady=true（当前 Ready=True）：未失联，不处理。
//   - nodeReady=false 且 lastReady 为空：从未就绪，不自动隔离（交由其他机制处理）。
//   - nodeReady=false 且 now-lastReady > threshold：失联超限，应隔离。
//   - nodeReady=false 且在阈值内：暂不打扰。
func DecideStaleAction(nodeReady bool, lastReady *metav1.Time, threshold time.Duration, now time.Time) StaleDecision {
	if nodeReady {
		return StaleDecision{Stale: false, Reason: "node ready"}
	}
	if lastReady == nil {
		return StaleDecision{Stale: false, Reason: "node never reported ready; not auto-isolating"}
	}
	if now.Sub(lastReady.Time) > threshold {
		return StaleDecision{
			Stale:         true,
			ShouldIsolate: true,
			Reason:        "node not ready beyond stale threshold",
		}
	}
	return StaleDecision{Stale: false, Reason: "node not ready but within stale threshold"}
}
