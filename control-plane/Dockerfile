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
# 说明：本机（Windows 开发环境）无 Docker daemon，无法在此执行 docker build；
# 镜像实际构建/推送由 CI 或具备 Docker 的主机完成。本地已用
# `go build ./cmd/<CMD_NAME>` 验证两个二进制均可编译（见 Makefile build / build-webhook）。

ARG GO_VERSION=1.24
FROM golang:${GO_VERSION}-bookworm AS builder
WORKDIR /workspace

# 单独拷贝 go.mod/go.sum 以复用依赖层缓存
COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG CMD_NAME=storage-controller
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/${CMD_NAME}

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
