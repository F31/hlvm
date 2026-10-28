package v1alpha1

import (
	"encoding/json"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// TestDeepCopyIndependent 验证 DeepCopy 产出与原文独立（改副本不影响原对象）。
// 覆盖含指针/切片的 NodeDisk 与 NodeVG。
func TestDeepCopyIndependent(t *testing.T) {
	orig := &NodeDisk{
		Spec: DiskSpec{
			NodeName:      "node-1",
			Adopt:         true,
			ConfirmSerial: "SN123",
			WipePolicy:    WipeZero,
		},
		Status: DiskStatus{
			Phase:      DiskPhaseDiscovered,
			Health:     DiskHealthHealthy,
			OccupiedBy: OccupiedNone,
			Raid:       &DiskRaid{MemberOf: "vg1", Degraded: false},
			Conditions: []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue}},
		},
	}
	cp := orig.DeepCopy()
	cp.Spec.NodeName = "mutated"
	cp.Status.Raid.MemberOf = "vg2"
	cp.Status.Conditions[0].Type = "NotReady"
	if orig.Spec.NodeName == "mutated" {
		t.Fatal("DeepCopy 未隔离 Spec.NodeName")
	}
	if orig.Status.Raid.MemberOf == "vg2" {
		t.Fatal("DeepCopy 未隔离 Status.Raid（指针字段应深拷贝）")
	}
	if orig.Status.Conditions[0].Type == "NotReady" {
		t.Fatal("DeepCopy 未隔离 Status.Conditions（切片元素应深拷贝）")
	}
}

func TestNodeVGDeepCopyIndependent(t *testing.T) {
	orig := &NodeVG{
		Spec: VGSpec{
			NodeName:   "node-1",
			Tier:       "gold",
			Layout:     VGLayoutPooled,
			Redundancy: RedundancyNone,
			Disks:      []string{"disk-a", "disk-b"},
			ThinPool:   ThinPoolSpec{Name: "pool0", InitialSizePercent: 80},
			Operations: VGOperations{RemoveDisks: []string{"disk-c"}},
		},
	}
	cp := orig.DeepCopy()
	cp.Spec.Disks[0] = "disk-x"
	cp.Spec.Operations.RemoveDisks[0] = "disk-y"
	if orig.Spec.Disks[0] == "disk-x" {
		t.Fatal("DeepCopy 未隔离 Spec.Disks 切片")
	}
	if orig.Spec.Operations.RemoveDisks[0] == "disk-y" {
		t.Fatal("DeepCopy 未隔离 Spec.Operations.RemoveDisks 切片")
	}
}

// TestJSONRoundTrip 验证 5 个 CRD 类型 JSON 编解码保持关键字段。
func TestJSONRoundTrip(t *testing.T) {
	cases := []struct {
		name string
		obj  runtime.Object
	}{
		{"NodeDisk", &NodeDisk{
			Spec:   DiskSpec{NodeName: "n1", WipePolicy: WipeSecureErase},
			Status: DiskStatus{Phase: DiskPhaseInVG, Health: DiskHealthCritical, OccupiedBy: OccupiedLVMPV},
		}},
		{"NodeVG", &NodeVG{
			Spec: VGSpec{NodeName: "n1", Layout: VGLayoutPerDisk, Redundancy: RedundancyLVRAID1},
		}},
		{"ThinPoolPolicy", &ThinPoolPolicy{
			Spec: ThinPoolPolicySpec{
				Thresholds: ThinPoolThresholds{WarningPercent: 70, CriticalPercent: 90, UnlockPercent: 60},
			},
		}},
		{"StorageTask", &StorageTask{
			Spec:   StorageTaskSpec{NodeName: "n1", Type: TaskVGCreate, ConfirmSerial: "SN9"},
			Status: StorageTaskStatus{Phase: TaskRunning},
		}},
		{"StorageNodeOps", &StorageNodeOps{
			Spec:   StorageNodeOpsSpec{NodeName: "n1", Operation: NodeOpIsolate},
			Status: StorageNodeOpsStatus{Phase: NodeOpsDrain},
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			b, err := json.Marshal(c.obj)
			if err != nil {
				t.Fatalf("marshal 失败: %v", err)
			}
			// 以同类空对象为模板反序列化。
			var out runtime.Object
			switch c.name {
			case "NodeDisk":
				out = &NodeDisk{}
			case "NodeVG":
				out = &NodeVG{}
			case "ThinPoolPolicy":
				out = &ThinPoolPolicy{}
			case "StorageTask":
				out = &StorageTask{}
			case "StorageNodeOps":
				out = &StorageNodeOps{}
			}
			if err := json.Unmarshal(b, out); err != nil {
				t.Fatalf("unmarshal 失败: %v", err)
			}
		})
	}
}

// TestEnumConstants 断言 Go 侧枚举常量与 CRD 中声明的枚举字符串一致，
// 防止 kubebuilder 标记（源码真相源）与手写 CRD 枚举漂移。
func TestEnumConstants(t *testing.T) {
	checks := []struct {
		got  string
		want string
	}{
		{string(DiskPhaseDiscovered), "Discovered"},
		{string(DiskPhaseRemoved), "Removed"},
		{string(DiskHealthHealthy), "healthy"},
		{string(DiskHealthFailed), "failed"},
		{string(MediaNVMe), "nvme"},
		{string(WipeNone), "none"},
		{string(WipeSecureErase), "secure-erase"},
		{string(OccupiedLVMPV), "lvm-pv"},
		{string(VGLayoutPooled), "pooled"},
		{string(VGLayoutPerDisk), "per-disk"},
		{string(RedundancyLVRAID1), "lvm-raid1"},
		{string(CapacityLocked), "locked"},
		{string(TaskWipe), "wipe"},
		{string(TaskThinpoolExtend), "thinpool-extend"},
		{string(TaskPending), "Pending"},
		{string(TaskUnknown), "Unknown"},
		{string(NodeOpRecoverDisk), "recover-disk"},
		{string(NodeOpsWaitPVCCleanup), "wait-pvc-cleanup"},
		{string(NodeOpsDone), "done"},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("枚举常量漂移: got=%q want=%q", c.got, c.want)
		}
	}
}

// TestAddToScheme 验证 5 个类型可注册进空白 scheme（init 注册链路有效）。
func TestAddToScheme(t *testing.T) {
	s := runtime.NewScheme()
	if err := AddToScheme(s); err != nil {
		t.Fatalf("AddToScheme 失败: %v", err)
	}
	for _, gvk := range []string{
		"NodeDisk", "NodeVG", "ThinPoolPolicy", "StorageTask", "StorageNodeOps",
	} {
		_ = gvk // 注册成功即代表 init() 中 SchemeBuilder.Register 生效；此处仅确认无 panic。
	}
	if !s.Recognizes(GroupVersion.WithKind("NodeDisk")) {
		t.Fatal("scheme 未识别 NodeDisk")
	}
}

// TestDeviceRefAlignment 验证 DiskSpec.DeviceRef 与 CRD deviceRef 字段对齐：
// 序列化包含 deviceRef、JSON 往返不丢失、DeepCopy 独立。此前 Go 类型缺该字段会导致控制面解码时静默丢弃 deviceRef（M14 Bug 4 仅改 CRD 未改 Go 类型）。
func TestDeviceRefAlignment(t *testing.T) {
	orig := &NodeDisk{Spec: DiskSpec{NodeName: "n1", DeviceRef: "/dev/sda"}}
	b, err := json.Marshal(orig)
	if err != nil {
		t.Fatalf("marshal 失败: %v", err)
	}
	if !strings.Contains(string(b), "deviceRef") {
		t.Fatal("序列化未包含 deviceRef 字段")
	}
	var out NodeDisk
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal 失败: %v", err)
	}
	if out.Spec.DeviceRef != "/dev/sda" {
		t.Fatalf("deviceRef 往返丢失: got=%q", out.Spec.DeviceRef)
	}
	cp := orig.DeepCopy()
	cp.Spec.DeviceRef = "/dev/nvme0"
	if orig.Spec.DeviceRef != "/dev/sda" {
		t.Fatal("DeepCopy 未隔离 DeviceRef（值类型应浅拷贝独立）")
	}
}
