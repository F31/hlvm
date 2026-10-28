package webhook

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	storagev1 "k8s.io/api/storage/v1"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	controller "github.com/F31/hlvm/control-plane/internal/controller"
)

func testScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(s)
	_ = storagev1alpha1.AddToScheme(s)
	return s
}

func platformSC(name, tier string) *storagev1.StorageClass {
	return &storagev1.StorageClass{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Provisioner: PlatformProvisioner,
		Parameters:  map[string]string{DeviceClassParam: tier},
	}
}

func thirdPartySC(name string) *storagev1.StorageClass {
	return &storagev1.StorageClass{ObjectMeta: metav1.ObjectMeta{Name: name}, Provisioner: "ebs.csi.aws.com"}
}

func nodeVG(name, tier string, status storagev1alpha1.CapacityStatus) storagev1alpha1.NodeVG {
	return storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec:       storagev1alpha1.VGSpec{NodeName: "n1", Tier: tier},
		Status:     storagev1alpha1.VGStatus{CapacityStatus: status},
	}
}

func pvc(name, scName, size string) *corev1.PersistentVolumeClaim {
	sc := scName
	q := resource.MustParse(size)
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec: corev1.PersistentVolumeClaimSpec{
			StorageClassName: &sc,
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{corev1.ResourceStorage: q},
			},
		},
	}
}

func TestStorageClassTier(t *testing.T) {
	if _, ok := StorageClassTier(thirdPartySC("x")); ok {
		t.Fatal("第三方 SC 不应识别为平台 SC")
	}
	tier, ok := StorageClassTier(platformSC("hlvm-nvme", "nvme"))
	if !ok || tier != "nvme" {
		t.Fatalf("平台 SC 应解析 tier=nvme，got %q %v", tier, ok)
	}
}

func TestTierHasAvailableNode(t *testing.T) {
	vgs := []storagev1alpha1.NodeVG{
		nodeVG("vg1", "nvme", storagev1alpha1.CapacityLocked),
		nodeVG("vg2", "nvme", storagev1alpha1.CapacityPressure),
		nodeVG("vg3", "ssd", storagev1alpha1.CapacityLocked),
	}
	if !TierHasAvailableNode(vgs, "nvme") {
		t.Fatal("nvme 有 pressure 节点应判为可用")
	}
	if TierHasAvailableNode(vgs, "ssd") {
		t.Fatal("ssd 全 locked 应判为不可用")
	}
	if TierHasAvailableNode(vgs, "hdd") {
		t.Fatal("未知 tier 应判为不可用")
	}
}

func TestBuildLockedNodeAffinity(t *testing.T) {
	aff := BuildLockedNodeAffinity([]string{"nvme"})
	if aff == nil || aff.RequiredDuringSchedulingIgnoredDuringExecution == nil {
		t.Fatal("应构造 required nodeAffinity")
	}
	terms := aff.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms
	if len(terms) != 1 || len(terms[0].MatchExpressions) != 1 {
		t.Fatalf("期望 1 条 term + 1 个表达式，got %+v", terms)
	}
	expr := terms[0].MatchExpressions[0]
	if expr.Key != controller.LockLabelName("nvme") || expr.Operator != corev1.NodeSelectorOpNotIn {
		t.Fatalf("锁标签表达式不符，got %+v", expr)
	}
	if BuildLockedNodeAffinity(nil) != nil {
		t.Fatal("空 tier 应返回 nil")
	}
}

func TestIsExpand(t *testing.T) {
	old := pvc("p", "sc", "10Gi")
	big := pvc("p", "sc", "20Gi")
	same := pvc("p", "sc", "10Gi")
	if !IsExpand(old, big) {
		t.Fatal("20Gi > 10Gi 应判为扩容")
	}
	if IsExpand(old, same) {
		t.Fatal("同容量不应判为扩容")
	}
}

func TestReplicasDeclared(t *testing.T) {
	p := pvc("p", "sc", "10Gi")
	if ReplicasDeclared(p) {
		t.Fatal("无 replicas 注解应判为未声明")
	}
	p.Annotations = map[string]string{ReplicasAnnotation: "3"}
	if !ReplicasDeclared(p) {
		t.Fatal("replicas=3 应判为已声明")
	}
	p.Annotations = map[string]string{ReplicasAnnotation: "notanint"}
	if ReplicasDeclared(p) {
		t.Fatal("非法 replicas 应判为未声明")
	}
}

func TestSanitizedDenyMessage(t *testing.T) {
	msg := SanitizedDenyMessage("nvme")
	if strContains(msg, "n1") || strContains(msg, "vg1") {
		t.Fatalf("脱敏信息不应含节点/VG 名，got %q", msg)
	}
	if !strContains(msg, "nvme") {
		t.Fatalf("脱敏信息应含 tier，got %q", msg)
	}
}

func TestPodReferencedPlatformTiers(t *testing.T) {
	scheme := testScheme()
	sc := platformSC("hlvm-nvme", "nvme")
	p := pvc("pvc-a", "hlvm-nvme", "10Gi")
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "pod1", Namespace: "default"},
		Spec: corev1.PodSpec{
			Volumes: []corev1.Volume{{Name: "v", VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "pvc-a"},
			}}},
		},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(sc, p).Build()
	tiers, err := PodReferencedPlatformTiers(context.Background(), c, pod)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(tiers) != 1 || tiers[0] != "nvme" {
		t.Fatalf("应解析出 tier=nvme，got %+v", tiers)
	}

	// 第三方 PVC 不计入。
	sc3 := thirdPartySC("ebs")
	p3 := pvc("pvc-b", "ebs", "10Gi")
	pod.Spec.Volumes = []corev1.Volume{{Name: "v", VolumeSource: corev1.VolumeSource{
		PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "pvc-b"},
	}}}
	c2 := fake.NewClientBuilder().WithScheme(scheme).WithObjects(sc3, p3).Build()
	tiers2, _ := PodReferencedPlatformTiers(context.Background(), c2, pod)
	if len(tiers2) != 0 {
		t.Fatalf("第三方 PVC 不应计入平台 tier，got %+v", tiers2)
	}
}

func TestRetireInFlightAndCountInUsePVs(t *testing.T) {
	ops := &storagev1alpha1.StorageNodeOps{
		Spec:   storagev1alpha1.StorageNodeOpsSpec{NodeName: "n1", Operation: storagev1alpha1.NodeOpRetire},
		Status: storagev1alpha1.StorageNodeOpsStatus{Phase: storagev1alpha1.NodeOpsWaitPVCCleanup},
	}
	if !RetireInFlight(ops) {
		t.Fatal("wait-pvc-cleanup 的 retire 应在飞")
	}
	done := &storagev1alpha1.StorageNodeOps{
		Spec:   storagev1alpha1.StorageNodeOpsSpec{NodeName: "n1", Operation: storagev1alpha1.NodeOpRetire},
		Status: storagev1alpha1.StorageNodeOpsStatus{Phase: storagev1alpha1.NodeOpsDone},
	}
	if RetireInFlight(done) {
		t.Fatal("done 不应在飞")
	}
	isolate := &storagev1alpha1.StorageNodeOps{
		Spec:   storagev1alpha1.StorageNodeOpsSpec{NodeName: "n1", Operation: storagev1alpha1.NodeOpIsolate},
		Status: storagev1alpha1.StorageNodeOpsStatus{Phase: storagev1alpha1.NodeOpsValidate},
	}
	if RetireInFlight(isolate) {
		t.Fatal("isolate 不应判为 retire 在飞")
	}

	scheme := testScheme()
	pvBound := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: "pv-bound", Annotations: map[string]string{controller.PVNodeAnnotation: "n1"}},
		Status:     corev1.PersistentVolumeStatus{Phase: corev1.VolumeBound},
	}
	pvReleased := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: "pv-rel", Annotations: map[string]string{controller.PVNodeAnnotation: "n1"}},
		Status:     corev1.PersistentVolumeStatus{Phase: corev1.VolumeReleased},
	}
	pvOther := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: "pv-other", Annotations: map[string]string{controller.PVNodeAnnotation: "n2"}},
		Status:     corev1.PersistentVolumeStatus{Phase: corev1.VolumeBound},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(pvBound, pvReleased, pvOther).Build()
	n, err := CountInUsePVs(context.Background(), c, "n1")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if n != 1 {
		t.Fatalf("n1 应仅 1 个 Bound PV，got %d", n)
	}
}

func strContains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
