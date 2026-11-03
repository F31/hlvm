package v1alpha1

import (
	"encoding/json"
	"reflect"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// fullStorageNodeOps 返回**所有字段都非零**的 v1alpha1 StorageNodeOps。
//
// 目的不是"看起来像真实对象"，而是让任何漏映射的字段都在往返比较里暴露出来：
// 零值字段即使被漏掉也发现不了（0 == 0、"" == ""），非零值才有区分度。
func fullStorageNodeOps() *StorageNodeOps {
	return &StorageNodeOps{
		TypeMeta: metav1.TypeMeta{APIVersion: GroupVersion.String(), Kind: "StorageNodeOps"},
		ObjectMeta: metav1.ObjectMeta{
			Name:            "ops-retire-node-a",
			ResourceVersion: "777",
			Labels:          map[string]string{"hlvm.io/node": "node-a"},
			Annotations:     map[string]string{"hlvm.io/force": "true"},
			Finalizers:      []string{"storage.example.io/nodeops-protection"},
		},
		Spec: StorageNodeOpsSpec{
			NodeName:  "node-a",
			Operation: NodeOpRetire,
			Force:     true,
		},
		Status: StorageNodeOpsStatus{
			Phase:        NodeOpsWaitPVCCleanup,
			BlockingPVCs: []string{"pvc-a", "pvc-b"},
		},
	}
}

func TestStorageNodeOpsConvertRoundTripIsLossless(t *testing.T) {
	alpha := fullStorageNodeOps()

	var beta storagev1beta1.StorageNodeOps
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}
	if beta.APIVersion != storagev1beta1.GroupVersion.String() || beta.Kind != "StorageNodeOps" {
		t.Fatalf("TypeMeta 未改写为 v1beta1: %s/%s", beta.APIVersion, beta.Kind)
	}

	var back StorageNodeOps
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

func TestStorageNodeOpsConvertCoversEveryJSONField(t *testing.T) {
	alpha := fullStorageNodeOps()
	var beta storagev1beta1.StorageNodeOps
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

func TestStorageNodeOpsListConvertPreservesItems(t *testing.T) {
	first := fullStorageNodeOps()
	second := fullStorageNodeOps()
	second.Name = "ops-isolate-node-b"
	second.Spec.Operation = NodeOpIsolate
	second.Spec.Force = false
	second.Status.Phase = NodeOpsDrain
	second.Status.BlockingPVCs = nil
	list := &StorageNodeOpsList{Items: []StorageNodeOps{*first, *second}}

	var beta storagev1beta1.StorageNodeOpsList
	if err := list.ConvertTo(&beta); err != nil {
		t.Fatalf("List.ConvertTo 失败: %v", err)
	}
	if len(beta.Items) != 2 {
		t.Fatalf("条目数不对: %d", len(beta.Items))
	}
	if beta.Items[1].Spec.Operation != storagev1beta1.NodeOpIsolate || beta.Items[1].Spec.Force {
		t.Fatalf("第二条未映射: %+v", beta.Items[1].Spec)
	}

	var back StorageNodeOpsList
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("List.ConvertFrom 失败: %v", err)
	}
	if !reflect.DeepEqual(list.Items, back.Items) {
		t.Fatalf("列表往返不等")
	}
}
