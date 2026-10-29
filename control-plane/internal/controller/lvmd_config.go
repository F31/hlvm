package controller

import (
	"fmt"
	"sort"
	"strings"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// ManagedNamespace 是 hlvm 控制面托管的命名空间（lvmd ConfigMap 等随附资源所在）。
const ManagedNamespace = "hlvm-system"

// ManagedAnnotation 标记资源由控制面渲染（漂移检测依据：带此注解且内容被人工改动即纠正）。
const ManagedAnnotation = "hlvm.dev/managed"

// LvmdConfigName 返回节点 lvmd ConfigMap 名（按节点名唯一，§2.1）。
func LvmdConfigName(nodeName string) string {
	return "hlmd-lvmd-" + nodeName
}

// DeviceClassName 返回 NodeVG 对应的 lvmd device-class 名（ADR-005）。
//
// 优先级：spec.deviceClassName > spec.tier > "default"。
// per-disk 布局下同节点多个 VG 共用同一 tier 时，由 spec.deviceClassName 区分。
func DeviceClassName(vg storagev1alpha1.NodeVG) string {
	if vg.Spec.DeviceClassName != "" {
		return vg.Spec.DeviceClassName
	}
	if vg.Spec.Tier != "" {
		return vg.Spec.Tier
	}
	return "default"
}

// AggregateLVMDConfig 由**同一节点**的全部 NodeVG 渲染一份 lvmd 配置。
//
// 语义（ADR-005，对齐 TopoLVM 的「每节点一份 lvmd.yaml、device-classes 为数组」）：
//   - 仅包含 status.vgExists=true 的 VG：device-class 指向尚不存在的 VG 会让 lvmd 无法服务该 class；
//     vgExists 由 false→true 会触发 NodeVG 事件并重渲染，窗口期可自愈；
//   - device-class 按名称**稳定升序**排列，保证确定性渲染与逐字节漂移比对；
//   - 同节点 device-class 名重复视为配置错误并返回 error（不生成 lvmd 会拒绝的文件）；
//   - **ok=false 表示该节点没有可服务的 device-class**（无 vgExists=true 的 VG）。此时不产出配置：
//     TopoLVM lvmd 的 ValidateDeviceClasses 对空列表直接报错
//     （`should have at least one device-class`，见 ADR-005 补遗），
//     写 `device-classes: []` 等于下发一份 lvmd 无法启动的配置。调用方应删除托管 ConfigMap。
func AggregateLVMDConfig(vgs []storagev1alpha1.NodeVG) (string, bool, error) {
	type entry struct {
		name string
		body string
	}
	entries := make([]entry, 0, len(vgs))
	owner := make(map[string]string, len(vgs))

	for _, vg := range vgs {
		if !vg.Status.VGExists {
			continue
		}
		name := DeviceClassName(vg)
		if prev, ok := owner[name]; ok {
			return "", false, fmt.Errorf(
				"同节点 device-class 名冲突: %q 同时来自 NodeVG %q 与 %q（请设置 spec.deviceClassName 区分）",
				name, prev, vg.Name)
		}
		owner[name] = vg.Name

		op := vg.Spec.ThinPool.OverprovisionRatio
		if op == 0 {
			op = 1.0
		}
		tpName := vg.Spec.ThinPool.Name
		if tpName == "" {
			tpName = "thinpool"
		}
		entries = append(entries, entry{
			name: name,
			body: fmt.Sprintf("  - name: %s\n    volume-group: %s\n    spare-gb: 0\n    thin-pool:\n      name: %s\n      overprovision-ratio: %.2f\n",
				name, vg.Name, tpName, op),
		})
	}

	sort.Slice(entries, func(i, j int) bool { return entries[i].name < entries[j].name })

	var b strings.Builder
	b.WriteString("# hlvm lvmd config (aggregated from NodeVGs on this node)\n")
	if len(entries) == 0 {
		// 不渲染 `device-classes: []`：lvmd 会拒绝该配置（见函数注释与 ADR-005 补遗）。
		return "", false, nil
	}
	b.WriteString("device-classes:\n")
	for _, e := range entries {
		b.WriteString(e.body)
	}
	return b.String(), true, nil
}
