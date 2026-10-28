package webhook

import (
	"context"
	"testing"

	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func newValidatorWith(objs ...client.Object) *PVCValidator {
	scheme := testScheme()
	b := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...)
	return &PVCValidator{Reader: b.Build(), Recorder: record.NewFakeRecorder(10)}
}

func TestPVCValidator_DenyWhenTierAllLocked(t *testing.T) {
	sc := platformSC("hlvm-nvme", "nvme")
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityLocked)
	p := pvc("pvc-1", "hlvm-nvme", "10Gi")
	v := newValidatorWith(sc, &vg, p)

	if _, err := v.ValidateCreate(context.Background(), p); err == nil {
		t.Fatal("tier 全 locked 应拒绝创建 PVC")
	}
}

func TestPVCValidator_AllowWhenTierAvailable(t *testing.T) {
	sc := platformSC("hlvm-nvme", "nvme")
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityAvailable)
	p := pvc("pvc-1", "hlvm-nvme", "10Gi")
	v := newValidatorWith(sc, &vg, p)

	if _, err := v.ValidateCreate(context.Background(), p); err != nil {
		t.Fatalf("tier 可用应允许，got %v", err)
	}
}

func TestPVCValidator_NonPlatformPassthrough(t *testing.T) {
	sc := thirdPartySC("ebs")
	p := pvc("pvc-1", "ebs", "10Gi")
	v := newValidatorWith(sc, p)

	if _, err := v.ValidateCreate(context.Background(), p); err != nil {
		t.Fatalf("第三方 SC PVC 应直通，got %v", err)
	}
}

func TestPVCValidator_ExpandUpdateDenied(t *testing.T) {
	sc := platformSC("hlvm-nvme", "nvme")
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityLocked)
	old := pvc("pvc-1", "hlvm-nvme", "10Gi")
	big := pvc("pvc-1", "hlvm-nvme", "20Gi")
	v := newValidatorWith(sc, &vg, old)

	if _, err := v.ValidateUpdate(context.Background(), old, big); err == nil {
		t.Fatal("扩容 UPDATE 在 tier 全 locked 时应拒绝")
	}
}

func TestPVCValidator_NonExpandUpdateAllowed(t *testing.T) {
	sc := platformSC("hlvm-nvme", "nvme")
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityLocked)
	old := pvc("pvc-1", "hlvm-nvme", "10Gi")
	same := pvc("pvc-1", "hlvm-nvme", "10Gi")
	same.Annotations = map[string]string{"team": "x"} // 仅注解变更，非扩容
	v := newValidatorWith(sc, &vg, old)

	if _, err := v.ValidateUpdate(context.Background(), old, same); err != nil {
		t.Fatalf("非扩容 UPDATE 应允许，got %v", err)
	}
}

func TestPVCValidator_ReplicasWarningNotBlocking(t *testing.T) {
	sc := platformSC("hlvm-nvme", "nvme")
	vg := nodeVG("vg-n1", "nvme", storagev1alpha1.CapacityAvailable)
	p := pvc("pvc-1", "hlvm-nvme", "10Gi") // 无 replicas 注解
	v := newValidatorWith(sc, &vg, p)
	warn, err := v.admit(context.Background(), p)
	if err != nil {
		t.Fatalf("无 replicas 注解仅提示不强拦，got %v", err)
	}
	if len(warn) == 0 {
		t.Fatal("应产生 replicas 声明提示")
	}
}
