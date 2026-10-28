// Package controller 的备份控制逻辑（add-backup-restore，设计 §7 / 风险登记 #21）。
//
// 设计决策：跨存储备份 SHALL 优先采用成熟方案（Velero + CSI 快照 + Kopia/Restic 数据移动），
// 平台 SHALL NOT 自研导出 Job。本文件承载控制面的"策略与可观测"逻辑——约定检测、备份状态分类、
// RPO 合规、IO 限速校验、一致性 pre-hook 构造、恢复演练（RTO/RPO + 季度调度 + 发布门禁）。
// 这些函数均为纯函数（无外部依赖），便于单测；实际备份执行由 Velero 完成，平台经 BackupInventory
// 接口（见 backup_controller.go）采集备份记录，未接入时为 nil（不误报）。
package controller

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
)

// 备份约定相关注解/标签键（设计 §6 使用规范第 4/5 条 + add-backup-restore 1.3）。
const (
	// BackupEnabledNamespaceLabel 命名空间级"默认开启备份"标记；值为 "enabled" 表示生产命名空间默认备份。
	BackupEnabledNamespaceLabel = "storage.example.io/backup"
	// BackupEnabledStorageClassAnnotation 存储类级开启备份标记；值为 "true" 表示走该 SC 的 PVC 默认备份。
	BackupEnabledStorageClassAnnotation = "storage.example.io/backup-enabled"
	// ProductionTierLabel 命名空间生产级标记；值为 "production" 表示生产命名空间（须默认备份）。
	ProductionTierLabel = "storage.example.io/tier"

	// DefaultRPO 默认恢复点目标（§11 非功能指标 RPO ≤24h）。
	DefaultRPO = 24 * time.Hour
)

// IsBackupEnabledNamespace 判定命名空间是否通过标签声明默认开启备份。
func IsBackupEnabledNamespace(ns *corev1.Namespace) bool {
	if ns == nil {
		return false
	}
	return ns.Labels[BackupEnabledNamespaceLabel] == "enabled"
}

// IsBackupEnabledStorageClass 判定存储类是否通过注解声明开启备份。
func IsBackupEnabledStorageClass(sc *storagev1.StorageClass) bool {
	if sc == nil {
		return false
	}
	return sc.Annotations[BackupEnabledStorageClassAnnotation] == "true"
}

// IsProductionNamespace 判定命名空间是否为生产级（须默认备份）。
func IsProductionNamespace(ns *corev1.Namespace) bool {
	if ns == nil {
		return false
	}
	return ns.Labels[ProductionTierLabel] == "production"
}

// BackupEnabledFor 判定某 PVC 是否已满足备份约定（设计 §6 第 4 条：生产 PVC 默认开启备份）。
//
// 返回 enabled 与原因：生产命名空间满足"ns 标签启用"或"SC 注解启用"即视为已开启；
// 非生产命名空间默认不强制，返回 enabled=true（不触发违例）。
func BackupEnabledFor(pvc *corev1.PersistentVolumeClaim, ns *corev1.Namespace, sc *storagev1.StorageClass) (enabled bool, reason string) {
	if !IsProductionNamespace(ns) {
		return true, "非生产命名空间，不强制备份"
	}
	if IsBackupEnabledNamespace(ns) {
		return true, "生产命名空间已通过 ns 标签开启默认备份"
	}
	if IsBackupEnabledStorageClass(sc) {
		return true, "存储类已通过注解开启备份"
	}
	return false, "生产命名空间未开启默认备份：请给命名空间加 storage.example.io/backup=enabled 或给存储类加 storage.example.io/backup-enabled=true"
}

// BackupPhase 是备份状态的归一化取值（映射 Velero Backup 阶段，见 ClassifyBackupPhase）。
type BackupPhase string

const (
	PhaseCompleted  BackupPhase = "Completed"
	PhaseFailed     BackupPhase = "Failed"
	PhaseInProgress BackupPhase = "InProgress"
	PhaseUnknown    BackupPhase = "Unknown"
)

// ClassifyBackupPhase 将 Velero Backup 阶段字符串归一化（见 Velero Backup 状态机）。
// Completed→PhaseCompleted；Failed/PartiallyFailed→PhaseFailed；InProgress/Uploading/Finalizing→PhaseInProgress；其余→PhaseUnknown。
func ClassifyBackupPhase(phase string) BackupPhase {
	switch phase {
	case "Completed":
		return PhaseCompleted
	case "Failed", "PartiallyFailed":
		return PhaseFailed
	case "InProgress", "Uploading", "Finalizing", "Deleting":
		return PhaseInProgress
	default:
		return PhaseUnknown
	}
}

// BackupRecord 是一条备份记录的归一化视图（源自 Velero Backup 或 VolumeSnapshot 状态）。
type BackupRecord struct {
	Name           string
	Namespace      string
	SourcePVC      string
	Phase          BackupPhase
	StartTime      *time.Time
	CompletionTime *time.Time
}

// LatestSuccessfulBackup 返回最近一次成功（PhaseCompleted 且 CompletionTime 非空）的备份记录。
func LatestSuccessfulBackup(records []BackupRecord) (BackupRecord, bool) {
	var latest *BackupRecord
	for i := range records {
		r := records[i]
		if r.Phase != PhaseCompleted || r.CompletionTime == nil {
			continue
		}
		if latest == nil || r.CompletionTime.After(*latest.CompletionTime) {
			cp := r
			latest = &cp
		}
	}
	if latest == nil {
		return BackupRecord{}, false
	}
	return *latest, true
}

// RPOCompliant 判定 lastSuccess 是否在 RPO 窗口内（now - lastSuccess ≤ rpo）。
// lastSuccess 为 nil（从未成功）视为不合规。
func RPOCompliant(lastSuccess *time.Time, rpo time.Duration, now time.Time) bool {
	if lastSuccess == nil {
		return false
	}
	return now.Sub(*lastSuccess) <= rpo
}

// RPOOverdueBy 返回 RPO 逾期时长；合规返回 0（含从未成功）。
func RPOOverdueBy(lastSuccess *time.Time, rpo time.Duration, now time.Time) time.Duration {
	if lastSuccess == nil {
		return 0
	}
	d := now.Sub(*lastSuccess) - rpo
	if d < 0 {
		return 0
	}
	return d
}

// 备份 IO 限速（设计 §7 自研路径要求 + add-backup-restore 1.4）：Velero --upload-rate-limit 单位为 MB/s。
const (
	// DefaultBackupRateLimit 默认备份上传限速（MB/s），避免挤占业务 IO。
	DefaultBackupRateLimit = "20"
)

// SanitizeRateLimit 校验并规范化限速值（非负整数 MB/s）。非法返回零值 + false。
func SanitizeRateLimit(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", false
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return "", false
	}
	return strconv.Itoa(n), true
}

// PreHook 是数据库一致性 pre-hook 的归一化定义（设计 §6 第 5 条 / add-backup-restore 2.1）。
// 用于渲染 Velero backup hook（pre 阶段在 CSI 快照前静默刷新 + 锁表，快照完成后解锁）。
type PreHook struct {
	Name      string
	Container string   // 执行命令的容器名（数据库 Pod 内）
	Command   []string // 静默命令（flush/锁表 → 短暂等待 → 解锁）
	OnError   string   // "Fail" 表示 hook 失败即中断备份
}

// SupportedPreHookKinds 返回平台内置支持的 pre-hook 类型（供校验，避免自造类型）。
func SupportedPreHookKinds() []string {
	return []string{"mysql"}
}

// BuildConsistencyPreHook 按业务类型构造一致性 pre-hook。当前支持 "mysql"（FLUSH TABLES WITH READ LOCK 静默窗口）。
// 不支持的种类返回零值 + false。
func BuildConsistencyPreHook(kind string) (PreHook, bool) {
	switch strings.ToLower(kind) {
	case "mysql":
		return PreHook{
			Name:      "mysql-quiesce",
			Container: "mysql",
			Command:   []string{"mysql", "-h", "127.0.0.1", "-u", "root", "-e", "FLUSH TABLES WITH READ LOCK; SELECT SLEEP(5); UNLOCK TABLES;"},
			OnError:   "Fail",
		}, true
	default:
		return PreHook{}, false
	}
}

// DrillSLO 是恢复演练的服务等级目标（设计 §11 / add-backup-restore 3.2）。
type DrillSLO struct {
	RTOMaxSeconds float64 // 恢复时间目标上限（秒）
	RPOMaxSeconds float64 // 恢复点目标上限（秒，数据陈旧度）
}

// DrillRecord 是一条恢复演练记录（设计 §7 / add-backup-restore 3.1-3.3）。
type DrillRecord struct {
	Name        string
	Namespace   string
	SourcePVC   string
	RestoredPVC string
	StartedAt   time.Time
	CompletedAt time.Time
	DataValid   bool    // 数据完整性校验是否通过
	RPOSeconds  float64 // 恢复点数据陈旧度（秒）
	SLO         DrillSLO
}

// ComputeRTO 返回演练实测 RTO（秒）= CompletedAt - StartedAt。
func (r DrillRecord) ComputeRTO() float64 {
	return r.CompletedAt.Sub(r.StartedAt).Seconds()
}

// DrillPassed 判定演练是否通过：数据校验通过且 RTO/RPO 均满足 SLO。
func DrillPassed(r DrillRecord) bool {
	if !r.DataValid {
		return false
	}
	if r.ComputeRTO() > r.SLO.RTOMaxSeconds {
		return false
	}
	if r.RPOSeconds > r.SLO.RPOMaxSeconds {
		return false
	}
	return true
}

// LatestPassedDrill 返回最近一次通过的演练记录（按 CompletedAt）。
func LatestPassedDrill(records []DrillRecord) (DrillRecord, bool) {
	var latest *DrillRecord
	for i := range records {
		r := records[i]
		if !DrillPassed(r) {
			continue
		}
		if latest == nil || r.CompletedAt.After(latest.CompletedAt) {
			cp := r
			latest = &cp
		}
	}
	if latest == nil {
		return DrillRecord{}, false
	}
	return *latest, true
}

// QuarterlyDrillDue 判定是否到了季度演练时点（设计 §7 / 3.2 每季度至少一次）。
// lastDrill 为 nil（从未演练）→ 立即到期；否则间隔 ≥ 90 天即到期。
func QuarterlyDrillDue(lastDrill *time.Time, now time.Time) bool {
	if lastDrill == nil {
		return true
	}
	return now.Sub(*lastDrill) >= 24*90*time.Hour
}

// DrillGateBlocked 判定发布门禁是否阻断（设计 §7 / 3.3：演练未通过不得上线/升级）。
// 条件：无通过演练、最近通过演练超过 maxStale、或数据校验未通过。maxStale 默认季度（90 天）。
func DrillGateBlocked(lastPass *DrillRecord, now time.Time, maxStale time.Duration) bool {
	if maxStale <= 0 {
		maxStale = 24 * 90 * time.Hour
	}
	if lastPass == nil {
		return true
	}
	if !lastPass.DataValid {
		return true
	}
	return now.Sub(lastPass.CompletedAt) > maxStale
}

// DrillConfigMapName 是恢复演练结果 ConfigMap 的固定名（DrillReconciler 监听）。
const DrillConfigMapName = "hlvm-backup-drill"

// DrillConfigMapKey 是 ConfigMap data 中存放演练记录 JSON 数组的键。
const DrillConfigMapKey = "drills"

// ParseDrillRecords 从演练结果 ConfigMap 解析 DrillRecord 列表（drills 键为 JSON 数组）。
// JSON 非法或键缺失返回错误（不静默丢弃，避免误判为"无演练"而放行门禁）。
func ParseDrillRecords(cm *corev1.ConfigMap) ([]DrillRecord, error) {
	if cm == nil {
		return nil, fmt.Errorf("configmap 为空")
	}
	raw, ok := cm.Data[DrillConfigMapKey]
	if !ok || strings.TrimSpace(raw) == "" {
		return nil, fmt.Errorf("configmap %s/%s 缺少 %s 键", cm.Namespace, cm.Name, DrillConfigMapKey)
	}
	var records []DrillRecord
	if err := json.Unmarshal([]byte(raw), &records); err != nil {
		return nil, fmt.Errorf("解析演练记录失败: %w", err)
	}
	return records, nil
}
