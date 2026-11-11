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

// TestLvmdPOCArtifactsConsistent 锁定 control-plane/config/lvmd/ 下多节点清单与渲染逻辑的一致性。
//
// 背景（ADR-006 路线 A / §13）：POC 用「手工 seed NodeVG → 控制面渲染 per-node ConfigMap →
// 汇总进聚合 CM → lvmd DaemonSet 按 NODE_NAME 投影」这条链。任一处单独改动都会让真机行为
// 与仓库声明脱节，而 TestManifestConfigMapRefsResolve 只校验「引用能解析」。这里断言：
//  1. 每个 seed 的 spec.nodeName 决定 per-node ConfigMap 名（LvmdConfigName）；
//  2. per-node ConfigMap 的 data["lvmd.yaml"] 与 AggregateLVMDConfig(seed) 逐字节相同；
//  3. 两个 seed 的 device-class 名必须相同（同一个 StorageClass 才能跨节点供给）；
//  4. 聚合 CM `hlvm-lvmd-all` 以节点名为 key，value 逐字节等于对应 per-node 渲染结果；
//  5. lvmd DS 用标签选择器（不再写死 hostname）、挂聚合 CM、initContainer 用 Downward API
//     的 spec.nodeName 投影到 emptyDir；
//  6. 判据脚本不再出现 `exec "ds/$LVMD_DS"` 这类多节点下任取 Pod 的写法。
func TestLvmdPOCArtifactsConsistent(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根目录失败: %v", err)
	}
	lvmdDir := filepath.Join(root, "control-plane", "config", "lvmd")

	// 1~3. 逐节点读 seed + per-node ConfigMap 快照，并与渲染逻辑比对。
	seeds := []string{"nodevg-seed-153.yaml", "nodevg-seed-202.yaml"}
	wantByNode := make(map[string]string, len(seeds))
	classNames := make(map[string]string, len(seeds))
	for _, file := range seeds {
		seedRaw, err := os.ReadFile(filepath.Join(lvmdDir, file))
		if err != nil {
			t.Fatalf("读取 NodeVG seed %s 失败: %v", file, err)
		}
		var seed storagev1beta1.NodeVG
		if err := yaml.Unmarshal(seedRaw, &seed); err != nil {
			t.Fatalf("解析 NodeVG seed %s 失败: %v", file, err)
		}
		if seed.Spec.NodeName == "" {
			t.Fatalf("seed %s 缺 spec.nodeName", file)
		}
		// 路线 A 在 apply 之后手工 patch status.vgExists=true（见 ADR-006 §10.3），
		// 渲染只认 vgExists=true 的 VG，故测试里补上这一步。
		seed.Status.VGExists = true
		classNames[seed.Name] = DeviceClassName(seed)

		want, ok, err := AggregateLVMDConfig([]storagev1beta1.NodeVG{seed})
		if err != nil {
			t.Fatalf("%s: AggregateLVMDConfig 报错: %v", file, err)
		}
		if !ok {
			t.Fatalf("%s: seed NodeVG 未产出 device-class（渲染返回 ok=false）", file)
		}
		wantByNode[seed.Spec.NodeName] = want

		cmPath := filepath.Join(lvmdDir, "configmap-lvmd-"+seed.Spec.NodeName+".yaml")
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
	}

	// 同一个 StorageClass 只引用一个 device-class 名，跨节点必须一致。
	var firstClass string
	for vg, class := range classNames {
		if firstClass == "" {
			firstClass = class
		} else if class != firstClass {
			t.Errorf("NodeVG %q 的 device-class=%q 与另一节点的 %q 不一致；同一个 SC 无法跨节点供给", vg, class, firstClass)
		}
	}

	// 4. 聚合 CM：key = 节点名，value = 对应渲染结果；不多不少。
	allRaw, err := os.ReadFile(filepath.Join(lvmdDir, "configmap-lvmd-all.yaml"))
	if err != nil {
		t.Fatalf("读取聚合 lvmd ConfigMap 失败: %v", err)
	}
	var all corev1.ConfigMap
	if err := yaml.Unmarshal(allRaw, &all); err != nil {
		t.Fatalf("解析聚合 lvmd ConfigMap 失败: %v", err)
	}
	if all.Name != "hlvm-lvmd-all" || all.Namespace != ManagedNamespace {
		t.Errorf("聚合 ConfigMap 名/命名空间不符：got %s/%s", all.Namespace, all.Name)
	}
	for node, want := range wantByNode {
		if got := all.Data[node]; got != want {
			t.Errorf("聚合 CM 中节点 %q 的配置与 per-node 渲染不一致：\n--- got ---\n%s\n--- want ---\n%s", node, got, want)
		}
	}
	if len(all.Data) != len(wantByNode) {
		t.Errorf("聚合 CM 的 key 数不符：got %d, want %d（多出来的节点没有 NodeVG seed）", len(all.Data), len(wantByNode))
	}

	// 5. DaemonSet 必须按节点投影，不能写死单节点。
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
	if got := ds.Spec.Template.Spec.NodeSelector["hlvm.io/lvmd"]; got != "true" {
		t.Errorf("DaemonSet 必须用 hlvm.io/lvmd=true 标签选择节点，实际 nodeSelector=%v", ds.Spec.Template.Spec.NodeSelector)
	}
	if got, bad := ds.Spec.Template.Spec.NodeSelector["kubernetes.io/hostname"]; bad {
		t.Errorf("DaemonSet 仍写死 hostname=%q，多节点扩容会失效", got)
	}

	var cmRefs []string
	var projectedEmptyDir bool
	for _, v := range ds.Spec.Template.Spec.Volumes {
		if v.ConfigMap != nil {
			cmRefs = append(cmRefs, v.ConfigMap.Name)
		}
		if v.Name == "lvmd-config" && v.EmptyDir != nil {
			projectedEmptyDir = true
		}
	}
	if len(cmRefs) != 1 || cmRefs[0] != all.Name {
		t.Errorf("DaemonSet 的 ConfigMap 卷引用不符：got %v, want [%s]", cmRefs, all.Name)
	}
	if !projectedEmptyDir {
		t.Errorf("lvmd-config 卷必须是 emptyDir（initContainer 投影目标），否则多节点配置无法写入")
	}

	var initFound bool
	for _, c := range ds.Spec.Template.Spec.InitContainers {
		if c.Name != "project-node-config" {
			continue
		}
		initFound = true
		var hasNodeName bool
		for _, e := range c.Env {
			if e.Name == "NODE_NAME" && e.ValueFrom != nil && e.ValueFrom.FieldRef != nil &&
				e.ValueFrom.FieldRef.FieldPath == "spec.nodeName" {
				hasNodeName = true
			}
		}
		if !hasNodeName {
			t.Errorf("initContainer 缺 NODE_NAME（Downward API spec.nodeName），无法按节点选配置")
		}
		if !strings.Contains(strings.Join(c.Args, "\n"), "${NODE_NAME}") {
			t.Errorf("initContainer 命令未按 NODE_NAME 选择聚合 CM 的 key")
		}
	}
	if !initFound {
		t.Errorf("DaemonSet 缺 project-node-config initContainer；单份静态 ConfigMap 无法服务多节点")
	}

	// 6. 判据脚本不得再用 ds/ 任取 Pod（多节点下会读到别的节点的 VG）。
	for _, script := range []string{"pvc-supply-e2e.sh", "deploy-agent-real.sh", "agent-lvmd-lock-verify.sh"} {
		raw, err := os.ReadFile(filepath.Join(root, "docs", "poc", "scripts", script))
		if err != nil {
			t.Fatalf("读取判据脚本 %s 失败: %v", script, err)
		}
		body := string(raw)
		if strings.Contains(body, `exec "ds/$LVMD_DS"`) || strings.Contains(body, `exec -i "ds/$LVMD_DS"`) {
			t.Errorf("%s 仍使用 `exec ds/$LVMD_DS` 任取 Pod，多节点下宿主 lvs 会读到别的节点", script)
		}
	}
}
