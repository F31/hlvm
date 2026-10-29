package webhook

import (
	"os"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// webhookManifest 是 manifests.yaml 中单个文档的最小结构（仅校验准入配置关键字段）。
type webhookManifest struct {
	Kind     string `json:"kind"`
	Webhooks []struct {
		Name  string `json:"name"`
		Rules []struct {
			APIGroups   []string `json:"apiGroups"`
			APIVersions []string `json:"apiVersions"`
			Operations  []string `json:"operations"`
			Resources   []string `json:"resources"`
			Scope       string   `json:"scope"`
		} `json:"rules"`
	} `json:"webhooks"`
}

// TestManifestsWebhooksHaveRules 防回归：Webhook 的 rules 为空时，API Server 不会把任何请求
// 路由到该 webhook（caBundle/Service 都正常也不会被调用）。M15 kind 集成曾因此静默失效。
func TestManifestsWebhooksHaveRules(t *testing.T) {
	data, err := os.ReadFile("../../config/webhook/manifests.yaml")
	if err != nil {
		t.Fatalf("读取 manifests.yaml 失败: %v", err)
	}

	checked := 0
	for _, doc := range strings.Split(string(data), "\n---\n") {
		doc = strings.TrimSpace(doc)
		if doc == "" {
			continue
		}
		var m webhookManifest
		if err := yaml.Unmarshal([]byte(doc), &m); err != nil {
			t.Fatalf("解析 manifests.yaml 文档失败: %v", err)
		}
		switch m.Kind {
		case "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration":
			if len(m.Webhooks) == 0 {
				t.Errorf("%s 未定义 webhooks", m.Kind)
			}
			for _, w := range m.Webhooks {
				checked++
				if len(w.Rules) == 0 {
					t.Errorf("%s webhook %q 的 rules 为空：API Server 将从不调用它", m.Kind, w.Name)
					continue
				}
				for _, r := range w.Rules {
					if len(r.APIGroups) == 0 || len(r.APIVersions) == 0 ||
						len(r.Operations) == 0 || len(r.Resources) == 0 || r.Scope == "" {
						t.Errorf("%s webhook %q 的 rule 不完整: %+v", m.Kind, w.Name, r)
					}
				}
			}
		}
	}
	if checked == 0 {
		t.Fatal("manifests.yaml 中未找到任何 webhook 定义（路径或格式可能已变更）")
	}
}
