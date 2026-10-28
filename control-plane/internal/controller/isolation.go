package controller

import (
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// DefaultIsolationTTL 是节点故障恢复后的默认隔离期（设计 §9.2 第 3 步，默认 7 天可配）。
const DefaultIsolationTTL = 7 * 24 * time.Hour

// IsolationExpired 判定隔离期是否届满（§9.2：旧节点恢复后进入隔离期，届满且经人工确认才清理）。
//
// startedAt 一般取 StorageNodeOps(isolate) 的创建时间（metadata.creationTimestamp）。
// 隔离期内严禁自动删除残留 LV——操作不可逆，且旧数据可能是唯一完好副本。
func IsolationExpired(startedAt *metav1.Time, ttl time.Duration, now time.Time) bool {
	if startedAt == nil {
		return false
	}
	if ttl <= 0 {
		ttl = DefaultIsolationTTL
	}
	return now.Sub(startedAt.Time) > ttl
}
