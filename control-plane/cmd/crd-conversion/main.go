// crd-conversion 是 CRD 多版本转换的服务入口（openspec add-hardening-rollout 3.1b）。
//
// 它只做一件事：处理 apiserver 发来的 ConversionReview，在
// storage.example.io/v1alpha1 与 v1beta1 之间按字段映射转换。
//
// 设计取舍：
//   - **不用 manager**：这个服务不 watch 集群、不需要 client，起一个 HTTPS
//     处理器 + 健康端点是它能做的最小形状；用 manager 会额外拉起 cache/leader
//     election，故障面反而更大（转换挂了会让整组 CRD 读写不可用）。
//   - **证书热加载**：证书由 cert-manager 轮换（secret 更新 → kubelet 更新挂载文件），
//     进程必须在不重启的情况下换证书，故用 certwatcher 监听文件变化。
//   - **启动即自检**：注册完 scheme 后立刻校验 NodeDisk 确实可转换（hub/spoke 齐全），
//     不可转换就直接退出——否则会部署出一个"看起来 Ready、实际转换全失败"的 webhook，
//     而它的故障表现是集群级 CRD 不可用。
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/certwatcher"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/webhook/conversion"

	storagev1alpha1 "github.com/F31/hlvm/control-plane/api/v1alpha1"
	storagev1beta1 "github.com/F31/hlvm/control-plane/api/v1beta1"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(storagev1alpha1.AddToScheme(scheme))
	utilruntime.Must(storagev1beta1.AddToScheme(scheme))
}

func main() {
	var (
		port       int
		healthAddr string
		certDir    string
		certName   string
		keyName    string
	)
	flag.IntVar(&port, "port", 9444, "HTTPS 转换服务监听端口")
	flag.StringVar(&healthAddr, "health-addr", ":9445", "健康探针监听地址（明文 HTTP，仅 /healthz 与 /readyz）")
	flag.StringVar(&certDir, "cert-dir", "/tmp/serving-certs", "TLS 证书目录（cert-manager 挂载的 secret）")
	flag.StringVar(&certName, "cert-name", "tls.crt", "证书文件名")
	flag.StringVar(&keyName, "key-name", "tls.key", "私钥文件名")
	opts := zap.Options{Development: false}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	logger := ctrl.Log.WithName("crd-conversion")

	// 启动自检：hub/spoke 必须齐全，否则宁可不启动。
	if ok, err := conversion.IsConvertible(scheme, &storagev1alpha1.NodeDisk{}); err != nil || !ok {
		logger.Error(err, "NodeDisk 不可转换（缺少 hub 或 ConvertTo/ConvertFrom），拒绝启动")
		os.Exit(1)
	}

	certPath := filepath.Join(certDir, certName)
	keyPath := filepath.Join(certDir, keyName)
	watcher, err := certwatcher.New(certPath, keyPath)
	if err != nil {
		logger.Error(err, "无法加载 TLS 证书", "cert", certPath, "key", keyPath)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		if err := watcher.Start(ctx); err != nil && !errors.Is(err, context.Canceled) {
			logger.Error(err, "证书监听退出（证书轮换将不再自动生效）")
		}
	}()

	mux := http.NewServeMux()
	// apiserver 只会打 /convert（与 CRD 的 clientConfig.service.path 对齐）。
	mux.Handle("/convert", conversion.NewWebhookHandler(scheme))

	srv := &http.Server{
		Addr:    fmt.Sprintf(":%d", port),
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion:     tls.VersionTLS12,
			GetCertificate: watcher.GetCertificate,
		},
		ReadHeaderTimeout: 10 * time.Second,
	}

	// 健康端点是明文的：探针不需要证书，也就不受证书轮换/过期影响。
	healthMux := http.NewServeMux()
	healthMux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	healthMux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	healthSrv := &http.Server{
		Addr:              healthAddr,
		Handler:           healthMux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 2)
	go func() {
		logger.Info("启动 CRD 转换服务", "port", port, "cert", certPath)
		ln, err := net.Listen("tcp", srv.Addr)
		if err != nil {
			errCh <- fmt.Errorf("监听 %s 失败: %w", srv.Addr, err)
			return
		}
		errCh <- srv.Serve(tls.NewListener(ln, srv.TLSConfig))
	}()
	go func() {
		logger.Info("启动健康探针", "addr", healthAddr)
		errCh <- healthSrv.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		logger.Info("收到退出信号，开始优雅关闭")
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error(err, "服务异常退出")
			os.Exit(1)
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	_ = healthSrv.Shutdown(shutdownCtx)
	logger.Info("已退出")
}
