package controller

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// 清单之间的交叉引用校验。
//
// 背景（2026-10-30 审计）：仓库已连续出现两次「清单引用了不存在的东西」——
// storage-agent 镜像从未构建、crd-conversion 镜像与入口都不存在。第三类是
// **命名空间级错配**：hlvm-agent 的 ServiceAccount 建在 kube-system，而正式
// DaemonSet 部署在 hlvm-system，Pod 会因 `serviceaccount "hlvm-agent" not found`
// 无法创建。这类错误离线看单文件完全正确，只有真正 apply 才暴露。
//
// 因此把「同一命名空间内可解析」固化为测试：ServiceAccount、Service 选择器、
// ConfigMap 引用，以及 cert-manager Certificate 产出的 Secret。

// nonDeployableSkeletons 是「明确禁止 apply」的骨架清单，不参与引用解析
// （骨架里引用的 SA/镜像/证书都尚未实现，见文件顶部警告）。
// 新增条目必须同步在 openspec 任务中登记为未完成项，不得静默放行。
//
// 2026-10-31 清理：03-crd-conversion.yaml 已实现（cmd/crd-conversion + SA + Deployment +
// 固定 CA 证书链），是 NodeDisk 收敛后 v1alpha1 兼容层的关键部署清单，不再是"骨架"。
// 移除它的跳过项，让 ServiceAccount / Service selector / ConfigMap 引用校验真正覆盖它。
var nonDeployableSkeletons = map[string]string{}

var yamlDocSepRe = regexp.MustCompile(`(?m)^---[ \t]*$`)

// manifestDoc 覆盖本测试需要读取的字段子集。
type manifestDoc struct {
	Kind     string `json:"kind"`
	Metadata struct {
		Name      string            `json:"name"`
		Namespace string            `json:"namespace"`
		Labels    map[string]string `json:"labels"`
	} `json:"metadata"`
	Spec struct {
		// Service 的 selector 是 map[string]string，而工作负载的是
		// metav1.LabelSelector（含 matchLabels/matchExpressions），结构不同，
		// 故先收原样再按 kind 解析。
		Selector   json.RawMessage `json:"selector"`
		SecretName string          `json:"secretName"` // Certificate
		Template   struct {
			Metadata struct {
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
			Spec struct {
				ServiceAccountName string `json:"serviceAccountName"`
				Volumes            []struct {
					ConfigMap *struct {
						Name string `json:"name"`
					} `json:"configMap"`
				} `json:"volumes"`
				Containers []struct {
					Env []struct {
						ValueFrom *struct {
							ConfigMapKeyRef *struct {
								Name string `json:"name"`
							} `json:"configMapKeyRef"`
						} `json:"valueFrom"`
					} `json:"env"`
					EnvFrom []struct {
						ConfigMapRef *struct {
							Name string `json:"name"`
						} `json:"configMapRef"`
					} `json:"envFrom"`
				} `json:"containers"`
			} `json:"spec"`
		} `json:"template"`
	} `json:"spec"`
}

// asNamespace 归一化：未写 namespace 的清单按 Kubernetes 语义落到 default。
func asNamespace(ns string) string {
	if ns == "" {
		return "default"
	}
	return ns
}

// isPlaceholder 跳过骨架清单（如 hlvm-storage-agent-<NODE>）。
func isPlaceholder(name string) bool {
	return strings.Contains(name, "<") || strings.Contains(name, "{")
}

// loadManifests 读取两个清单目录下的全部 YAML（跳过占位骨架）。
func loadManifests(t *testing.T) []manifestDoc {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根目录失败: %v", err)
	}
	dirs := []string{
		filepath.Join(root, "control-plane", "config"),
		filepath.Join(root, "agent", "config"),
	}
	var out []manifestDoc
	for _, dir := range dirs {
		walkErr := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || !strings.HasSuffix(d.Name(), ".yaml") {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			rel, relErr := filepath.Rel(root, path)
			if relErr != nil {
				return relErr
			}
			if _, skip := nonDeployableSkeletons[filepath.ToSlash(rel)]; skip {
				return nil
			}
			for _, raw := range yamlDocSepRe.Split(string(data), -1) {
				if strings.TrimSpace(raw) == "" {
					continue
				}
				var doc manifestDoc
				if err := yaml.Unmarshal([]byte(raw), &doc); err != nil {
					t.Fatalf("解析 %s 失败: %v", path, err)
				}
				if doc.Kind == "" {
					continue
				}
				out = append(out, doc)
			}
			return nil
		})
		if walkErr != nil {
			t.Fatalf("扫描 %s 失败: %v", dir, walkErr)
		}
	}
	if len(out) == 0 {
		t.Fatal("未读到任何清单，扫描路径可能已变")
	}
	return out
}

// TestManifestServiceAccountsResolve 防回归：工作负载引用的 SA 必须在同一命名空间定义。
func TestManifestServiceAccountsResolve(t *testing.T) {
	docs := loadManifests(t)

	defined := make(map[string]string) // "ns/name" -> kind
	for _, d := range docs {
		if d.Kind == "ServiceAccount" && !isPlaceholder(d.Metadata.Name) {
			key := asNamespace(d.Metadata.Namespace) + "/" + d.Metadata.Name
			defined[key] = "ServiceAccount"
		}
	}
	if len(defined) == 0 {
		t.Fatal("未解析到任何 ServiceAccount")
	}

	var problems []string
	for _, d := range docs {
		switch d.Kind {
		case "DaemonSet", "Deployment", "StatefulSet", "Job":
			sa := d.Spec.Template.Spec.ServiceAccountName
			if sa == "" || isPlaceholder(sa) {
				continue
			}
			key := asNamespace(d.Metadata.Namespace) + "/" + sa
			if _, ok := defined[key]; !ok {
				problems = append(problems, fmt.Sprintf("%s/%s 引用 SA %s（ns=%s）但该命名空间无定义",
					d.Kind, d.Metadata.Name, sa, asNamespace(d.Metadata.Namespace)))
			}
		}
	}

	if len(problems) > 0 {
		sort.Strings(problems)
		t.Fatalf("ServiceAccount 引用无法解析，部署时 Pod 会因 serviceaccount not found 无法创建：\n  %s\n已定义：%v",
			strings.Join(problems, "\n  "), sortedSet(defined))
	}
}

// TestManifestServiceSelectorsMatch 防回归：Service 选择器必须能选中同一命名空间的工作负载。
//
// 选择器写错的后果是「Service 存在但没有 Endpoint」，metrics/webhook 静默失联，
// 而 kubectl get svc 一切正常，排查成本很高。
func TestManifestServiceSelectorsMatch(t *testing.T) {
	docs := loadManifests(t)

	type podLabels struct {
		origin string
		labels map[string]string
	}
	pods := make(map[string][]podLabels) // ns -> 各工作负载的 Pod 标签
	for _, d := range docs {
		switch d.Kind {
		case "DaemonSet", "Deployment", "StatefulSet", "Job":
			ns := asNamespace(d.Metadata.Namespace)
			pods[ns] = append(pods[ns], podLabels{
				origin: d.Kind + "/" + d.Metadata.Name,
				labels: d.Spec.Template.Metadata.Labels,
			})
		}
	}

	var problems []string
	checked := 0
	for _, d := range docs {
		if d.Kind != "Service" || isPlaceholder(d.Metadata.Name) {
			continue
		}
		var sel map[string]string
		if len(d.Spec.Selector) > 0 {
			if err := json.Unmarshal(d.Spec.Selector, &sel); err != nil {
				t.Fatalf("解析 Service/%s 的 selector 失败: %v", d.Metadata.Name, err)
			}
		}
		if len(sel) == 0 {
			problems = append(problems, fmt.Sprintf("Service/%s 无 selector（若为 ExternalName 可忽略）", d.Metadata.Name))
			continue
		}
		checked++
		ns := asNamespace(d.Metadata.Namespace)
		matched := false
		for _, p := range pods[ns] {
			ok := true
			for k, v := range sel {
				if p.labels[k] != v {
					ok = false
					break
				}
			}
			if ok {
				matched = true
				break
			}
		}
		if !matched {
			problems = append(problems, fmt.Sprintf("Service/%s（ns=%s）选择器 %v 未选中任何工作负载",
				d.Metadata.Name, ns, sel))
		}
	}
	if checked == 0 {
		t.Fatal("未解析到任何带 selector 的 Service")
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		t.Fatalf("Service 选择器无法命中端点，服务会静默失联：\n  %s", strings.Join(problems, "\n  "))
	}
}

// TestManifestConfigMapRefsResolve 防回归：ConfigMap 引用必须存在。
func TestManifestConfigMapRefsResolve(t *testing.T) {
	docs := loadManifests(t)

	defined := make(map[string]bool)
	for _, d := range docs {
		if d.Kind == "ConfigMap" {
			defined[asNamespace(d.Metadata.Namespace)+"/"+d.Metadata.Name] = true
		}
	}

	var problems []string
	for _, d := range docs {
		switch d.Kind {
		case "DaemonSet", "Deployment", "StatefulSet", "Job":
			ns := asNamespace(d.Metadata.Namespace)
			ref := func(kind, name string) {
				if name == "" || isPlaceholder(name) {
					return
				}
				if !defined[ns+"/"+name] {
					problems = append(problems, fmt.Sprintf("%s/%s 引用 %s %s，但仓库无定义",
						d.Kind, d.Metadata.Name, kind, name))
				}
			}
			for _, v := range d.Spec.Template.Spec.Volumes {
				if v.ConfigMap != nil {
					ref("ConfigMap", v.ConfigMap.Name)
				}
			}
			for _, c := range d.Spec.Template.Spec.Containers {
				for _, e := range c.Env {
					if e.ValueFrom != nil && e.ValueFrom.ConfigMapKeyRef != nil {
						ref("ConfigMap", e.ValueFrom.ConfigMapKeyRef.Name)
					}
				}
				for _, ef := range c.EnvFrom {
					if ef.ConfigMapRef != nil {
						ref("ConfigMap", ef.ConfigMapRef.Name)
					}
				}
			}
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		t.Fatalf("ConfigMap 引用无法解析：\n  %s", strings.Join(problems, "\n  "))
	}
}

func sortedSet(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
