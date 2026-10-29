# syntax=docker/dockerfile:1
#
# hlvm control-plane 多阶段镜像构建。
# 通过 build-arg CMD_NAME 选择要构建的子命令二进制（默认 storage-controller）：
#   storage-controller -> config/manager/manager.yaml 引用的镜像
#   storage-webhook    -> config/webhook/deployment.yaml 引用的镜像（admission 4.3 动态层依赖）
#
# 用法（在 control-plane/ 目录）：
#   docker build -f Dockerfile --build-arg CMD_NAME=storage-webhook \
#     -t ghcr.io/f31/hlvm/storage-webhook:latest .
#
# 说明：镜像构建在具备 Docker daemon 的环境执行（CI 的 images job，或经 WSL 的本地环境）；
# 本机经 WSL 已实测可完整构建并 kind load，见 docs/m15-integration-runbook.md §7.1。
# 无 Docker 时仍可用 `go build ./cmd/<CMD_NAME>` 验证两个二进制均可编译（Makefile build / build-webhook）。

ARG GO_VERSION=1.24
# 运行态基础镜像可覆盖：默认 distroless（生产）。离线/无法拉取 distroless 时，
# 可用 --build-arg RUNTIME_IMAGE=<已缓存镜像> 覆盖（仅用于本地 kind 验证，不建议生产使用）。
ARG RUNTIME_IMAGE=gcr.io/distroless/static:nonroot
FROM golang:${GO_VERSION}-bookworm AS builder
WORKDIR /workspace

# 单独拷贝 go.mod/go.sum 以复用依赖层缓存；缓存挂载使模块下载在多次构建/重试间复用
# （已下载模块不会重复传输）。
COPY go.mod go.sum ./
#
# 重试：代理在并发下载时会截断连接（`unexpected EOF`），单次失败不代表依赖不可用。
# 有限重试 5 次后仍然失败则构建失败——只吸收瞬时网络抖动，不掩盖真实问题。
RUN --mount=type=cache,target=/go/pkg/mod \
    for i in 1 2 3 4 5; do \
        if go mod download; then exit 0; fi; \
        echo "go mod download 失败（第 ${i}/5 次），2s 后重试"; \
        sleep 2; \
    done; \
    echo "go mod download 连续失败 5 次，放弃"; exit 1

COPY . .

ARG CMD_NAME=storage-controller
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${CMD_NAME}

FROM ${RUNTIME_IMAGE}
WORKDIR /
COPY --from=builder /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
