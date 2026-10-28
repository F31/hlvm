package controller

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// fakeLVReporter 是测试用 LVReporter，返回预设的实际 LV。
type fakeLVReporter struct {
	lvs []ActualLV
}

func (f *fakeLVReporter) ListActualLVs(node string) ([]ActualLV, error) {
	return f.lvs, nil
}

func TestDriftDetector_FindsUnmanagedLV(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = storagev1alpha1.AddToScheme(scheme)

	pv := boundPV("pv-1", "n1", "default", "claim") // 账面 managed LV（node=n1）
	vg := &storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-n1"},
		Spec:       storagev1alpha1.VGSpec{NodeName: "n1"},
	}
	// 实际 lvs：一个与账面一致（pv-1），一个人工创建（manual-lv）。
	reporter := &fakeLVReporter{lvs: []ActualLV{
		{Node: "n1", VG: "", Name: "pv-1"},
		{Node: "n1", VG: "", Name: "manual-lv"},
	}}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&pv, vg).Build()
	r := &DriftDetectorReconciler{Client: c, Scheme: scheme, Recorder: rec, Reporter: reporter}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-n1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}

	count := 0
	for i := 0; i < 5; i++ {
		select {
		case e := <-rec.Events:
			if strContains(e, "manual-lv") {
				count++
			}
		default:
			goto done
		}
	}
done:
	if count != 1 {
		t.Fatalf("应发现 1 条 unmanaged 漂移（manual-lv），got %d", count)
	}
}

func TestDriftDetector_NoReporterNoFalsePositive(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = storagev1alpha1.AddToScheme(scheme)

	pv := boundPV("pv-1", "n1", "default", "claim")
	vg := &storagev1alpha1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg-n1"}, Spec: storagev1alpha1.VGSpec{NodeName: "n1"}}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(&pv, vg).Build()
	r := &DriftDetectorReconciler{Client: c, Scheme: scheme, Recorder: rec} // Reporter=nil

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "vg-n1"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("未接入 lvs 上报时不应误报 drift，got %q", e)
	default:
	}
}
