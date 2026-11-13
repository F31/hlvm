package metrics

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// Alertmanager / Grafana 配置的**语义**守卫（ADR-006 §20）。
//
// 分工：
//   - scripts/observability-config-check.sh：真跑 amtool check-config / promtool check rules，
//     证「配置能被官方解析器接受」。
//   - 本文件：不需要 docker，跑在普通 `go test ./...` 里，守**解析器查不出来的语义**：
//       1) 抑制规则引用的 alertname 必须真的存在于规则文件（拼错 ⇒ 该条抑制永不生效，
//          不报错，表现为「告警变少了」，与「一切正常」不可区分）；
//       2) 每条 severity 都必须有路由接收（severity 拼错 ⇒ 落到默认接收器，值班人什么都收不到）；
//       3) 面板查询引用的指标必须真实存在（改名后 Grafana 只显示 No data，看起来像没异常）。
//
// 这三条恰好都是「错了也不报错、只是安静地不做该做的事」——与 §17/§18 要治的是同一种病。

// ---------------------------- 数据结构 ----------------------------

type amMatcherRule struct {
	SourceMatchers []string `json:"source_matchers"`
	TargetMatchers []string `json:"target_matchers"`
	// 已废弃的单数形式；同时出现时 Alertmanager 会报错，这里也一并拒绝。
	SourceMatch []string `json:"source_match"`
	TargetMatch []string `json:"target_match"`
	Equal       []string `json:"equal"`
}

type amRoute struct {
	Receiver string    `json:"receiver"`
	Matchers []string  `json:"matchers"`
	Routes   []amRoute `json:"routes"`
}

type amConfig struct {
	Route struct {
		Receiver string    `json:"receiver"`
		Matchers []string  `json:"matchers"`
		Routes   []amRoute `json:"routes"`
	} `json:"route"`
	Receivers    []map[string]any `json:"receivers"`
	InhibitRules []amMatcherRule  `json:"inhibit_rules"`
}

type dashTarget struct {
	RefID string `json:"refId"`
	Expr  string `json:"expr"`
}

type dashPanel struct {
	ID      int          `json:"id"`
	Type    string       `json:"type"`
	Title   string       `json:"title"`
	Targets []dashTarget `json:"targets"`
	Panels  []dashPanel  `json:"panels"`
}

type dashboard struct {
	UID    string      `json:"uid"`
	Title  string      `json:"title"`
	Panels []dashPanel `json:"panels"`
}

var (
	// matcher 形如 `severity="critical"` / `alertname=~"A|B"`。
	matcherRe = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)\s*(=~|!~|!=|=)\s*"([^"]*)"$`)
	// 只接受「字面量」或「字面量的 | 分支」：别的正则没法静态展开成告警名集合，
	// 而抑制规则的价值恰恰在于「引用的名字必须真的存在」。
	literalAltRe = regexp.MustCompile(`^[A-Za-z0-9_.:-]+(\|[A-Za-z0-9_.:-]+)*$`)
	severityRe   = regexp.MustCompile(`(?m)^\s+severity:\s*([A-Za-z0-9_-]+)\s*$`)
	metricTokRe  = regexp.MustCompile(`storage_[a-z0-9_]+`)
)

func loadAMConfig(t *testing.T) amConfig {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "alertmanager", "alertmanager.yaml"))
	if err != nil {
		t.Fatalf("读取 Alertmanager 配置失败（§20 的路由与抑制规则不能缺席）: %v", err)
	}
	var cfg amConfig
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("解析 alertmanager.yaml 失败: %v", err)
	}
	return cfg
}

func alertRuleFiles(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join("..", "..", "config", "prometheus", "alert-rules*.yaml"))
	if err != nil {
		t.Fatalf("扫描告警规则失败: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("没有扫到任何 alert-rules*.yaml")
	}
	return files
}

// knownAlertNames 取全部告警名与 severity 集合。
func knownAlertNames(t *testing.T) (map[string]bool, map[string]bool) {
	t.Helper()
	alerts := map[string]bool{}
	severities := map[string]bool{}
	for _, f := range alertRuleFiles(t) {
		names, err := alertNamesIn(f)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", filepath.Base(f), err)
		}
		for n := range names {
			alerts[n] = true
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", filepath.Base(f), err)
		}
		for _, m := range severityRe.FindAllStringSubmatch(string(raw), -1) {
			severities[m[1]] = true
		}
	}
	if len(alerts) == 0 || len(severities) == 0 {
		t.Fatalf("没有解析到告警/severity（规则文件结构变了？alerts=%d severities=%d）",
			len(alerts), len(severities))
	}
	return alerts, severities
}

// expandMatchers 把 matcher 串解析成 (标签名 → 允许的字面量集合)。
// 非 alertname 的 matcher 只校验语法形态，不展开。
func expandMatchers(t *testing.T, side string, matchers []string) map[string][]string {
	t.Helper()
	out := map[string][]string{}
	for _, m := range matchers {
		sub := matcherRe.FindStringSubmatch(strings.TrimSpace(m))
		if sub == nil {
			t.Fatalf("%s 里的 matcher %q 不是 `label=\"value\"` / `label=~\"A|B\"` 形态", side, m)
		}
		label, op, value := sub[1], sub[2], sub[3]
		switch op {
		case "=", "=~":
		default:
			// != / !~ 是「排除」语义，无法枚举出「必须存在」的集合，跳过展开。
			continue
		}
		if !literalAltRe.MatchString(value) {
			t.Fatalf("%s 的 %s 取值 %q 不是字面量或其 | 分支 —— 静态守卫无法展开，请改写", side, label, value)
		}
		out[label] = append(out[label], strings.Split(value, "|")...)
	}
	return out
}

// 抑制规则里的 alertname 必须真的存在：拼错时 Alertmanager 不报错，该条抑制永不生效。
// 这类回归表现为「告警变多」（噪声回来），而噪声不会让人怀疑抑制规则写坏了。
func TestAlertmanagerInhibitRulesReferenceKnownAlerts(t *testing.T) {
	cfg := loadAMConfig(t)
	known, _ := knownAlertNames(t)

	if len(cfg.InhibitRules) == 0 {
		t.Fatal("alertmanager.yaml 没有任何 inhibit_rules —— 同源告警会成串刷屏（§20 的核心诉求）")
	}

	// equal 的标签必须真的存在于对应告警上，否则抑制永不生效。这里只能约束到「闭集」；
	// 「标签在真实序列上是否存在」要在真机 grafana/alertmanager 里看（ADR §20 诚实边界）。
	allowedEqual := map[string]bool{"node": true, "vg": true, "device": true, "kind": true, "pvc": true}

	for i, r := range cfg.InhibitRules {
		if len(r.SourceMatch) > 0 || len(r.TargetMatch) > 0 {
			t.Errorf("inhibit_rules[%d] 用了已废弃的 source_match/target_match，请改用 matchers", i)
		}
		if len(r.SourceMatchers) == 0 || len(r.TargetMatchers) == 0 {
			t.Errorf("inhibit_rules[%d] 缺少 source_matchers 或 target_matchers —— 另一侧为空等于无条件抑制", i)
			continue
		}
		src := expandMatchers(t, "inhibit_rules["+itoa(i)+"].source_matchers", r.SourceMatchers)
		dst := expandMatchers(t, "inhibit_rules["+itoa(i)+"].target_matchers", r.TargetMatchers)
		// 两侧都必须由 alertname 限定：只按 severity/node 抑制就是跨子系统压制，
		// 会连同「需要完全不同的处置动作」的告警一起吞掉（见配置文件里的「刻意不加」段）。
		if len(src["alertname"]) == 0 {
			t.Errorf("inhibit_rules[%d] 的 source 没有 alertname 约束 —— 抑制范围不可预测", i)
		}
		if len(dst["alertname"]) == 0 {
			t.Errorf("inhibit_rules[%d] 的 target 没有 alertname 约束 —— 抑制范围不可预测", i)
		}
		for _, side := range []struct {
			name string
			set  map[string][]string
		}{{"source", src}, {"target", dst}} {
			for _, name := range side.set["alertname"] {
				if !known[name] {
					t.Errorf("inhibit_rules[%d].%s_matchers 引用了不存在的告警 %q —— 该条抑制永远不会生效",
						i, side.name, name)
				}
			}
		}
		if len(r.Equal) == 0 {
			// equal 为空 = 全局抑制，几乎总是错的（一条告警会压掉所有节点的同类告警）。
			t.Errorf("inhibit_rules[%d] 的 equal 为空 —— 等于全局抑制，请显式列出用于对齐的标签", i)
		}
		for _, l := range r.Equal {
			if !allowedEqual[l] {
				t.Errorf("inhibit_rules[%d].equal 含未知标签 %q（允许：node/vg/device/kind/pvc）", i, l)
			}
		}
	}
}

// 每条 severity 都必须有路由接收，且接收器必须真的配有投递通道。
// severity 拼错（severity="warn"）时路由永远匹配不上，告警落到默认接收器 ——
// 而默认接收器是黑洞，于是「告警配置齐全、值班人什么都没收到」。
func TestAlertmanagerRoutesCoverEverySeverity(t *testing.T) {
	cfg := loadAMConfig(t)
	_, severities := knownAlertNames(t)

	receivers := map[string]map[string]any{}
	for _, r := range cfg.Receivers {
		name, _ := r["name"].(string)
		if name == "" {
			t.Error("receivers 里有条目缺少 name")
			continue
		}
		if _, dup := receivers[name]; dup {
			t.Errorf("receivers 里 %q 重复定义", name)
		}
		receivers[name] = r
	}
	if len(receivers) == 0 {
		t.Fatal("alertmanager.yaml 没有 receivers")
	}

	// 深度优先展开（Alertmanager 按此顺序求值，第一个匹配的叶子路由胜出）。
	var flat []amRoute
	var walk func(rs []amRoute)
	walk = func(rs []amRoute) {
		for _, r := range rs {
			flat = append(flat, r)
			walk(r.Routes)
		}
	}
	walk(cfg.Route.Routes)

	if cfg.Route.Receiver == "" {
		t.Error("route 缺少默认 receiver —— 未匹配的告警会被丢弃")
	}
	if _, ok := receivers[cfg.Route.Receiver]; !ok {
		t.Errorf("route.receiver=%q 没有对应的 receiver 定义", cfg.Route.Receiver)
	}

	delivers := func(name string) bool {
		r, ok := receivers[name]
		if !ok {
			return false
		}
		for k, v := range r {
			if !strings.HasSuffix(k, "_configs") {
				continue
			}
			if list, ok := v.([]any); ok && len(list) > 0 {
				return true
			}
		}
		return false
	}

	// severity → 第一个匹配的路由下标
	matchedAt := map[string]int{}
	for sev := range severities {
		matchedAt[sev] = -1
	}
	for idx, r := range flat {
		if r.Receiver == "" {
			t.Errorf("route[%d] 缺少 receiver", idx)
			continue
		}
		if _, ok := receivers[r.Receiver]; !ok {
			t.Errorf("route[%d].receiver=%q 没有对应的 receiver 定义（启动时会直接报错）", idx, r.Receiver)
		}
		for _, m := range r.Matchers {
			sub := matcherRe.FindStringSubmatch(strings.TrimSpace(m))
			if sub == nil {
				t.Errorf("route[%d] 的 matcher %q 不是 `label=\"value\"` 形态", idx, m)
				continue
			}
			if sub[1] != "severity" || sub[2] != "=" {
				continue
			}
			sev := sub[3]
			if _, ok := matchedAt[sev]; !ok {
				t.Errorf("route[%d] 按 severity=%q 路由，但规则文件里没有任何告警用这个 severity（拼写错误？）",
					idx, sev)
				continue
			}
			if matchedAt[sev] == -1 {
				matchedAt[sev] = idx
			}
		}
	}

	for sev := range severities {
		if matchedAt[sev] < 0 {
			t.Errorf("severity=%q 没有任何路由接收 —— 告警会落到默认接收器 %q", sev, cfg.Route.Receiver)
			continue
		}
		recv := flat[matchedAt[sev]].Receiver
		if !delivers(recv) {
			t.Errorf("severity=%q 落到 receiver %q，但它没有任何投递通道（等于黑洞）", sev, recv)
		}
	}

	// 顺序敏感：Alertmanager 只走第一条匹配的叶子路由（除非 continue: true）。
	// warning 排在 critical 前面会把所有 critical 静默降级成工单。
	if c, w := matchedAt["critical"], matchedAt["warning"]; c >= 0 && w >= 0 && w < c {
		t.Errorf("route 顺序错误：warning(%d) 排在 critical(%d) 前面 —— critical 会被降级成工单", w, c)
	}
	if c, ok := matchedAt["critical"]; ok && c >= 0 && flat[c].Receiver == cfg.Route.Receiver {
		t.Errorf("critical 用了默认接收器 %q：默认接收器一旦是黑洞，Critical 就没人收到", cfg.Route.Receiver)
	}
}

// 面板查询引用的指标必须真实存在（改名后 Grafana 只显示 No data，看起来像没异常）。
func TestDashboardQueriesReferenceKnownMetrics(t *testing.T) {
	dir := filepath.Join("..", "..", "config", "grafana", "dashboards")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("读取仪表盘目录失败（§20 的仪表盘不能缺席）: %v", err)
	}
	known := knownMetricNames(t)

	// §17 的四族指标是「对账静默停摆可被发现」的唯一入口，面板必须覆盖到。
	requiredInDrift := []string{
		MetricLVReportTimestampSeconds,
		MetricLVReportPresent,
		MetricDriftReconcileSkippedTotal,
		MetricDriftItems,
	}

	nDash := 0
	var driftExprs []string
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", e.Name(), err)
		}
		var d dashboard
		if err := json.Unmarshal(raw, &d); err != nil {
			t.Errorf("%s 不是合法 JSON: %v", e.Name(), err)
			continue
		}
		nDash++
		if strings.TrimSpace(d.UID) == "" {
			t.Errorf("%s 缺少 uid（provisioning 与分享链接靠它定位）", e.Name())
		}
		var walk func(ps []dashPanel)
		walk = func(ps []dashPanel) {
			for _, p := range ps {
				for _, tg := range p.Targets {
					expr := strings.TrimSpace(tg.Expr)
					if expr == "" {
						t.Errorf("%s panel(id=%d, %s) 的 target %q 没有 expr", e.Name(), p.ID, p.Title, tg.RefID)
						continue
					}
					if strings.Contains(d.UID, "drift") {
						driftExprs = append(driftExprs, expr)
					}
					for _, tok := range metricTokRe.FindAllString(expr, -1) {
						tok = strings.TrimSuffix(tok, "_")
						if _, ok := known[tok]; !ok {
							t.Errorf("%s panel(id=%d) 引用未知指标 %q —— 面板会永远 No data",
								e.Name(), p.ID, tok)
						}
					}
				}
				walk(p.Panels)
			}
		}
		walk(d.Panels)
	}
	if nDash < 2 {
		t.Errorf("仪表盘只有 %d 个；至少应有总览与对账两个（§20）", nDash)
	}
	joined := strings.Join(driftExprs, "\n")
	for _, m := range requiredInDrift {
		if !strings.Contains(joined, m) {
			t.Errorf("对账仪表盘没有用到 %q —— 「对账静默停摆」从面板上就看不出来了", m)
		}
	}
}

// 脚本写了但没人跑 = 配置校验实际上没进 CI（标准的假门禁）。
func TestObservabilityConfigCheckIsWiredIntoCI(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根失败: %v", err)
	}
	for _, rel := range []string{
		filepath.Join("scripts", "observability-config-check.sh"),
		filepath.Join("scripts", "dashboard_lint.py"),
	} {
		info, err := os.Stat(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("缺少 %s: %v", rel, err)
		}
		if strings.HasSuffix(rel, ".sh") && info.Mode().Perm()&0o100 == 0 {
			// 注意：/mnt/e（drvfs）下所有文件都是 0777，本地这条断言基本恒真；
			// 它的鉴别力来自 CI 的 ext4 检出（§18 实测：脚本以 100644 入库时 CI permission denied）。
			t.Errorf("%s 没有可执行位（Windows 上 chmod 不进索引，需 git update-index --chmod=+x）", rel)
		}
	}

	ciRaw, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "ci.yml"))
	if err != nil {
		t.Fatalf("读取 ci.yml 失败: %v", err)
	}
	ci := string(ciRaw)
	if !strings.Contains(ci, "scripts/observability-config-check.sh") {
		t.Error("ci.yml 没有调用 scripts/observability-config-check.sh —— §20 的配置校验没进门禁")
	}
	if !strings.Contains(ci, "scripts/prometheus-rules-check.sh") {
		t.Error("ci.yml 不再调用 scripts/prometheus-rules-check.sh —— 规则求值被摘掉了")
	}

	readyNeedsRe := regexp.MustCompile(`(?s)ready:.*?needs:\s*\[([^\]]*)\]`)
	m := readyNeedsRe.FindStringSubmatch(ci)
	if m == nil {
		t.Fatal("未能解析 ci.yml 的 ready.needs")
	}
	if !strings.Contains(m[1], "observability") {
		t.Errorf("ready.needs=[%s] 未包含 observability —— 配置校验失败不会拦住 Ready", m[1])
	}
}

// 抑制规则的**运行时**证据只有 §21 的实测脚本能给（静态解析证明不了「真的压住了」）。
// 该脚本不进 CI（要拉 alertmanager 镜像），所以这里退一步守一件事：每条规则的 source 告警
// 都必须真的被脚本注入过。新加一条抑制规则却不补用例时这里会红 —— 否则判据会安静地
// 覆盖不到新规则，而那正是本 ADR 反复出现的失败模式。
func TestInhibitRulesHaveRuntimeE2ECase(t *testing.T) {
	cfg := loadAMConfig(t)
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "poc", "scripts", "alertmanager-inhibit-e2e.sh"))
	if err != nil {
		t.Fatalf("读取 §21 实测判据脚本失败: %v", err)
	}
	script := string(raw)
	if !strings.Contains(script, "SUMMARY PASS=") {
		t.Error("实测脚本缺少 SUMMARY 汇总行 —— 与 docs/poc/scripts 其它判据的纪律不一致")
	}
	if !strings.Contains(script, `VERDICT="FAIL"`) {
		t.Error("实测脚本没有 FAIL 判定路径 —— 全绿可能只是「没断言」")
	}

	for i, r := range cfg.InhibitRules {
		injected := false
		for _, m := range r.SourceMatchers {
			sub := matcherRe.FindStringSubmatch(strings.TrimSpace(m))
			if sub == nil || sub[1] != "alertname" || (sub[2] != "=" && sub[2] != "=~") {
				continue
			}
			for _, name := range strings.Split(sub[3], "|") {
				// 必须出现在 am_add 行里：只在注释里提到不算覆盖。
				re := regexp.MustCompile(`(?m)^\s*am_add\s+alertname=` + regexp.QuoteMeta(name) + `\b`)
				if !re.MatchString(script) {
					t.Errorf("inhibit_rules[%d] 的 source 告警 %q 在 §21 实测脚本里从未被注入 —— "+
						"该条规则「运行时是否真的抑制」没有证据", i, name)
					continue
				}
				injected = true
			}
		}
		if !injected {
			t.Errorf("inhibit_rules[%d] 没有任何 source 告警被实测脚本覆盖", i)
		}
	}
}

func itoa(i int) string { return strconv.Itoa(i) }

// knownMetricNames 汇总「代码里真实存在」的指标名：控制面 collector + exporter 侧规范名常量。
// 与 TestAlertRulesReferenceKnownMetrics 共用，避免两处各写一份后各自漂移。
func knownMetricNames(t *testing.T) map[string]struct{} {
	t.Helper()
	known := collectorNames(t,
		ReconcileErrors, ReconcileDuration,
		AdmissionDuration, AdmissionsTotal, RejectionsTotal,
		BackupLastSuccessTimestampSeconds, BackupTotal, BackupDurationSeconds,
		BackupRPOOverdue, BackupDrillLastSuccessTimestampSeconds,
		LVReportTimestampSeconds, LVReportPresent,
		DriftReconcileSkippedTotal, DriftItems,
	)
	for _, n := range []string{
		MetricDiskSmartHealth, MetricDiskSmartTemperature, MetricDiskMediaErrorsTotal,
		MetricDiskAvailableSparePercent, MetricDiskPercentUsed,
		MetricVGTotalBytes, MetricVGFreeBytes,
		MetricThinPoolDataPercent, MetricThinPoolMetadataPercent,
		MetricThinPoolProvisionedBytes, MetricThinPoolOverprovisionRatio,
		MetricThinPoolOutOfSpace, MetricThinPoolCollectOK, MetricRaidDegraded,
		MetricAgentLastScanTimestamp, MetricAgentTaskFailuresTotal, MetricDriftDetected,
	} {
		known[n] = struct{}{}
	}
	return known
}
