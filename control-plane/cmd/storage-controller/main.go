// Command storage-controller 是 hlvm 自研控制面入口。
//
// 部署形态（设计 §2/§7）：Deployment ×2 + leader election。本二进制只承载控制面控制器，
// webhook 为独立 Deployment（见 add-admission-scheduling change）。
package main

import (
	"flag"
	"os"
	"runtime"

	corev1 "k8s.io/api/core/v1"
	kruntime "k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
	"github.com/F31/hlvm/control-plane/internal/controller"
	"github.com/F31/hlvm/control-plane/internal/dashboard"
)

var scheme = kruntime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(storagev1alpha1.AddToScheme(scheme))
	utilruntime.Must(storagev1beta1.AddToScheme(scheme))
}

func main() {
	var metricsAddr, probeAddr, dashboardAddr string
	var enableLeaderElection bool
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "Metrics 监听地址")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "健康检查监听地址")
	flag.StringVar(&dashboardAddr, "dashboard-bind-address", ":8082", "只读大盘与纳管入口 HTTP 监听地址（add-observability 3.2/3.3）")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false, "启用 leader election（Deployment ×2 部署时置 true）")
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	logger := ctrl.Log.WithName("hlvm")

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "hlvm-storage-controller",
		// collector Pod 只在 hlvm-system 内创建，RBAC 也只授予该命名空间的 pod 权限。
		// 默认缓存是全集群 informer，会因 list/watch 全集群 pod 被 403 拒绝；这里按对象
		// 收敛缓存范围，避免为了跑通而把 pods 权限提升成 ClusterRole。
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				&corev1.Pod{}: {Namespaces: map[string]cache.Config{
					controller.ManagedNamespace: {},
				}},
			},
		},
	})
	if err != nil {
		logger.Error(err, "无法创建 manager")
		os.Exit(1)
	}

	if err = (&controller.DiskReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 DiskReconciler")
		os.Exit(1)
	}

	// 每盘一个 collector Pod（add-disk-device-plugin 6.1）：SMART 采集从「非特权 DaemonSet
	// 读不了块设备」改为「按盘申请 + 只采该盘」。镜像可经 HLVM_AGENT_IMAGE 覆盖（与 agent 同镜像）。
	if err = (&controller.DiskCollectorReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
		Image:  os.Getenv("HLVM_AGENT_IMAGE"),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 DiskCollectorReconciler")
		os.Exit(1)
	}

	if err = (&controller.VGReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 VGReconciler")
		os.Exit(1)
	}

	if err = (&controller.CapacityReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 CapacityReconciler")
		os.Exit(1)
	}

	if err = (&controller.LvmdConfigReconciler{
		Client:    mgr.GetClient(),
		Scheme:    mgr.GetScheme(),
		Namespace: controller.ManagedNamespace,
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 LvmdConfigReconciler")
		os.Exit(1)
	}

	if err = (&controller.NodeOpsReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 NodeOpsReconciler")
		os.Exit(1)
	}

	if err = (&controller.OrphanGCReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("orphan-gc"),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 OrphanGCReconciler")
		os.Exit(1)
	}

	if err = (&controller.DriftDetectorReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("drift-detector"),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 DriftDetectorReconciler")
		os.Exit(1)
	}

	if err = (&controller.StorageTaskReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("storage-task"),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 StorageTaskReconciler")
		os.Exit(1)
	}

	if err = (&controller.BackupReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("backup"),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 BackupReconciler")
		os.Exit(1)
	}

	if err = (&controller.DrillReconciler{
		Client:            mgr.GetClient(),
		Scheme:            mgr.GetScheme(),
		Recorder:          mgr.GetEventRecorderFor("drill"),
		ManagedNamespace:  controller.ManagedNamespace,
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "无法注册 DrillReconciler")
		os.Exit(1)
	}

	// 只读大盘 + 纳管入口（add-observability 3.2/3.3）：只读查询走直连 APIReader（无缓存同步依赖），
	// adopt 写操作走缓存客户端（GetClient）。adopt 仅生成待审批任务，绝不直接执行破坏性操作。
	if err = mgr.Add(dashboard.NewServer(
		mgr.GetAPIReader(),
		mgr.GetClient(),
		ctrl.Log.WithName("dashboard"),
		dashboardAddr,
	)); err != nil {
		logger.Error(err, "无法注册 dashboard 服务")
		os.Exit(1)
	}

	if err = mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		logger.Error(err, "无法注册 healthz")
		os.Exit(1)
	}
	if err = mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		logger.Error(err, "无法注册 readyz")
		os.Exit(1)
	}

	logger.Info("启动 storage-controller", "go", runtime.Version())
	if err = mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		logger.Error(err, "manager 退出异常")
		os.Exit(1)
	}
}
