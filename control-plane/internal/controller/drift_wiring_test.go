package controller

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// TestLVReporterWiringDiscipline 钉死 ADR-006 §16 的跨语言接线纪律。
//
// 三方对账的 lvs 一侧横跨 Rust agent（采集/过滤/回写）、CRD status 字段、
// Go 控制器（Reporter/PV watch）与真机判据脚本；任何一环被单独回退都不会被
// 同语言单测发现，故用源码/清单断言兜底，防止「Reporter 又被改回 nil」这类静默退化。
func TestLVReporterWiringDiscipline(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("解析仓库根目录失败: %v", err)
	}
	read := func(rel string) string {
		t.Helper()
		raw, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", rel, err)
		}
		return string(raw)
	}
	want := func(rel string, needles ...string) {
		t.Helper()
		body := read(rel)
		for _, n := range needles {
			if !strings.Contains(body, n) {
				t.Errorf("%s 缺少 %q（§16 接线纪律）", rel, n)
			}
		}
	}

	// 1. Agent 必须有权 patch NodeVG/status，否则 LV 上报 403。
	want("control-plane/config/rbac/agent_role.yaml",
		`resources: ["nodevgs/status"]`, `verbs: ["get", "update", "patch"]`)
	// 2. 控制器必须装配生产 Reporter（nil 会让三方对账静默失效）。
	want("control-plane/cmd/storage-controller/main.go",
		`Reporter: &controller.NodeVGLVReporter{Client: mgr.GetClient()}`)
	// 3. PV 增删改必须触发对账；任一节点上报失败要整轮放弃，不能 continue 造成误报。
	want("control-plane/internal/controller/drift_controller.go",
		`Watches(&corev1.PersistentVolume{}`, "本轮放弃三方对账")
	// 4. Go 类型与 deepcopy 必须声明新字段，否则 VGReconciler 的 Status().Update 会抹掉上报。
	want("control-plane/api/v1beta1/nodevg_types.go",
		"LogicalVolumes []LVReport", "LastLVReportTime *metav1.Time")
	want("control-plane/api/v1beta1/zz_generated.deepcopy.go",
		"in.LogicalVolumes != nil", "in.LastLVReportTime != nil")
	// 5. Rust 侧：主循环必须启动第三条上报循环；读路径必须带 lv_attr 并做过滤。
	want("agent/src/agent/mod.rs", "run_nodevg_lv_reconciler(")
	want("agent/src/lvm/mod.rs", "lv_attr,pool_lv", "is_reportable_lv", "reportable_lvs")
	want("agent/src/reporter/kube_rw.rs", "collect_reportable_lvs", "lastLVReportTime")
	want("agent/src/reporter/mod.rs", "build_nodevg_lv_patch")
	// 6. 真机常驻 DS 必须注入推荐 wrapper（宿主 lvs 与写路径锁同源）。
	want("docs/poc/scripts/deploy-agent-real.sh", "HLVM_HOST_WRAPPER")
	// 7. 真机验收脚本：必须覆盖注入/清理/零误报，且字段读取走 kc_get。
	want("docs/poc/scripts/drift-reconcile-e2e.sh",
		"kc_get() {", "DRIFT_E2E_RESULT", "unmanaged-lv", "missing-lv",
		"lastLVReportTime", "event_count_sum", "trap cleanup EXIT")
}

// TestVGStatusDecodesAgentPatch 验证 Rust agent 的 merge patch 能被 Go 侧无损解码。
// 字段名或时间戳格式不一致时，控制面会把上报当成「尚无 LV 上报」而失败关闭。
func TestVGStatusDecodesAgentPatch(t *testing.T) {
	// jiff::Timestamp::now().to_string() 输出形态（含小数秒），与 metav1.Time 兼容。
	const patch = `{"status":{"logicalVolumes":[{"name":"9e639840-23de-403e-aebe-2335b9505816","bytes":1073741824}],"lastLVReportTime":"2026-11-12T02:57:17.123456789Z"}}`
	var envelope struct {
		Status storagev1beta1.VGStatus `json:"status"`
	}
	if err := json.Unmarshal([]byte(patch), &envelope); err != nil {
		t.Fatalf("agent patch 无法解码: %v", err)
	}
	st := envelope.Status
	if len(st.LogicalVolumes) != 1 ||
		st.LogicalVolumes[0].Name != "9e639840-23de-403e-aebe-2335b9505816" ||
		st.LogicalVolumes[0].Bytes != 1073741824 {
		t.Fatalf("logicalVolumes 解码错误: %+v", st.LogicalVolumes)
	}
	if st.LastLVReportTime == nil || st.LastLVReportTime.Time.Year() != 2026 {
		t.Fatalf("lastLVReportTime 解码错误: %+v", st.LastLVReportTime)
	}
}
