package controller

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	gortn "runtime"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// TestLifecycleOpsEnvtest 是 add-lifecycle-ops 5.1/5.2「演练（需 envtest）」的真实实现：
// 在 envtest（真实 kube-apiserver + etcd，版本 1.33.0）上安装 CRD，启动 DiskReconciler 与
// DriftDetectorReconciler，验证：
//   - 5.1 节点故障（NotReady 且 lastReady 超阈值）：DiskReconciler 自动创建隔离入口
//     StorageNodeOps(auto-isolate-<node>, operation=isolate) 并置 NodeDisk Stale=True（隔离期/人工清理把手）。
//   - 5.2 手工 lvcreate 绕过平台：注入假 LVReporter 模拟节点实际多出平台未记账 LV，DriftDetector
//     经 CR/PV/lvs 三方对账发现 unmanaged-lv 漂移并发布 StorageDrift 告警事件（补录建议；平台不自动修复）。
//
// 注：原 tasks 标"需 envtest/测试集群，移交集成验证"——现 envtest 二进制已就绪，落地真实控制平面验收
// （手法同 add-crd-controller-skeleton V.2 与 add-capacity-governance 4.2）。
func TestLifecycleOpsEnvtest(t *testing.T) {
	logf.SetLogger(zap.New(zap.UseDevMode(true)))

	assets := os.Getenv("KUBEBUILDER_ASSETS")
	if assets == "" {
		t.Skip("KUBEBUILDER_ASSETS 未设置；需先 `setup-envtest use 1.33.0` 并导出（CI 由 Makefile 设置）")
	}

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(storagev1alpha1.AddToScheme(scheme))

	_, thisFile, _, _ := gortn.Caller(0)
	crdDir := filepath.Join(filepath.Dir(thisFile), "..", "..", "config", "crd", "bases")

	testEnv := &envtest.Environment{
		CRDDirectoryPaths:     []string{crdDir},
		ErrorIfCRDPathMissing: true,
		BinaryAssetsDirectory: assets,
		Scheme:                scheme,
	}
	cfg, err := testEnv.Start()
	if err != nil {
		t.Fatalf("envtest 启动失败: %v", err)
	}
	defer func() { _ = testEnv.Stop() }()

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
		LeaderElection:         false,
	})
	if err != nil {
		t.Fatalf("manager 创建失败: %v", err)
	}
	if err := (&DiskReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme()}).SetupWithManager(mgr); err != nil {
		t.Fatalf("DiskReconciler 注册失败: %v", err)
	}
	// 5.2：注入假 LVReporter 模拟"手工 lvcreate"产生的实际 LV（平台未记账）。
	fakeReporter := &fakeLVReporter{lvs: []ActualLV{
		{Node: "node-drift", VG: "vg0", Name: "lv-handmade"},
	}}
	if err := (&DriftDetectorReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("drift-detector"),
		Reporter: fakeReporter,
	}).SetupWithManager(mgr); err != nil {
		t.Fatalf("DriftDetectorReconciler 注册失败: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		if err := mgr.Start(ctx); err != nil {
			t.Errorf("manager 运行失败: %v", err)
		}
	}()
	if !mgr.GetCache().WaitForCacheSync(ctx) {
		t.Fatal("cache 同步超时")
	}

	c := mgr.GetClient()

	// ---------- 5.1 节点故障 -> 隔离入口 ----------
	// 节点 NotReady 且 lastReady 远早于阈值（默认 30min），构成失联超限 -> 应自动隔离。
	nodeFail := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-fail"},
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{
				{
					Type:               corev1.NodeReady,
					Status:             corev1.ConditionFalse,
					LastTransitionTime: metav1.NewTime(time.Now().Add(-1 * time.Hour)),
				},
			},
		},
	}
	mustCreate(t, c, ctx, nodeFail)
	waitForNodeExists(t, c, ctx, "node-fail")

	diskFail := &storagev1alpha1.NodeDisk{
		ObjectMeta: metav1.ObjectMeta{Name: "disk-fail"},
		Spec: storagev1alpha1.DiskSpec{
			NodeName:      "node-fail",
			Adopt:         true,
			DeviceRef:     "/dev/sdb",
			ConfirmSerial: "FAILSN0001",
			WipePolicy:    storagev1alpha1.WipeNone,
		},
	}
	mustCreate(t, c, ctx, diskFail)

	// 断言：DiskReconciler 自动创建隔离入口 StorageNodeOps(auto-isolate-node-fail, operation=isolate)。
	if err := waitForIsolateOps(t, c, ctx, "node-fail"); err != nil {
		t.Fatalf("5.1 节点故障未生成隔离入口: %v", err)
	}
	// 断言：NodeDisk 被标 Stale=True（失联）。
	if err := waitForDiskStale(t, c, ctx, "disk-fail", true); err != nil {
		t.Fatalf("5.1 NodeDisk 未标 Stale: %v", err)
	}

	// ---------- 5.2 手工 lvcreate 触发 drift 告警 ----------
	// 先建一个平台记账侧 PV（带 hlvm.dev/node 注解）+ 一个 NodeVG（触发 drift reconcile）。
	pvManaged := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{
			Name: "pv-managed",
			Annotations: map[string]string{
				PVNodeAnnotation: "node-drift",
				"hlvm.dev/vg":    "vg0",
			},
		},
		Spec: corev1.PersistentVolumeSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
			Capacity: corev1.ResourceList{
				corev1.ResourceStorage: resource.MustParse("1Gi"),
			},
			PersistentVolumeSource: corev1.PersistentVolumeSource{
				HostPath: &corev1.HostPathVolumeSource{Path: "/tmp"},
			},
		},
	}
	mustCreate(t, c, ctx, pvManaged)
	waitForPVExists(t, c, ctx, "pv-managed")

	vgDrift := &storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-drift"},
		Spec:       storagev1alpha1.VGSpec{NodeName: "node-drift", Tier: "gold"},
	}
	mustCreate(t, c, ctx, vgDrift)

	// 断言：DriftDetector 经三方对账发现 unmanaged-lv 漂移并发布 StorageDrift 告警事件。
	if err := waitForDriftEvent(t, c, ctx, "node-drift"); err != nil {
		t.Fatalf("5.2 未发布 StorageDrift 告警: %v", err)
	}
}

// 注：fakeLVReporter 已在同包 drift_controller_test.go 声明（形状一致），此处直接复用。

func waitForIsolateOps(t *testing.T, c client.Client, ctx context.Context, nodeName string) error {
	t.Helper()
	name := fmt.Sprintf("auto-isolate-%s", nodeName)
	deadline := time.Now().Add(30 * time.Second)
	for {
		var ops storagev1alpha1.StorageNodeOps
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &ops); err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return fmt.Errorf("30s 内未创建 %s: %w", name, err)
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			return err
		}
		if ops.Spec.Operation == storagev1alpha1.NodeOpIsolate && ops.Spec.NodeName == nodeName {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("30s 内 %s 的 operation 非 isolate（实际 %s）", name, ops.Spec.Operation)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func waitForDiskStale(t *testing.T, c client.Client, ctx context.Context, name string, wantTrue bool) error {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var d storagev1alpha1.NodeDisk
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &d); err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return err
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			return err
		}
		cond := apimeta.FindStatusCondition(d.Status.Conditions, "Stale")
		if cond != nil && (cond.Status == metav1.ConditionTrue) == wantTrue {
			return nil
		}
		if time.Now().After(deadline) {
			got := "nil"
			if cond != nil {
				got = string(cond.Status)
			}
			return fmt.Errorf("30s 内 disk %s Stale 未达预期（实际 %s）", name, got)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

func waitForPVExists(t *testing.T, c client.Client, ctx context.Context, name string) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var pv corev1.PersistentVolume
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &pv); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("30s 内 PV %s 未进入缓存", name)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func waitForDriftEvent(t *testing.T, c client.Client, ctx context.Context, node string) error {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var el corev1.EventList
		if err := c.List(ctx, &el); err != nil {
			return err
		}
		for _, e := range el.Items {
			if e.Reason == "StorageDrift" && e.InvolvedObject.Name == node {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("30s 内未出现节点 %s 的 StorageDrift 告警事件", node)
		}
		time.Sleep(300 * time.Millisecond)
	}
}
