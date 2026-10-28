package controller

import (
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// AuditSource 标识写操作来源（设计 §4.1）。
type AuditSource string

const (
	AuditSourceController AuditSource = "controller"
	AuditSourceWebhook    AuditSource = "webhook"
	AuditSourceCLI        AuditSource = "cli"
	AuditSourceBreakGlass AuditSource = "break-glass"
)

// AuditEntry 是一条平台写操作审计记录（§4.1：操作人/对象/前后值/时间/来源）。
type AuditEntry struct {
	Operator   string
	ObjectKind string
	ObjectName string
	Before     string
	After      string
	Source     AuditSource
	Time       metav1.Time
}

// NewAuditEntry 构造审计条目（时间默认当前 UTC）。
func NewAuditEntry(operator, kind, name, before, after string, source AuditSource) AuditEntry {
	return AuditEntry{
		Operator:   operator,
		ObjectKind: kind,
		ObjectName: name,
		Before:     before,
		After:      after,
		Source:     source,
		Time:       metav1.Time{Time: time.Now().UTC()},
	}
}

// RecordAuditEvent 将审计条目写入 K8s Event（与 K8s audit log 可交叉校验，§4.1）。
//
// 审计字段（操作人/对象/前后值/时间/来源）全部落入事件消息，便于与集群 audit log 对齐。
// recorder 或 obj 为空时静默跳过（不阻塞主流程）。
func RecordAuditEvent(recorder record.EventRecorder, obj client.Object, e AuditEntry) {
	if recorder == nil || obj == nil {
		return
	}
	msg := fmt.Sprintf("[%s] operator=%s src=%s object=%s/%s before=%q after=%q",
		e.Time.Format(time.RFC3339), e.Operator, e.Source, e.ObjectKind, e.ObjectName, e.Before, e.After)
	recorder.Event(obj, "Normal", "StorageAudit", msg)
}
