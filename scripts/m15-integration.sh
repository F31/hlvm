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
#   verify-agent      节点 Agent 真机验证：SA/RBAC、节点名注入、任务状态回写、NodeDisk 观测写回
#   verify-device-plugin 磁盘设备插件：kubelet 注册、可分配量、非特权按盘读取（含未授权对照）
#   verify-collector  每盘一个 collector Pod：NodeDisk → 非特权按盘 Pod → /metrics → 删除回收
#   all               check → bootstrap → build → verify-admission → verify-controller → verify-lvmd → verify-taskgc → verify-ttl → verify-agent → verify-device-plugin → verify-collector
#
# 环境变量：
#   CLUSTER_NAME=hlvm-kind  NODE_IMAGE=kindest/node:v1.36.1
#   IMG_REGISTRY=ghcr.io/f31/hlvm  IMG_TAG=latest
#   CERT_MANAGER_VERSION=v1.17.2   LOCK_TIER=data
#   RUNTIME_IMAGE=（空=用 Dockerfile 默认 distroless；离线 kind 可设为已缓存基础镜像）
#   PAUSE_IMAGE=registry.k8s.io/pause:3.10（verify-admission 测试 Pod 使用）
#   AGENT_BUILD_PROXY=http://172.17.0.1:17890（无 Rust 时容器内 cargo 用的代理；留空=不走）
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
# 无本机 Rust 时容器内 cargo 走代理（kind 节点/容器内访问宿主代理，见 runbook §7.1）。
AGENT_BUILD_PROXY="${AGENT_BUILD_PROXY:-}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
# 断言失败结果必须落在 stdout：审计按 stdout 数 PASS/FAIL，走了 stderr 就会「看起来全绿」。
fail_msg() { printf '\033[1;31m    %s\033[0m\n' "$*"; }
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
      if [ -z "${minor:-}" ]; then
        # API 不可达时，下面每个 kc get 都会失败；若照常输出「未创建/未安装」，
        # 会让人误以为集群资源丢失（实际只是容器停止）。这里明确区分「查不到」与「不存在」。
        warn "API server 不可达（节点容器可能已停止；bootstrap 会自动 docker start 并等待就绪）"
        warn "集群内资源状态未检查（不是「未安装」，是查不到）"
      else
        info "server minor: ${minor}"
        if [ "${minor}" -lt 36 ]; then
          warn "集群 minor=${minor} < 36，与目标 1.36 存在版本差（准入/VAP 语义可能不同）"
        fi
        kc get ns hlvm-system >/dev/null 2>&1 && info "hlvm-system: 已存在" || info "hlvm-system: 未创建"
        kc get crd nodevgs.storage.example.io >/dev/null 2>&1 && info "CRD: 已安装" || info "CRD: 未安装"
        kc get ns cert-manager >/dev/null 2>&1 && info "cert-manager: 已安装" || info "cert-manager: 未安装"
        kc -n hlvm-system get deploy hlvm-storage-webhook >/dev/null 2>&1 \
          && info "storage-webhook: 已部署" || info "storage-webhook: 未部署"
      fi
    else
      warn "context ${KCTX} 不存在（kubeconfig 未包含该集群）"
    fi
  else
    warn "kind 集群 '${CLUSTER_NAME}' 不存在；bootstrap 阶段将按 ${NODE_IMAGE} 创建"
  fi

  if [ -f "${CP}/Dockerfile" ]; then info "Dockerfile: 存在"; else warn "Dockerfile: 缺失"; fi
  info "下一步: $0 bootstrap"
}

# ensure_node_running 确保 kind 节点容器处于运行态。
#
# 背景（实测 2026-10-30）：Docker Desktop / WSL VM 重启后，kind 节点容器**没有 restart policy**，
# 会停在 Exited (128)；但 `kind get clusters` 仍然列出该集群（它按容器标签查找，不看容器状态）。
# 于是脚本误判「集群存在」并直接进入 apply/wait，全部以 connection refused 失败，
# 日志里看不出根因；手工 `docker start` 即可恢复。
ensure_node_running() {
  have docker || die "需要 docker 检查 kind 节点容器状态"
  local container="${CLUSTER_NAME}-control-plane"
  local st
  st="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || echo missing)"

  case "${st}" in
    running) info "节点容器 ${container}: running" ;;
    exited|created|paused)
      warn "节点容器 ${container} 状态=${st}（Docker 重启后 kind 无 restart policy，不会自愈），自动启动"
      docker start "${container}" >/dev/null \
        || die "启动 ${container} 失败；docker logs ${container} 可定位"
      ;;
    missing)
      die "找不到节点容器 ${container}：集群元数据与容器不一致（建议 kind delete cluster --name ${CLUSTER_NAME} 后重建）"
      ;;
    *) warn "节点容器 ${container} 状态异常: ${st}" ;;
  esac

  local i
  for i in $(seq 1 45); do
    if kc get --raw /readyz >/dev/null 2>&1; then
      info "API server 就绪"
      return 0
    fi
    sleep 2
  done
  die "API server 在 90s 内未就绪：docker logs ${container} 可查（inotify/kube-proxy 见 runbook §7.2）"
}

# 验证阶段统一入口：节点容器自愈 → API 就绪 → 节点可读。
#
# 独立执行 verify-* 时不应依赖「先跑过 bootstrap」。实测 Docker Desktop 重启后 kind 节点
# 容器停在 Exited(128)（kind 无 restart policy），而 API 刚起来时 RBAC 尚未就绪，会瞬时
# 返回 `nodes is forbidden`；两者都会表现为「未找到任何节点」，极易误判为集群数据丢失。
NODE_NAME=""
ensure_cluster_ready() {
  context_exists || die "context ${KCTX} 不存在"
  ensure_node_running
  local i out
  for i in $(seq 1 20); do
    out="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "${out}" ]; then
      NODE_NAME="${out}"
      return 0
    fi
    sleep 3
  done
  out="$(kc get nodes 2>&1 || true)"
  die "无法读取节点（重试 10 次）：${out}"
}

# ensure_kernel_limits 修正并**持久化**节点 inotify 上限。
#
# 背景（runbook §7.2）：Docker Desktop / kind 节点容器重启后，sysctl 回落到
# fs.inotify.max_user_instances=128；同机多个 kind 集群共享同一内核，实例很快耗尽，
# kube-proxy 报 `too many open files` → Service 规则无法编程 → ClusterIP 10.96.0.1 不可达。
# 现象极具误导性：kubectl 直连 6443 正常，而 controller/webhook/coredns 全部失联，
# 所有 verify-* 一起变红，看起来像代码回归。
#
# 持久化边界（实测 2026-10-29）：写入 /etc/sysctl.d/ 在**容器 stop/start** 后可保留
# （内核未重启），但 Docker Desktop / WSL VM 重启会重置内核参数，实测再次回落 128。
# 因此不能依赖一次配置：本函数在每次 bootstrap 校验并修复，才是真正的保障。
ensure_kernel_limits() {
  have docker || return 0
  local container="${CLUSTER_NAME}-control-plane"
  docker inspect "${container}" >/dev/null 2>&1 || return 0

  local cur
  cur="$(docker exec "${container}" sysctl -n fs.inotify.max_user_instances 2>/dev/null || true)"
  if [ -z "${cur}" ]; then
    warn "无法读取节点 inotify 限制，跳过（非 kind 环境可忽略）"
    return 0
  fi
  if [ "${cur}" -ge 2048 ]; then
    info "节点 inotify.max_user_instances=${cur}（充足）"
    return 0
  fi

  warn "节点 inotify.max_user_instances=${cur} < 2048：kube-proxy 可能因 too many open files 崩溃"
  if ! docker exec "${container}" sh -c \
    'printf "fs.inotify.max_user_instances=2048\nfs.inotify.max_user_watches=1048576\n" > /etc/sysctl.d/99-hlvm-kind.conf && sysctl -p /etc/sysctl.d/99-hlvm-kind.conf' \
    >/dev/null 2>&1; then
    warn "写入 sysctl 失败（需要节点 root），请手工执行 runbook §7.2 的命令"
    return 0
  fi
  info "已提升并持久化至 /etc/sysctl.d/99-hlvm-kind.conf"

  # 已经崩溃的 kube-proxy 不会自愈，必须重建才会重新编程 Service 规则。
  local bad
  bad="$(kc -n kube-system get pods -l k8s-app=kube-proxy \
    -o jsonpath='{range .items[*]}{.status.phase}/{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
    | grep -vc '^Running/true$' || true)"
  if [ "${bad:-0}" -gt 0 ]; then
    warn "检测到 kube-proxy 非就绪，重建 kube-proxy 与 CoreDNS"
    kc -n kube-system delete pod -l k8s-app=kube-proxy >/dev/null 2>&1 || true
    kc -n kube-system delete pod -l k8s-app=kube-dns >/dev/null 2>&1 || true
    if kc -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-proxy --timeout=150s >/dev/null 2>&1; then
      info "kube-proxy 已恢复"
    else
      warn "kube-proxy 未在 150s 内就绪，后续验证可能整体失败"
    fi
  fi
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
  # 容器可能因 Docker Desktop 重启而停在 Exited，而 kind 仍列出集群：先确保运行态。
  ensure_node_running
  ensure_kernel_limits
  local minor; minor="$(server_minor)"
  if [ -z "${minor:-}" ]; then
    warn "无法解析 server 版本：版本一致性校验未生效（/version 失败或格式变化）"
  elif [ "${minor}" -lt 36 ]; then
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
  # collector 管理权限（add-disk-device-plugin 6.1）：Role 仅限 hlvm-system 内的 Pod。
  kc apply -f "${CP}/config/rbac/collector_role.yaml"
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
    -t "${IMG_REGISTRY}/storage-controller:${IMG_TAG}" "${CP}" \
    || die "storage-controller 镜像构建失败"
  docker build -f "${CP}/Dockerfile" --build-arg CMD_NAME=storage-webhook "${extra[@]}" \
    -t "${IMG_REGISTRY}/storage-webhook:${IMG_TAG}" "${CP}" \
    || die "storage-webhook 镜像构建失败"
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
  ensure_cluster_ready

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
  ensure_cluster_ready

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
    fail_msg "FAIL: pendingOps 未出现冗余丧失阻塞（实际: ${ops:-<空>}）"
    kc get nodevg "${vg}" -o yaml 2>/dev/null | tail -25 >&2 || true
    fail=1
  fi

  if kc get storagetask "vg-${vg}-vgcreate" >/dev/null 2>&1; then
    info "PASS: 已下发 vgcreate 任务（vg-${vg}-vgcreate）"
  else
    fail_msg "FAIL: 未下发 vgcreate 任务（controller 未 reconcile 或 RBAC 不足）"
    fail=1
  fi

  if kc get storagetask "vg-${vg}-vgreduce-0" >/dev/null 2>&1; then
    fail_msg "FAIL: 被阻塞的盘仍下发了 vgreduce 任务（vg-${vg}-vgreduce-0）"
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
    fail_msg "FAIL: 解除删盘意图后 pendingOps 未清空（实际: ${ops}）"
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
  ensure_cluster_ready

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
    fail_msg "FAIL: 节点无可用 device-class 时仍渲染了 device-classes: []（lvmd 会拒绝该配置）"
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
    fail_msg "FAIL: ConfigMap 未聚合（检查 controller 是否运行新镜像）"
    fail=1
  fi
  local first
  first="$(lvmd_content | grep '  - name:' | head -1 | awk '{print $3}' || true)"
  if [ "${first}" = "data" ]; then
    info "PASS: device-class 稳定升序（首项 data）"
  else
    fail_msg "FAIL: 排序异常（首项 ${first:-<空>}）"
    fail=1
  fi
  local owners
  owners="$(kc -n "${ns}" get cm "${cm}" -o jsonpath='{.metadata.ownerReferences[*].name}' 2>/dev/null || true)"
  if printf '%s' "${owners}" | grep -q "${prefix}-a" && printf '%s' "${owners}" | grep -q "${prefix}-b"; then
    info "PASS: 两个 NodeVG 均写入 ownerReference（非 controller owner）"
  else
    fail_msg "FAIL: ownerReference 不完整（${owners:-<空>}）"
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
    fail_msg "FAIL: 无可用 device-class 时托管 ConfigMap 未被撤销"
    fail=1
  fi
  kc patch nodevg "${prefix}-a" "${prefix}-b" --subresource=status --type=merge -p '{"status":{"vgExists":true}}' >/dev/null
  if lvmd_wait "name: data"; then
    info "PASS: 恢复 vgExists 后 ConfigMap 重建"
  else
    fail_msg "FAIL: 恢复 vgExists 后 ConfigMap 未重建"
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
    fail_msg "FAIL: 篡改未自愈（检查 Owns(builder.MatchEveryOwner) 与 ownerReference）"
    fail=1
  fi

  # C) spec.deviceClassName 生效
  lvmd_mkvg "${prefix}-c" data cold
  if lvmd_wait "name: cold"; then
    info "PASS: spec.deviceClassName 生效（cold）"
  else
    fail_msg "FAIL: deviceClassName 未生效"
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
    fail_msg "FAIL: 删除 VG 后配置未收敛"
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
    fail_msg "FAIL: ConfigMap 未被 GC（检查多 ownerReference 与 GC）"
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
  ensure_cluster_ready

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
    fail_msg "FAIL: 未下发 vgcreate 任务（检查 controller 是否运行新镜像 / RBAC）"
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
    fail_msg "FAIL: ownerReference 不符（kind=${kind:-<空>} name=${refName:-<空>} uid=${refUID:-<空>} vs vgUID=${vgUID:-<空>}）"
    fail=1
  fi
  if [ "${isController}" = "false" ]; then
    info "PASS: ownerReference 为非 controller（只借 GC 归属，不占用 controller 槽位）"
  else
    fail_msg "FAIL: ownerReference 应为非 controller（实际 controller=${isController:-<空>}）"
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
    fail_msg "FAIL: 删除 NodeVG 后任务仍存在（GC 未生效：检查 ownerReference UID 与 GC controller）"
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
      fail_msg "FAIL: NodeDisk 归属不符（kind=${kind:-<空>} uid=${refUID:-<空>} vs ${diskUID:-<空>}）"
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
      fail_msg "FAIL: 删除 NodeDisk 后任务残留（GC 未生效）"
      fail=1
    fi
  else
    fail_msg "FAIL: NodeDisk 未下发 pvcreate 任务（检查 adopt / identity.byId / phase 前置条件）"
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
  ensure_cluster_ready

  local node="${NODE_NAME}" fail=0 i phase result
  local expired="m15-ttl-expired" live="m15-ttl-live" bad="m15-ttl-bad"

  # 时钟偏差预检：TTL 是「创建时间 + 时长」的比较，控制面/节点与本地时钟不同步时，
  # 到期判定会整体偏移（偏差远大于 TTL 时表现为「刚创建就过期」或「永不过期」）。
  # 探针取 apiserver 写入的 creationTimestamp（秒级）与本地 UTC 比较。
  local probe="m15-clock-probe" created created_epoch local_epoch skew
  kc delete cm "${probe}" --ignore-not-found >/dev/null 2>&1 || true
  created="$(kc create cm "${probe}" --from-literal=probe=1 \
    -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
  kc delete cm "${probe}" --ignore-not-found >/dev/null 2>&1 || true
  if [ -n "${created}" ]; then
    created_epoch="$(date -d "${created}" +%s 2>/dev/null || true)"
    local_epoch="$(date -u +%s)"
    if [ -n "${created_epoch}" ]; then
      skew=$((local_epoch - created_epoch))
      [ "${skew}" -lt 0 ] && skew=$((-skew))
      if [ "${skew}" -le 2 ]; then
        info "PASS: apiserver 与本地时钟偏差 ${skew}s（TTL 判定前提）"
      else
        warn "WARN: apiserver 与本地时钟偏差 ${skew}s，TTL 到期判定可能不准（请确认 NTP）"
      fi
    fi
  fi

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
    fail_msg "FAIL: 到期任务未按预期标记（phase=${phase:-<空>} result=${result:-<空>}）"
    fail=1
  fi
  if kc get storagetask "${expired}" >/dev/null 2>&1; then
    info "PASS: 到期任务对象保留（不自动删除/不自动重试）"
  else
    fail_msg "FAIL: 到期任务对象被删除（应保留供排查）"
    fail=1
  fi

  # B) 窗口内任务不得被误杀（ttl=1h，观察 8s；无 agent 时 phase 应保持为空）。
  mk_task "${live}" "1h"
  sleep 8
  phase="$(kc get storagetask "${live}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ -z "${phase}" ] || [ "${phase}" = "Pending" ]; then
    info "PASS: 窗口内任务未被改写（phase=${phase:-<空>}）"
  else
    fail_msg "FAIL: 窗口内任务被提前判定为 ${phase}"
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
    fail_msg "FAIL: 非法 ttl 未失败关闭（phase=${phase:-<空>} result=${result:-<空>}）"
    fail=1
  fi

  ttl_cleanup
  if [ "${fail}" -ne 0 ]; then
    die "StorageTask TTL 验证未通过（见上）"
  fi
  info "StorageTask TTL 验证全部 PASS（到期失败关闭 / 窗口内不误杀 / 非法值失败关闭）"
}

# 构建 agent 二进制：本机有 cargo 就用本机，否则用容器内 rust 工具链
# （本仓库开发机通常无 Rust 链接器，这也是 agent 长期未在真机跑过的原因之一）。
# target/ 与 registry 放在命名卷里，重复构建走缓存（约 25s）。
ensure_agent_binary() {
  local bin="${REPO_ROOT}/agent/hlvm-agent"
  if have cargo; then
    info "使用本机 cargo 构建 release 二进制"
    ( cd "${REPO_ROOT}/agent" && cargo build --release ) || die "cargo build 失败"
    cp "${REPO_ROOT}/agent/target/release/hlvm-agent" "${bin}" || die "拷贝二进制失败"
    return 0
  fi
  have docker || die "本机既无 Rust 工具链也无 docker：无法构建 agent 二进制"
  if ! docker image inspect rust:slim >/dev/null 2>&1; then
    warn "本机无 rust:slim，首次需拉取约 1.3GB（代理不稳时可能多次重试）"
    docker pull rust:slim || die "拉取 rust:slim 失败"
  fi
  docker volume create hlvm-cargo-target >/dev/null
  docker volume create hlvm-cargo-registry >/dev/null
  info "容器内 cargo build --release（首次约 1 分钟，之后走卷缓存）"
  docker run --rm \
    -v "${REPO_ROOT}/agent:/src" -w /src \
    -e CARGO_TARGET_DIR=/target -e CARGO_HOME=/usr/local/cargo \
    ${AGENT_BUILD_PROXY:+-e HTTP_PROXY=${AGENT_BUILD_PROXY} -e HTTPS_PROXY=${AGENT_BUILD_PROXY}} \
    -v hlvm-cargo-target:/target -v hlvm-cargo-registry:/usr/local/cargo/registry \
    rust:slim cargo build --release || die "容器内 cargo build 失败"
  docker run --rm -v hlvm-cargo-target:/target -v "${REPO_ROOT}/agent:/out" rust:slim \
    sh -c 'cp /target/release/hlvm-agent /out/hlvm-agent && chmod +x /out/hlvm-agent' \
    || die "导出二进制失败"
  [ -x "${bin}" ] || die "二进制未生成：${bin}"
}

# 构建 agent 镜像并装载进 kind（agent 与 device-plugin 共用同一镜像，仅 --mode 不同）。
#
# 抽成 helper 的原因：两个验证阶段都要「本机无 Rust → 容器内构建 → 打包 → kind load」，
# 复制一份意味着镜像 tag/装载方式改一次要改两处，且容易只改一边导致镜像版本错配。
ensure_agent_image() {
  local img="${1:-hlvm-storage-agent:dev}"
  have docker || die "需要 docker（构建/装载本地镜像）"
  ensure_agent_binary
  info "构建本地镜像 ${img}（GHCR 包为私有，kind 内不能直接拉）"
  docker build -q -t "${img}" "${REPO_ROOT}/agent" >/dev/null || die "docker build 失败"
  kind load docker-image "${img}" --name "${CLUSTER_NAME}" >/dev/null || die "kind load 失败"
}

# 节点 Agent 真机验证。
#
# 此前 Agent 从未进入集成流程，导致三类缺陷长期未暴露（均在本阶段首次真跑时才发现）：
#   1. storage-agent 镜像从未被 CI 构建（部署必 ImagePullBackOff）；
#   2. hlvm-agent SA 建在 kube-system，而 DaemonSet 在 hlvm-system（Pod 无法创建）；
#   3. Agent 不读 Downward API 注入的节点名，node="unknown" 时按 nodeName 过滤
#      → 表面健康却永远不执行任何任务；lsblk -b 的 size 为数字导致 discovery 直接失败。
phase_verify_agent() {
  log "验证节点 Agent：SA/RBAC 可解析、节点名注入、任务状态回写、NodeDisk 观测写回、占用判定"
  ensure_cluster_ready
  local img="hlvm-storage-agent:dev" node="${NODE_NAME}" fail=0 i phase msg logs
  ensure_agent_image "${img}"

  agent_cleanup() {
    kc -n hlvm-system delete ds hlvm-storage-agent --ignore-not-found >/dev/null 2>&1 || true
    kc delete storagetask m15-agent-exec --ignore-not-found >/dev/null 2>&1 || true
    kc delete nodedisk m15-agent-disk --ignore-not-found >/dev/null 2>&1 || true
    kc delete nodedisk m15-agent-fsdisk --ignore-not-found >/dev/null 2>&1 || true
  }
  agent_cleanup

  kc apply -f "${REPO_ROOT}/control-plane/config/rbac/agent_role.yaml" >/dev/null \
    || die "apply agent RBAC 失败"
  kc apply -f "${REPO_ROOT}/agent/config/daemonset-agent.yaml" >/dev/null \
    || die "apply agent DaemonSet 失败"
  kc -n hlvm-system set image ds/hlvm-storage-agent agent="${img}" >/dev/null \
    || die "设置 agent 镜像失败"
  # 清单以 :latest 声明，创建时 imagePullPolicy 会被固化为 Always；本地镜像必须改回
  # IfNotPresent，否则节点会去 docker.io 拉同名镜像并 ImagePullBackOff。
  kc -n hlvm-system patch ds hlvm-storage-agent --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
    >/dev/null || die "设置 imagePullPolicy 失败"

  # 用 rollout status 而非 kubectl wait：后者在 DaemonSet 尚未创建出 Pod 时会立即报
  # "no matching resources found" 并返回失败，看起来像 Pod 起不来，实为时序问题。
  if kc -n hlvm-system rollout status ds/hlvm-storage-agent --timeout=180s >/dev/null 2>&1; then
    info "PASS: agent Pod 就绪"
  else
    fail_msg "FAIL: agent DaemonSet 未在 180s 内就绪"
    kc -n hlvm-system get pods -l app.kubernetes.io/component=storage-agent 2>&1 | tail -3
    kc -n hlvm-system describe pod -l app.kubernetes.io/component=storage-agent 2>&1 | tail -8
    fail=1
  fi

  # tracing 默认输出 ANSI 色码（kubectl logs 里是 \x1b[...m），直接 grep 会失配。
  logs="$(kc -n hlvm-system logs ds/hlvm-storage-agent --tail=80 2>&1 | sed -r 's/\x1B\[[0-9;]*[mK]//g' || true)"
  if printf '%s' "${logs}" | grep -q "node=\"${node}\""; then
    info "PASS: agent 解析到节点名 ${node}（Downward API 注入生效）"
  else
    fail_msg "FAIL: agent 未解析出节点名（node=unknown 时任务过滤恒不成立，Agent 会静默空转）"
    printf '%s\n' "${logs}" | tail -5
    fail=1
  fi
  if printf '%s' "${logs}" | grep -q "进入 StorageTask 回写协调循环"; then
    info "PASS: agent 已建立 kube 客户端并进入回写循环（SA token/RBAC 生效）"
  else
    fail_msg "FAIL: agent 未进入回写循环"
    fail=1
  fi
  if printf '%s' "${logs}" | grep -q "discovery 失败"; then
    fail_msg "FAIL: agent 磁盘发现失败（lsblk 解析或权限问题）"
    printf '%s\n' "${logs}" | grep "discovery 失败" | tail -2
    fail=1
  else
    info "PASS: 磁盘发现无报错"
  fi

  # A) 任务状态回写：目标设备不存在 → 执行必然失败，但过程无宿主副作用，
  #    足以验证 agent 的 storagetasks/status 写权限（曾因 CRD 缺 status 子资源返回 404）。
  kc apply -f - >/dev/null <<EOF
apiVersion: storage.example.io/v1alpha1
kind: StorageTask
metadata:
  name: m15-agent-exec
spec:
  nodeName: ${node}
  type: pvcreate
  target:
    diskRef: /dev/disk/by-id/m15-agent-nonexistent
EOF
  phase=""
  for i in $(seq 1 20); do
    phase="$(kc get storagetask m15-agent-exec -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${phase}" = "Failed" ] && break
    sleep 2
  done
  msg="$(kc get storagetask m15-agent-exec -o jsonpath='{.status.message}' 2>/dev/null || true)"
  if [ "${phase}" = "Failed" ] && [ -n "${msg}" ]; then
    info "PASS: agent 自主回写任务状态（$((i * 2))s，message=${msg}）"
  else
    fail_msg "FAIL: agent 未回写任务状态（phase=${phase:-<空>} message=${msg:-<空>}）"
    kc -n hlvm-system logs ds/hlvm-storage-agent --tail=20 2>&1 | grep -E "回写|403|404" | tail -3
    fail=1
  fi

  # B) NodeDisk 观测写回：adopt=false 时控制面不下发任何任务，只验证 agent 观测。
  #    health/occupiedBy/isSystemDisk 仅由 agent 写（控制面 disk_controller 不写这三个字段）。
  kc apply -f - >/dev/null <<EOF
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: m15-agent-disk
  labels:
    hlvm.storage/node: ${node}
spec:
  nodeName: ${node}
  deviceRef: /dev/sda
  adopt: false
EOF
  local health=""
  for i in $(seq 1 20); do
    health="$(kc get nodedisk m15-agent-disk -o jsonpath='{.status.health}' 2>/dev/null || true)"
    [ -n "${health}" ] && break
    sleep 3
  done
  if [ -n "${health}" ]; then
    info "PASS: agent 写回 NodeDisk 观测状态（$((i * 3))s，health=${health}）"
  else
    fail_msg "FAIL: agent 未写回 NodeDisk 观测状态（nodedisks/status 权限或扫描失败）"
    kc -n hlvm-system logs ds/hlvm-storage-agent --tail=30 2>&1 | grep -E "扫描|NodeDisk" | tail -3
    fail=1
  fi

  # C) 占用判定（occupiedBy）：旧实现恒写 "none"（且调用 `blkid --json`——blkid 根本没有
  #    这个选项，签名规则在生产路径上从未生效）。这里在节点内造一块**带 ext4 签名**的 loop
  #    设备，让 agent 真观测：必须得到 occupiedBy=filesystem 且不可纳管（phase 不得推进到
  #    PreChecked，否则该盘会被下发 wipe/vgcreate）。
  local loop_dev="/dev/loop77" loop_ok=1 occ="" nd_phase=""
  if docker exec "${CLUSTER_NAME}-control-plane" sh -c "
      dd if=/dev/zero of=/tmp/m15-occ.img bs=1M count=32 2>/dev/null
      mknod ${loop_dev} b 7 77 2>/dev/null || true
      losetup -d ${loop_dev} 2>/dev/null || true
      losetup ${loop_dev} /tmp/m15-occ.img && mkfs.ext4 -q -F ${loop_dev}
    " >/dev/null 2>&1; then
    kc apply -f - >/dev/null <<EOF
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: m15-agent-fsdisk
spec:
  nodeName: ${node}
  deviceRef: ${loop_dev}
  adopt: false
EOF
    for i in $(seq 1 20); do
      occ="$(kc get nodedisk m15-agent-fsdisk -o jsonpath='{.status.occupiedBy}' 2>/dev/null || true)"
      [ -n "${occ}" ] && break
      sleep 3
    done
    nd_phase="$(kc get nodedisk m15-agent-fsdisk -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "${occ}" = "filesystem" ] && [ "${nd_phase}" != "PreChecked" ]; then
      info "PASS: 带 ext4 签名的盘判定 occupiedBy=filesystem 且未通过预检（$((i * 3))s，phase=${nd_phase:-<空>}）"
    else
      fail_msg "FAIL: 占用判定错误（occupiedBy=${occ:-<空>} phase=${nd_phase:-<空>}；期望 filesystem 且非 PreChecked）"
      kc -n hlvm-system logs ds/hlvm-storage-agent --tail=20 2>&1 | grep -E "扫描|NodeDisk|blkid" | tail -3
      fail=1
    fi
  else
    warn "跳过占用判定断言：无法在节点内创建 loop 设备（缺 losetup/mkfs 或权限不足）"
    loop_ok=0
  fi

  # 清理：Agent 常驻会改变 verify-ttl 的前提（无 agent 时窗口内任务不该被写），
  # 故本阶段结束时撤掉 DaemonSet，只保留 RBAC（可重复 apply）。
  agent_cleanup
  if [ "${loop_ok}" -eq 1 ]; then
    docker exec "${CLUSTER_NAME}-control-plane" sh -c \
      "losetup -d ${loop_dev} 2>/dev/null; rm -f /tmp/m15-occ.img" >/dev/null 2>&1 || true
  fi
  if [ "${fail}" -ne 0 ]; then
    die "节点 Agent 验证未通过（见上）"
  fi
  info "节点 Agent 验证全部 PASS（节点名注入 / kube 客户端 / 任务回写 / 观测写回 / 占用判定）"
}

# 磁盘设备插件（`hlvm.io/disk`）验证。
#
# 验证的是**kubelet 侧的客观事实**，不是插件日志的自述：
# 1) 节点 status.allocatable 出现 `hlvm.io/disk` 且 > 0（注册 + ListAndWatch 生效）；
# 2) 非特权 Pod 申请 1 块盘后能真正读该设备（kubelet 把它写进 devices cgroup 允许列表）；
# 3) 对照：同样非特权、同样挂 hostPath /dev，但**不申请**资源的 Pod 读设备得到 EPERM。
#    没有第 3 条，第 2 条无法证明是「分配的功劳」而不是环境本来就允许；
# 4) 容量账实一致：盘位用满时全部 Running、再多申请一个必须 Pending、释放一个后它能 Running。
#    注意 `status.allocatable` 对扩展资源是**静态上限**（kubelet 不因分配而扣减，记账在调度器），
#    所以不能用「allocatable 变小」当判据；只看「能分配」不看「能归还」会漏掉盘位永久占用的故障。
#
# 注意 runAsUser：设备节点通常是 `brw-rw---- root:disk`，非 root 会被**文件权限**（不是 cgroup）
# 挡住。故两例都用 uid=0 + privileged:false + drop ALL，单独隔离「设备 cgroup」这一个变量。
phase_verify_device_plugin() {
  log "验证磁盘设备插件：kubelet 注册、节点可分配量、非特权按盘读取（含未授权对照）"
  ensure_cluster_ready
  local img="hlvm-storage-agent:dev" node="${NODE_NAME}" fail=0 i alloc logs

  ensure_agent_image "${img}"

  plugin_cleanup() {
    kc -n hlvm-system delete ds hlvm-disk-plugin --ignore-not-found >/dev/null 2>&1 || true
    # 测试 Pod 统一打 m15-probe 标签，按标签清理：新增用例时不必再改清理清单，
    # 也避免残留 Pod 占住盘位让下一次运行莫名其妙分不到盘。
    kc -n hlvm-system delete pod -l hlvm.io/m15-probe=true \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
  plugin_cleanup

  kc apply -f "${REPO_ROOT}/agent/config/daemonset-device-plugin.yaml" >/dev/null \
    || die "apply 设备插件 DaemonSet 失败"
  kc -n hlvm-system set image ds/hlvm-disk-plugin plugin="${img}" >/dev/null \
    || die "设置设备插件镜像失败"
  kc -n hlvm-system patch ds hlvm-disk-plugin --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
    >/dev/null || die "设置 imagePullPolicy 失败"

  if kc -n hlvm-system rollout status ds/hlvm-disk-plugin --timeout=180s >/dev/null 2>&1; then
    info "PASS: 设备插件 Pod 就绪"
  else
    fail_msg "FAIL: 设备插件 DaemonSet 未在 180s 内就绪"
    kc -n hlvm-system get pods -l app.kubernetes.io/component=disk-device-plugin 2>&1 | tail -3
    kc -n hlvm-system describe pod -l app.kubernetes.io/component=disk-device-plugin 2>&1 | tail -8
    fail=1
  fi

  # 1) 节点可分配量（kubelet 视角）。jsonpath 的 key 里含 '.'，必须转义。
  alloc=""
  for i in $(seq 1 30); do
    alloc="$(kc get node "${node}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
    if [[ "${alloc}" =~ ^[0-9]+$ ]] && [ "${alloc}" -gt 0 ]; then
      break
    fi
    sleep 2
  done
  if [[ "${alloc}" =~ ^[0-9]+$ ]] && [ "${alloc}" -gt 0 ]; then
    info "PASS: 节点 ${node} 可分配 hlvm.io/disk=${alloc}（注册与 ListAndWatch 生效）"
  else
    fail_msg "FAIL: 节点未出现 hlvm.io/disk 可分配量（当前='${alloc}'）"
    kc -n hlvm-system logs ds/hlvm-disk-plugin --tail=20 2>&1 \
      | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tail -12
    fail=1
  fi

  # 2) 申请到盘的非特权 Pod：能读该设备。
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-disk-alloc
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "for d in /dev/sd* /dev/nvme*; do [ -b \"\$d\" ] || continue; dd if=\"\$d\" of=/dev/null bs=512 count=1 >/dev/null 2>&1 && echo READ_OK=\$d; done"]
      resources:
        limits:
          hlvm.io/disk: 1
      securityContext:
        privileged: false
        runAsUser: 0
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF

  # 3) 对照 Pod：不申请资源，但把宿主 /dev 挂进来（与 exporter 的挂法一致）→ 应 EPERM。
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-disk-denied
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "for d in /hostdev/sd*; do [ -b \"\$d\" ] || continue; dd if=\"\$d\" of=/dev/null bs=512 count=1 2>&1; done"]
      securityContext:
        privileged: false
        runAsUser: 0
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: dev
          mountPath: /hostdev
          readOnly: true
  volumes:
    - name: dev
      hostPath:
        path: /dev
EOF

  # 两个 Pod 都是 restartPolicy: Never 的一次性任务，可能先 Ready 再 Succeeded，
  # 故等 phase 终态而非 Ready（等 Ready 会随机失败）。
  #
  # 终态判定要分开看：对照组**应当** Failed —— 它的最后一条命令就是失败的 dd，
  # 用 "phase==Succeeded" 统一要求会把「对照组正常工作」误判成失败（首次跑即踩到）。
  local pod phase alloc_phase=""
  for pod in m15-disk-alloc m15-disk-denied; do
    phase=""
    for i in $(seq 1 60); do
      phase="$(kc -n hlvm-system get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "${phase}" in Succeeded|Failed) break ;; esac
      sleep 2
    done
    if [ "${phase}" != "Succeeded" ] && [ "${phase}" != "Failed" ]; then
      fail_msg "FAIL: ${pod} 未在 120s 内到终态（phase='${phase}'）"
      kc -n hlvm-system describe pod "${pod}" 2>&1 | tail -8
      fail=1
    fi
    [ "${pod}" = "m15-disk-alloc" ] && alloc_phase="${phase}"
  done
  if [ "${alloc_phase}" != "Succeeded" ]; then
    fail_msg "FAIL: 申请资源的 Pod 未成功退出（phase='${alloc_phase}'）"
    fail=1
  fi

  logs="$(kc -n hlvm-system logs m15-disk-alloc 2>&1 || true)"
  if printf '%s' "${logs}" | grep -q "READ_OK="; then
    info "PASS: 非特权 Pod 申请到磁盘后可读（$(printf '%s' "${logs}" | grep -o 'READ_OK=[^ ]*' | head -1)）"
  else
    fail_msg "FAIL: 申请到磁盘的非特权 Pod 仍读不到设备"
    printf '%s\n' "${logs}" | tail -5
    fail=1
  fi

  logs="$(kc -n hlvm-system logs m15-disk-denied 2>&1 || true)"
  if printf '%s' "${logs}" | grep -q "Operation not permitted"; then
    info "PASS: 未申请资源的非特权 Pod 读同一设备仍 EPERM（证明授权来自按盘分配）"
  else
    fail_msg "FAIL: 对照组未出现 EPERM —— 该环境的设备 cgroup 未生效，上面的 PASS 不可信"
    printf '%s\n' "${logs}" | tail -5
    fail=1
  fi

  # 4) 容量账实一致：扩展资源的 `status.allocatable` 是**静态上限**——kubelet 不会因为分配
  #    而扣减它（真正的记账在调度器）。第一版按「allocatable 变小」写，实测占用期间仍是 2，
  #    断言本身就错了。改用**超发**证明三件事：
  #    ① 申请数 = 盘位时全部 Running；② 再多申请一个必须 Pending（容量账生效）；
  #    ③ 释放一个后它必须能 Running（设备真的回到了 kubelet，而不只是数字好看）。
  kc -n hlvm-system delete pod m15-disk-alloc m15-disk-denied \
    --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true

  local base="" n="" running=0 over="" ev=""
  for i in $(seq 1 30); do
    base="$(kc get node "${node}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
    [[ "${base}" =~ ^[0-9]+$ ]] && [ "${base}" -gt 0 ] && break
    sleep 2
  done
  [[ "${base}" =~ ^[0-9]+$ ]] && [ "${base}" -gt 0 ] \
    || die "无法读到基线可分配量（'${base}'），容量验证无法进行"

  if [ "${base}" -gt 4 ]; then
    info "跳过超发验证：盘位 ${base} 过多（不为此创建 ${base}+1 个 Pod）——本项在此环境未覆盖"
  else
    for n in $(seq 1 "${base}"); do
      kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-disk-hold-${n}
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
    hlvm.io/m15-role: hold
spec:
  restartPolicy: Never
  containers:
    - name: hold
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 300"]
      resources:
        limits:
          hlvm.io/disk: 1
      securityContext:
        privileged: false
        runAsUser: 0
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF
    done

    running=0
    for i in $(seq 1 90); do
      running="$(kc -n hlvm-system get pod -l hlvm.io/m15-role=hold \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | grep -c '^Running$' || true)"
      [ "${running}" = "${base}" ] && break
      sleep 2
    done
    if [ "${running}" = "${base}" ]; then
      info "PASS: 盘位用满时 ${base} 个申请者全部 Running（容量允许）"
    else
      fail_msg "FAIL: 只有 ${running}/${base} 个申请者 Running（容量不足以支撑 allocatable）"
      kc -n hlvm-system get pod -l hlvm.io/m15-role=hold 2>&1 | tail -4
      fail=1
    fi

    kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-disk-over
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
    hlvm.io/m15-role: over
spec:
  restartPolicy: Never
  containers:
    - name: over
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 120"]
      resources:
        limits:
          hlvm.io/disk: 1
      securityContext:
        privileged: false
        runAsUser: 0
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF

    # 超发那一个必须卡在 Pending；一旦 Running 就说明容量账失效（能超额分配）。
    over=""
    for i in $(seq 1 20); do
      over="$(kc -n hlvm-system get pod m15-disk-over -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [ "${over}" = "Running" ] && break
      sleep 2
    done
    if [ "${over}" = "Pending" ]; then
      ev="$(kc -n hlvm-system get events --field-selector involvedObject.name=m15-disk-over \
        -o jsonpath='{.items[*].message}' 2>/dev/null || true)"
      if printf '%s' "${ev}" | grep -q "Insufficient hlvm.io/disk"; then
        info "PASS: 超出盘位的申请被调度器拒绝（Insufficient hlvm.io/disk，容量账生效）"
      else
        info "PASS: 超出盘位的申请保持 Pending（容量账生效；未取到 Insufficient 事件文本）"
      fi
    else
      fail_msg "FAIL: 第 $((base + 1)) 个申请者未被拒绝（phase='${over}'）——容量上限未生效"
      fail=1
    fi

    # 释放一个盘位：超发 Pod 必须能起来。这一步才是「设备真的回到 kubelet」的证据。
    kc -n hlvm-system delete pod m15-disk-hold-1 --wait=true --timeout=90s >/dev/null 2>&1 || true
    for i in $(seq 1 90); do
      over="$(kc -n hlvm-system get pod m15-disk-over -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [ "${over}" = "Running" ] && break
      sleep 2
    done
    if [ "${over}" = "Running" ]; then
      info "PASS: 释放一个盘位后超发 Pod 转为 Running（设备已回池，不是只把数字还原）"
    else
      fail_msg "FAIL: 释放盘位后超发 Pod 仍未起来（phase='${over}'）——盘位未真正归还"
      kc -n hlvm-system describe pod m15-disk-over 2>&1 | tail -8
      fail=1
    fi
  fi

  plugin_cleanup
  if [ "${fail}" -ne 0 ]; then
    die "设备插件验证未通过（见上）"
  fi
  info "设备插件验证全部 PASS（注册 / 可分配量 / 按盘读取 / 未授权对照 / 容量上限与回收）"
}

# verify-collector：每盘一个 collector Pod（add-disk-device-plugin 6.1）。
#
# 解决什么：旧 exporter DaemonSet 以非 root 挂宿主 /dev，而块设备是 root:disk 0640，
# 非 root 打开即 EACCES，SMART 永远采不到。设备插件按盘授权后，collector 只保留
# uid 0 + SYS_RAWIO，不特权、不挂宿主 /dev。
#
# 诚实边界：kind 的 virtio 盘不支持 SMART，健康值会走文档化的回退（Healthy）；本阶段
# 证明「授权链路 / 指标端点 / 生命周期」，不声称「真实磁盘的 SMART 数值正确」。
phase_verify_collector() {
  log "验证每盘 collector：NodeDisk → 非特权按盘 Pod → /metrics → 删除回收"
  ensure_cluster_ready
  local img="hlvm-storage-agent:dev" node="${NODE_NAME}" fail=0
  local disk="m15-collector-disk" pod="" pf_pid="" metrics="" phase alloc="" gone=0

  ensure_agent_image "${img}"

  # 独立执行时不能假定已 bootstrap：collector 依赖命名空间级 pod 权限，缺了会只看到
  # `pods is forbidden` 且 Pod 永远不出现（首次跑即踩到，集群早于该 RBAC 文件创建）。
  kc apply -f "${CP}/config/rbac/collector_role.yaml" >/dev/null \
    || die "apply collector RBAC 失败"

  # kind 里 agent 镜像只在节点本地（GHCR 包私有），而 controller 默认镜像是
  # ghcr.io/f31/hlvm/storage-agent:latest——`:latest` 的默认拉取策略是 Always，
  # 会直接 401 并把 Pod 卡在 ImagePullBackOff（首次跑即踩到）。
  # 显式指向本地 dev 镜像（tag 非 latest ⇒ IfNotPresent），并等 controller 滚动完成。
  kc -n hlvm-system set env deploy/hlvm-storage-controller HLVM_AGENT_IMAGE="${img}" >/dev/null \
    || die "设置 HLVM_AGENT_IMAGE 失败"
  kc -n hlvm-system rollout status deploy/hlvm-storage-controller --timeout=180s >/dev/null \
    || die "controller 未完成滚动（collector 会用旧镜像配置）"

  collector_cleanup() {
    [ -n "${pf_pid}" ] && kill "${pf_pid}" >/dev/null 2>&1 || true
    kc delete nodedisk "${disk}" --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete pod -l component=storage-collector \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
  # 用 EXIT 而非 RETURN：RETURN 会在每个被调函数返回时触发，会把清理插到阶段中途。
  trap 'collector_cleanup' EXIT
  collector_cleanup

  # 1) collector 依赖扩展资源授权：设备插件未跑起来时，先补部署。
  alloc="$(kc get node "${node}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
  if ! [[ "${alloc}" =~ ^[0-9]+$ ]] || [ "${alloc}" -le 0 ]; then
    info "设备插件未就绪（allocatable='${alloc}'），先部署"
    kc apply -f "${REPO_ROOT}/agent/config/daemonset-device-plugin.yaml" >/dev/null \
      || die "apply 设备插件 DaemonSet 失败"
    kc -n hlvm-system set image ds/hlvm-disk-plugin plugin="${img}" >/dev/null \
      || die "设置设备插件镜像失败"
    kc -n hlvm-system patch ds hlvm-disk-plugin --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
      >/dev/null || die "设置 imagePullPolicy 失败"
    kc -n hlvm-system rollout status ds/hlvm-disk-plugin --timeout=180s >/dev/null 2>&1 \
      || die "设备插件未就绪（collector 无法获得磁盘授权）"
  fi
  for i in $(seq 1 30); do
    alloc="$(kc get node "${node}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
    [[ "${alloc}" =~ ^[0-9]+$ ]] && [ "${alloc}" -gt 0 ] && break
    sleep 2
  done
  [[ "${alloc}" =~ ^[0-9]+$ ]] && [ "${alloc}" -gt 0 ] \
    || die "节点 ${node} 无 hlvm.io/disk 可分配量（当前='${alloc}'）"
  info "节点可分配盘位=${alloc}"

  # 2) 建一个 NodeDisk，控制器应据此创建单个 collector Pod。
  cat <<EOF | kc apply -f - >/dev/null || die "创建 NodeDisk 失败"
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: ${disk}
spec:
  nodeName: ${node}
  deviceRef: /dev/sda
  adopt: false
EOF

  for i in $(seq 1 60); do
    pod="$(kc -n hlvm-system get pod -l component=storage-collector \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "${pod}" ] && break
    sleep 2
  done
  if [ -z "${pod}" ]; then
    fail_msg "FAIL: 控制器未创建 collector Pod"
    kc -n hlvm-system logs deploy/hlvm-storage-controller --tail=15 2>&1 | tail -12
    fail=1
    collector_cleanup
    die "collector 验证未通过（Pod 未创建）"
  fi
  info "collector Pod=${pod}"

  # 3) 资源与安全上下文：申请恰好 1 块盘，且不靠特权/挂宿主 /dev 取设备。
  local slot priv hostdevs
  slot="$(kc -n hlvm-system get pod "${pod}" -o jsonpath='{.spec.containers[0].resources.limits.hlvm\.io/disk}' 2>/dev/null || true)"
  [ "${slot}" = "1" ] && info "PASS: 申请 hlvm.io/disk=1" \
    || { fail_msg "FAIL: 资源申请不是 1 块盘（实际='${slot}'）"; fail=1; }

  priv="$(kc -n hlvm-system get pod "${pod}" -o jsonpath='{.spec.containers[0].securityContext.privileged}' 2>/dev/null || true)"
  [ "${priv}" = "false" ] && info "PASS: collector 非特权" \
    || { fail_msg "FAIL: collector privileged='${priv}'（应为 false）"; fail=1; }

  hostdevs="$(kc -n hlvm-system get pod "${pod}" -o jsonpath='{.spec.volumes[*].hostPath.path}' 2>/dev/null || true)"
  if printf '%s' "${hostdevs}" | tr ' ' '\n' | grep -qx '/dev'; then
    fail_msg "FAIL: collector 挂载了宿主 /dev（绕过了按盘分配）"
    fail=1
  else
    info "PASS: 未挂载宿主 /dev（设备由设备插件下发）"
  fi

  # 4) 就绪：readinessProbe 就是 /metrics，Ready 即端点可用。
  if kc -n hlvm-system wait --for=condition=Ready "pod/${pod}" --timeout=120s >/dev/null 2>&1; then
    info "PASS: collector 就绪"
  else
    fail_msg "FAIL: collector 未在 120s 内就绪"
    kc -n hlvm-system describe pod "${pod}" 2>&1 | tail -10
    fail=1
  fi

  # 5) 指标内容：心跳 + 一块盘的健康序列。用 port-forward 读，避免依赖镜像内有 curl。
  # `--noproxy` 不可省：WSL 会注入 HTTP_PROXY，curl 会把 127.0.0.1 也发给代理，
  # 回来的是代理的 400 页面（"plain HTTP request was sent to HTTPS port"），
  # 看起来像端点坏了，实际是本地请求被代理接管。
  kc -n hlvm-system port-forward "pod/${pod}" 19105:9105 >/dev/null 2>&1 &
  pf_pid=$!
  for i in $(seq 1 20); do
    metrics="$(curl -fsS --noproxy '*' --max-time 5 http://127.0.0.1:19105/metrics 2>/dev/null || true)"
    printf '%s' "${metrics}" | grep -q "storage_disk_smart_health" && break
    sleep 1
  done
  if printf '%s' "${metrics}" | grep -q "storage_agent_heartbeat"; then
    info "PASS: /metrics 返回心跳"
  else
    fail_msg "FAIL: /metrics 无心跳（端点不可用）"
    fail=1
  fi
  if printf '%s' "${metrics}" | grep -qE 'storage_disk_smart_health\{[^}]*device="(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+)"'; then
    info "PASS: 采集到实际分配到的那块盘（$(printf '%s' "${metrics}" \
      | grep -oE 'storage_disk_smart_health\{[^}]*\}' | head -1)）"
  else
    fail_msg "FAIL: 未出现盘级 SMART 序列（设备可能未挂入或采集侧未识别）"
    printf '%s\n' "${metrics}" | head -5
    fail=1
  fi

  # 6) 生命周期：删除 NodeDisk 后，Pod 必须被主动回收（跨作用域 ownerReference 不可用）。
  kc delete nodedisk "${disk}" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    if ! kc -n hlvm-system get pod "${pod}" >/dev/null 2>&1; then
      gone=1
      break
    fi
    sleep 2
  done
  if [ "${gone}" -eq 1 ]; then
    info "PASS: 删除 NodeDisk 后 collector Pod 已回收（无跨作用域 owner 泄漏）"
  else
    fail_msg "FAIL: NodeDisk 删除后 collector Pod 仍存在（需要 controller 主动清理）"
    fail=1
  fi

  # 7) 盘位保护：NodeDisk 多于可分配盘位时，多出来的必须**不创建 Pod**（而不是建一个永久
  #    Pending 的 Pod 占住调度位）；批量删除后必须全部回收。
  #    默认 MaxConcurrentReconciles=1，因此「先 List 再 Create」不会并发穿透；将来若提高
  #    并发，这里是最先会红的地方。
  local want=$((alloc + 1)) n=0 podn=0 runn=0 extra=0
  for n in $(seq 1 "${want}"); do
    cat <<EOF | kc apply -f - >/dev/null || die "创建盘位测试 NodeDisk 失败"
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: m15-slot-${n}
spec:
  nodeName: ${node}
  deviceRef: /dev/sda
  adopt: false
EOF
  done

  for i in $(seq 1 90); do
    runn="$(kc -n hlvm-system get pod -l component=storage-collector \
      -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | grep -c '^Running$' || true)"
    [ "${runn}" = "${alloc}" ] && break
    sleep 2
  done
  # 稳定期：多出来的那个若会被创建，也落在这一窗口内（控制器已按盘位跳过）。
  sleep 8
  podn="$(kc -n hlvm-system get pod -l component=storage-collector -o name 2>/dev/null | wc -l || true)"
  extra="$(kc -n hlvm-system get pod -l component=storage-collector \
    -o jsonpath='{range .items[*]}{.metadata.annotations.hlvm\.io/disk-name}{"\n"}{end}' 2>/dev/null \
    | grep -c "^m15-slot-${want}$" || true)"
  if [ "${podn}" -eq "${alloc}" ] && [ "${extra}" -eq 0 ]; then
    info "PASS: 盘位用尽后不再创建（${want} 个 NodeDisk 只生成 ${alloc} 个 collector，第 ${want} 个被挡住）"
  else
    fail_msg "FAIL: 盘位保护未生效（Pod 数=${podn}，期望 ${alloc}；第 ${want} 个盘的 Pod 数=${extra}）"
    kc -n hlvm-system get pod -l component=storage-collector -o wide 2>&1 | tail -5
    fail=1
  fi

  for n in $(seq 1 "${want}"); do
    kc delete nodedisk "m15-slot-${n}" --ignore-not-found >/dev/null 2>&1 || true
  done
  gone=0
  for i in $(seq 1 60); do
    podn="$(kc -n hlvm-system get pod -l component=storage-collector -o name 2>/dev/null | wc -l || true)"
    if [ "${podn}" -eq 0 ]; then gone=1; break; fi
    sleep 2
  done
  if [ "${gone}" -eq 1 ]; then
    info "PASS: 批量删除 NodeDisk 后 collector 全部回收（无残留）"
  else
    fail_msg "FAIL: 批量删除后仍有 ${podn} 个 collector 残留"
    fail=1
  fi

  collector_cleanup
  trap - EXIT
  if [ "${fail}" -ne 0 ]; then
    die "collector 验证未通过（见上）"
  fi
  info "collector 验证全部 PASS（按盘申请 / 非特权 / 指标端点 / 删除回收 / 盘位保护）"
}

usage() {
  sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
    verify-agent)      phase_verify_agent ;;
    verify-device-plugin) phase_verify_device_plugin ;;
    verify-collector)  phase_verify_collector ;;
    all)              phase_check; phase_bootstrap; phase_build; phase_verify_admission; phase_verify_controller; phase_verify_lvmd; phase_verify_taskgc; phase_verify_ttl; phase_verify_agent; phase_verify_device_plugin; phase_verify_collector ;;
    -h|--help|help)   usage ;;
    *) die "未知子命令: ${cmd}（可用: check/bootstrap/build/verify-admission/verify-controller/verify-lvmd/verify-taskgc/verify-ttl/verify-agent/verify-device-plugin/verify-collector/all）" ;;
  esac
}

main "$@"
