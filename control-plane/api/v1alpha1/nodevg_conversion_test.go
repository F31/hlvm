package v1alpha1

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// fullNodeVG 返回**所有字段都非零**的 v1alpha1 NodeVG。
//
// 目的不是"看起来像真实对象"，而是让任何漏映射的字段都在往返比较里暴露出来：
// 零值字段即使被漏掉也发现不了（0 == 0、"" == ""），非零值才有区分度。
func fullNodeVG() *NodeVG {
	probe := metav1.NewTime(time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC))
	return &NodeVG{
		TypeMeta: metav1.TypeMeta{APIVersion: GroupVersion.String(), Kind: "NodeVG"},
		ObjectMeta: metav1.ObjectMeta{
			Name:            "node-a-vg",
			ResourceVersion: "12345",
			Labels:          map[string]string{"hlvm.io/node": "node-a"},
			Annotations:     map[string]string{"hlvm.io/tier": "nvme"},
			Finalizers:      []string{"storage.example.io/nodevg-protection"},
		},
		Spec: VGSpec{
			NodeName:        "node-a",
			Tier:            "nvme",
			DeviceClassName: "nvme-dc",
			Layout:          VGLayoutPooled,
			Redundancy:      RedundancyLVRAID1,
			Disks:           []string{"sda", "sdb"},
			ThinPool: ThinPoolSpec{
				Name:               "pool0",
				InitialSizePercent: 50,
				MaxSizePercent:     90,
				MetadataSize:       "1Gi",
				ChunkSize:          "128k",
				OverprovisionRatio: 2.5,
			},
			Operations: VGOperations{RemoveDisks: []string{"sdb"}},
		},
		Status: VGStatus{
			VGExists:        true,
			VGUUID:          "abc-123",
			TotalBytes:      2 << 40,
			FreeBytes:       1 << 40,
			ThinPool: VGThinPoolStatus{
				CurrentSizeBytes: 1 << 39,
				DataPercent:      42.5,
				MetadataPercent:  10.0,
				ProvisionedBytes: 3 << 39,
				State:            "active",
				OutOfSpace:       false,
			},
			CapacityStatus:     CapacityPressure,
			LastDriftCheck:     &probe,
			PendingOps:         []string{"remove sdb"},
			Conditions: []metav1.Condition{{
				Type:               "Ready",
				Status:             metav1.ConditionTrue,
				Reason:             "VGReady",
				Message:            "VG 就绪",
				LastTransitionTime: probe,
				ObservedGeneration: 3,
			}},
			GrowthBytesPerHour: 1 << 30,
			LvmdConfig:         "devices:\n  - name: nvme-dc\n",
		},
	}
}

func TestNodeVGConvertRoundTripIsLossless(t *testing.T) {
	alpha := fullNodeVG()

	var beta storagev1beta1.NodeVG
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}
	if beta.APIVersion != storagev1beta1.GroupVersion.String() || beta.Kind != "NodeVG" {
		t.Fatalf("TypeMeta 未改写为 v1beta1: %s/%s", beta.APIVersion, beta.Kind)
	}

	var back NodeVG
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("ConvertFrom 失败: %v", err)
	}

	// 逐字段往返无损：任何漏映射的字段都会在这里不等。
	if !reflect.DeepEqual(alpha.Spec, back.Spec) {
		t.Errorf("spec 往返不等\nin : %+v\nout: %+v", alpha.Spec, back.Spec)
	}
	if !reflect.DeepEqual(alpha.Status, back.Status) {
		t.Errorf("status 往返不等\nin : %+v\nout: %+v", alpha.Status, back.Status)
	}
	if !reflect.DeepEqual(alpha.ObjectMeta, back.ObjectMeta) {
		t.Errorf("ObjectMeta 往返不等\nin : %+v\nout: %+v", alpha.ObjectMeta, back.ObjectMeta)
	}
}

// TestNodeVGConvertCoversEveryJSONField 用 JSON 视角做"整对象等价"检查。
//
// reflect 比较依赖 Go 结构体形状，而 apiserver 真正比对的是序列化结果；
// 这里把两边序列化后整体比对（删除 apiVersion 后），能抓出"结构体里没有但 JSON tag 有"的漏映射。
func TestNodeVGConvertCoversEveryJSONField(t *testing.T) {
	alpha := fullNodeVG()
	var beta storagev1beta1.NodeVG
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}

	alphaJSON := normalizeJSON(t, alpha)
	betaJSON := normalizeJSON(t, &beta)

	// apiVersion 必然不同（这正是转换的目的），不参与比较。
	delete(alphaJSON, "apiVersion")
	delete(betaJSON, "apiVersion")

	if !reflect.DeepEqual(alphaJSON, betaJSON) {
		a, _ := json.MarshalIndent(alphaJSON, "", "  ")
		b, _ := json.MarshalIndent(betaJSON, "", "  ")
		t.Fatalf("转换后 JSON 不等价（存在漏映射字段）\n--- v1alpha1 ---\n%s\n--- v1beta1 ---\n%s", a, b)
	}
}

func TestNodeVGListConvertPreservesItems(t *testing.T) {
	first := fullNodeVG()
	second := fullNodeVG()
	second.Name = "node-b-vg"
	second.Spec.NodeName = "node-b"
	second.Spec.Disks = []string{"sdc"}
	list := &NodeVGList{Items: []NodeVG{*first, *second}}

	var beta storagev1beta1.NodeVGList
	if err := list.ConvertTo(&beta); err != nil {
		t.Fatalf("List.ConvertTo 失败: %v", err)
	}
	if len(beta.Items) != 2 {
		t.Fatalf("条目数不对: %d", len(beta.Items))
	}
	if beta.Items[1].Spec.NodeName != "node-b" || beta.Items[1].Spec.Disks[0] != "sdc" {
		t.Fatalf("第二条未映射: %+v", beta.Items[1].Spec)
	}

	var back NodeVGList
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("List.ConvertFrom 失败: %v", err)
	}
	if !reflect.DeepEqual(list.Items, back.Items) {
		t.Fatalf("列表往返不等")
	}
}
