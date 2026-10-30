package controller

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// 镜像引用与 CI 构建目标的交叉校验。
//
// 背景（2026-10-30 审计发现的第二类缺陷）：仓库清单会引用自建镜像
// （ghcr.io/f31/hlvm/<name>），但 CI 的 images job 必须真的构建并推送它。
// 实际发生过：storage-agent 被两处清单引用却从未构建，真实集群部署必然
// ImagePullBackOff，且本机无 Rust 链接器无法本地复现，长期未被发现。
// 因此把「清单引用的自有镜像 ⊆ CI 构建列表（或显式白名单）」固化为测试。

var (
	// CI 中形如 `tags: ghcr.io/f31/hlvm/storage-agent:latest` 的构建目标。
	ciImageTagRe = regexp.MustCompile(`tags:\s*ghcr\.io/f31/hlvm/([A-Za-z0-9._-]+)`)
	// 清单中形如 `image: ghcr.io/f31/hlvm/storage-agent:latest` 的引用。
	manifestImageRe = regexp.MustCompile(`image:\s*ghcr\.io/f31/hlvm/([A-Za-z0-9._-]+)`)
)

// unbuiltImageAllowlist 记录「清单引用了但 CI 不构建」的已知例外，键为相对仓库根的路径。
// 新增条目必须同步在 openspec 任务中登记为未完成项，不得静默放行。
var unbuiltImageAllowlist = map[string]string{
	"control-plane/config/hardening/03-crd-conversion.yaml": "conversion webhook 骨架，无 cmd 入口（add-hardening-rollout 3.1b），文件顶部禁止 apply",
}

// TestManifestImagesAreBuiltByCI 防回归：清单引用的自有镜像必须由 CI 构建。
func TestManifestImagesAreBuiltByCI(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根目录失败: %v", err)
	}

	ciData, err := os.ReadFile(filepath.Join(root, ".github", "workflows", "ci.yml"))
	if err != nil {
		t.Fatalf("读取 ci.yml 失败: %v", err)
	}
	built := make(map[string]bool)
	for _, m := range ciImageTagRe.FindAllStringSubmatch(string(ciData), -1) {
		built[m[1]] = true
	}
	if len(built) == 0 {
		t.Fatal("未能从 ci.yml 解析出任何自有镜像构建目标（正则或工作流结构已变）")
	}

	// 只扫描会进入部署路径的清单目录（绝对路径，避免 .. 相对路径无法求 Rel）。
	dirs := []string{
		filepath.Join(root, "control-plane", "config"),
		filepath.Join(root, "agent", "config"),
	}

	var missing []string
	seen := make(map[string]bool)
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
			matches := manifestImageRe.FindAllStringSubmatch(string(data), -1)
			if len(matches) == 0 {
				return nil
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			rel = filepath.ToSlash(rel)
			if reason, ok := unbuiltImageAllowlist[rel]; ok {
				_ = reason // 已知例外，允许；原因见白名单定义
				return nil
			}
			for _, m := range matches {
				if built[m[1]] {
					continue
				}
				entry := rel + " -> " + m[1]
				if !seen[entry] {
					seen[entry] = true
					missing = append(missing, entry)
				}
			}
			return nil
		})
		if walkErr != nil {
			t.Fatalf("扫描 %s 失败: %v", dir, walkErr)
		}
	}

	if len(missing) > 0 {
		sort.Strings(missing)
		t.Fatalf("以下清单引用的镜像不在 CI 构建列表 %v 中，部署会 ImagePullBackOff：\n  %s",
			sortedKeys(built), strings.Join(missing, "\n  "))
	}
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
