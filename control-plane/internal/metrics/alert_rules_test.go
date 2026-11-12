package metrics

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

// collectorNames 从 collector 的 Describe 里取 fqName，得到「代码里真实存在」的指标名集合。
func collectorNames(t *testing.T, cs ...prometheus.Collector) map[string]struct{} {
	t.Helper()
	fq := regexp.MustCompile(`fqName: "([^"]+)"`)
	out := make(map[string]struct{}, len(cs))
	for _, c := range cs {
		ch := make(chan *prometheus.Desc, 8)
		go func(c prometheus.Collector) {
			c.Describe(ch)
			close(ch)
		}(c)
		for d := range ch {
			if m := fq.FindStringSubmatch(d.String()); m != nil {
				out[m[1]] = struct{}{}
			}
		}
	}
	return out
}

// 告警规则里引用了不存在的指标名时，Prometheus 不会报错，只会让这条告警**永远不触发** ——
// 与「一切正常」不可区分。本测试把规则文件钉在真实指标名上（ADR-006 §17）。
func TestAlertRulesReferenceKnownMetrics(t *testing.T) {
	// 指标名集合集中在 knownMetricNames（observability_config_test.go）：规则文件与
	// Grafana 面板的守卫必须用同一份清单，否则改名时总有一边"看起来还是绿的"。
	known := knownMetricNames(t)

	files, err := filepath.Glob(filepath.Join("..", "..", "config", "prometheus", "*.yaml"))
	if err != nil {
		t.Fatalf("扫描告警规则失败: %v", err)
	}
	// 文件被改名/删除时上面的 glob 会静默少扫，这里显式要求 §17 的规则文件在位。
	var hasDrift bool
	for _, f := range files {
		if filepath.Base(f) == "alert-rules-drift.yaml" {
			hasDrift = true
		}
	}
	if !hasDrift {
		t.Fatalf("缺少 alert-rules-drift.yaml（ADR-006 §17 的三方对账告警），已扫到: %v", files)
	}

	token := regexp.MustCompile(`storage_[a-z0-9_]+`)
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("读 %s 失败: %v", f, err)
		}
		for i, line := range strings.Split(string(b), "\n") {
			// 注释里会出现 storage_thinpool_* 这类残片，跳过注释行避免误判。
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			for _, tok := range token.FindAllString(line, -1) {
				if strings.HasSuffix(tok, "_") {
					continue
				}
				if _, ok := known[tok]; !ok {
					t.Errorf("%s:%d 引用未知指标 %q —— 该告警永远不会触发",
						filepath.Base(f), i+1, tok)
				}
			}
		}
	}
}
