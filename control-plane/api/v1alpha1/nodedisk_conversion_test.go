package v1alpha1

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// fullNodeDisk 返回**所有字段都非零**的 v1alpha1 NodeDisk。
//
// 目的不是"看起来像真实对象"，而是让任何漏映射的字段都在往返比较里暴露出来：
// 零值字段即使被漏掉也发现不了（0 == 0、"" == ""），非零值才有区分度。
func fullNodeDisk() *NodeDisk {
	probe := metav1.NewTime(time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC))
	return &NodeDisk{
		TypeMeta: metav1.TypeMeta{APIVersion: GroupVersion.String(), Kind: "NodeDisk"},
		ObjectMeta: metav1.ObjectMeta{
			Name:            "node-a-sda",
			ResourceVersion: "12345",
			Labels:          map[string]string{"hlvm.io/node": "node-a"},
			Annotations:     map[string]string{"hlvm.io/disk-name": "sda"},
			Finalizers:      []string{"storage.example.io/nodedisk-protection"},
		},
		Spec: DiskSpec{
			NodeName:      "node-a",
			Adopt:         true,
			DeviceRef:     "/dev/sda",
			ConfirmSerial: "SN12345678",
			WipePolicy:    WipeSecureErase,
		},
		Status: DiskStatus{
			Identity: DiskIdentity{
				Serial: "SN12345678",
				WWN:    "0x5000c500a1b2c3d4",
				Model:  "SAMSUNG MZ7L3480HCHQ",
				ByID:   "/dev/disk/by-id/wwn-0x5000c500a1b2c3d4",
			},
			CurrentDevice: "/dev/sdb",
			CapacityBytes: 480103981056,
			Phase:         DiskPhaseInVG,
			Health:        DiskHealthWarning,
			Smart: DiskSMART{
				LastProbeTime:         &probe,
				OverallStatus:         "PASSED",
				CriticalWarning:       2,
				AvailableSparePercent: 97,
				PercentUsed:           13,
				TemperatureCelsius:    41,
				MediaErrors:           7,
				MediaErrorsLastProbe:  5,
				UnsafeShutdowns:       3,
			},
			OccupiedBy:   OccupiedLVMPV,
			IsSystemDisk: false,
			Raid:         &DiskRaid{MemberOf: "md0", Degraded: true},
			VgRef:        "node-a-vg",
			Conditions: []metav1.Condition{{
				Type:               "Ready",
				Status:             metav1.ConditionTrue,
				Reason:             "PreCheckPassed",
				Message:            "预检通过",
				LastTransitionTime: probe,
				ObservedGeneration: 3,
			}},
		},
	}
}

func TestNodeDiskConvertRoundTripIsLossless(t *testing.T) {
	alpha := fullNodeDisk()

	var beta storagev1beta1.NodeDisk
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}

	// 映射本身：spec.deviceRef → spec.device.path
	if beta.Spec.Device == nil || beta.Spec.Device.Path != "/dev/sda" {
		t.Fatalf("deviceRef 未映射到 device.path，实际: %+v", beta.Spec.Device)
	}
	if beta.APIVersion != storagev1beta1.GroupVersion.String() || beta.Kind != "NodeDisk" {
		t.Fatalf("TypeMeta 未改写为 v1beta1: %s/%s", beta.APIVersion, beta.Kind)
	}

	var back NodeDisk
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

// TestNodeDiskConvertCoversEveryJSONField 用 JSON 视角做"整对象等价"检查。
//
// reflect 比较依赖 Go 结构体形状，而 apiserver 真正比对的是序列化结果；
// 这里把两边的 JSON 归一化（把 deviceRef/device 折成同一形状）后整体比对，
// 能抓出"结构体里没有但 JSON tag 有"这类漏映射（如 embed 字段、inline 字段）。
func TestNodeDiskConvertCoversEveryJSONField(t *testing.T) {
	alpha := fullNodeDisk()
	var beta storagev1beta1.NodeDisk
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}

	alphaJSON := normalizeJSON(t, alpha)
	betaJSON := normalizeJSON(t, &beta)

	// v1beta1 的 spec.device.path 归一化回 spec.deviceRef，便于直接比对。
	spec := betaJSON["spec"].(map[string]any)
	if dev, ok := spec["device"].(map[string]any); ok {
		spec["deviceRef"] = dev["path"]
		delete(spec, "device")
	}
	// apiVersion 必然不同（这正是转换的目的），不参与比较。
	delete(alphaJSON, "apiVersion")
	delete(betaJSON, "apiVersion")

	if !reflect.DeepEqual(alphaJSON, betaJSON) {
		a, _ := json.MarshalIndent(alphaJSON, "", "  ")
		b, _ := json.MarshalIndent(betaJSON, "", "  ")
		t.Fatalf("转换后 JSON 不等价（存在漏映射字段）\n--- v1alpha1 ---\n%s\n--- v1beta1(归一化) ---\n%s", a, b)
	}
}

func TestNodeDiskConvertEmptyDeviceRefBecomesNil(t *testing.T) {
	alpha := fullNodeDisk()
	alpha.Spec.DeviceRef = ""

	var beta storagev1beta1.NodeDisk
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}
	if beta.Spec.Device != nil {
		t.Fatalf("空 deviceRef 应映射为 nil，实际: %+v", beta.Spec.Device)
	}

	var back NodeDisk
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("ConvertFrom 失败: %v", err)
	}
	if back.Spec.DeviceRef != "" {
		t.Fatalf("nil device 应还原为空 deviceRef，实际: %q", back.Spec.DeviceRef)
	}
}

func TestNodeDiskListConvertPreservesItems(t *testing.T) {
	first := fullNodeDisk()
	second := fullNodeDisk()
	second.Name = "node-b-sdc"
	second.Spec.DeviceRef = "/dev/sdc"
	list := &NodeDiskList{Items: []NodeDisk{*first, *second}}

	var beta storagev1beta1.NodeDiskList
	if err := list.ConvertTo(&beta); err != nil {
		t.Fatalf("List.ConvertTo 失败: %v", err)
	}
	if len(beta.Items) != 2 {
		t.Fatalf("条目数不对: %d", len(beta.Items))
	}
	if beta.Items[1].Spec.Device == nil || beta.Items[1].Spec.Device.Path != "/dev/sdc" {
		t.Fatalf("第二条的 device 未映射: %+v", beta.Items[1].Spec.Device)
	}

	var back NodeDiskList
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("List.ConvertFrom 失败: %v", err)
	}
	if !reflect.DeepEqual(list.Items, back.Items) {
		t.Fatalf("列表往返不等")
	}
}

// normalizeJSON 把对象序列化为 map，便于按键比对（忽略字段顺序）。
func normalizeJSON(t *testing.T, obj any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(obj)
	if err != nil {
		t.Fatalf("序列化失败: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("反序列化失败: %v", err)
	}
	return m
}
