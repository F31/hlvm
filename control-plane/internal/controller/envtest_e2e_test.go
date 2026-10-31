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
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	gortn "runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

// TestEnvtestE2E 是 add-crd-controller-skeleton V.2「测试集群 e2e」的真实实现：
// 在 envtest（真实 kube-apiserver + etcd，版本 1.36.2，与目标集群同 minor）上安装 5 个手写 CRD，启动
// DiskReconciler / VGReconciler，手工创建 NodeDisk / NodeVG 并断言被真实控制器写回 status。
//
// 这是 V.1/V.3 阶段 fake-client 单测之外的真实 apiserver 验收：CRD schema 校验
// （Required/Enum/MaxLength/DeviceRef）与控制器对账均在真实控制平面上验证。
func TestEnvtestE2E(t *testing.T) {
	logf.SetLogger(zap.New(zap.UseDevMode(true)))

	assets := os.Getenv("KUBEBUILDER_ASSETS")
	if assets == "" {
		t.Skip("KUBEBUILDER_ASSETS 未设置；需先 `setup-envtest use 1.36.2` 并导出（CI 由 Makefile 设置）")
	}

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(storagev1alpha1.AddToScheme(scheme))
	utilruntime.Must(storagev1beta1.AddToScheme(scheme))

	// CRD 目录相对本测试源文件定位，避免 go test 工作目录不确定导致路径解析失败。
	_, thisFile, _, _ := gortn.Caller(0)
	crdDir := filepath.Join(filepath.Dir(thisFile), "..", "..", "config", "crd", "envtest")

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

	mgr := newEnvtestManager(t, cfg, scheme)
	if err := (&DiskReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme()}).SetupWithManager(mgr); err != nil {
		t.Fatalf("DiskReconciler 注册失败: %v", err)
	}
	if err := (&VGReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme()}).SetupWithManager(mgr); err != nil {
		t.Fatalf("VGReconciler 注册失败: %v", err)
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
	direct := newDirectClient(t, cfg, scheme)

	// 1) Ready Node：让 DiskReconciler 不触发隔离。
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-1"},
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{
				{Type: corev1.NodeReady, Status: corev1.ConditionTrue, LastTransitionTime: metav1.Now()},
			},
		},
	}
	mustCreate(t, c, ctx, node)

	// 2) NodeDisk：CRD schema 校验（Required NodeName / Enum WipePolicy / MaxLength ConfirmSerial /
	//    DeviceRef）+ 真实控制器写回 Stale 条件。
	disk := &storagev1beta1.NodeDisk{
		ObjectMeta: metav1.ObjectMeta{Name: "disk-1"},
		Spec: storagev1beta1.DiskSpec{
			NodeName:      "node-1",
			Adopt:         true,
			Device:        &storagev1beta1.DiskDevice{Path: "/dev/sda"},
			ConfirmSerial: "SN12345678",
			WipePolicy:    storagev1beta1.WipeNone,
		},
	}
	mustCreate(t, c, ctx, disk)

	// status 子资源：Create 会忽略 status，需显式写回供 VG 删盘保护判断 InVG。
	// 用直连 client + 重试：DiskReconciler 同时写 Stale 条件，直接 Update 会并发冲突。
	updateStatusRetry(t, ctx, direct, disk, func(o client.Object) {
		d := o.(*storagev1beta1.NodeDisk)
		d.Status.Phase = storagev1beta1.DiskPhaseInVG
		d.Status.VgRef = "vg-1"
		d.Status.Identity = storagev1beta1.DiskIdentity{ByID: "disk-1"}
		d.Status.CurrentDevice = "disk-1"
	})

	// 断言 DiskReconciler 对真实 apiserver 上的对象完成了 reconcile（Stale 条件被写回）。
	if err := waitForNodeDiskStale(t, c, ctx, "disk-1"); err != nil {
		t.Fatalf("NodeDisk 未被 reconcile: %v", err)
	}

	// 确认 NodeDisk 的 InVG 状态已落入控制器缓存（VGReconciler 不监听 NodeDisk，
	// 需在创建 VG 前保证缓存已热，避免删盘保护读不到 InVG）。
	if err := waitForCachedDiskInVG(t, c, ctx, "disk-1"); err != nil {
		t.Fatalf("NodeDisk 状态未落入缓存: %v", err)
	}

	// 3) NodeVG：CRD schema 校验（Required NodeName / thinPool.name Required / Enum Layout/Redundancy）+
	//    删盘保护：候选 disk-1 仍 InVG 被阻塞 -> status.pendingOps 被真实控制器写回。
	vg := &storagev1alpha1.NodeVG{
		ObjectMeta: metav1.ObjectMeta{Name: "vg-1"},
		Spec: storagev1alpha1.VGSpec{
			NodeName:   "node-1",
			Layout:     storagev1alpha1.VGLayoutPooled,
			Redundancy: storagev1alpha1.RedundancyNone,
			Disks:      []string{"disk-1"},
			ThinPool:   storagev1alpha1.ThinPoolSpec{Name: "thin0", InitialSizePercent: 80, MaxSizePercent: 95},
			Operations: storagev1alpha1.VGOperations{RemoveDisks: []string{"disk-1"}},
		},
	}
	mustCreate(t, c, ctx, vg)

	if err := waitForVGPendingOps(t, c, ctx, "vg-1"); err != nil {
		t.Fatalf("NodeVG 未被 reconcile（删盘保护未生效）: %v", err)
	}
}

func mustCreate(t *testing.T, c client.Client, ctx context.Context, obj client.Object) {
	t.Helper()
	if err := c.Create(ctx, obj); err != nil {
		t.Fatalf("创建对象 %s 失败: %v", obj.GetName(), err)
	}
}

func waitForNodeDiskStale(t *testing.T, c client.Client, ctx context.Context, name string) error {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var d storagev1beta1.NodeDisk
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &d); err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return fmt.Errorf("NodeDisk 不存在超时: %w", err)
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			return err
		}
		if apimeta.FindStatusCondition(d.Status.Conditions, "Stale") != nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("30s 内 Stale 条件未出现（DiskReconciler 未真实 reconcile）")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func waitForCachedDiskInVG(t *testing.T, c client.Client, ctx context.Context, name string) error {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var d storagev1beta1.NodeDisk
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &d); err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return fmt.Errorf("NodeDisk 不存在超时: %w", err)
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			return err
		}
		if d.Status.Phase == storagev1beta1.DiskPhaseInVG {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("30s 内 NodeDisk 缓存未反映 InVG 状态")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func waitForVGPendingOps(t *testing.T, c client.Client, ctx context.Context, name string) error {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var v storagev1alpha1.NodeVG
		if err := c.Get(ctx, client.ObjectKey{Name: name}, &v); err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return fmt.Errorf("NodeVG 不存在超时: %w", err)
				}
				time.Sleep(200 * time.Millisecond)
				continue
			}
			return err
		}
		if len(v.Status.PendingOps) > 0 {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("30s 内 pendingOps 未出现（VGReconciler 删盘保护未真实生效）")
		}
		time.Sleep(300 * time.Millisecond)
	}
}
