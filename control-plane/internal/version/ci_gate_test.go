package version

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// ciJobBlock 取出 ci.yml 里某个顶层 job 的整段文本（到下一个同级 job 或文件末尾）。
func ciJobBlock(t *testing.T, ci, job string) string {
	t.Helper()
	lines := strings.Split(ci, "\n")
	head := regexp.MustCompile(`^  ` + regexp.QuoteMeta(job) + `:\s*$`)
	next := regexp.MustCompile(`^  [A-Za-z0-9_-]+:\s*$`)
	var out []string
	in := false
	for _, line := range lines {
		trimmed := strings.TrimSuffix(line, "\r")
		if !in {
			if head.MatchString(trimmed) {
				in = true
				out = append(out, trimmed)
			}
			continue
		}
		if next.MatchString(trimmed) {
			break
		}
		out = append(out, trimmed)
	}
	if !in {
		t.Fatalf("ci.yml 里找不到 job %q", job)
	}
	return strings.Join(out, "\n")
}

// 汇总门禁必须自己断言结果。
//
// 2026-11-12 CI 实测发现：`ready` job 只因 `if: always()` 就一定运行，但步骤里只有一句
// echo —— go / rust / prometheus-rules 三个 job 同时 failure 时，Ready 依然绿。分支保护
// 看的是 Ready，于是整条门禁被这一句 echo 废掉。这类缺陷靠读 yml 看不出来，只能钉住。
func TestCIFinalGateAssertsResults(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根失败: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "ci.yml"))
	if err != nil {
		t.Fatalf("读取 ci.yml 失败: %v", err)
	}
	ci := string(raw)

	ready := ciJobBlock(t, ci, "ready")
	for _, must := range []string{"toJSON(needs)", "exit 1", "::error::"} {
		if !strings.Contains(ready, must) {
			t.Errorf("ready job 缺少 %q —— 汇总门禁必须读取各 needs 的结果并在失败时 exit 1", must)
		}
	}
	// needs 列表必须覆盖所有硬门禁；漏一个就等于该门禁失败不影响 Ready。
	needsRe := regexp.MustCompile(`needs:\s*\[([^\]]*)\]`)
	m := needsRe.FindStringSubmatch(ready)
	if m == nil {
		t.Fatal("ready job 没有 needs 列表")
	}
	needs := m[1]
	for _, want := range []string{"go", "rust", "prometheus-rules"} {
		if !strings.Contains(needs, want) {
			t.Errorf("ready.needs=[%s] 未包含 %q", needs, want)
		}
	}

	// 规则求值 job 必须真的被某处调用脚本，否则守卫测试会通过而门禁是空的。
	rulesJob := ciJobBlock(t, ci, "prometheus-rules")
	if !strings.Contains(rulesJob, "scripts/prometheus-rules-check.sh") {
		t.Error("prometheus-rules job 没有调用 scripts/prometheus-rules-check.sh")
	}
}
