package main

import (
	"flag"
	"os"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/webhook"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	hlvmwebhook "github.com/F31/hlvm/control-plane/internal/webhook"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(storagev1alpha1.AddToScheme(scheme))
}

func main() {
	var metricsAddr, probeAddr, certDir string
	var webhookPort int
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "Metrics 监听地址")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "探针监听地址")
	flag.StringVar(&certDir, "cert-dir", "/tmp/k8s-webhook-server/serving-certs", "Webhook 证书目录")
	flag.IntVar(&webhookPort, "webhook-port", 9443, "Webhook 监听端口")
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	logger := ctrl.Log.WithName("setup")

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:  scheme,
		Metrics: metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		WebhookServer: webhook.NewServer(webhook.Options{
			Port:    webhookPort,
			CertDir: certDir,
		}),
	})
	if err != nil {
		logger.Error(err, "无法创建 manager")
		os.Exit(1)
	}

	// 第 1 层：tier 级 PVC 准入（CREATE + 扩容 UPDATE）。不含任何业务计算，仅读 NodeVG status。
	if err := ctrl.NewWebhookManagedBy(mgr).
		For(&corev1.PersistentVolumeClaim{}).
		WithValidator(&hlvmwebhook.PVCValidator{Reader: mgr.GetClient(), Recorder: mgr.GetEventRecorderFor("storage-webhook")}).
		WithCustomPath("/validate-hlvm-pvc").
		Complete(); err != nil {
		logger.Error(err, "无法注册 PVCValidator")
		os.Exit(1)
	}

	// 第 2 层：节点级调度约束注入（Pod 变更，排除 locked 节点）。
	if err := ctrl.NewWebhookManagedBy(mgr).
		For(&corev1.Pod{}).
		WithDefaulter(&hlvmwebhook.PodMutator{Reader: mgr.GetClient()}).
		WithCustomPath("/mutate-hlvm-pod").
		Complete(); err != nil {
		logger.Error(err, "无法注册 PodMutator")
		os.Exit(1)
	}

	// 第 3 层（删除保护，Fail 类）：StorageNodeOps / NodeVG 删除时校验 retire 在用 PV。
	if err := ctrl.NewWebhookManagedBy(mgr).
		For(&storagev1alpha1.StorageNodeOps{}).
		WithValidator(&hlvmwebhook.DeleteProtector{Reader: mgr.GetClient()}).
		WithCustomPath("/validate-hlvm-storagenodeops").
		Complete(); err != nil {
		logger.Error(err, "无法注册 StorageNodeOps DeleteProtector")
		os.Exit(1)
	}
	if err := ctrl.NewWebhookManagedBy(mgr).
		For(&storagev1alpha1.NodeVG{}).
		WithValidator(&hlvmwebhook.DeleteProtector{Reader: mgr.GetClient()}).
		WithCustomPath("/validate-hlvm-nodevg").
		Complete(); err != nil {
		logger.Error(err, "无法注册 NodeVG DeleteProtector")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		logger.Error(err, "无法添加 healthz")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		logger.Error(err, "无法添加 readyz")
		os.Exit(1)
	}

	logger.Info("启动 storage-webhook", "port", webhookPort)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		logger.Error(err, "manager 退出异常")
		os.Exit(1)
	}
}
