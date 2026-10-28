package controller

import (
	"fmt"

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

// RenderLVMDConfig 由 NodeVG 渲染 lvmd 配置（TopoLVM 风格 device-class + thin-pool + overprovision）。
//
// 纯函数、确定性输出，供漂移检测逐字节比对（§2.3）。
//   - device-class 名取 VG 的 tier（缺省 default）；
//   - volume-group 取 NodeVG 名（本平台 VG 标识即 CR 名）；
//   - thin-pool 名取 spec.thinPool.name（缺省 thinpool）；
//   - overprovision-ratio 零值视为不超分（1.00）。
func RenderLVMDConfig(vg storagev1alpha1.NodeVG) string {
	op := vg.Spec.ThinPool.OverprovisionRatio
	if op == 0 {
		op = 1.0
	}
	dcName := vg.Spec.Tier
	if dcName == "" {
		dcName = "default"
	}
	tpName := vg.Spec.ThinPool.Name
	if tpName == "" {
		tpName = "thinpool"
	}
	return fmt.Sprintf(`# hlvm lvmd config (rendered from NodeVG %s)
device-classes:
  - name: %s
    volume-group: %s
    spare-gb: 0
    thin-pool:
      name: %s
      overprovision-ratio: %.2f
`, vg.Name, dcName, vg.Name, tpName, op)
}
