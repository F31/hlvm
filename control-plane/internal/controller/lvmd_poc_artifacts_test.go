package controller

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/yaml"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// TestLvmdPOCArtifactsConsistent 锁定 control-plane/config/lvmd/ 下三份清单与渲染逻辑的一致性。
//
// 背景（ADR-006 路线 A）：POC 用「手工 seed NodeVG → 控制面渲染 per-node ConfigMap → lvmd DaemonSet 挂载它」
// 这条链。仓库里因此同时存在三份必须彼此吻合的产物：
//
//	nodevg-seed-153.yaml                  —— NodeVG 真相源（路线 A 手工 seed）
//	configmap-lvmd-10-60-153-100.yaml     —— 控制器渲染结果的快照副本（让清单自洽可 apply）
//	daemonset.yaml                        —— 消费该 ConfigMap 的 lvmd
//
// 三者任一处单独改动都会让真机行为与仓库声明脱节，而 TestManifestConfigMapRefsResolve 只校验
// 「引用能解析」，不校验「内容对不对」。这里把三者的耦合点显式断言出来：
//  1. ConfigMap 名必须是 LvmdConfigName(seed.spec.nodeName)；
//  2. ConfigMap 的 data["lvmd.yaml"] 必须与 AggregateLVMDConfig(seed) 逐字节相同；
//  3. DaemonSet 引用的 ConfigMap 名与 nodeSelector 必须指向同一个节点。
func TestLvmdPOCArtifactsConsistent(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根目录失败: %v", err)
	}
	lvmdDir := filepath.Join(root, "control-plane", "config", "lvmd")

	// 1. 读 seed NodeVG。
	seedPath := filepath.Join(lvmdDir, "nodevg-seed-153.yaml")
	seedRaw, err := os.ReadFile(seedPath)
	if err != nil {
		t.Fatalf("读取 NodeVG seed 失败: %v", err)
	}
	var seed storagev1beta1.NodeVG
	if err := yaml.Unmarshal(seedRaw, &seed); err != nil {
		t.Fatalf("解析 NodeVG seed 失败: %v", err)
	}
	if seed.Spec.NodeName == "" {
		t.Fatalf("seed NodeVG 缺 spec.nodeName")
	}
	// 路线 A 在 apply 之后手工 patch status.vgExists=true（见 ADR-006 §10.3），
	// 渲染只认 vgExists=true 的 VG，故测试里补上这一步。
	seed.Status.VGExists = true

	// 2. 期望的渲染结果。
	want, ok, err := AggregateLVMDConfig([]storagev1beta1.NodeVG{seed})
	if err != nil {
		t.Fatalf("AggregateLVMDConfig 报错: %v", err)
	}
	if !ok {
		t.Fatalf("seed NodeVG 未产出 device-class（渲染返回 ok=false）")
	}

	// 3. 快照 ConfigMap 必须与渲染结果一致。
	cmPath := filepath.Join(lvmdDir, "configmap-lvmd-10-60-153-100.yaml")
	cmRaw, err := os.ReadFile(cmPath)
	if err != nil {
		t.Fatalf("读取 lvmd ConfigMap 失败: %v", err)
	}
	var cm corev1.ConfigMap
	if err := yaml.Unmarshal(cmRaw, &cm); err != nil {
		t.Fatalf("解析 lvmd ConfigMap 失败: %v", err)
	}
	if wantName := LvmdConfigName(seed.Spec.NodeName); cm.Name != wantName {
		t.Errorf("ConfigMap 名不符：got %q, want %q（必须由 LvmdConfigName 按节点名生成）", cm.Name, wantName)
	}
	if cm.Namespace != ManagedNamespace {
		t.Errorf("ConfigMap 命名空间不符：got %q, want %q", cm.Namespace, ManagedNamespace)
	}
	if got := cm.Data["lvmd.yaml"]; got != want {
		t.Errorf("ConfigMap 的 lvmd.yaml 与 AggregateLVMDConfig 渲染结果不一致：\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}

	// 4. DaemonSet 必须挂同一个 ConfigMap、且只落 seed 声明的节点。
	dsRaw, err := os.ReadFile(filepath.Join(lvmdDir, "daemonset.yaml"))
	if err != nil {
		t.Fatalf("读取 lvmd DaemonSet 失败: %v", err)
	}
	var ds *appsv1.DaemonSet
	for _, doc := range strings.Split(string(dsRaw), "\n---") {
		var probe struct {
			Kind string `json:"kind"`
		}
		if err := yaml.Unmarshal([]byte(doc), &probe); err != nil {
			continue
		}
		if probe.Kind != "DaemonSet" {
			continue
		}
		var parsed appsv1.DaemonSet
		if err := yaml.Unmarshal([]byte(doc), &parsed); err != nil {
			t.Fatalf("解析 lvmd DaemonSet 失败: %v", err)
		}
		ds = &parsed
	}
	if ds == nil {
		t.Fatalf("daemonset.yaml 里找不到 kind: DaemonSet")
	}

	var cmRefs []string
	for _, v := range ds.Spec.Template.Spec.Volumes {
		if v.ConfigMap != nil {
			cmRefs = append(cmRefs, v.ConfigMap.Name)
		}
	}
	if len(cmRefs) != 1 || cmRefs[0] != cm.Name {
		t.Errorf("DaemonSet 的 ConfigMap 卷引用不符：got %v, want [%s]", cmRefs, cm.Name)
	}
	if got := ds.Spec.Template.Spec.NodeSelector["kubernetes.io/hostname"]; got != seed.Spec.NodeName {
		t.Errorf("DaemonSet nodeSelector 指向的节点 (%q) 与 seed NodeVG 的节点 (%q) 不一致", got, seed.Spec.NodeName)
	}
}
