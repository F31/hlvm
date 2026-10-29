#!/usr/bin/env bash
#
# hlvm M15 集成引导脚本
#
# 目的：把 M15 递延项里「kind 可自动化覆盖」的部分固化为一键可执行流程，
#       其余依赖真实 LV / Velero / 评审灰度的项明确跳过（见 docs/m15-integration-runbook.md）。
#
# 子命令（默认 check，安全只读）：
#   check             仅前置检查：工具链 / 集群 / 版本 / CRD / cert-manager，不改动集群与 kubeconfig
#   bootstrap         确保集群存在 → 装 cert-manager → CRD/命名空间/RBAC/证书/webhook/manager
#   build             用 control-plane/Dockerfile 构建两镜像并 kind load（需 docker daemon）
#   verify-admission  admission 4.3 可自动化部分：验证锁标签 nodeAffinity 注入链路
#   verify-controller	VG controller 端到端：删盘保护阻塞写 pendingOps、vgcreate 下发、解除后清空
#   all               check → bootstrap → build → verify-admission → verify-controller
#
# 环境变量：
#   CLUSTER_NAME=hlvm-kind  NODE_IMAGE=kindest/node:v1.36.1
#   IMG_REGISTRY=ghcr.io/f31/hlvm  IMG_TAG=latest
#   CERT_MANAGER_VERSION=v1.17.2   LOCK_TIER=data
#   RUNTIME_IMAGE=（空=用 Dockerfile 默认 distroless；离线 kind 可设为已缓存基础镜像）
#   PAUSE_IMAGE=registry.k8s.io/pause:3.10（verify-admission 测试 Pod 使用）
#
# 诚实边界（脚本不会假装覆盖）：
#   - kind 无 LVM 块设备：thinpool 打满、dmeventd autoextend、拔盘、SMART、lvs/vgs 实测对账
#     均无法在此验证，需真实 LV 硬件（见 runbook §B）。
#   - Velero 闭环（backup-restore 5.1）需另行部署 Velero 与对象存储。
#   - 评审 / 灰度 / 上线门禁为流程项，非脚本可自动化。
#   - kind 内无 TopoLVM CSI，PVC 不会绑定；本脚本只验证「mutating webhook 是否注入了
#     storage.example.io/<tier>-locked NotIn [true] 的 nodeAffinity」，不声称验证了真实调度排除。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CP="${REPO_ROOT}/control-plane"

CLUSTER_NAME="${CLUSTER_NAME:-hlvm-kind}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.36.1}"
IMG_REGISTRY="${IMG_REGISTRY:-ghcr.io/f31/hlvm}"
IMG_TAG="${IMG_TAG:-latest}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
LOCK_TIER="${LOCK_TIER:-data}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
KCTX="kind-${CLUSTER_NAME}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# 显式指定 context，避免隐式切换用户当前 kubeconfig 上下文。
kc() { kubectl --context "${KCTX}" "$@"; }

require_tools() {
  local missing=0
  for c in kubectl kind docker helm; do
    if have "$c"; then info "已安装: $c"; else warn "缺少: $c"; missing=1; fi
  done
  [ "$missing" -eq 0 ] || die "工具链不完整；本脚本应在 WSL/Linux 且具备 docker daemon 的环境运行"
}

context_exists() {
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "${KCTX}"
}

server_minor() {
  kc get --raw /version 2>/dev/null \
    | grep -oE '"minor"[[:space:]]*:[[:space:]]*"[0-9]+' \
    | grep -oE '[0-9]+' | head -1 || true
}

phase_check() {
  log "1/5 前置检查（只读：不改动集群，也不切换 kubeconfig 上下文）"
  require_tools

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    info "kind 集群 '${CLUSTER_NAME}': 存在"
    if context_exists; then
      local minor; minor="$(server_minor)"
      info "server minor: ${minor:-unknown}"
      if [ -n "${minor:-}" ] && [ "${minor}" -lt 36 ]; then
        warn "集群 minor=${minor} < 36，与目标 1.36 存在版本差（准入/VAP 语义可能不同）"
      fi
      kc get ns hlvm-system >/dev/null 2>&1 && info "hlvm-system: 已存在" || info "hlvm-system: 未创建"
      kc get crd nodevgs.storage.example.io >/dev/null 2>&1 && info "CRD: 已安装" || info "CRD: 未安装"
      kc get ns cert-manager >/dev/null 2>&1 && info "cert-manager: 已安装" || info "cert-manager: 未安装"
      kc -n hlvm-system get deploy hlvm-storage-webhook >/dev/null 2>&1 \
        && info "storage-webhook: 已部署" || info "storage-webhook: 未部署"
    else
      warn "context ${KCTX} 不存在（kubeconfig 未包含该集群）"
    fi
  else
    warn "kind 集群 '${CLUSTER_NAME}' 不存在；bootstrap 阶段将按 ${NODE_IMAGE} 创建"
  fi

  if [ -f "${CP}/Dockerfile" ]; then info "Dockerfile: 存在"; else warn "Dockerfile: 缺失"; fi
  info "下一步: $0 bootstrap"
}

phase_bootstrap() {
  log "2/5 集群"
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    info "复用已有集群 ${CLUSTER_NAME}"
  else
    info "创建 kind 集群 ${CLUSTER_NAME} (${NODE_IMAGE})"
    kind create cluster --name "${CLUSTER_NAME}" --image "${NODE_IMAGE}" --wait 180s
  fi
  context_exists || die "context ${KCTX} 不存在"
  local minor; minor="$(server_minor)"
  if [ -n "${minor:-}" ] && [ "${minor}" -lt 36 ]; then
    warn "集群 minor=${minor} < 36，与目标 1.36 有版本差"
  fi

  log "3/5 cert-manager"
  if kc get ns cert-manager >/dev/null 2>&1; then
    info "cert-manager 已存在，跳过安装"
  else
    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    helm upgrade --install cert-manager jetstack/cert-manager \
      --kube-context "${KCTX}" \
      --namespace cert-manager --create-namespace \
      --version "${CERT_MANAGER_VERSION}" \
      --set crds.enabled=true --wait --timeout 300s
    kc -n cert-manager wait --for=condition=Available deployment/cert-manager --timeout=180s
    kc -n cert-manager wait --for=condition=Available deployment/cert-manager-webhook --timeout=180s
    kc -n cert-manager wait --for=condition=Available deployment/cert-manager-cainjector --timeout=180s
  fi

  log "4/5 CRD / 命名空间 / RBAC / 证书 / webhook / manager"
  kc apply -f "${CP}/config/hardening/00-namespace-psa.yaml"
  kc apply -f "${CP}/config/crd/bases"
  kc apply -f "${CP}/config/rbac/role.yaml"
  kc apply -f "${CP}/config/webhook/rbac.yaml"
  kc apply -f "${CP}/config/webhook/certificate.yaml"
  kc -n hlvm-system wait --for=condition=Ready certificate/hlvm-storage-webhook-serving-cert --timeout=180s \
    || warn "Certificate 未就绪（cert-manager 未装或签发失败）"
  kc apply -f "${CP}/config/webhook/service.yaml"
  kc apply -f "${CP}/config/webhook/deployment.yaml"
  kc apply -f "${CP}/config/webhook/poddisruptionbudget.yaml"
  kc apply -f "${CP}/config/webhook/manifests.yaml"
  kc apply -f "${CP}/config/webhook/validatingadmissionpolicy.yaml"
  kc apply -f "${CP}/config/manager/manager.yaml"
  info "bootstrap 完成（镜像需 build 阶段加载，否则 Deployment 拉取 GHCR 镜像）"
}

phase_build() {
  log "构建并加载镜像"
  have docker || die "docker 不可用，无法构建镜像"
  [ -f "${CP}/Dockerfile" ] || die "缺少 ${CP}/Dockerfile"
  local extra=()
  if [ -n "${RUNTIME_IMAGE}" ]; then
    extra+=(--build-arg "RUNTIME_IMAGE=${RUNTIME_IMAGE}")
    info "运行态基础镜像覆盖: ${RUNTIME_IMAGE}（仅本地验证）"
  fi
  # BuildKit 预定义 proxy args：透传给 RUN 步骤（go mod download 等需要网络）。
  if [ -n "${HTTP_PROXY:-}" ]; then
    extra+=(--build-arg "HTTP_PROXY=${HTTP_PROXY}" \
            --build-arg "HTTPS_PROXY=${HTTPS_PROXY:-${HTTP_PROXY}}" \
            --build-arg "NO_PROXY=${NO_PROXY:-}")
    info "构建代理: ${HTTP_PROXY}"
  fi
  docker build -f "${CP}/Dockerfile" --build-arg CMD_NAME=storage-controller "${extra[@]}" \
    -t "${IMG_REGISTRY}/storage-controller:${IMG_TAG}" "${CP}"
  docker build -f "${CP}/Dockerfile" --build-arg CMD_NAME=storage-webhook "${extra[@]}" \
    -t "${IMG_REGISTRY}/storage-webhook:${IMG_TAG}" "${CP}"
  kind load docker-image --name "${CLUSTER_NAME}" "${IMG_REGISTRY}/storage-controller:${IMG_TAG}"
  kind load docker-image --name "${CLUSTER_NAME}" "${IMG_REGISTRY}/storage-webhook:${IMG_TAG}"
  # :latest 默认 imagePullPolicy=Always；kind 内改为 IfNotPresent 才会使用已加载镜像。
  kc -n hlvm-system patch deployment hlvm-storage-controller --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' 2>/dev/null || true
  kc -n hlvm-system patch deployment hlvm-storage-webhook --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' 2>/dev/null || true
  kc -n hlvm-system rollout status deployment/hlvm-storage-controller --timeout=180s || warn "controller 未就绪"
  kc -n hlvm-system rollout status deployment/hlvm-storage-webhook --timeout=180s || warn "webhook 未就绪"
}

phase_verify_admission() {
  log "验证 admission 4.3（可自动化部分）"
  context_exists || die "context ${KCTX} 不存在"

  # 1) 证书注入链路：MutatingWebhookConfiguration.caBundle 必须由 cert-manager 注入。
  local ca
  ca="$(kc get mutatingwebhookconfiguration hlvm-storage-webhook-mutating \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)"
  if [ -n "${ca}" ]; then
    info "cert-manager 已注入 caBundle（长度 ${#ca}）"
  else
    warn "caBundle 为空：cert-manager 未生效或 webhook 配置未 apply，注入验证不可信"
  fi

  # 2) 构造平台 SC + NodeVG + PVC + 引用该 PVC 的 Pod；检查 mutator 是否注入锁标签 nodeAffinity。
  #    NodeVG 用于让 PVC 校验 webhook 判定该 tier 有可用节点（否则 PVC CREATE 会被拒绝）。
  local node_name
  node_name="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  kc create namespace m15-verify --dry-run=client -o yaml | kc apply -f - >/dev/null
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1alpha1
kind: NodeVG
metadata:
  name: m15-verify-vg
spec:
  nodeName: ${node_name}
  tier: ${LOCK_TIER}
  thinPool:
    name: ${LOCK_TIER}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: topolvm-${LOCK_TIER}
provisioner: topolvm.io
parameters:
  topolvm.io/device-class: ${LOCK_TIER}
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: m15-pvc
  namespace: m15-verify
spec:
  storageClassName: topolvm-${LOCK_TIER}
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF

  cat <<EOF | kc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: m15-pod
  namespace: m15-verify
  labels:
    app: m15-verify
spec:
  containers:
    - name: pause
      image: ${PAUSE_IMAGE}
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: m15-pvc
EOF

  sleep 2
  local aff
  aff="$(kc -n m15-verify get pod m15-pod \
    -o jsonpath='{.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[*].key}' 2>/dev/null || true)"
  local expect="storage.example.io/${LOCK_TIER}-locked"
  if printf '%s' "${aff}" | grep -q "${expect}"; then
    info "PASS: mutator 已注入 ${expect} 的 nodeAffinity 排除表达式"
  else
    warn "未检测到注入的锁标签表达式（实际 keys: ${aff:-<空>}）"
    warn "排查：webhook Pod 是否 Ready、caBundle 是否注入、Service endpoints 是否就绪"
  fi

  local node
  node="$(kc -n m15-verify get pod m15-pod -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  info "Pod spec.nodeName = '${node:-<未调度>}'（kind 无 TopoLVM CSI，PVC 不绑定属预期；真实调度排除需真环境复验）"

  # 清理
  kc delete namespace m15-verify --wait=false >/dev/null 2>&1 || true
  kc delete storageclass "topolvm-${LOCK_TIER}" >/dev/null 2>&1 || true
  kc delete nodevg m15-verify-vg --wait=false >/dev/null 2>&1 || true
}

phase_verify_controller() {
  log "验证 VG controller 端到端（删盘保护 + 任务下发，真实集群）"
  context_exists || die "context ${KCTX} 不存在"

  local vg="m15-vg-verify" node i ops fail=0
  node="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${node}" ] || die "未找到任何节点"

  cleanup_vg_verify() {
    kc delete nodevg "${vg}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc delete storagetask "vg-${vg}-vgcreate" "vg-${vg}-vgreduce-0" --ignore-not-found >/dev/null 2>&1 || true
  }
  cleanup_vg_verify

  # 构造：pooled + md-raid1 + 2 盘，请求移除 1 盘 → 移除后仅剩 1 盘 < 2，判冗余丧失。
  # 期望 controller 写入 status.pendingOps 阻塞、不下发 vgreduce；同时因 VGExists=false 下发 vgcreate。
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1alpha1
kind: NodeVG
metadata:
  name: ${vg}
spec:
  nodeName: ${node}
  tier: ${LOCK_TIER}
  layout: pooled
  redundancy: md-raid1
  disks: ["/dev/m15-d1", "/dev/m15-d2"]
  thinPool:
    name: ${LOCK_TIER}
  operations:
    removeDisks: ["/dev/m15-d1"]
EOF

  for i in $(seq 1 30); do
    ops="$(kc get nodevg "${vg}" -o jsonpath='{.status.pendingOps}' 2>/dev/null || true)"
    printf '%s' "${ops}" | grep -q "冗余丧失" && break
    sleep 2
  done

  if printf '%s' "${ops}" | grep -q "冗余丧失"; then
    info "PASS: controller 写入 pendingOps（冗余丧失阻塞）: ${ops}"
  else
    warn "FAIL: pendingOps 未出现冗余丧失阻塞（实际: ${ops:-<空>}）"
    kc get nodevg "${vg}" -o yaml 2>/dev/null | tail -25 >&2 || true
    fail=1
  fi

  if kc get storagetask "vg-${vg}-vgcreate" >/dev/null 2>&1; then
    info "PASS: 已下发 vgcreate 任务（vg-${vg}-vgcreate）"
  else
    warn "FAIL: 未下发 vgcreate 任务（controller 未 reconcile 或 RBAC 不足）"
    fail=1
  fi

  if kc get storagetask "vg-${vg}-vgreduce-0" >/dev/null 2>&1; then
    warn "FAIL: 被阻塞的盘仍下发了 vgreduce 任务（vg-${vg}-vgreduce-0）"
    fail=1
  else
    info "PASS: 被阻塞的盘未下发 vgreduce 任务"
  fi

  # 解除删盘意图 → 期望 pendingOps 被清空（幂等路径）。
  kc patch nodevg "${vg}" --type=merge -p '{"spec":{"operations":{"removeDisks":null}}}' >/dev/null
  ops=""
  for i in $(seq 1 30); do
    ops="$(kc get nodevg "${vg}" -o jsonpath='{.status.pendingOps}' 2>/dev/null || true)"
    [ -z "${ops}" ] && break
    sleep 2
  done
  if [ -z "${ops}" ]; then
    info "PASS: 解除删盘意图后 pendingOps 已清空"
  else
    warn "FAIL: 解除删盘意图后 pendingOps 未清空（实际: ${ops}）"
    fail=1
  fi

  cleanup_vg_verify

  if [ "${fail}" -ne 0 ]; then
    die "VG controller 端到端验证未通过（见上）"
  fi
  info "VG controller 端到端验证全部 PASS（删盘保护 / 任务下发 / 幂等清空）"
}

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-check}"
  case "${cmd}" in
    check)            phase_check ;;
    bootstrap)        phase_check; phase_bootstrap ;;
    build)            phase_build ;;
    verify-admission) phase_verify_admission ;;
    verify-controller) phase_verify_controller ;;
    all)              phase_check; phase_bootstrap; phase_build; phase_verify_admission; phase_verify_controller ;;
    -h|--help|help)   usage ;;
    *) die "未知子命令: ${cmd}（可用: check/bootstrap/build/verify-admission/verify-controller/all）" ;;
  esac
}

main "$@"
