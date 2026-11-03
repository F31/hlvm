package v1alpha1

import (
	"encoding/json"
	"reflect"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// fullThinPoolPolicy 返回**所有字段都非零**的 v1alpha1 ThinPoolPolicy。
//
// ThinPoolPolicy 无 status 子资源，只校验 spec 往返。目的与 NodeVG 一致：让任何漏映射的字段
// 都在往返比较里暴露出来（零值字段即使被漏掉也发现不了，非零值才有区分度）。
func fullThinPoolPolicy() *ThinPoolPolicy {
	tier := map[string]ThinPoolThresholds{
		"nvme": {
			AutoExtendPercent:       80,
			AutoExtendStepPercent:   10,
			WarningPercent:          70,
			CriticalPercent:         90,
			UnlockPercent:           60,
			MetadataWarningPercent:  65,
			MetadataCriticalPercent: 85,
		},
	}
	return &ThinPoolPolicy{
		TypeMeta: metav1.TypeMeta{APIVersion: GroupVersion.String(), Kind: "ThinPoolPolicy"},
		ObjectMeta: metav1.ObjectMeta{
			Name:            "default",
			ResourceVersion: "555",
			Labels:          map[string]string{"hlvm.io/tier": "default"},
			Annotations:     map[string]string{"hlvm.io/managed": "true"},
			Finalizers:      []string{"storage.example.io/policy-protection"},
		},
		Spec: ThinPoolPolicySpec{
			Thresholds: ThinPoolThresholds{
				AutoExtendPercent:       75,
				AutoExtendStepPercent:   5,
				WarningPercent:          60,
				CriticalPercent:         85,
				UnlockPercent:           50,
				MetadataWarningPercent:  55,
				MetadataCriticalPercent: 80,
			},
			Forecast: ThinPoolForecast{
				TimeToFullWarning:  "24h",
				TimeToFullCritical: "4h",
			},
			Lock: ThinPoolLock{
				BlockNewPVC:        true,
				BlockPVCExpansion:  true,
			},
			RequireFreeVGSpace: "10%",
			AlertChannels:      []string{"slack-prod", "pagerduty"},
			TierOverrides:      tier,
		},
	}
}

func TestThinPoolPolicyConvertRoundTripIsLossless(t *testing.T) {
	alpha := fullThinPoolPolicy()

	var beta storagev1beta1.ThinPoolPolicy
	if err := alpha.ConvertTo(&beta); err != nil {
		t.Fatalf("ConvertTo 失败: %v", err)
	}
	if beta.APIVersion != storagev1beta1.GroupVersion.String() || beta.Kind != "ThinPoolPolicy" {
		t.Fatalf("TypeMeta 未改写为 v1beta1: %s/%s", beta.APIVersion, beta.Kind)
	}

	var back ThinPoolPolicy
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("ConvertFrom 失败: %v", err)
	}

	if !reflect.DeepEqual(alpha.Spec, back.Spec) {
		t.Errorf("spec 往返不等\nin : %+v\nout: %+v", alpha.Spec, back.Spec)
	}
	if !reflect.DeepEqual(alpha.ObjectMeta, back.ObjectMeta) {
		t.Errorf("ObjectMeta 往返不等\nin : %+v\nout: %+v", alpha.ObjectMeta, back.ObjectMeta)
	}
}

func TestThinPoolPolicyConvertCoversEveryJSONField(t *testing.T) {
	alpha := fullThinPoolPolicy()
	var beta storagev1beta1.ThinPoolPolicy
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

func TestThinPoolPolicyListConvertPreservesItems(t *testing.T) {
	first := fullThinPoolPolicy()
	second := fullThinPoolPolicy()
	second.Name = "tier-nvme"
	second.Spec.RequireFreeVGSpace = "20%"
	second.Spec.AlertChannels = []string{"slack-nvme"}
	list := &ThinPoolPolicyList{Items: []ThinPoolPolicy{*first, *second}}

	var beta storagev1beta1.ThinPoolPolicyList
	if err := list.ConvertTo(&beta); err != nil {
		t.Fatalf("List.ConvertTo 失败: %v", err)
	}
	if len(beta.Items) != 2 {
		t.Fatalf("条目数不对: %d", len(beta.Items))
	}
	if beta.Items[1].Spec.RequireFreeVGSpace != "20%" || beta.Items[1].Spec.AlertChannels[0] != "slack-nvme" {
		t.Fatalf("第二条未映射: %+v", beta.Items[1].Spec)
	}

	var back ThinPoolPolicyList
	if err := back.ConvertFrom(&beta); err != nil {
		t.Fatalf("List.ConvertFrom 失败: %v", err)
	}
	if !reflect.DeepEqual(list.Items, back.Items) {
		t.Fatalf("列表往返不等")
	}
}
