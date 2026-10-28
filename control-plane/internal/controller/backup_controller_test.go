package controller

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	metrics "github.com/F31/hlvm/control-plane/internal/metrics"
)

type fakeInventory struct {
	records []BackupRecord
	err     error
}

func (f *fakeInventory) ListBackups(_ context.Context) ([]BackupRecord, error) {
	return f.records, f.err
}

func backupScheme() *runtime.Scheme {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = storagev1alpha1.AddToScheme(scheme)
	return scheme
}

func newPVC(name, ns string, sc *string) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
		Spec: corev1.PersistentVolumeClaimSpec{
			StorageClassName: sc,
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("10Gi")},
			},
		},
	}
}

func TestBackupReconciler_ConventionViolation(t *testing.T) {
	scheme := backupScheme()
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
		Name:   "prod",
		Labels: map[string]string{ProductionTierLabel: "production"},
	}}
	pvc := newPVC("p", "prod", nil)
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ns, pvc).Build()
	r := &BackupReconciler{Client: c, Scheme: scheme, Recorder: rec}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "p", Namespace: "prod"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case e := <-rec.Events:
		if !strContains(e, "BackupConventionViolation") {
			t.Fatalf("应产生约定违例事件，got %q", e)
		}
	default:
		t.Fatal("应产生约定违例事件")
	}
}

func TestBackupReconciler_RPOCompliant(t *testing.T) {
	scheme := backupScheme()
	now := time.Now()
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
		Name:   "prod",
		Labels: map[string]string{ProductionTierLabel: "production", BackupEnabledNamespaceLabel: "enabled"},
	}}
	pvc := newPVC("p", "prod", nil)
	inv := &fakeInventory{records: []BackupRecord{
		{Name: "b1", Namespace: "prod", SourcePVC: "p", Phase: PhaseCompleted, CompletionTime: ptrT(now.Add(-10 * time.Hour))},
	}}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ns, pvc).Build()
	r := &BackupReconciler{Client: c, Scheme: scheme, Recorder: rec, Inventory: inv}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "p", Namespace: "prod"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	// 合规：RPO 逾期指标应为 0，且无逾期事件。
	if got := testutil.ToFloat64(metrics.BackupRPOOverdue.WithLabelValues("prod", "p")); got != 0 {
		t.Fatalf("合规时 RPO 逾期指标应为 0，got %v", got)
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("合规不应产生告警事件，got %q", e)
	default:
	}
}

func TestBackupReconciler_RPOOverdue(t *testing.T) {
	scheme := backupScheme()
	now := time.Now()
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
		Name:   "prod",
		Labels: map[string]string{ProductionTierLabel: "production", BackupEnabledNamespaceLabel: "enabled"},
	}}
	pvc := newPVC("p", "prod", nil)
	inv := &fakeInventory{records: []BackupRecord{
		{Name: "b1", Namespace: "prod", SourcePVC: "p", Phase: PhaseCompleted, CompletionTime: ptrT(now.Add(-30 * time.Hour))},
	}}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ns, pvc).Build()
	r := &BackupReconciler{Client: c, Scheme: scheme, Recorder: rec, Inventory: inv}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: "p", Namespace: "prod"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	if got := testutil.ToFloat64(metrics.BackupRPOOverdue.WithLabelValues("prod", "p")); got != 1 {
		t.Fatalf("逾期时 RPO 逾期指标应为 1，got %v", got)
	}
	select {
	case e := <-rec.Events:
		if !strContains(e, "BackupRPOOverdue") {
			t.Fatalf("应产生 RPO 逾期事件，got %q", e)
		}
	default:
		t.Fatal("应产生 RPO 逾期事件")
	}
}

func TestDrillReconciler_Passed(t *testing.T) {
	scheme := backupScheme()
	now := time.Now()
	dr := DrillRecord{
		Name: "d1", Namespace: "prod", SourcePVC: "p", RestoredPVC: "rp",
		StartedAt: now.Add(-200 * time.Second), CompletedAt: now.Add(-100 * time.Second),
		DataValid: true, RPOSeconds: 100,
		SLO: DrillSLO{RTOMaxSeconds: 600, RPOMaxSeconds: 3600},
	}
	raw, _ := json.Marshal([]DrillRecord{dr})
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: DrillConfigMapName, Namespace: "hlvm-system"},
		Data: map[string]string{DrillConfigMapKey: string(raw)}}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cm).Build()
	r := &DrillReconciler{Client: c, Scheme: scheme, Recorder: rec, ManagedNamespace: "hlvm-system"}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: DrillConfigMapName, Namespace: "hlvm-system"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	// 通过：应刷新最近通过演练时间戳指标，且不应有门禁阻断事件。
	if got := testutil.ToFloat64(metrics.BackupDrillLastSuccessTimestampSeconds); got == 0 {
		t.Fatalf("应通过演练刷新指标")
	}
	select {
	case e := <-rec.Events:
		t.Fatalf("通过演练不应产生门禁阻断事件，got %q", e)
	default:
	}
}

func TestDrillReconciler_GateBlocked(t *testing.T) {
	scheme := backupScheme()
	// 无通过演练（数据校验未过）→ 门禁阻断。
	now := time.Now()
	dr := DrillRecord{
		Name: "d1", Namespace: "prod", SourcePVC: "p", RestoredPVC: "rp",
		StartedAt: now.Add(-200 * time.Second), CompletedAt: now.Add(-100 * time.Second),
		DataValid: false, RPOSeconds: 100,
		SLO: DrillSLO{RTOMaxSeconds: 600, RPOMaxSeconds: 3600},
	}
	raw, _ := json.Marshal([]DrillRecord{dr})
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: DrillConfigMapName, Namespace: "hlvm-system"},
		Data: map[string]string{DrillConfigMapKey: string(raw)}}
	rec := record.NewFakeRecorder(10)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cm).Build()
	r := &DrillReconciler{Client: c, Scheme: scheme, Recorder: rec, ManagedNamespace: "hlvm-system"}

	if _, err := r.Reconcile(context.Background(), reconcile.Request{NamespacedName: client.ObjectKey{Name: DrillConfigMapName, Namespace: "hlvm-system"}}); err != nil {
		t.Fatalf("reconcile err: %v", err)
	}
	select {
	case e := <-rec.Events:
		if !strContains(e, "BackupDrillGateBlocked") {
			t.Fatalf("应产生门禁阻断事件，got %q", e)
		}
	default:
		t.Fatal("应产生门禁阻断事件")
	}
}
