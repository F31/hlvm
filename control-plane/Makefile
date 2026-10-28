# hlvm control-plane Makefile
#
# 说明：本环境 controller-gen 在缓存异常下 CRD 生成不稳定，CRD YAML 当前为手写（config/crd/bases）。
# 当工具链稳定后可用 `make manifests` 重新生成；deepcopy 已生成（zz_generated.deepcopy.go）。

GO ?= go
CONTROLLER_GEN ?= $(shell $(GO) env GOPATH)/bin/controller-gen
SETUP_ENVTEST ?= $(shell $(GO) env GOPATH)/bin/setup-envtest
ENVTEST_K8S_VERSION ?= 1.33.0

.PHONY: build test vet generate manifests tidy clean test-envtest

build:
	$(GO) build -o bin/storage-controller ./cmd/storage-controller

test:
	$(GO) test ./...

# test-envtest：运行依赖真实控制平面的 e2e（envtest，对应 add-crd-controller-skeleton V.2）。
# 需先 `go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest`（下载 kube-apiserver/etcd 二进制）。
test-envtest:
	KUBEBUILDER_ASSETS="$$($(SETUP_ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" $(GO) test ./internal/controller/ -run TestEnvtestE2E -v -timeout 360s

vet:
	$(GO) vet ./...

tidy:
	$(GO) mod tidy

# 重新生成 deepcopy（CRD 当前手写，见上说明）。
generate:
	$(CONTROLLER_GEN) object:headerFile=hack/boilerplate.go.txt paths=./api/v1alpha1

manifests:
	$(CONTROLLER_GEN) crd paths=./api/v1alpha1 output:crd:dir=config/crd/bases

clean:
	rm -rf bin
