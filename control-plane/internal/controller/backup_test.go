package controller

import (
	"encoding/json"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func ptrT(t time.Time) *time.Time { return &t }

func TestBackupEnabledFor(t *testing.T) {
	prodNS := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
		Name:   "prod",
		Labels: map[string]string{ProductionTierLabel: "production"},
	}}
	nonProdNS := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "dev"}}
	enabledNS := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
		Name:   "prod2",
		Labels: map[string]string{ProductionTierLabel: "production", BackupEnabledNamespaceLabel: "enabled"},
	}}
	scBacked := &storagev1.StorageClass{ObjectMeta: metav1.ObjectMeta{
		Name:        "topolvm-nvme",
		Annotations: map[string]string{BackupEnabledStorageClassAnnotation: "true"},
	}}
	pvc := &corev1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{Name: "p", Namespace: "prod"}}

	// 生产 + 无开启 → 违例
	if ok, _ := BackupEnabledFor(pvc, prodNS, nil); ok {
		t.Fatalf("生产命名空间未开启备份应违例")
	}
	// 生产 + ns 标签开启 → 满足
	if ok, _ := BackupEnabledFor(pvc, enabledNS, nil); !ok {
		t.Fatalf("ns 标签开启应满足")
	}
	// 生产 + SC 注解开启 → 满足
	if ok, _ := BackupEnabledFor(pvc, prodNS, scBacked); !ok {
		t.Fatalf("SC 注解开启应满足")
	}
	// 非生产 → 不强制
	if ok, _ := BackupEnabledFor(pvc, nonProdNS, nil); !ok {
		t.Fatalf("非生产不应强制")
	}
}

func TestClassifyBackupPhase(t *testing.T) {
	cases := map[string]BackupPhase{
		"Completed":     PhaseCompleted,
		"Failed":        PhaseFailed,
		"PartiallyFailed": PhaseFailed,
		"InProgress":    PhaseInProgress,
		"Uploading":     PhaseInProgress,
		"Finalizing":    PhaseInProgress,
		"Deleting":      PhaseInProgress,
		"UnknownThing":  PhaseUnknown,
	}
	for in, want := range cases {
		if got := ClassifyBackupPhase(in); got != want {
			t.Fatalf("ClassifyBackupPhase(%q)=%q want %q", in, got, want)
		}
	}
}

func TestLatestSuccessfulBackup(t *testing.T) {
	now := time.Now()
	recs := []BackupRecord{
		{Name: "b1", Namespace: "ns", SourcePVC: "p", Phase: PhaseCompleted, CompletionTime: ptrT(now.Add(-3 * time.Hour))},
		{Name: "b2", Namespace: "ns", SourcePVC: "p", Phase: PhaseCompleted, CompletionTime: ptrT(now.Add(-1 * time.Hour))},
		{Name: "b3", Namespace: "ns", SourcePVC: "p", Phase: PhaseFailed, CompletionTime: ptrT(now)},
		{Name: "b4", Namespace: "ns", SourcePVC: "p", Phase: PhaseInProgress},
	}
	got, ok := LatestSuccessfulBackup(recs)
	if !ok || got.Name != "b2" {
		t.Fatalf("LatestSuccessfulBackup=%v ok=%v want b2", got, ok)
	}

	if _, ok := LatestSuccessfulBackup(nil); ok {
		t.Fatalf("空列表应返回 false")
	}
	if _, ok := LatestSuccessfulBackup([]BackupRecord{{Phase: PhaseFailed}}); ok {
		t.Fatalf("无成功记录应返回 false")
	}
}

func TestRPOCompliance(t *testing.T) {
	now := time.Now()
	// 在窗口内
	if !RPOCompliant(ptrT(now.Add(-10*time.Hour)), DefaultRPO, now) {
		t.Fatalf("10h 内应合规")
	}
	// 超窗口
	if RPOCompliant(ptrT(now.Add(-30*time.Hour)), DefaultRPO, now) {
		t.Fatalf("30h 应不合规")
	}
	// 从未成功
	if RPOCompliant(nil, DefaultRPO, now) {
		t.Fatalf("nil 应不合规")
	}
	// 逾期量
	if d := RPOOverdueBy(ptrT(now.Add(-30*time.Hour)), DefaultRPO, now); d < 0 || d < 4*time.Hour {
		t.Fatalf("逾期量应约 6h，got %v", d)
	}
	if d := RPOOverdueBy(ptrT(now.Add(-10*time.Hour)), DefaultRPO, now); d != 0 {
		t.Fatalf("窗口内逾期量应为 0，got %v", d)
	}
}

func TestSanitizeRateLimit(t *testing.T) {
	cases := []struct {
		in   string
		want string
		ok   bool
	}{
		{"20", "20", true},
		{" 20 ", "20", true},
		{"0", "0", true},
		{"-1", "", false},
		{"abc", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, ok := SanitizeRateLimit(c.in)
		if ok != c.ok || got != c.want {
			t.Fatalf("SanitizeRateLimit(%q)=(%q,%v) want (%q,%v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestBuildConsistencyPreHook(t *testing.T) {
	h, ok := BuildConsistencyPreHook("mysql")
	if !ok || h.Name != "mysql-quiesce" || h.OnError != "Fail" {
		t.Fatalf("mysql pre-hook 构造失败: %+v %v", h, ok)
	}
	if _, ok := BuildConsistencyPreHook("postgres"); ok {
		t.Fatalf("不支持的类型应返回 false")
	}
}

func TestDrillComputation(t *testing.T) {
	slo := DrillSLO{RTOMaxSeconds: 600, RPOMaxSeconds: 3600}
	base := time.Now()
	passed := DrillRecord{
		Name: "d1", Namespace: "ns", SourcePVC: "p", RestoredPVC: "rp",
		StartedAt: base, CompletedAt: base.Add(300 * time.Second),
		DataValid: true, RPOSeconds: 1000, SLO: slo,
	}
	if !DrillPassed(passed) {
		t.Fatalf("应通过")
	}
	if got := passed.ComputeRTO(); got != 300 {
		t.Fatalf("RTO 应 300，got %v", got)
	}

	failedData := passed
	failedData.DataValid = false
	if DrillPassed(failedData) {
		t.Fatalf("数据校验未过不应通过")
	}
	slow := passed
	slow.CompletedAt = base.Add(900 * time.Second)
	if DrillPassed(slow) {
		t.Fatalf("RTO 超 SLO 不应通过")
	}

	// 季度到期
	if !QuarterlyDrillDue(nil, base) {
		t.Fatalf("从未演练应立即到期")
	}
	if QuarterlyDrillDue(ptrT(base.Add(-80*24*time.Hour)), base) {
		t.Fatalf("80 天内不应到期")
	}
	if !QuarterlyDrillDue(ptrT(base.Add(-100*24*time.Hour)), base) {
		t.Fatalf("100 天应到期")
	}

	// 发布门禁
	if !DrillGateBlocked(nil, base, 0) {
		t.Fatalf("无通过演练应阻断")
	}
	if DrillGateBlocked(&passed, base, 0) {
		t.Fatalf("通过且在窗口内不应阻断")
	}
	stale := passed
	stale.CompletedAt = base.Add(-100 * 24 * time.Hour)
	if !DrillGateBlocked(&stale, base, 0) {
		t.Fatalf("超期应阻断")
	}

	// LatestPassedDrill
	latest, ok := LatestPassedDrill([]DrillRecord{passed, failedData})
	if !ok || latest.Name != "d1" {
		t.Fatalf("LatestPassedDrill=%v ok=%v", latest, ok)
	}
}

func TestParseDrillRecords(t *testing.T) {
	now := time.Now()
	recs := []DrillRecord{
		{Name: "d1", StartedAt: now, CompletedAt: now.Add(100 * time.Second), DataValid: true,
			SLO: DrillSLO{RTOMaxSeconds: 600, RPOMaxSeconds: 3600}},
	}
	raw, _ := json.Marshal(recs)
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: DrillConfigMapName, Namespace: "hlvm-system"},
		Data: map[string]string{DrillConfigMapKey: string(raw)}}

	got, err := ParseDrillRecords(cm)
	if err != nil || len(got) != 1 {
		t.Fatalf("解析失败: %v got=%v", err, got)
	}

	// 缺键
	bad := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: DrillConfigMapName}, Data: map[string]string{}}
	if _, err := ParseDrillRecords(bad); err == nil {
		t.Fatalf("缺键应报错")
	}
	// 非法 JSON
	badJSON := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: DrillConfigMapName},
		Data: map[string]string{DrillConfigMapKey: "{not json"}}
	if _, err := ParseDrillRecords(badJSON); err == nil {
		t.Fatalf("非法 JSON 应报错")
	}
}
