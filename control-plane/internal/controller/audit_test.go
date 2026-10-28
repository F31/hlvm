package controller

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

func TestNewAuditEntry(t *testing.T) {
	e := NewAuditEntry("alice", "NodeVG", "vg-n1", "free=100", "free=50", AuditSourceController)
	if e.Operator != "alice" || e.ObjectKind != "NodeVG" || e.ObjectName != "vg-n1" {
		t.Fatal("审计条目字段错误")
	}
	if e.Before != "free=100" || e.After != "free=50" || e.Source != AuditSourceController {
		t.Fatal("审计前后值/来源错误")
	}
	if e.Time.IsZero() {
		t.Fatal("审计时间不应为空")
	}
}

func TestRecordAuditEvent(t *testing.T) {
	rec := record.NewFakeRecorder(1)
	obj := &storagev1alpha1.NodeVG{ObjectMeta: metav1.ObjectMeta{Name: "vg-n1"}}
	RecordAuditEvent(rec, obj, NewAuditEntry("alice", "NodeVG", "vg-n1", "a", "b", AuditSourceWebhook))
	select {
	case e := <-rec.Events:
		if !strContains(e, "alice") || !strContains(e, "StorageAudit") {
			t.Fatalf("审计事件应包含操作人与类型，got %q", e)
		}
	default:
		t.Fatal("应产生审计事件")
	}

	// recorder 为空时静默跳过。
	RecordAuditEvent(nil, obj, NewAuditEntry("bob", "NodeVG", "vg-n1", "x", "y", AuditSourceCLI))
	_ = corev1.EventTypeNormal
}
