package v1alpha1

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// fullStorageTask 返回**所有字段都非零**的 v1alpha1 StorageTask。
//
// 目的不是"看起来像真实对象"，而是让任何漏映射的字段都在往返比较里暴露出来：
// 零值字段即使被漏掉也发现不了（0 == 0、"" == ""），非零值才有区分度。
func fullStorageTask() *StorageTask {
	probe := metav1.NewTime(time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC))
	return &StorageTask{
		TypeMeta: metav1.TypeMeta{APIVersion: GroupVersion.String(), Kind: "StorageTask"},
		ObjectMeta: metav1.ObjectMeta{
			Name:            "task-wipe-d1",
			ResourceVersion: "999",
			Labels:          map[string]string{"hlvm.io/node": "node-a"},
			Annotations:     map[string]string{"hlvm.io/approved": "alice"},
			Finalizers:      []string{"storage.example.io/task-protection"},
		},
		Spec: StorageTaskSpec{
			NodeName:      "node-a",
			Type:          TaskWipe,
			Target:        TaskTarget{DiskRef: "d1"},
			Disks:         []string{"sda", "sdb"},
			ConfirmSerial: "SN-12345",
			DryRun:        true,
			ApprovedBy:    "alice",
			TTL:           "1h",
		},
		Status: StorageTaskStatus{
			Phase:       TaskSucceeded,
			StartedAt:   &probe,
			CompletedAt: &probe,
			Result:      "ok",
			Message:     "wipe 完成",
		},
	}
}

func TestStorageTaskConvertRoundTripIsLossless(t *testing.T) {
	alpha := fullStorageTask()

	var beta storagev1beta1.StorageTask
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}
	if beta.APIVersion != storagev1beta1.GroupVersion.String() || beta.Kind != "StorageTask" {
		t.Fatalf("TypeMeta 未改写为 v1beta1: %s/%s", beta.APIVersion, beta.Kind)
	}

	var back StorageTask
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("ConvertFrom 失败: %v", err)
	}

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

func TestStorageTaskConvertCoversEveryJSONField(t *testing.T) {
	alpha := fullStorageTask()
	var beta storagev1beta1.StorageTask
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}

	alphaJSON := normalizeJSON(t, alpha)
	betaJSON := normalizeJSON(t, &beta)

	delete(alphaJSON, "apiVersion")
	delete(betaJSON, "apiVersion")

	if !reflect.DeepEqual(alphaJSON, betaJSON) {
		a, _ := json.MarshalIndent(alphaJSON, "", "  ")
		b, _ := json.MarshalIndent(betaJSON, "", "  ")
		t.Fatalf("转换后 JSON 不等价（存在漏映射字段）\n--- v1alpha1 ---\n%s\n--- v1beta1 ---\n%s", a, b)
	}
}

func TestStorageTaskListConvertPreservesItems(t *testing.T) {
	first := fullStorageTask()
	second := fullStorageTask()
	second.Name = "task-vgcreate-vg1"
	second.Spec.Type = TaskVGCreate
	second.Spec.Disks = []string{"sdc"}
	list := &StorageTaskList{Items: []StorageTask{*first, *second}}

	var beta storagev1beta1.StorageTaskList
	if err := list.ConvertTo(&beta); err != nil {
		t.Fatalf("List.ConvertTo 失败: %v", err)
	}
	if len(beta.Items) != 2 {
		t.Fatalf("条目数不对: %d", len(beta.Items))
	}
	if beta.Items[1].Spec.Type != storagev1beta1.TaskVGCreate || beta.Items[1].Spec.Disks[0] != "sdc" {
		t.Fatalf("第二条未映射: %+v", beta.Items[1].Spec)
	}

	var back StorageTaskList
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("List.ConvertFrom 失败: %v", err)
	}
	if !reflect.DeepEqual(list.Items, back.Items) {
		t.Fatalf("列表往返不等")
	}
}
