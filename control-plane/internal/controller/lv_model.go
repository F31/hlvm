package controller

// ManagedLV 是平台"账面"认为存在的 LV（来自 CR / PV，即 TopoLVM 按 PVC 创建的 LV）。
type ManagedLV struct {
	Node  string
	VG    string
	Name  string
	Bytes int64
}

// ActualLV 是节点上 lvs 实际报告的 LV（经 agent 采集上报；控制面当前尚未接入，待 agent 侧落地）。
type ActualLV struct {
	Node  string
	VG    string
	Name  string
	Bytes int64
}

// LVReporter 提供节点上实际 LV 列表（来自 agent lvs 采集）。
// 控制面当前尚未接入 agent LV 上报，默认 nil → 跳过三方对账的 lvs 一侧。
type LVReporter interface {
	ListActualLVs(node string) ([]ActualLV, error)
}

// lvKey 以 node/vg/name 生成 LV 唯一键，用于三方对账。
func lvKey(node, vg, name string) string {
	return node + "/" + vg + "/" + name
}
