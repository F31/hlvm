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
