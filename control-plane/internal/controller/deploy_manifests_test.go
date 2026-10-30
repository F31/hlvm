package controller

import (
	"os"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// crdManifest 是 CRD 清单的最小结构（仅校验 status 子资源声明）。
type crdManifest struct {
	Spec struct {
		Versions []struct {
			Name         string `json:"name"`
			Served       bool   `json:"served"`
			Subresources struct {
				// 指针用于区分「未声明」与「声明为空对象 {}」。
				Status *struct{} `json:"status"`
			} `json:"subresources"`
		} `json:"versions"`
	} `json:"spec"`
}

// TestStorageTaskCRDDeclaresStatusSubresource 防回归：StorageTask CRD 必须声明 status 子资源。
//
// 背景（M15 kind 实测暴露的两个部署期缺陷）：
//   - 缺少 subresources.status 时，`PATCH/PUT .../status` 返回 404：
//     agent 的 patch_status 回执（设计 §3.4 单写者）与控制器写终态/超期状态全部失效；
//   - 同时 ClusterRole 必须授予 storagetasks/status 的 update，否则 403。
//
// envtest/单测均不覆盖 CRD 清单本身，故在此以清单断言兜底。
func TestStorageTaskCRDDeclaresStatusSubresource(t *testing.T) {
	data, err := os.ReadFile("../../config/crd/bases/storage.example.io_storagetasks.yaml")
	if err != nil {
		t.Fatalf("读取 StorageTask CRD 失败: %v", err)
	}
	var crd crdManifest
	if err := yaml.Unmarshal(data, &crd); err != nil {
		t.Fatalf("解析 CRD 失败: %v", err)
	}
	if len(crd.Spec.Versions) == 0 {
		t.Fatal("CRD 未声明任何版本")
	}
	for _, v := range crd.Spec.Versions {
		if !v.Served {
			continue
		}
		if v.Subresources.Status == nil {
			t.Fatalf("版本 %s 缺少 subresources.status：agent patch_status 与控制器状态写入会返回 404", v.Name)
		}
	}
}

// roleManifest 是 ClusterRole 的最小结构。
type roleManifest struct {
	Rules []struct {
		APIGroups []string `json:"apiGroups"`
		Resources []string `json:"resources"`
		Verbs     []string `json:"verbs"`
	} `json:"rules"`
}

// TestControllerRoleAllowsStorageTaskStatus 防回归：控制器必须能更新 storagetasks/status。
//
// 实际故障：TTL 到期标记与结果回写需要写 status，ClusterRole 缺该子资源时 Reconcile 持续
// 报 `cannot update resource "storagetasks/status" ... forbidden`，任务永远停在 Pending。
func TestControllerRoleAllowsStorageTaskStatus(t *testing.T) {
	data, err := os.ReadFile("../../config/rbac/role.yaml")
	if err != nil {
		t.Fatalf("读取 role.yaml 失败: %v", err)
	}
	var role roleManifest
	if err := yaml.Unmarshal(data, &role); err != nil {
		t.Fatalf("解析 role.yaml 失败: %v", err)
	}

	for _, rule := range role.Rules {
		hasResource := false
		for _, res := range rule.Resources {
			if res == "storagetasks/status" {
				hasResource = true
				break
			}
		}
		if !hasResource {
			continue
		}
		verbs := strings.Join(rule.Verbs, ",")
		if strings.Contains(verbs, "update") || strings.Contains(verbs, "*") {
			return // 找到授权，通过。
		}
		t.Fatalf("storagetasks/status 缺少 update 权限（verbs=%v）", rule.Verbs)
	}
	t.Fatal("ClusterRole 未授予 storagetasks/status：TTL 到期标记与结果回写会持续 403")
}

// agentDaemonSetManifest 是节点侧 DaemonSet 的最小结构（仅校验安全上下文与启动参数）。
type agentDaemonSetManifest struct {
	Spec struct {
		Template struct {
			Spec struct {
				Containers []struct {
					Name            string   `json:"name"`
					Args            []string `json:"args"`
					SecurityContext struct {
						Privileged *bool `json:"privileged"`
					} `json:"securityContext"`
				} `json:"containers"`
			} `json:"spec"`
		} `json:"template"`
	} `json:"spec"`
}

// loadAgentDaemonSets 读取清单文件中的全部 DaemonSet 文档。
//
// 归一化行尾：Windows 检出为 CRLF，直接按 "\n---\n" 切分会把整份文件当成单文档，
// 表现为「找不到容器」而不是解析错误（2026-10-30 踩过）。
func loadAgentDaemonSets(t *testing.T, path string) []agentDaemonSetManifest {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取清单失败(%s): %v", path, err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	var docs []agentDaemonSetManifest
	for _, doc := range strings.Split(text, "\n---\n") {
		if !strings.Contains(doc, "kind: DaemonSet") {
			continue
		}
		var ds agentDaemonSetManifest
		if err := yaml.Unmarshal([]byte(doc), &ds); err != nil {
			t.Fatalf("解析 DaemonSet 失败(%s): %v", path, err)
		}
		docs = append(docs, ds)
	}
	return docs
}

// TestAgentDaemonSetIsPrivileged 防回归：节点 Agent 必须 privileged（spec: agent 特权、读写）。
//
// 实际故障（2026-10-30 集群实测）：把 `privileged: false` + drop ALL → add
// SYS_ADMIN/DAC_OVERRIDE/SYS_RAWIO 当作「特权最小化」后，容器内 uid=0 仍无法读设备：
// `dd if=/dev/loop77` / `blkid` / `wipefs` 全部 EPERM。根因是**设备 cgroup**（runc 的
// BPF device filter），与 capability 无关——非特权 Pod 的 device allowlist 为空，加 capability
// 也绕不过。后果：签名预检读不到盘（还会把「读失败」误判成干净盘）、wipe/pvcreate 全部失败。
//
// 若要让 agent 恢复非特权，必须先让它能「拿到本节点全部盘」——设备插件只能表达「申请 N 块」，
// 表达不了全集，故设备插件（见下）不解决这一条，agent 仍保持 privileged。
func TestAgentDaemonSetIsPrivileged(t *testing.T) {
	docs := loadAgentDaemonSets(t, "../../../agent/config/daemonset-agent.yaml")
	if len(docs) != 1 {
		t.Fatalf("期望恰好 1 个 agent DaemonSet，实际 %d", len(docs))
	}
	for _, c := range docs[0].Spec.Template.Spec.Containers {
		if c.Name != "agent" {
			continue
		}
		if c.SecurityContext.Privileged == nil || !*c.SecurityContext.Privileged {
			t.Fatal("agent 容器必须 privileged: true —— 非特权 Pod 受设备 cgroup 限制，读写块设备会 EPERM")
		}
		return
	}
	t.Fatal("agent DaemonSet 未找到名为 agent 的容器")
}

// TestDevicePluginDaemonSetIsNonPrivileged 防回归：设备插件**必须**保持非特权。
//
// 它与 agent 的约束正好相反，且容易被「顺手统一」改错：
// - 插件不读盘（只读 /sys、/dev/disk/by-id 与 kubelet 的 device-plugins 目录），
//   所以它既不需要特权，也不该被设备 cgroup 影响；
// - 一旦被改成 privileged，就等于在集群里多了一个对全部盘有原始读写权的常驻进程，
//   与「按盘最小授权」的设计目的直接冲突；
// - 反过来说，如果插件启动失败（EPERM），正确修法是查挂载/属主，不是加特权。
func TestDevicePluginDaemonSetIsNonPrivileged(t *testing.T) {
	docs := loadAgentDaemonSets(t, "../../../agent/config/daemonset-device-plugin.yaml")
	if len(docs) != 1 {
		t.Fatalf("期望恰好 1 个 device-plugin DaemonSet，实际 %d", len(docs))
	}
	found := false
	for _, c := range docs[0].Spec.Template.Spec.Containers {
		if c.Name != "plugin" {
			continue
		}
		found = true
		if c.SecurityContext.Privileged != nil && *c.SecurityContext.Privileged {
			t.Fatal("device-plugin 容器不得 privileged：它不读盘，靠 kubelet 按盘分配授权")
		}
		hasMode := false
		for _, a := range c.Args {
			if a == "--mode=device-plugin" {
				hasMode = true
			}
		}
		if !hasMode {
			t.Fatalf("device-plugin 容器启动参数必须含 --mode=device-plugin，实际 %v", c.Args)
		}
	}
	if !found {
		t.Fatal("device-plugin DaemonSet 未找到名为 plugin 的容器")
	}
}
