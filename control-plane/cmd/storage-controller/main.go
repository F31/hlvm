// Command storage-controller 是 hlvm 自研控制面入口。
//
// 部署形态（设计 §2/§7）：Deployment ×2 + leader election。本二进制只承载控制面控制器，
// webhook 为独立 Deployment（见 add-admission-scheduling change）。
package main

import (
	"flag"
	"os"
	"runtime"

	kruntime "k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	"github.com/F31/hlvm/control-plane/internal/controller"
)

var scheme = kruntime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(storagev1alpha1.AddToScheme(scheme))
}

func main() {
	var metricsAddr, probeAddr string
	var enableLeaderElection bool
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "Metrics 监听地址")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "健康检查监听地址")
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
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
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
