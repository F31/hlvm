#!/usr/bin/env bash
#
# M15 集成测试的 WSL 入口脚本。
#
# 为什么需要它：
#   1. 仓库位于 Windows 盘（/mnt/e），9p 文件系统上跑 docker build context 与容器内
#      cargo 绑定挂载编译会慢一个量级；本脚本先把工作树同步到 WSL 原生 ext4 再执行。
#   2. Windows 侧经 Git Bash -> wsl.exe 传参时，shell 变量会被中间层吞掉，
#      因此所有逻辑都放在脚本文件里，Windows 侧只传子命令名。
#
# 用法（Windows / Git Bash）：
#   wsl.exe -d Ubuntu24.04LTS -- bash /mnt/e/projects/hlvm/scripts/m15-wsl.sh check
#   wsl.exe -d Ubuntu24.04LTS -- bash /mnt/e/projects/hlvm/scripts/m15-wsl.sh all
#
# 环境变量：
#   HLVM_WSL_SRC=/mnt/e/projects/hlvm   源工作树（默认）
#   HLVM_WSL_DST=$HOME/hlvm             WSL 内构建目录（默认）
#   HLVM_WSL_NO_SYNC=1                  跳过同步，直接跑已有副本（调试用）
#
# 注意：本脚本只做「同步 + 转发」，不改变 m15-integration.sh 的语义与断言。

set -euo pipefail

SRC="${HLVM_WSL_SRC:-/mnt/e/projects/hlvm}"
DST="${HLVM_WSL_DST:-${HOME}/hlvm}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# 必须在 WSL 内运行：否则 /mnt/e 路径与 docker daemon 语义都不成立。
if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  die "未检测到 WSL 内核；本脚本应在 WSL 内执行"
fi

[ -d "${SRC}" ] || die "源目录不存在: ${SRC}"
[ -f "${SRC}/scripts/m15-integration.sh" ] || die "未找到 ${SRC}/scripts/m15-integration.sh"

if [ "${HLVM_WSL_NO_SYNC:-0}" != "1" ]; then
  log "同步工作树到 WSL ext4：${SRC} -> ${DST}"
  command -v rsync >/dev/null 2>&1 || die "缺少 rsync（apt-get install -y rsync）"
  mkdir -p "${DST}"
  # 排除项说明：
  #   .git        容器构建不需要，且体积最大
  #   .gocache/.gotmp  Windows 侧 Go 构建缓存
  #   target       Rust 构建产物；agent 用 docker 卷 hlvm-cargo-target 做缓存
  #   hlvm-agent   上次导出的二进制，由 ensure_agent_binary 重新生成
  # 被 exclude 的既有文件默认不参与 --delete，所以 DST 里的构建缓存不受影响。
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.gocache' \
    --exclude '.gotmp' \
    --exclude '.workbuddy' \
    --exclude 'target' \
    --exclude 'node_modules' \
    --exclude 'hlvm-agent' \
    "${SRC}/" "${DST}/"
  info "同步完成（$(du -sh "${DST}" | cut -f1)）"
fi

[ -d "${DST}/scripts" ] || die "目标目录不完整: ${DST}"

# 构建期代理修正（WSL 特有）：
#   WSL 会自动把 Windows 的代理注入为 HTTP_PROXY=http://127.0.0.1:7890。该地址在 WSL host
#   内可用（实测 200），但 docker build 的 RUN 与 rust:slim 容器内的 127.0.0.1 是**容器自身**，
#   不是宿主回环。实测容器内直连外网会超时（wget: download timed out），只有经 docker0 网关
#   上的转发器（scripts/wsl-proxy-fwd.py，监听 0.0.0.0:17890）才可达。
#   若不修正，只要 go.mod / Cargo.toml 有变更导致缓存失效，构建就会以「网络错误」失败。
#   仅当探测成功时才覆盖，避免在未启动转发器的机器上把可用配置改坏。
CONTAINER_PROXY="${HLVM_CONTAINER_PROXY:-http://172.17.0.1:17890}"
if [ -z "${HLVM_KEEP_PROXY:-}" ] && command -v curl >/dev/null 2>&1 \
   && curl -fsS -o /dev/null -m 5 -x "${CONTAINER_PROXY}" https://proxy.golang.org/ 2>/dev/null; then
  export HTTP_PROXY="${CONTAINER_PROXY}"
  export HTTPS_PROXY="${CONTAINER_PROXY}"
  export AGENT_BUILD_PROXY="${AGENT_BUILD_PROXY:-${CONTAINER_PROXY}}"
  info "容器内构建代理: ${CONTAINER_PROXY}（来自 WSL 代理转发器）"
else
  info "容器内构建代理: 未修正（转发器不可达或已显式关闭），沿用当前 HTTP_PROXY=${HTTP_PROXY:-<空>}"
fi

log "在 WSL 内执行 M15：$*"
cd "${DST}"
exec bash scripts/m15-integration.sh "$@"
