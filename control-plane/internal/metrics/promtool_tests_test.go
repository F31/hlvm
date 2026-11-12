package metrics

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// promtool 求值用例的**结构**守卫（ADR-006 §18）。
//
// 分工：
//   - scripts/prometheus-rules-check.sh：真跑 promtool（需要 docker/二进制），求值语义由它证。
//   - 本测试：不需要 docker，跑在普通 `go test ./...` 里，守「用例还在、覆盖没掉、判据有鉴别力、
//     并且 CI 真的会去跑那个脚本」。
//
// 为什么值得单独守：promtool 用例最危险的退化不是写错，而是**被删掉/被跳过**。
// 用例没了 CI 依旧全绿，规则写错也没人知道（规则静默不触发 = 与「一切正常」不可区分）。

type promtoolSeries struct {
	Series string `json:"series"`
	Values string `json:"values"`
}

type promtoolAlertCase struct {
	EvalTime  string `json:"eval_time"`
	Alertname string `json:"alertname"`
	ExpAlerts []struct {
		ExpLabels map[string]string `json:"exp_labels"`
	} `json:"exp_alerts"`
}

type promtoolTestGroup struct {
	Interval       string              `json:"interval"`
	InputSeries    []promtoolSeries    `json:"input_series"`
	AlertRuleTest  []promtoolAlertCase `json:"alert_rule_test"`
	PromqlExprTest []struct {
		Expr       string `json:"expr"`
		EvalTime   string `json:"eval_time"`
		ExpSamples []struct {
			Labels string  `json:"labels"`
			Value  float64 `json:"value"`
		} `json:"exp_samples"`
	} `json:"promql_expr_test"`
}

type promtoolTestFile struct {
	RuleFiles []string            `json:"rule_files"`
	Tests     []promtoolTestGroup `json:"tests"`
}

// promtool 的 eval_time 形如 `5m`、`90s`；空值会让用例退化成「不校验任何时刻」。
var evalTimeRe = regexp.MustCompile(`^[0-9]+(ms|s|m|h)$`)

func TestPromtoolDriftRuleTestsAreIntact(t *testing.T) {
	rulesDir := filepath.Join("..", "..", "config", "prometheus")
	testsDir := filepath.Join(rulesDir, "tests")

	entries, err := os.ReadDir(testsDir)
	if err != nil {
		t.Fatalf("读取 promtool 用例目录失败（§18 的规则求值用例不能缺席）: %v", err)
	}
	var testFiles []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if strings.HasSuffix(e.Name(), ".yml") || strings.HasSuffix(e.Name(), ".yaml") {
			testFiles = append(testFiles, filepath.Join(testsDir, e.Name()))
		}
	}
	if len(testFiles) == 0 {
		t.Fatal("config/prometheus/tests 下没有任何 promtool 用例")
	}

	// 规则文件里的告警名（全部 alert-rules*.yaml；recording 没有 alert，不参与）。
	ruleFiles, err := filepath.Glob(filepath.Join(rulesDir, "alert-rules*.yaml"))
	if err != nil {
		t.Fatalf("扫描规则文件失败: %v", err)
	}
	if len(ruleFiles) == 0 {
		t.Fatal("没有扫到任何 alert-rules*.yaml")
	}
	ruleAlerts := map[string]string{} // 告警名 → 所属规则文件
	for _, rf := range ruleFiles {
		names, err := alertNamesIn(rf)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", filepath.Base(rf), err)
		}
		if len(names) == 0 {
			t.Errorf("%s 里没有解析到任何告警名（规则文件结构变了？）", filepath.Base(rf))
		}
		for n := range names {
			if prev, dup := ruleAlerts[n]; dup {
				t.Errorf("告警名 %q 同时出现在 %s 与 %s —— 告警名必须全局唯一，否则用例断言分不清对象",
					n, prev, filepath.Base(rf))
			}
			ruleAlerts[n] = filepath.Base(rf)
		}
	}

	cases := map[string]int{}
	empties := map[string]int{}
	seenTested := map[string]bool{}
	coveredRules := map[string]bool{}

	for _, path := range testFiles {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", path, err)
		}
		var tf promtoolTestFile
		if err := yaml.Unmarshal(raw, &tf); err != nil {
			t.Fatalf("%s 不是合法 YAML: %v", filepath.Base(path), err)
		}
		if len(tf.RuleFiles) == 0 {
			t.Errorf("%s 没有声明 rule_files —— promtool 会以空规则集跑，全部用例变成空转",
				filepath.Base(path))
		}
		for _, rf := range tf.RuleFiles {
			if _, err := os.Stat(filepath.Join(rulesDir, rf)); err != nil {
				t.Errorf("%s 引用了不存在的规则文件 %q: %v", filepath.Base(path), rf, err)
				continue
			}
			coveredRules[rf] = true
		}
		if len(tf.Tests) == 0 {
			t.Errorf("%s 没有 tests 段", filepath.Base(path))
		}
		for gi, g := range tf.Tests {
			if g.Interval == "" {
				t.Errorf("%s tests[%d] 缺 interval：采样推进速率不确定，求值时刻不可复现",
					filepath.Base(path), gi)
			}
			if len(g.InputSeries) == 0 {
				t.Errorf("%s tests[%d] 没有 input_series：没有输入序列就测不出任何告警",
					filepath.Base(path), gi)
			}
			// 告警用例断言 alert_rule_test；记录规则用例断言 promql_expr_test。
			// 两者都空 = 这一组什么也没验证，promtool 会「通过」它。
			if len(g.AlertRuleTest) == 0 && len(g.PromqlExprTest) == 0 {
				t.Errorf("%s tests[%d] 既没有 alert_rule_test 也没有 promql_expr_test", filepath.Base(path), gi)
			}
			for ei, e := range g.PromqlExprTest {
				if strings.TrimSpace(e.Expr) == "" {
					t.Errorf("%s tests[%d].promql_expr_test[%d] 没有 expr", filepath.Base(path), gi, ei)
				}
				if !evalTimeRe.MatchString(e.EvalTime) {
					t.Errorf("%s tests[%d].promql_expr_test[%d] 的 eval_time=%q 非法",
						filepath.Base(path), gi, ei, e.EvalTime)
				}
				if len(e.ExpSamples) == 0 {
					t.Errorf("%s tests[%d].promql_expr_test[%d]（%s）没有 exp_samples —— 结果为空也要显式断言，否则聚合写错测不出来",
						filepath.Base(path), gi, ei, e.Expr)
				}
			}
			for ci, c := range g.AlertRuleTest {
				if !evalTimeRe.MatchString(c.EvalTime) {
					t.Errorf("%s tests[%d].alert_rule_test[%d] 的 eval_time=%q 非法（期望形如 5m/90s）",
						filepath.Base(path), gi, ci, c.EvalTime)
				}
				if c.Alertname == "" {
					t.Errorf("%s tests[%d].alert_rule_test[%d] 没有 alertname", filepath.Base(path), gi, ci)
					continue
				}
				seenTested[c.Alertname] = true
				if _, ok := ruleAlerts[c.Alertname]; !ok {
					t.Errorf("%s 断言了 %q，但没有任何 alert-rules*.yaml 定义它（改名后用例成了空转）",
						filepath.Base(path), c.Alertname)
				}
				cases[c.Alertname]++
				if len(c.ExpAlerts) == 0 {
					empties[c.Alertname]++
				}
			}
		}
	}

	// 每个含告警的规则文件都必须被某个用例引用：否则该文件的规则一条都没求值过。
	for _, rf := range ruleFiles {
		base := filepath.Base(rf)
		if !coveredRules[base] {
			t.Errorf("没有任何用例声明 rule_files: [%s] —— 该文件的规则从未被求值", base)
		}
	}

	for a := range ruleAlerts {
		if !seenTested[a] {
			t.Errorf("告警 %q 没有 promtool 求值用例（新增告警必须同时给出会触发/不会触发两组断言）", a)
			continue
		}
		// 判据必须有鉴别力：只有「触发」断言的主人公是恒真告警，只有「不触发」断言的主人公是死告警，
		// 两种都测不出回归。要求同一告警同时具备正例与反例。
		if empties[a] == 0 {
			t.Errorf("告警 %q 只有「应触发」用例，缺少「应静默」反例（健康态误报测不出来）", a)
		}
		if cases[a] == empties[a] {
			t.Errorf("告警 %q 只有「应静默」用例，从没验证过它真的能触发", a)
		}
	}
}

// alertNamesIn 取 PrometheusRule 里 `- alert: X` 的告警名集合。
func alertNamesIn(path string) (map[string]bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, line := range strings.Split(string(raw), "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "- alert:") {
			continue
		}
		name := strings.TrimSpace(strings.TrimPrefix(trimmed, "- alert:"))
		if name != "" {
			out[name] = true
		}
	}
	return out, nil
}

// 脚本存在但没人调用 = 规则求值实际上没进 CI，属最容易发生的「假门禁」。
func TestPrometheusRulesCheckIsWiredIntoCI(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根失败: %v", err)
	}
	script := filepath.Join(root, "scripts", "prometheus-rules-check.sh")
	info, err := os.Stat(script)
	if err != nil {
		t.Fatalf("缺少规则校验脚本 %s: %v", script, err)
	}
	if info.Mode().Perm()&0o100 == 0 {
		t.Errorf("%s 没有可执行位（CI 里按路径直接调用会 permission denied）", script)
	}

	ciRaw, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "ci.yml"))
	if err != nil {
		t.Fatalf("读取 ci.yml 失败: %v", err)
	}
	if !strings.Contains(string(ciRaw), "scripts/prometheus-rules-check.sh") {
		t.Error("ci.yml 没有调用 scripts/prometheus-rules-check.sh —— 规则求值没进门禁")
	}
	// ready 是汇总门禁；新 job 不进 needs 就等于「失败了也照样 Ready 绿」。
	readyNeedsRe := regexp.MustCompile(`(?s)ready:.*?needs:\s*\[([^\]]*)\]`)
	m := readyNeedsRe.FindStringSubmatch(string(ciRaw))
	if m == nil {
		t.Fatal("未能解析 ci.yml 的 ready.needs")
	}
	if !strings.Contains(m[1], "prometheus-rules") {
		t.Errorf("ready.needs=[%s] 未包含 prometheus-rules —— 规则求值失败不会拦住 Ready", m[1])
	}
}
