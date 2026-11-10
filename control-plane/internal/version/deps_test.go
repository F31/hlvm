package version

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// k8sDepBaseline 是当前**被接受**的 k8s 依赖组合快照。
//
// 【为什么是「基线锁定」而不是断言「全部同版本」】
// 当前组合本来就不是同一批发版：
//   - k8s.io/api / apimachinery                 v0.33.0
//   - k8s.io/client-go / apiextensions-apiserver v0.32.1
//   - sigs.k8s.io/controller-runtime           v0.20.4（官方绑定 k8s v0.32.x）
//
// Rust 侧是 kube 4.x → k8s-openapi 0.28 / feature v1_36，与 kind 1.36.x
// 实测集群对齐；Go 侧则因 MVS 让 client-go 0.32.1 链接到 apimachinery 0.33.0，
// 属于上游未验证的搭配。直接断言「版本必须一致」会让 CI 立刻变红，而本里程碑的
// 结论恰恰是**不在此时升级**：升到 k8s 0.36 需要 controller-runtime 0.22+，
// 牵连 webhook decoder / cache / CRD conversion 接线，必须单独立项并在真实集群
// 回归后评估，不能借「顺手统一版本」夹带进来。
//
// 因此门禁是「任何变动都必须显式改这里」：go get -u、手工改 go.mod、或 CI 里
// 某个工具隐式升级，都会让 TestK8sDependencyBaseline 失败，逼出一次有记录的
// 兼容性评估，而不是静默漂移。更新基线时请同步改 CHANGELOG 的已知风险登记。
var k8sDepBaseline = map[string]string{
	"k8s.io/api":                     "v0.33.0",
	"k8s.io/apimachinery":            "v0.33.0",
	"k8s.io/client-go":               "v0.32.1",
	"k8s.io/apiextensions-apiserver": "v0.32.1",
	"sigs.k8s.io/controller-runtime": "v0.20.4",
}

// goModRequireRe 匹配 require 块内（或单行 require）的 "模块 版本"。
// 不匹配 replace / exclude 之后的内容，也不匹配带 => 的替换行。
var goModRequireRe = regexp.MustCompile(`^([A-Za-z0-9._\-/]+)\s+(v[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.\-]*)`)

type goModRequires struct {
	all    map[string]string // 含 indirect
	direct map[string]string // 只含直接依赖（无 // indirect 标记）
}

// readGoModRequires 用 runtime.Caller 定位 go.mod，不依赖测试进程的工作目录。
func readGoModRequires(t *testing.T) goModRequires {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("无法定位当前测试文件，无法读取 go.mod")
	}
	path := filepath.Join(filepath.Dir(thisFile), "..", "..", "go.mod")
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("读取 %s 失败: %v", path, err)
	}
	defer f.Close()

	res := goModRequires{all: map[string]string{}, direct: map[string]string{}}
	inRequireBlock := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "require (") {
			inRequireBlock = true
			continue
		}
		if inRequireBlock && line == ")" {
			inRequireBlock = false
			continue
		}
		target := ""
		switch {
		case strings.HasPrefix(line, "require "):
			target = strings.TrimSpace(strings.TrimPrefix(line, "require "))
		case inRequireBlock:
			target = line
		default:
			continue
		}
		m := goModRequireRe.FindStringSubmatch(target)
		if m == nil {
			continue // 注释行、或 replace 行的 "a => b" 形态
		}
		mod, ver := m[1], m[2]
		res.all[mod] = ver
		if !strings.Contains(target, "// indirect") {
			res.direct[mod] = ver
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("扫描 go.mod 失败: %v", err)
	}
	if len(res.all) == 0 {
		t.Fatal("未从 go.mod 解析出任何 require 条目（go.mod 结构或正则已变）")
	}
	return res
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// TestK8sDependencyBaseline 锁住已知代差：版本变了必须显式更新基线并做兼容性评估。
func TestK8sDependencyBaseline(t *testing.T) {
	got := readGoModRequires(t)
	for _, mod := range sortedKeys(k8sDepBaseline) {
		want := k8sDepBaseline[mod]
		actual, ok := got.all[mod]
		if !ok {
			t.Errorf("go.mod 里找不到 %s（基线期望 %s）；依赖被移除也要同步更新基线", mod, want)
			continue
		}
		if actual != want {
			t.Errorf("%s = %s，基线为 %s。k8s 依赖变动必须同步更新 k8sDepBaseline，"+
				"并完成 controller-runtime / webhook decoder / CRD conversion 的兼容性评估（见本文件顶部注释）",
				mod, actual, want)
		}
	}
	// 反向：新增的 k8s 直接依赖若未登记基线，也要挡住（indirect 里 klog/utils 等
	// 由 MVS 带入的传递依赖不算，避免每次 go mod tidy 都误报）。
	for mod, ver := range got.direct {
		if _, tracked := k8sDepBaseline[mod]; tracked {
			continue
		}
		if strings.HasPrefix(mod, "k8s.io/") || strings.HasPrefix(mod, "sigs.k8s.io/controller-runtime") {
			t.Errorf("发现未登记基线的 k8s 直接依赖 %s %s —— 请评估后加入 k8sDepBaseline", mod, ver)
		}
	}
}

// TestK8sDependencyPairs 是跨模块的内部一致性约束：即使将来更新了基线，
// 同批发版的模块也不该被单独升一个（这类错配比整体升级更隐蔽）。
func TestK8sDependencyPairs(t *testing.T) {
	got := readGoModRequires(t)
	pairs := [][2]string{
		{"k8s.io/api", "k8s.io/apimachinery"},
		{"k8s.io/client-go", "k8s.io/apiextensions-apiserver"},
	}
	for _, p := range pairs {
		a, b := got.all[p[0]], got.all[p[1]]
		if a == "" || b == "" {
			t.Errorf("配对检查缺模块：%s=%q / %s=%q", p[0], a, p[1], b)
			continue
		}
		if a != b {
			t.Errorf("%s (%s) 与 %s (%s) 应为同批发版同版本；单独升其中一个会破坏内部 API 契约",
				p[0], a, p[1], b)
		}
	}
}
