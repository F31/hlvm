#!/usr/bin/env bash
#
# 集群就绪后的收尾（在能跑 kubectl、且能 ssh 到所有节点的机器上执行）。
#
# 做三件事：
#   ① 建 hlvm-system 并写入 GHCR 拉取凭据（私有包必须，否则 controller/webhook/agent
#      全部 ImagePullBackOff，而现象很像「镜像不存在」）；
#   ② 把凭据挂到 namespace 的 default ServiceAccount，避免每个清单都要写 imagePullSecrets；
#   ③ 逐节点跑 disk-precheck.sh，把「能不能当裸盘用」这件事在部署前就定下来。
#
# 幂等：secret 用 --dry-run | apply 覆盖，SA patch 可重复执行。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-hlvm-system}"
SECRET_NAME="${SECRET_NAME:-ghcr-pull}"
IMG_REGISTRY="${IMG_REGISTRY:-ghcr.io/f31/hlvm}"
GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
M15_SSH_USER="${M15_SSH_USER:-root}"
M15_SSH_PORT="${M15_SSH_PORT:-22}"
M15_SSH_KEY="${M15_SSH_KEY:-}"
NODE_FILTER="${NODE_FILTER:-}"   # 例如 "worker"（按名字子串过滤，留空=全部）

die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null || die "缺少 kubectl"
kubectl get --raw /readyz >/dev/null 2>&1 || die "kubectl 连不上集群（检查 KUBECONFIG）"

step "1/3 命名空间与拉取凭据"
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
[ -n "${GHCR_USER}" ] && [ -n "${GHCR_TOKEN}" ] \
  || die "需要 GHCR_USER / GHCR_TOKEN（${IMG_REGISTRY} 是私有包，缺凭据必然 ImagePullBackOff）"

# 用 --dry-run=client -o yaml | apply：避免把 token 写进 shell history 之外的任何文件。
kubectl -n "${NAMESPACE}" create secret docker-registry "${SECRET_NAME}" \
  --docker-server="ghcr.io" \
  --docker-username="${GHCR_USER}" \
  --docker-password="${GHCR_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "已写入 ${NAMESPACE}/${SECRET_NAME}"

step "2/3 挂到 default ServiceAccount"
kubectl -n "${NAMESPACE}" patch serviceaccount default \
  -p "{\"imagePullSecrets\":[{\"name\":\"${SECRET_NAME}\"}]}" >/dev/null
echo "已为 ${NAMESPACE}/default 注入 imagePullSecrets"

step "3/3 逐节点数据盘预检（只读）"
NODES="$(kubectl get nodes --no-headers -o custom-columns=:metadata.name | grep -F "${NODE_FILTER}" || true)"
[ -n "${NODES}" ] || die "没有匹配的节点（NODE_FILTER='${NODE_FILTER}'）"

ssh_base() {
  local target="$1"; shift
  local opts=(-p "${M15_SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
  [ -n "${M15_SSH_KEY}" ] && opts+=(-i "${M15_SSH_KEY}")
  ssh "${opts[@]}" "${M15_SSH_USER}@${target}" "$@"
}

rc=0
for n in ${NODES}; do
  ip="$(kubectl get node "${n}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')"
  if [ -z "${ip}" ]; then
    echo "[warn] 节点 ${n} 无 InternalIP，跳过"
    continue
  fi
  echo
  echo "########## ${n} (${ip}) ##########"
  if ssh_base "${ip}" 'bash -s' < "${HERE}/disk-precheck.sh"; then
    :
  else
    echo "[warn] ${n} 预检有告警（见上）"
    rc=1
  fi
done

echo
if [ "${rc}" -ne 0 ]; then
  echo "预检有告警：按上面每条的提示处理后再跑 M15（告警不等于失败，但要能解释）。"
else
  echo "全部节点预检通过。下一步："
  echo "  M15_TARGET=real KCTX=\$(kubectl config current-context) ./m15-integration.sh check"
fi
