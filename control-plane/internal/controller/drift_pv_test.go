package controller

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// 以下常量是 2026-11-12 真机（SC hlvm-b / TopoLVM v0.42.0 / 节点 10-60-153-100）
// 创建 1Gi PVC 后读到的真实值，见 ADR-006 §15。用真实值而非自拟占位符，
// 是为了让「PV 名 ≠ LV 名」这个容易回退的事实被测试钉死。
const (
	realPVName       = "pvc-cf9b6816-3cb3-477f-b139-fc408de3cf4a"
	realVolumeHandle = "9e639840-23de-403e-aebe-2335b9505816"
	realNode         = "10-60-153-100"
	realVG           = "hlvm-lvmd-vg-153"
	realPVCBytes     = int64(1073741824)
)

func topoLVMManagedPV() corev1.PersistentVolume {
	return corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{
			Name: realPVName,
			// 真机实测：只有 provisioned-by 等注解，没有 hlvm.dev/node / hlvm.dev/vg。
			Annotations: map[string]string{"pv.kubernetes.io/provisioned-by": "topolvm.io"},
		},
		Spec: corev1.PersistentVolumeSpec{
			Capacity: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("1Gi")},
			PersistentVolumeSource: corev1.PersistentVolumeSource{
				CSI: &corev1.CSIPersistentVolumeSource{
					Driver:       "topolvm.io",
					VolumeHandle: realVolumeHandle,
				},
			},
			NodeAffinity: &corev1.VolumeNodeAffinity{
				Required: &corev1.NodeSelector{
					NodeSelectorTerms: []corev1.NodeSelectorTerm{{
						MatchExpressions: []corev1.NodeSelectorRequirement{{
							Key: "topology.topolvm.io/node", Operator: corev1.NodeSelectorOpIn,
							Values: []string{realNode},
						}},
					}},
				},
			},
		},
	}
}

func realNodeVGs() []storagev1beta1.NodeVG {
	return []storagev1beta1.NodeVG{{
		ObjectMeta: metav1.ObjectMeta{Name: realVG},
		Spec:       storagev1beta1.VGSpec{NodeName: realNode, DeviceClassName: "hlvm-lvmd"},
	}}
}

func TestManagedLVsFromPVs_TopoLVMRealClusterFacts(t *testing.T) {
	pv := topoLVMManagedPV()
	got := ManagedLVsFromPVs([]corev1.PersistentVolume{pv}, realNodeVGs())
	if len(got) != 1 {
		t.Fatalf("真机形态的 TopoLVM PV 应产生 1 条账面项，got %d: %+v", len(got), got)
	}
	m := got[0]
	if m.Name != realVolumeHandle {
		t.Fatalf("账面 LV 名必须是 csi.volumeHandle=%s，got %q（用 pv.Name 会对账出双向误报）", realVolumeHandle, m.Name)
	}
	if m.Name == pv.Name {
		t.Fatal("账面 LV 名不能等于 pv.Name")
	}
	if m.Node != realNode || m.VG != realVG || m.Bytes != realPVCBytes {
		t.Fatalf("节点/VG/容量解析错误：got %+v，want node=%s vg=%s bytes=%d", m, realNode, realVG, realPVCBytes)
	}
}

func TestManagedLVsFromPVs_DetectDriftUsesVolumeHandle(t *testing.T) {
	pv := topoLVMManagedPV()
	managed := ManagedLVsFromPVs([]corev1.PersistentVolume{pv}, realNodeVGs())
	// actual 是宿主 lvs 上报的那颗 thin LV，名字就是 volumeHandle。
	actual := []ActualLV{{Node: realNode, VG: realVG, Name: realVolumeHandle, Bytes: realPVCBytes}}
	if items := DetectDrift(managed, actual); len(items) != 0 {
		t.Fatalf("按 volumeHandle 对账应无漂移，got %+v", items)
	}
	// 反例：旧实现把 pv.Name 当 LV 名，同一组数据必然双向误报。
	bad := []ManagedLV{{Node: realNode, VG: realVG, Name: pv.Name, Bytes: realPVCBytes}}
	items := DetectDrift(bad, actual)
	kinds := map[string]bool{}
	for _, it := range items {
		kinds[it.Kind] = true
	}
	if len(items) != 2 || !kinds["unmanaged-lv"] || !kinds["missing-lv"] {
		t.Fatalf("旧实现应产生 unmanaged-lv + missing-lv 双向误报，got %+v", items)
	}
}

func TestManagedLVsFromPVs_SkipIncompleteOrUnrelated(t *testing.T) {
	base := topoLVMManagedPV()
	cases := []struct {
		name   string
		mutate func(*corev1.PersistentVolume)
		vgs    []storagev1beta1.NodeVG
	}{
		{"非 topolvm.io 驱动", func(p *corev1.PersistentVolume) { p.Spec.CSI.Driver = "other.csi.io" }, realNodeVGs()},
		{"缺 volumeHandle", func(p *corev1.PersistentVolume) { p.Spec.CSI.VolumeHandle = "" }, realNodeVGs()},
		{"缺 nodeAffinity 且无注解", func(p *corev1.PersistentVolume) { p.Spec.NodeAffinity = nil }, realNodeVGs()},
		{"节点无对应 NodeVG（VG 无法反查）", func(p *corev1.PersistentVolume) {}, nil},
		{"非 CSI 且无注解", func(p *corev1.PersistentVolume) { p.Spec.PersistentVolumeSource.CSI = nil; p.Spec.NodeAffinity = nil }, realNodeVGs()},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pv := *base.DeepCopy()
			tc.mutate(&pv)
			if got := ManagedLVsFromPVs([]corev1.PersistentVolume{pv}, tc.vgs); len(got) != 0 {
				t.Fatalf("信息不全/非本平台的 PV 必须跳过而不是产生账面项，got %+v", got)
			}
		})
	}
}

func TestManagedLVsFromPVs_LegacyAnnotationPathUnchanged(t *testing.T) {
	// hlvm 自研供给 / envtest 形态：无 CSI，靠 hlvm.dev/node 注解归属，PV 名即账面 LV 名。
	pv := boundPV("pv-1", "n1", "default", "claim")
	pv.Annotations[PVVGAnnotation] = "vg0"
	got := ManagedLVsFromPVs([]corev1.PersistentVolume{pv}, nil)
	if len(got) != 1 || got[0].Name != "pv-1" || got[0].Node != "n1" || got[0].VG != "vg0" {
		t.Fatalf("注解兼容路径语义被改变：got %+v", got)
	}
}

func TestDetectDrift_ThinPoolLVNeedsReporterFiltering(t *testing.T) {
	// 宿主 lvs 同时包含 thin-pool 自身（lv_attr=twi...，无 pool_lv）。LVReporter 接线时
	// 必须在 agent 上报侧过滤 pool/内部 LV，否则每个节点都会稳定产生一条 unmanaged-lv
	// 误报。此测试把该前置行为固定下来，供 §15 与后续接线引用。
	managed := ManagedLVsFromPVs([]corev1.PersistentVolume{topoLVMManagedPV()}, realNodeVGs())
	actual := []ActualLV{
		{Node: realNode, VG: realVG, Name: realVolumeHandle, Bytes: realPVCBytes},
		{Node: realNode, VG: realVG, Name: "thinpool", Bytes: 38654705664},
	}
	items := DetectDrift(managed, actual)
	if len(items) != 1 || items[0].Kind != "unmanaged-lv" || items[0].LV != "thinpool" {
		t.Fatalf("未过滤的 thin-pool 应产生且只产生 1 条 unmanaged-lv，got %+v", items)
	}
}
