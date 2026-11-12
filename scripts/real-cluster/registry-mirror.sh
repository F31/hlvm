#!/usr/bin/env bash
#
# 真机镜像源与镜像预拉（ADR-006 §22）。
#
# 解决的问题（2026-11-12 真机 m15 all 实测）：
#   云主机到 ghcr.io 的**直连带宽只有 ~23KB/s**（14MB 的 controller 镜像拉了 10 分 19 秒，
#   376MB 的 agent 镜像要 4.5 小时）。于是：
#     - verify-agent 的 180s 就绪判据必然超时（首跑就是这么红的）；
#     - 已经预拉好的镜像，kubelet 仍会卡在 Pulling —— 不是缺 layer，而是**前面那次慢速
#       pull 还占着队列**（强删 Pod 不会取消 containerd 内部的 fetch）。
#   解法两步：① 让 containerd 走镜像源（hosts.d 里给 ghcr.io 配 mirror），
#   ② 预拉镜像并**重启 containerd** 清掉卡住的 fetch（否则新 Pod 继续排在旧 pull 后面）。
#   实测：预拉 376MB 用时 15.3s，配完 mirror 后 kubelet 拉取 1.7s。
#
# 为什么要落到仓库里：这是**环境事实**而不是一次性操作。没写进仓库的话，换一台云主机
# （或镜像 tag 一升级）就会重演 4.5 小时的等待，而且失败形态是「判据超时」，很容易被
# 误判成「agent 有问题」。
#
# 判据纪律：
#   - 只读检查（mirror 配置 / 镜像是否在本地）不写盘；写操作（写 hosts.toml、重启
#     containerd、预拉镜像）都要显式 CONFIRM_WRITE=1；
#   - 能力缺失（无 ssh / 节点不可达 / 无 ctr）一律 SKIP 并写明未覆盖，绝不计 PASS；
#   - 重启 containerd 会让该节点上所有容器重建（静态 Pod 也一样），因此**默认只预拉**，
#     RESTART_CONTAINERD=1 才重启 —— 重启前必须先确认该节点不是唯一的控制面节点。
#
# 用法（WSL 内、仓库根）：
#   bash scripts/real-cluster/registry-mirror.sh --check
#   CONFIRM_WRITE=1 bash scripts/real-cluster/registry-mirror.sh
#   CONFIRM_WRITE=1 RESTART_CONTAINERD=1 bash scripts/real-cluster/registry-mirror.sh
#   MIRROR=https://ghcr.nju.edu.cn IMAGES=ghcr.io/f31/hlvm/storage-agent:v0.1.0-preview.5 ...
set -uo pipefail

MIRROR="${MIRROR:-https://ghcr.nju.edu.cn}"
IMAGES_RAW="${IMAGES:-}"
# set -u 下空数组的 "${arr[@]}" 会报未绑定（bash < 4.4），统一走 "+展开" 形式。
IMAGES=()
read -r -a IMAGES <<< "${IMAGES_RAW}" || true
CONFIRM_WRITE="${CONFIRM_WRITE:-0}"
RESTART_CONTAINERD="${RESTART_CONTAINERD:-0}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/hlvm-real.conf}"
SSH_KEY="${SSH_KEY:-/home/jinfeng105/.ssh/hlvm-real}"
CERT_DIR="${CERT_DIR:-/etc/containerd/certs.d}"
HOSTS_TOML_DIR="${CERT_DIR}/ghcr.io"

pass=0 fail=0 skip=0
ok()   { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
skip() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; skip=$((skip+1)); }

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

command -v kubectl >/dev/null 2>&1 || { echo "[error] 缺少 kubectl" >&2; exit 1; }
[[ -f "${KUBECONFIG}" ]] || { echo "[error] kubeconfig 不存在：${KUBECONFIG}" >&2; exit 1; }
if [[ -n "${SSH_KEY}" && ! -f "${SSH_KEY}" ]]; then
  echo "[error] SSH key 不存在：${SSH_KEY}" >&2; exit 1
fi

# 节点清单：优先从集群取 InternalIP（真机 kubeconfig 里的 context 名不固定，按当前 context 取）。
mapfile -t NODE_IPS < <(
  kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk 'NF>=2 {print $1" "$2}'
)
if [[ "${#NODE_IPS[@]}" -eq 0 ]]; then
  echo "[error] 没取到任何节点的 InternalIP" >&2; exit 1
fi
info "目标节点 ${#NODE_IPS[@]} 个"

# 远端脚本用 base64 传输，避开多层 SSH 的引号地狱。
REMOTE="$(cat <<'EOS'
set -u
MIRROR="$1"; CONFIRM_WRITE="$2"; RESTART_CONTAINERD="$3"; CERT_DIR="$4"
shift 4
IMAGES=("$@")

echo "--- mirror 配置"
if [ -f "${CERT_DIR}/ghcr.io/hosts.toml" ]; then
  echo "MIRROR_PRESENT=1"
  cat "${CERT_DIR}/ghcr.io/hosts.toml"
else
  echo "MIRROR_PRESENT=0"
fi
echo "--- 镜像缓存"
for img in "${IMAGES[@]}"; do
  [ -n "$img" ] || continue
  if ctr -n k8s.io images ls 2>/dev/null | grep -q "^${img}[[:space:]]"; then
    echo "IMG_PRESENT=1 ${img}"
  else
    echo "IMG_PRESENT=0 ${img}"
  fi
done
echo "--- 卡住的 fetch（占队列的慢速 pull）"
ctr -n k8s.io content active 2>/dev/null | tail -n +2 | head -5 || true

if [ "$CONFIRM_WRITE" != "1" ]; then
  echo "WRITE_SKIPPED=1"
  exit 0
fi

mkdir -p "${CERT_DIR}/ghcr.io"
cat > "${CERT_DIR}/ghcr.io/hosts.toml" <<EOF
server = "https://ghcr.io"
[host."${MIRROR}"]
  capabilities = ["pull", "resolve"]
EOF
echo "MIRROR_WRITTEN=1 ${CERT_DIR}/ghcr.io/hosts.toml"

for img in "${IMAGES[@]}"; do
  [ -n "$img" ] || continue
  echo "PULL ${img}"
  ctr -n k8s.io images pull --hosts-dir "${CERT_DIR}/ghcr.io" "$img" 2>&1 | tail -2
done

if [ "$RESTART_CONTAINERD" = "1" ]; then
  echo "RESTART_CONTAINERD=1"
  systemctl restart containerd
  sleep 12
  systemctl is-active containerd || echo "CONTAINERD_NOT_ACTIVE=1"
else
  echo "RESTART_CONTAINERD=0"
fi
EOS
)"
REMOTE_B64="$(printf '%s' "${REMOTE}" | base64 -w0 || true)"
[[ -n "${REMOTE_B64}" ]] || { echo "[error] base64 编码失败" >&2; exit 1; }

for entry in "${NODE_IPS[@]}"; do
  ip="${entry%% *}"; name="${entry##* }"
  echo
  echo "=== 节点 ${name} (${ip})"
  out=""
  if [[ -f "${SSH_KEY}" ]]; then
    args=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=15 "root@${ip}")
    if [[ "${#IMAGES[@]}" -gt 0 ]]; then
      out="$(ssh "${args[@]}" "echo ${REMOTE_B64} | base64 -d | bash -s -- '${MIRROR}' '${CONFIRM_WRITE}' '${RESTART_CONTAINERD}' '${CERT_DIR}' ${IMAGES[*]+${IMAGES[*]}}" 2>&1 || true)"
    else
      out="$(ssh "${args[@]}" "echo ${REMOTE_B64} | base64 -d | bash -s -- '${MIRROR}' '${CONFIRM_WRITE}' '${RESTART_CONTAINERD}' '${CERT_DIR}'" 2>&1 || true)"
    fi
  else
    skip "节点 ${name}：无 SSH key，只做集群侧观察"
    continue
  fi
  printf '%s\n' "${out}" | sed 's/^/    /'

  if printf '%s' "${out}" | grep -q "MIRROR_PRESENT=1"; then
    ok "节点 ${name} 已配置 ghcr.io 镜像源"
  elif [[ "${CHECK_ONLY}" = "1" ]]; then
    bad "节点 ${name} 未配置 ghcr.io 镜像源（kubelet 拉取会退化成直连 ~23KB/s）"
  else
    warn "节点 ${name} 未配置镜像源（写操作被拒或失败）"
  fi
  if [[ "${#IMAGES[@]}" -gt 0 ]]; then
    missing="$(printf '%s' "${out}" | grep -c 'IMG_PRESENT=0' || true)"
    if [[ "${missing}" = "0" ]]; then
      ok "节点 ${name} 目标镜像已缓存"
    else
      bad "节点 ${name} 有 ${missing} 个镜像未缓存（kubelet 会去直连拉，慢）"
    fi
  fi
  if printf '%s' "${out}" | grep -q "MIRROR_WRITTEN=1"; then
    ok "节点 ${name} 已写入镜像源配置"
  fi
  if printf '%s' "${out}" | grep -q "CONTAINERD_NOT_ACTIVE=1"; then
    bad "节点 ${name} 重启 containerd 后未处于 active"
  fi
done

echo
echo "SUMMARY PASS=${pass} FAIL=${fail} SKIP=${skip}"
[[ "${fail}" -gt 0 ]] && exit 1
exit 0
