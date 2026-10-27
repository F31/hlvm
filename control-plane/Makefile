# hlvm control-plane Makefile
#
# 说明：本环境 controller-gen 在缓存异常下 CRD 生成不稳定，CRD YAML 当前为手写（config/crd/bases）。
# 当工具链稳定后可用 `make manifests` 重新生成；deepcopy 已生成（zz_generated.deepcopy.go）。

GO ?= go
CONTROLLER_GEN ?= $(shell $(GO) env GOPATH)/bin/controller-gen

.PHONY: build test vet generate manifests tidy clean

build:
	$(GO) build -o bin/storage-controller ./cmd/storage-controller

test:
	$(GO) test ./...

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
