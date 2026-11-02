// Package version 承载构建期注入的版本信息。
//
// 为什么需要它：发布前所有二进制里没有任何可追溯的版本串，现场报问题时
// 无法判断跑的是哪个构建（`latest` 镜像尤其）。这里用 -X 注入三个变量，
// 未注入时保持 dev 默认值，使 `go run` / `go test` 无需额外参数即可工作。
//
// 注入方式（Makefile / Dockerfile / CI 均为同一组 ldflags）：
//
//	go build -ldflags "-X github.com/F31/hlvm/control-plane/internal/version.Version=v0.1.0 \
//	  -X github.com/F31/hlvm/control-plane/internal/version.Commit=$(git rev-parse --short HEAD) \
//	  -X github.com/F31/hlvm/control-plane/internal/version.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
package version

import "fmt"

// 这三个变量只由链接器写入，代码里不要赋值（否则会被 -X 覆盖语义搞混）。
var (
	// Version 是语义版本串，与仓库根 VERSION 文件一致（发布时由 CI 从 git tag 注入）。
	Version = "dev"
	// Commit 是构建所用提交的短 SHA。
	Commit = "unknown"
	// BuildDate 是构建时间的 UTC RFC3339 时间戳。
	BuildDate = "unknown"
)

// String 返回单行版本摘要，供启动日志与 --version 输出。
func String() string {
	return fmt.Sprintf("%s (commit %s, built %s)", Version, Commit, BuildDate)
}
