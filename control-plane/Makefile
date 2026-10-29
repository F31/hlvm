# hlvm control-plane Makefile
#
# 说明：本环境 controller-gen 在缓存异常下 CRD 生成不稳定，CRD YAML 当前为手写（config/crd/bases）。
# 当工具链稳定后可用 `make manifests` 重新生成；deepcopy 已生成（zz_generated.deepcopy.go）。

GO ?= go
CONTROLLER_GEN ?= $(shell $(GO) env GOPATH)/bin/controller-gen
SETUP_ENVTEST ?= $(shell $(GO) env GOPATH)/bin/setup-envtest
ENVTEST_K8S_VERSION ?= 1.36.2

.PHONY: build build-webhook test vet generate manifests tidy clean test-envtest docker-build docker-push

build:
	$(GO) build -o bin/storage-controller ./cmd/storage-controller

# 构建 webhook 独立二进制（admission 4.3 动态层部署依赖；见 config/webhook/deployment.yaml）。
build-webhook:
	$(GO) build -o bin/storage-webhook ./cmd/storage-webhook

# 镜像构建（M15 门槛 1.4：control-plane 需可构建镜像以部署 webhook）。
# 参数化复用同一 Dockerfile，按 CMD_NAME 选择二进制；本机无 Docker daemon，由 CI/有 Docker 的主机执行。
IMG_REGISTRY ?= ghcr.io/f31/hlvm
IMG_TAG ?= latest

docker-build:
	docker build -f Dockerfile --build-arg CMD_NAME=storage-controller -t $(IMG_REGISTRY)/storage-controller:$(IMG_TAG) .
	docker build -f Dockerfile --build-arg CMD_NAME=storage-webhook -t $(IMG_REGISTRY)/storage-webhook:$(IMG_TAG) .

docker-push:
	docker push $(IMG_REGISTRY)/storage-controller:$(IMG_TAG)
	docker push $(IMG_REGISTRY)/storage-webhook:$(IMG_TAG)

test:
	$(GO) test ./...

# test-envtest：运行依赖真实控制平面的 e2e（envtest）。
# 覆盖 add-crd-controller-skeleton V.2 与 add-capacity-governance 4.2（同一包内各用例自建独立 envtest 环境，串行执行）。
# 需先 `go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest`（下载 kube-apiserver/etcd 二进制）。
test-envtest:
	KUBEBUILDER_ASSETS="$$($(SETUP_ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" $(GO) test ./internal/controller/ -run Envtest -v -timeout 600s

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
