package webhook

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	controller "github.com/F31/hlvm/control-plane/internal/controller"
)

func newPodMutatorWith(objs ...client.Object) *PodMutator {
	scheme := testScheme()
	b := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...)
	return &PodMutator{Reader: b.Build()}
}

func TestPodMutator_InjectsLockedAffinity(t *testing.T) {
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
	m := newPodMutatorWith(sc, p)
	if err := m.Default(context.Background(), pod); err != nil {
		t.Fatalf("Default err: %v", err)
	}
	if pod.Spec.Affinity == nil || pod.Spec.Affinity.NodeAffinity == nil ||
		pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution == nil {
		t.Fatal("应注入 nodeAffinity 排除 locked 节点")
	}
	exprs := pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms[0].MatchExpressions
	if len(exprs) != 1 || exprs[0].Key != controller.LockLabelName("nvme") || exprs[0].Operator != corev1.NodeSelectorOpNotIn {
		t.Fatalf("锁标签表达式不符，got %+v", exprs)
	}
}

func TestPodMutator_PreservesExistingAffinity(t *testing.T) {
	sc := platformSC("hlvm-nvme", "nvme")
	p := pvc("pvc-a", "hlvm-nvme", "10Gi")
	existing := &corev1.NodeSelectorRequirement{
		Key: "disktype", Operator: corev1.NodeSelectorOpIn, Values: []string{"ssd"},
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "pod1", Namespace: "default"},
		Spec: corev1.PodSpec{
			Affinity: &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{
				RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
					NodeSelectorTerms: []corev1.NodeSelectorTerm{{MatchExpressions: []corev1.NodeSelectorRequirement{*existing}}},
				},
			}},
			Volumes: []corev1.Volume{{Name: "v", VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "pvc-a"},
			}}},
		},
	}
	m := newPodMutatorWith(sc, p)
	if err := m.Default(context.Background(), pod); err != nil {
		t.Fatalf("Default err: %v", err)
	}
	exprs := pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms[0].MatchExpressions
	if len(exprs) != 2 {
		t.Fatalf("应保留既有约束并追加 locked 排除，got %+v", exprs)
	}
	if exprs[0].Key != "disktype" {
		t.Fatalf("既有 disktype 约束应保留，got %+v", exprs[0])
	}
}

func TestPodMutator_NonPlatformNoInjection(t *testing.T) {
	sc := thirdPartySC("ebs")
	p := pvc("pvc-b", "ebs", "10Gi")
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "pod1", Namespace: "default"},
		Spec: corev1.PodSpec{
			Volumes: []corev1.Volume{{Name: "v", VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "pvc-b"},
			}}},
		},
	}
	m := newPodMutatorWith(sc, p)
	if err := m.Default(context.Background(), pod); err != nil {
		t.Fatalf("Default err: %v", err)
	}
	if pod.Spec.Affinity != nil {
		t.Fatal("第三方 PVC 不应注入亲和约束")
	}
}
