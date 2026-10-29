package controller

import (
	"context"
	"testing"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/util/retry"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/config"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

// newEnvtestManager 创建测试用 manager，统一关闭 controller 名称唯一性校验。
//
// 原因：controller-runtime 的 controller 名称唯一性检查用的是**进程级全局集合**
// （pkg/controller/name.go 的 usedNames），manager 销毁时不会清理。同一测试进程内
// 运行多个 envtest（各自新建 manager、注册同名 controller，如 DiskReconciler 的
// 默认名 nodedisk）时，第二个 manager 会直接失败：
//
//	controller with name nodedisk already exists
//
// 该问题只在「多个 envtest 同进程」时出现——单独跑任一测试都通过，CI 用
// `-run Envtest` 汇总跑才暴露；产品运行时只有一个 manager，不受影响。
// 跳过的是预防性名称检查，不影响 controller 的实际行为与 watch 关系。
func newEnvtestManager(t *testing.T, cfg *rest.Config, scheme *runtime.Scheme) ctrl.Manager {
	t.Helper()
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
		LeaderElection:         false,
		Controller:             config.Controller{SkipNameValidation: ptr.To(true)},
	})
	if err != nil {
		t.Fatalf("manager 创建失败: %v", err)
	}
	return mgr
}

// newDirectClient 创建**不经缓存**的 client（直连 apiserver）。
//
// 用途：测试里写 status 必须用它，而不是 mgr.GetClient()——
// 后者的读走 informer 缓存，刚 Create 的对象在缓存同步前 Get 会返回 not found。
func newDirectClient(t *testing.T, cfg *rest.Config, scheme *runtime.Scheme) client.Client {
	t.Helper()
	c, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		t.Fatalf("创建直连 client 失败: %v", err)
	}
	return c
}

// updateStatusRetry 重取最新对象后写回 status，避免与控制器 reconcile 撞车。
//
// 控制器（DiskReconciler / CapacityReconciler）也在写同一对象的 status，测试直接
// Update 会得到 `the object has been modified; please apply your changes to the latest
// version`。单独跑通常侥幸通过，组合跑多个 envtest 时（缓存已热）必现。
// mutate 接收**重新读取后的对象**，只应改动本用例关心的字段。
func updateStatusRetry(t *testing.T, ctx context.Context, direct client.Client, obj client.Object, mutate func(client.Object)) {
	t.Helper()
	key := client.ObjectKeyFromObject(obj)
	if err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := obj.DeepCopyObject().(client.Object)
		if err := direct.Get(ctx, key, latest); err != nil {
			return err
		}
		mutate(latest)
		return direct.Status().Update(ctx, latest)
	}); err != nil {
		t.Fatalf("%T %s status 写回失败: %v", obj, key.Name, err)
	}
}
