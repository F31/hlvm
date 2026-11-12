package controller

import (
	"context"
	"fmt"
	"strings"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/client"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// DefaultLVReportMaxAge 是控制面接受 Agent LV 上报的最长滞后时间（ADR-006 §16）。
// Agent 每 30s 采样、最长 60s 保活写回；3min 允许连续两轮写失败才判过期。
const DefaultLVReportMaxAge = 3 * time.Minute

// LV 上报不可用的原因（作为指标 reason 标签取值，ADR-006 §17）。
//
// 必须是**闭集常量**而不是任意错误串：reason 做指标标签，若拼进 node/vg 会打爆基数，
// 也会把内部拓扑暴露到 /metrics。
const (
	LVReportReasonListFailed = "list_failed"
	LVReportReasonNoNodeVG   = "no_nodevg"
	LVReportReasonMissing    = "report_missing"
	LVReportReasonStale      = "report_stale"
)

// LVReportUnavailableError 表示某节点的 LV 上报不可用，携带脱敏后的原因分类。
type LVReportUnavailableError struct {
	Node   string
	VG     string
	Reason string
	Detail string
}

func (e *LVReportUnavailableError) Error() string { return e.Detail }

// NodeVGLVReporter 是 LVReporter 的生产实现：从 NodeVG.status.logicalVolumes 读取
// Agent 在宿主 `lvs` 采集并回写的实际 LV 清单（ADR-006 §16 路线 B）。
//
// 单写者边界：本类型**只读** NodeVG.status；logicalVolumes / lastLVReportTime 的唯一
// 写者是节点 Agent（patch /status 子资源）。控制面其余控制器不得改写这两个字段。
//
// 失败关闭：任何数据缺失/过期/无对应 NodeVG 都返回 error，由 DriftDetectorReconciler
// 整轮放弃对账（绝不能「部分节点有 actual、部分没有」→ 后者全部变成 missing-lv 误报）。
type NodeVGLVReporter struct {
	client.Client
	// MaxAge 是上报新鲜度上限；<=0 时取 DefaultLVReportMaxAge。
	MaxAge time.Duration
	// Now 注入时钟（单测用）；nil 时取 time.Now。
	Now func() time.Time
}

func (r *NodeVGLVReporter) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *NodeVGLVReporter) maxAge() time.Duration {
	if r.MaxAge > 0 {
		return r.MaxAge
	}
	return DefaultLVReportMaxAge
}

// ListActualLVs 返回指定节点上 Agent 上报的业务 LV（含 node/vg 归属）。
func (r *NodeVGLVReporter) ListActualLVs(node string) ([]ActualLV, error) {
	var list storagev1beta1.NodeVGList
	if err := r.List(context.Background(), &list); err != nil {
		return nil, &LVReportUnavailableError{
			Node:   node,
			Reason: LVReportReasonListFailed,
			Detail: fmt.Sprintf("读取 NodeVG 列表失败（LV 上报未覆盖）: %v", err),
		}
	}

	maxAge := r.maxAge()
	now := r.now()
	out := make([]ActualLV, 0)
	found := false
	for i := range list.Items {
		vg := &list.Items[i]
		if vg.Spec.NodeName != node {
			continue
		}
		found = true
		if vg.Status.LastLVReportTime == nil {
			return nil, &LVReportUnavailableError{
				Node: node, VG: vg.Name, Reason: LVReportReasonMissing,
				Detail: fmt.Sprintf("node=%s vg=%s 尚无 LV 上报（lastLVReportTime 为空），本轮对账未覆盖", node, vg.Name),
			}
		}
		age := now.Sub(vg.Status.LastLVReportTime.Time)
		if age < 0 {
			// 控制面时钟落后于 Agent（NTP 抖动）：不判过期，也别把未来时间当新鲜度凭证。
			age = 0
		}
		if age > maxAge {
			return nil, &LVReportUnavailableError{
				Node: node, VG: vg.Name, Reason: LVReportReasonStale,
				Detail: fmt.Sprintf("node=%s vg=%s LV 上报已过期 %s（上限 %s），本轮对账未覆盖",
					node, vg.Name, age.Round(time.Second), maxAge),
			}
		}
		for _, lv := range vg.Status.LogicalVolumes {
			if lv.Name == "" {
				continue
			}
			// 兜底过滤：旧版 Agent（未过滤 thin-pool）或内部 LV 泄漏时，控制面不能
			// 把它们算成业务 LV，否则每个节点稳定产生一条 unmanaged-lv 误报。
			if lv.Name == vg.Spec.ThinPool.Name || strings.HasPrefix(lv.Name, "[") {
				continue
			}
			out = append(out, ActualLV{
				Node: node, VG: vg.Name, Name: lv.Name, Bytes: lv.Bytes,
			})
		}
	}
	if !found {
		return nil, &LVReportUnavailableError{
			Node: node, Reason: LVReportReasonNoNodeVG,
			Detail: fmt.Sprintf("node=%s 没有对应的 NodeVG，本轮对账未覆盖", node),
		}
	}
	return out, nil
}
