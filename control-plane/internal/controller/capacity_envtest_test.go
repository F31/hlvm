package controller

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	gortn "runtime"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
)

// TestCapacityGovernanceEnvtest 是 add-capacity-governance 4.2「envtest」的真实实现：
// 在 envtest（真实 kube-apiserver + etcd，版本 1.33.0）上安装 CRD，启动 CapacityReconciler，
// 手工创建 NodeVG（不同水位）并断言：
//   - locked 流转：data% 越过 Critical(默认 85) -> CapacityLocked；
//   - metadata 阈值独立评估：data% 低但 metadata% 越过 MetadataCritical(默认 75) -> CapacityLocked；
//   - 标签联动：locked 时对应节点被打 storage.example.io/<tier>-locked=true；
//   - 滞回解锁：水位回落到 Unlock(默认 80) 以下才解锁为 Available，且标签被摘除。
//
// 这是 4.1 fake-client 单测之外的真实 apiserver 验收（4.2 原注「本环境用 fake-client 等价覆盖」，
// 现 envtest 二进制已就绪，故落地真实集群验收，手法同 add-crd-controller-skeleton V.2）。
func TestCapacityGovernanceEnvtest(t *testing.T) {
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
	if err := (&CapacityReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme()}).SetupWithManager(mgr); err != nil {
		t.Fatalf("CapacityReconciler 注册失败: %v", err)
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

	// 先创建两个节点（标签联动需节点存在；warm 缓存以确保首次 reconcile 即能打标）。
	node1 := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-1"}}
	node2 := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "node-2"}}
	mustCreate(t, c, ctx, node1)
	mustCreate(t, c, ctx, node2)
	waitForNodeExists(t, c, ctx, "node-1")
	waitForNodeExists(t, c, ctx, "node-2")

	// vg-1：data% = 90（>= Critical 85）-> Locked；tier=gold；节点 node-1。
	vg1 := &storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-1"},
		Spec:       storagev1alpha1.VGSpec{NodeName: "node-1", Tier: "gold"},
		Status:     storagev1alpha1.VGStatus{ThinPool: storagev1alpha1.VGThinPoolStatus{DataPercent: 90, MetadataPercent: 0}},
	}
	mustCreate(t, c, ctx, vg1)
	// 注意：Create 响应会清空传入对象的 Status，须重新赋值后再写回 status 子资源。
	vg1.Status = storagev1alpha1.VGStatus{ThinPool: storagev1alpha1.VGThinPoolStatus{DataPercent: 90, MetadataPercent: 0}}
	if err := c.Status().Update(ctx, vg1); err != nil {
		t.Fatalf("vg-1 status 写回失败: %v", err)
	}
	if err := waitForVGStatus(t, c, ctx, "vg-1", storagev1alpha1.CapacityLocked); err != nil {
		t.Fatalf("vg-1 未锁定: %v", err)
	}
	if err := waitForNodeLabel(t, c, ctx, "node-1", LockLabelName("gold"), true); err != nil {
		t.Fatalf("vg-1 锁定后 node-1 未打 gold-locked 标签: %v", err)
	}

	// vg-2：data% = 10（低）但 metadata% = 90（>= MetadataCritical 75）-> 经 metadata 路径 Locked；
	// tier=silver；节点 node-2。验证 metadata 阈值独立评估（不依赖 data% 触发）。
	vg2 := &storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-2"},
		Spec:       storagev1alpha1.VGSpec{NodeName: "node-2", Tier: "silver"},
		Status:     storagev1alpha1.VGStatus{ThinPool: storagev1alpha1.VGThinPoolStatus{DataPercent: 10, MetadataPercent: 90}},
	}
	mustCreate(t, c, ctx, vg2)
	// 同 vg-1：Create 响应清空 Status，重新赋值后写回。
	vg2.Status = storagev1alpha1.VGStatus{ThinPool: storagev1alpha1.VGThinPoolStatus{DataPercent: 10, MetadataPercent: 90}}
	if err := c.Status().Update(ctx, vg2); err != nil {
		t.Fatalf("vg-2 status 写回失败: %v", err)
	}
	if err := waitForVGStatus(t, c, ctx, "vg-2", storagev1alpha1.CapacityLocked); err != nil {
		t.Fatalf("vg-2 未经 metadata 路径锁定: %v", err)
	}
	if err := waitForNodeLabel(t, c, ctx, "node-2", LockLabelName("silver"), true); err != nil {
		t.Fatalf("vg-2 锁定后 node-2 未打 silver-locked 标签: %v", err)
	}

	// 滞回解锁：将 vg-1 的 data% 降到 50（< Unlock 80，且 < Warning 75）-> 应从 Locked 解锁为 Available，
	// 且 node-1 的 gold-locked 标签被摘除（标签联动对称）。
	var cur1 storagev1alpha1.NodeVG
	if err := c.Get(ctx, client.ObjectKey{Name: "vg-1"}, &cur1); err != nil {
		t.Fatalf("取 vg-1 失败: %v", err)
	}
	cur1.Status.ThinPool = storagev1alpha1.VGThinPoolStatus{DataPercent: 50, MetadataPercent: 0}
	if err := c.Status().Update(ctx, &cur1); err != nil {
		t.Fatalf("vg-1 降压写回失败: %v", err)
	}
	if err := waitForVGStatus(t, c, ctx, "vg-1", storagev1alpha1.CapacityAvailable); err != nil {
		t.Fatalf("vg-1 未滞回解锁: %v", err)
	}
	if err := waitForNodeLabel(t, c, ctx, "node-1", LockLabelName("gold"), false); err != nil {
		t.Fatalf("vg-1 解锁后 node-1 的 gold-locked 标签未摘除: %v", err)
	}
}

func waitForNodeExists(t *testing.T, c client.Client, ctx context.Context, name string) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var n corev1.Node
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &n); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("30s 内节点 %s 未进入缓存", name)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func waitForVGStatus(t *testing.T, c client.Client, ctx context.Context, name string, want storagev1alpha1.CapacityStatus) error {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var v storagev1alpha1.NodeVG
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &v); err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return err
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			return err
		}
		if v.Status.CapacityStatus == want {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("30s 内 vg %s capacityStatus 未变为 %s（实际 %s）", name, want, v.Status.CapacityStatus)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

func waitForNodeLabel(t *testing.T, c client.Client, ctx context.Context, name, key string, wantExists bool) error {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var n corev1.Node
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &n); err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return err
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			return err
		}
		_, has := n.Labels[key]
		if has == wantExists {
			return nil
		}
		if time.Now().After(deadline) {
			if wantExists {
				return fmt.Errorf("30s 内节点 %s 未出现标签 %s", name, key)
			}
			return fmt.Errorf("30s 内节点 %s 标签 %s 未摘除", name, key)
		}
		time.Sleep(300 * time.Millisecond)
	}
}
