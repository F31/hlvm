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
#   verify-lvmd       lvmd ConfigMap 聚合语义（ADR-005）：多 VG 聚合/稳定排序/无可用 class 时撤 CM/篡改自愈/删除收敛/GC
#   verify-taskgc     StorageTask 归属与回收（ADR-006）：NodeVG/NodeDisk ownerReference、删除拥有者后由 GC 回收
#   verify-ttl        StorageTask 执行窗口（spec.ttl）：到期失败关闭、窗口内不误杀、非法值失败关闭
#   all               check → bootstrap → build → verify-admission → verify-controller → verify-lvmd → verify-taskgc → verify-ttl
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
  # 同一 tag（如 latest）重新构建后 Deployment spec 无变化，必须显式重启才会换用新镜像。
  kc -n hlvm-system rollout restart deployment/hlvm-storage-controller deployment/hlvm-storage-webhook >/dev/null 2>&1 || true
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

phase_verify_lvmd() {
  log "验证 lvmd ConfigMap 聚合语义（ADR-005：聚合 / 排序 / 自愈 / 收敛 / GC）"
  context_exists || die "context ${KCTX} 不存在"

  local node ns cm prefix fail=0 i
  node="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${node}" ] || die "未找到任何节点"
  ns="hlvm-system"
  cm="hlmd-lvmd-${node}"
  prefix="m15-lvmd"

  lvmd_cleanup() {
    kc delete nodevg "${prefix}-a" "${prefix}-b" "${prefix}-c" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc delete storagetask "vg-${prefix}-a-vgcreate" "vg-${prefix}-b-vgcreate" "vg-${prefix}-c-vgcreate" \
      --ignore-not-found >/dev/null 2>&1 || true
  }
  lvmd_content() { kc -n "${ns}" get cm "${cm}" -o jsonpath='{.data.lvmd\.yaml}' 2>/dev/null || true; }
  lvmd_wait() {
    local i
    for i in $(seq 1 25); do
      lvmd_content | grep -q "$1" && return 0
      sleep 2
    done
    return 1
  }
  lvmd_mkvg() {
    cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1alpha1
kind: NodeVG
metadata:
  name: ${1}
spec:
  nodeName: ${node}
  tier: ${2}
  deviceClassName: "${3}"
  disks: ["/dev/${1}"]
  thinPool:
    name: ${2}
EOF
    # 无 agent 的 kind 环境：手工置 vgExists=true 模拟 VG 已建成。
    kc patch nodevg "${1}" --subresource=status --type=merge -p '{"status":{"vgExists":true}}' >/dev/null
  }

  lvmd_cleanup

  # A0) 无可用 device-class 时不得渲染 `device-classes: []`
  #     TopoLVM lvmd 的 ValidateDeviceClasses 对空列表直接报错
  #     （should have at least one device-class），写入等于给节点下发无法启动的配置。
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1alpha1
kind: NodeVG
metadata:
  name: ${prefix}-a
spec:
  nodeName: ${node}
  tier: data
  disks: ["/dev/${prefix}-a"]
  thinPool:
    name: data
EOF
  sleep 6
  if kc -n "${ns}" get cm "${cm}" -o jsonpath='{.data.lvmd\.yaml}' 2>/dev/null | grep -q 'device-classes: \[\]'; then
    warn "FAIL: 节点无可用 device-class 时仍渲染了 device-classes: []（lvmd 会拒绝该配置）"
    fail=1
  else
    info "PASS: 无可用 device-class 时不渲染空 device-classes 列表"
  fi

  # A) 同节点两个 VG 聚合 + 稳定排序
  lvmd_mkvg "${prefix}-a" data ""
  lvmd_mkvg "${prefix}-b" metadata ""
  if lvmd_wait "name: metadata"; then
    info "PASS: 同节点两个 NodeVG 已聚合进同一份 ConfigMap"
  else
    warn "FAIL: ConfigMap 未聚合（检查 controller 是否运行新镜像）"
    fail=1
  fi
  local first
  first="$(lvmd_content | grep '  - name:' | head -1 | awk '{print $3}' || true)"
  if [ "${first}" = "data" ]; then
    info "PASS: device-class 稳定升序（首项 data）"
  else
    warn "FAIL: 排序异常（首项 ${first:-<空>}）"
    fail=1
  fi
  local owners
  owners="$(kc -n "${ns}" get cm "${cm}" -o jsonpath='{.metadata.ownerReferences[*].name}' 2>/dev/null || true)"
  if printf '%s' "${owners}" | grep -q "${prefix}-a" && printf '%s' "${owners}" | grep -q "${prefix}-b"; then
    info "PASS: 两个 NodeVG 均写入 ownerReference（非 controller owner）"
  else
    warn "FAIL: ownerReference 不完整（${owners:-<空>}）"
    fail=1
  fi

  # A1) 已有 ConfigMap 但节点**失去全部**可用 class（所有 VG 的 vgExists 回退）→ 撤销托管 CM；恢复后重建。
  kc patch nodevg "${prefix}-a" "${prefix}-b" --subresource=status --type=merge -p '{"status":{"vgExists":false}}' >/dev/null
  local removed=0
  for i in $(seq 1 15); do
    if ! kc -n "${ns}" get cm "${cm}" >/dev/null 2>&1; then
      removed=1
      info "PASS: 节点失去全部可用 device-class 后 ${i}s 内撤销托管 ConfigMap"
      break
    fi
    sleep 1
  done
  if [ "${removed}" -eq 0 ]; then
    warn "FAIL: 无可用 device-class 时托管 ConfigMap 未被撤销"
    fail=1
  fi
  kc patch nodevg "${prefix}-a" "${prefix}-b" --subresource=status --type=merge -p '{"status":{"vgExists":true}}' >/dev/null
  if lvmd_wait "name: data"; then
    info "PASS: 恢复 vgExists 后 ConfigMap 重建"
  else
    warn "FAIL: 恢复 vgExists 后 ConfigMap 未重建"
    fail=1
  fi

  # B) 篡改自愈（ownerRef + Owns(MatchEveryOwner)）
  kc -n "${ns}" patch cm "${cm}" --type=merge -p '{"data":{"lvmd.yaml":"# TAMPERED-BY-M15"}}' >/dev/null
  local healed=0 i
  for i in $(seq 1 20); do
    if ! lvmd_content | grep -q "TAMPERED"; then
      healed=1
      info "PASS: 篡改后 ${i}s 内自愈（owner watch 生效）"
      break
    fi
    sleep 1
  done
  if [ "${healed}" -eq 0 ]; then
    warn "FAIL: 篡改未自愈（检查 Owns(builder.MatchEveryOwner) 与 ownerReference）"
    fail=1
  fi

  # C) spec.deviceClassName 生效
  lvmd_mkvg "${prefix}-c" data cold
  if lvmd_wait "name: cold"; then
    info "PASS: spec.deviceClassName 生效（cold）"
  else
    warn "FAIL: deviceClassName 未生效"
    fail=1
  fi

  # D) 删除一个 VG 后内容与 owner 收敛
  kc delete nodevg "${prefix}-b" >/dev/null
  local shrunk=0
  for i in $(seq 1 20); do
    if ! lvmd_content | grep -q "name: metadata"; then
      shrunk=1
      info "PASS: 删除 VG 后 $((i * 2))s 内收敛（metadata 已移除）"
      break
    fi
    sleep 2
  done
  if [ "${shrunk}" -eq 0 ]; then
    warn "FAIL: 删除 VG 后配置未收敛"
    fail=1
  fi

  # E) 删除最后一个 VG → ConfigMap 由 GC 回收
  kc delete nodevg "${prefix}-a" "${prefix}-c" >/dev/null
  local collected=0
  for i in $(seq 1 30); do
    if ! kc -n "${ns}" get cm "${cm}" >/dev/null 2>&1; then
      collected=1
      info "PASS: 最后一个 VG 删除后 $((i * 2))s 内 ConfigMap 被 GC"
      break
    fi
    sleep 2
  done
  if [ "${collected}" -eq 0 ]; then
    warn "FAIL: ConfigMap 未被 GC（检查多 ownerReference 与 GC）"
    fail=1
  fi

  lvmd_cleanup
  # 说明：StorageTask 现已持有 NodeVG 的非 controller ownerReference，删除 NodeVG 后由 GC 回收
  # （ADR-006，见 verify-taskgc）。此处仍显式清理，避免旧镜像或 GC 延迟在集群留下测试残留。
  if [ "${fail}" -ne 0 ]; then
    die "lvmd 聚合验证未通过（见上）"
  fi
  info "lvmd 聚合验证全部 PASS（空列表拒绝 / 聚合 / 排序 / owner / 撤销与重建 / 自愈 / 收敛 / GC）"
}

phase_verify_taskgc() {
  log "验证 StorageTask 归属与 GC（ADR-006：ownerReference → 删除拥有者后自动回收）"
  context_exists || die "context ${KCTX} 不存在"

  local node vg task fail=0
  node="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${node}" ] || die "未找到任何节点"
  vg="m15-taskgc-vg"
  task="vg-${vg}-vgcreate"

  taskgc_cleanup() {
    kc delete nodevg "${vg}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc delete storagetask "${task}" --ignore-not-found >/dev/null 2>&1 || true
  }
  taskgc_cleanup
  sleep 2

  # 创建 NodeVG（vgExists=false + 2 盘）→ VG controller 应下发 vgcreate 任务。
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1alpha1
kind: NodeVG
metadata:
  name: ${vg}
spec:
  nodeName: ${node}
  tier: data
  disks: ["/dev/m15-taskgc-a", "/dev/m15-taskgc-b"]
  thinPool:
    name: data
EOF

  local i found=0
  for i in $(seq 1 30); do
    if kc get storagetask "${task}" >/dev/null 2>&1; then found=1; break; fi
    sleep 2
  done
  if [ "${found}" -eq 0 ]; then
    warn "FAIL: 未下发 vgcreate 任务（检查 controller 是否运行新镜像 / RBAC）"
    taskgc_cleanup
    die "StorageTask 归属验证未通过（见上）"
  fi
  info "任务已下发: ${task}"

  # 1) 必须持有 NodeVG 的非 controller ownerReference（含正确 UID）。
  local vgUID kind refName refUID isController
  vgUID="$(kc get nodevg "${vg}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  kind="$(kc get storagetask "${task}" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
  refName="$(kc get storagetask "${task}" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
  refUID="$(kc get storagetask "${task}" -o jsonpath='{.metadata.ownerReferences[0].uid}' 2>/dev/null || true)"
  isController="$(kc get storagetask "${task}" -o jsonpath='{.metadata.ownerReferences[0].controller}' 2>/dev/null || true)"
  if [ "${kind}" = "NodeVG" ] && [ "${refName}" = "${vg}" ] && [ "${refUID}" = "${vgUID}" ]; then
    info "PASS: ownerReference 指向 NodeVG ${vg} 且 UID 一致"
  else
    warn "FAIL: ownerReference 不符（kind=${kind:-<空>} name=${refName:-<空>} uid=${refUID:-<空>} vs vgUID=${vgUID:-<空>}）"
    fail=1
  fi
  if [ "${isController}" = "false" ]; then
    info "PASS: ownerReference 为非 controller（只借 GC 归属，不占用 controller 槽位）"
  else
    warn "FAIL: ownerReference 应为非 controller（实际 controller=${isController:-<空>}）"
    fail=1
  fi

  # 2) 删除 NodeVG → 任务应被 GC 回收（不再残留孤儿任务）。
  kc delete nodevg "${vg}" >/dev/null
  local collected=0
  for i in $(seq 1 30); do
    if ! kc get storagetask "${task}" >/dev/null 2>&1; then collected=1; break; fi
    sleep 2
  done
  if [ "${collected}" -eq 1 ]; then
    info "PASS: 删除 NodeVG 后任务在 $((i * 2))s 内被 GC（无孤儿残留）"
  else
    warn "FAIL: 删除 NodeVG 后任务仍存在（GC 未生效：检查 ownerReference UID 与 GC controller）"
    fail=1
  fi

  taskgc_cleanup

  # 3) NodeDisk 路径：pvcreate 任务同样持有 NodeDisk 归属，删除磁盘对象后由 GC 回收。
  local disk="m15-taskgc-disk"
  local dtask="disk-${disk}-pvcreate"
  local diskUID
  kc delete nodedisk "${disk}" --ignore-not-found >/dev/null 2>&1 || true
  kc delete storagetask "${dtask}" --ignore-not-found >/dev/null 2>&1 || true
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: ${disk}
spec:
  nodeName: ${node}
  adopt: true
  deviceRef: /dev/m15-taskgc-disk
EOF
  # kind 无 agent：手工置身份与初相（模拟发现完成），否则控制器不下发纳管任务。
  kc patch nodedisk "${disk}" --subresource=status --type=merge \
    -p '{"status":{"identity":{"byId":"/dev/disk/by-id/m15-taskgc"},"phase":"Discovered"}}' >/dev/null
  found=0
  for i in $(seq 1 20); do
    if kc get storagetask "${dtask}" >/dev/null 2>&1; then found=1; break; fi
    sleep 1
  done
  if [ "${found}" -eq 1 ]; then
    info "任务已下发: ${dtask}"
    diskUID="$(kc get nodedisk "${disk}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    kind="$(kc get storagetask "${dtask}" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
    refUID="$(kc get storagetask "${dtask}" -o jsonpath='{.metadata.ownerReferences[0].uid}' 2>/dev/null || true)"
    if [ "${kind}" = "NodeDisk" ] && [ "${refUID}" = "${diskUID}" ]; then
      info "PASS: NodeDisk 归属正确（kind=NodeDisk，UID 一致）"
    else
      warn "FAIL: NodeDisk 归属不符（kind=${kind:-<空>} uid=${refUID:-<空>} vs ${diskUID:-<空>}）"
      fail=1
    fi
    kc delete nodedisk "${disk}" >/dev/null
    collected=0
    for i in $(seq 1 20); do
      if ! kc get storagetask "${dtask}" >/dev/null 2>&1; then collected=1; break; fi
      sleep 1
    done
    if [ "${collected}" -eq 1 ]; then
      info "PASS: 删除 NodeDisk 后任务在 ${i}s 内被 GC"
    else
      warn "FAIL: 删除 NodeDisk 后任务残留（GC 未生效）"
      fail=1
    fi
  else
    warn "FAIL: NodeDisk 未下发 pvcreate 任务（检查 adopt / identity.byId / phase 前置条件）"
    fail=1
  fi
  kc delete nodedisk "${disk}" --ignore-not-found >/dev/null 2>&1 || true
  kc delete storagetask "${dtask}" --ignore-not-found >/dev/null 2>&1 || true

  if [ "${fail}" -ne 0 ]; then
    die "StorageTask 归属验证未通过（见上）"
  fi
  info "StorageTask 归属验证全部 PASS（NodeVG/NodeDisk ownerReference / 非 controller / GC 回收）"
}

phase_verify_ttl() {
  log "验证 StorageTask 执行窗口（spec.ttl，对齐 K8s Job activeDeadlineSeconds）"
  context_exists || die "context ${KCTX} 不存在"

  local node fail=0 i phase result
  node="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${node}" ] || die "未找到任何节点"
  local expired="m15-ttl-expired" live="m15-ttl-live" bad="m15-ttl-bad"

  ttl_cleanup() {
    kc delete storagetask "${expired}" "${live}" "${bad}" --ignore-not-found >/dev/null 2>&1 || true
  }
  ttl_cleanup

  mk_task() {
    cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1alpha1
kind: StorageTask
metadata:
  name: ${1}
spec:
  nodeName: ${node}
  type: pvcreate
  ttl: ${2}
  target:
    diskRef: /dev/disk/by-id/m15-ttl
EOF
  }

  # A) 到期任务：标记 Failed(DeadlineExceeded) 且不执行；对象保留供排查。
  mk_task "${expired}" "2s"
  phase=""
  for i in $(seq 1 30); do
    phase="$(kc get storagetask "${expired}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${phase}" = "Failed" ] && break
    sleep 1
  done
  result="$(kc get storagetask "${expired}" -o jsonpath='{.status.result}' 2>/dev/null || true)"
  if [ "${phase}" = "Failed" ] && printf '%s' "${result}" | grep -q "DeadlineExceeded"; then
    info "PASS: ttl 到期后任务在 ${i}s 内标记 Failed（${result}）"
  else
    warn "FAIL: 到期任务未按预期标记（phase=${phase:-<空>} result=${result:-<空>}）"
    fail=1
  fi
  if kc get storagetask "${expired}" >/dev/null 2>&1; then
    info "PASS: 到期任务对象保留（不自动删除/不自动重试）"
  else
    warn "FAIL: 到期任务对象被删除（应保留供排查）"
    fail=1
  fi

  # B) 窗口内任务不得被误杀（ttl=1h，观察 8s；无 agent 时 phase 应保持为空）。
  mk_task "${live}" "1h"
  sleep 8
  phase="$(kc get storagetask "${live}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ -z "${phase}" ] || [ "${phase}" = "Pending" ]; then
    info "PASS: 窗口内任务未被改写（phase=${phase:-<空>}）"
  else
    warn "FAIL: 窗口内任务被提前判定为 ${phase}"
    fail=1
  fi

  # C) 非法 ttl：失败关闭（拒绝执行），并说明原因。
  mk_task "${bad}" "nonsense"
  phase=""
  for i in $(seq 1 20); do
    phase="$(kc get storagetask "${bad}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${phase}" = "Failed" ] && break
    sleep 1
  done
  result="$(kc get storagetask "${bad}" -o jsonpath='{.status.result}' 2>/dev/null || true)"
  if [ "${phase}" = "Failed" ] && printf '%s' "${result}" | grep -q "不是合法时长"; then
    info "PASS: 非法 ttl 按失败关闭拒绝执行（${result}）"
  else
    warn "FAIL: 非法 ttl 未失败关闭（phase=${phase:-<空>} result=${result:-<空>}）"
    fail=1
  fi

  ttl_cleanup
  if [ "${fail}" -ne 0 ]; then
    die "StorageTask TTL 验证未通过（见上）"
  fi
  info "StorageTask TTL 验证全部 PASS（到期失败关闭 / 窗口内不误杀 / 非法值失败关闭）"
}

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-check}"
  case "${cmd}" in
    check)            phase_check ;;
    bootstrap)        phase_check; phase_bootstrap ;;
    build)            phase_build ;;
    verify-admission) phase_verify_admission ;;
    verify-controller) phase_verify_controller ;;
    verify-lvmd)       phase_verify_lvmd ;;
    verify-taskgc)     phase_verify_taskgc ;;
    verify-ttl)        phase_verify_ttl ;;
    all)              phase_check; phase_bootstrap; phase_build; phase_verify_admission; phase_verify_controller; phase_verify_lvmd; phase_verify_taskgc; phase_verify_ttl ;;
    -h|--help|help)   usage ;;
    *) die "未知子命令: ${cmd}（可用: check/bootstrap/build/verify-admission/verify-controller/verify-lvmd/verify-taskgc/verify-ttl/all）" ;;
  esac
}

main "$@"
