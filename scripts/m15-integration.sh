#!/usr/bin/env bash
#
# hlvm M15 集成引导脚本
#
# 目的：把 M15 递延项里「kind 可自动化覆盖」的部分固化为一键可执行流程，
#       其余依赖真实 LV / Velero / 评审灰度的项明确跳过（见 docs/m15-integration-runbook.md）。
#
# 子命令（默认 check，安全只读）：
#   check             仅前置检查：工具链 / 集群 / 版本 / CRD / cert-manager，不改动集群与 kubeconfig
#   preflight         首跑前的只读体检：控制面可达 / 节点 Ready / worker 不变量 / imagePullSecret /
#                     镜像标签可复现性 / 造盘钩子可执行 / 逐节点能力快照。结构性缺失 FAIL（非 0 退出），
#                     能力缺失只 WARN。真机首跑前应先单独跑它
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
#   verify-kubelet-restart  kubelet 重启后插件自愈重注册 + checkpoint 恢复（kind 用 docker，real 用 ssh 重启 CP 的 kubelet）
#   verify-device-hotplug  设备热插拔：ListAndWatch 增量推送、设备节点就绪才暴露、双向增减去留（kind 用 scsi_debug 造真整盘；real 需 M15_DISK_ATTACH_CMD，否则 SKIP）
#   verify-topology-scale  跨节点调度拓扑/容量账（6.5b 的本地可覆盖部分）：无选择子落容量节点、每节点独立填满、集群耗尽 Pending、释放后跨节点回调度（real 用节点上真实盘）
#   verify-conversion CRD 双版本 + conversion webhook：写入/读取路径转换、字段映射、列表转换、收敛后爆炸半径（临时切到 03b 双版本，结束恢复 bases 单版本 v1beta1）
#   verify-cert-rotation  serving 证书轮换：固定根 CA 使 caBundle 免重注入、证书热加载、Pod 不重启（含 selfSigned 反证）
#   verify-storage-migration  storedVersions 切换与回滚：etcd 直读判定落盘版本 / 控制器可写 / 字段完好 / 残留清理（破坏性，临时把 storage 切到 v1alpha1 再回滚 v1beta1）
#   verify-nodedisk-convergence  NodeDisk 收敛基线回归护栏：单版本 v1beta1 存储 / v1alpha1 不服务 / 裸资源名免转换读写（防双版本被悄悄带回导致裸名读空字段；破坏性相位之前先断言基线完好）
#   verify-velero   backup-restore 软件栈：Velero + minio 后端安装/BSL 连通/最小端到端备份恢复（kind 自包含；真实 LV CSI 快照与 RTO/RPO 留待真实测试集群）
#   all               上述 verify-* 顺序全跑（conversion / cert-rotation / storage-migration 放最后：它们会临时改写 NodeDisk CRD）
#
# 环境变量：
#   M15_TARGET=kind|real（默认 kind）。real 表示真实集群（kubeadm / 云主机），此时：
#     - 不创建/检查 kind 集群，不构建也不 load 镜像（节点直接从 IMG_REGISTRY 拉）；
#     - 节点上的操作走 `ssh $M15_SSH_USER@<InternalIP>` 而不是 `docker exec`；
#     - 被测节点自动选 worker（kind 下是 control-plane），etcd/kubelet 类操作仍打 CP；
#     - 造盘/拔盘必须由 M15_DISK_ATTACH_CMD / M15_DISK_DETACH_CMD 提供，
#       未提供时热插拔相位 SKIP（不 FAIL）；拓扑相位用节点上已有的真实盘。
#   KCTX=（real 必填）真实集群的 kubeconfig context；kind 默认 kind-<CLUSTER_NAME>
#   M15_SSH_USER=root  M15_SSH_PORT=22  M15_SSH_KEY=~/.ssh/id_ed25519  M15_SSH_EXTRA_OPTS=
#   M15_SKIP_BUILD=（real 默认 1；kind 默认 0）跳过 build，使用 IMG_REGISTRY 里的镜像
#   CLUSTER_NAME=hlvm-kind  NODE_IMAGE=kindest/node:v1.36.1
#   M15_SINGLE_NODE=1（默认 0）显式声明「集群只有 1 个节点，且它就是控制面」。
#     设了才按单节点跑；未设而实测没有 worker 仍判 FAIL（不做静默降级）。
#     代价写在结论里：verify-topology-scale 显式 SKIP（无跨节点拓扑可验），
#     preflight 记录「本次结论不含跨节点调度」。kind 下自动改用单节点集群配置。
#   IMG_REGISTRY=ghcr.io/f31/hlvm  IMG_TAG=latest（real 模式用 latest 会被 preflight 判 FAIL；
#                                   确要试跑时设 M15_ALLOW_LATEST=1，但该结论不可复现）
#   M15_GHCR_PUBLIC=1（默认 0）显式声明该 registry 下的 4 个包已设为 public、走匿名拉取：
#     preflight 跳过 ghcr-pull 检查，但会从控制面逐个实测匿名 pull token HTTP 200，否则仍 FAIL
#     （公开包匿名 GET manifest 也会 401，不能拿它当私有判据）。
#     汇总会标注「不覆盖 registry 鉴权链路」；不设时缺 secret 一律 FAIL（不静默降级）。
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

# 目标环境：kind（默认，本地 WSL）| real（真实集群，kubeadm / 云主机）。
#
# 两种目标的差异只有三处，全部收敛到下面的抽象函数里，相位代码不再直接感知：
#   ① 节点上的 shell 执行：kind = `docker exec <容器>`；real = `ssh <user>@<InternalIP>`。
#   ② 镜像装载：kind = `kind load docker-image`；real = 不装载（节点直接从 IMG_REGISTRY 拉）。
#   ③ 造盘/拔盘：kind = `modprobe scsi_debug`；real = 外部钩子（云 API / virsh attach-disk）。
# 这样同一套断言在两边跑，结论才可比——否则「kind 绿、真机红」永远分不清是环境还是产品。
M15_TARGET="${M15_TARGET:-kind}"

# 单节点模式：**必须显式声明**，不做「检测到只有一个节点就自动降级」。
#
# 为什么禁止静默检测：本套脚本的很多断言依赖「被测节点 ≠ 控制面」「节点之间容量独立」。
# 若因为「只剩一台机器」就自动跳过跨节点相位，环境削掉一层会表现为「测试变少但全绿」，
# 与真实回归无法区分。所以这里只有一个开关：设了才按单节点跑，并**同步收窄结论范围**
# （preflight 记录、拓扑相位显式 SKIP、runbook 写清未覆盖项）。
#
# 值与实际不匹配一律判 FAIL：声明单节点却实测 N>1 个节点，会让本该验证的跨节点拓扑被跳过。
M15_SINGLE_NODE="${M15_SINGLE_NODE:-0}"

CLUSTER_NAME="${CLUSTER_NAME:-hlvm-kind}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.36.1}"
IMG_REGISTRY="${IMG_REGISTRY:-ghcr.io/f31/hlvm}"
# 单节点模式默认用单节点 kind 配置：用 3 节点配置建的集群有 2 个 worker，
# 里面「验证单节点部署」要么断言不到重点，要么直接与 preflight 的节点数断言冲突。
if [ "${M15_SINGLE_NODE}" = "1" ] && [ -z "${KIND_CONFIG:-}" ]; then
  KIND_CONFIG="${SCRIPT_DIR}/kind-config-single.yaml"
else
  KIND_CONFIG="${KIND_CONFIG:-${SCRIPT_DIR}/kind-config.yaml}"
fi
IMG_TAG="${IMG_TAG:-latest}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
LOCK_TIER="${LOCK_TIER:-data}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
# real 模式必须显式给 KCTX（真实集群的 context 名由 kubeadm/云厂商决定，猜不出来）。
KCTX="${KCTX:-kind-${CLUSTER_NAME}}"
# 无本机 Rust 时容器内 cargo 走代理（kind 节点/容器内访问宿主代理，见 runbook §7.1）。
AGENT_BUILD_PROXY="${AGENT_BUILD_PROXY:-}"

# real 模式的节点访问参数。默认 root + 22；密钥为空时走 ssh-agent / 默认密钥。
M15_SSH_USER="${M15_SSH_USER:-root}"
M15_SSH_PORT="${M15_SSH_PORT:-22}"
M15_SSH_KEY="${M15_SSH_KEY:-}"
M15_SSH_EXTRA_OPTS="${M15_SSH_EXTRA_OPTS:-}"
# real 模式是否跳过 build（默认跳过：镜像应由 CI 推 IMG_REGISTRY，节点直接拉；
# 在测试机上现编镜像既慢又会因缺 Rust 工具链失败）。真实集群要现编时显式设 0。
M15_SKIP_BUILD="${M15_SKIP_BUILD:-}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
# 断言失败结果必须落在 stdout：审计按 stdout 数 PASS/FAIL，走了 stderr 就会「看起来全绿」。
fail_msg() { printf '\033[1;31m    %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# 显式指定 context，避免隐式切换用户当前 kubeconfig 上下文。
kc() { kubectl --context "${KCTX}" "$@"; }

# ---------------------------------------------------------------------------
# 环境抽象层（kind / real）
#
# 相位代码只调 node_exec / image_load / disk_*，不直接写 docker exec / kind load /
# modprobe scsi_debug。这层存在的唯一目的：让「同一套断言」在本地 kind 与真实集群上
# 跑出可比结论；否则每处 kind 专属写法都是一次「真机上悄悄跳过」的机会。
# ---------------------------------------------------------------------------
is_real() { [ "${M15_TARGET}" = "real" ]; }
# 单节点模式（见 M15_SINGLE_NODE 定义处）。相位代码只在「结论范围会变」的两处看它：
# 被测节点选择、跨节点拓扑相位。其余断言一视同仁——单节点不该降低任何单机断言的强度。
is_single_node() { [ "${M15_SINGLE_NODE}" = "1" ]; }

# real 默认不构建（镜像来自 CI）；kind 默认构建（本地 GHCR 包私有，节点拉不到）。
if [ -z "${M15_SKIP_BUILD}" ]; then
  if is_real; then M15_SKIP_BUILD=1; else M15_SKIP_BUILD=0; fi
fi

# 节点名 → InternalIP。real 模式 ssh 要用它；kind 模式不关心。
# 缓存一次：同一相位里对同一节点通常要执行十几条命令，没必要重复打 apiserver。
declare -A M15_NODE_IP_CACHE=()
node_ip() {
  local node="$1"
  if [ -n "${M15_NODE_IP_CACHE[${node}]:-}" ]; then
    printf '%s' "${M15_NODE_IP_CACHE[${node}]}"
    return 0
  fi
  local ip
  ip="$(kc get node "${node}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')"
  [ -n "${ip}" ] || return 1
  M15_NODE_IP_CACHE[${node}]="${ip}"
  printf '%s' "${ip}"
}

# 在节点上执行一条 shell 命令（单字符串），透传 stdout/stderr 与退出码。
# 调用点统一写成 node_exec <节点名> '<命令>'，两种目标的语义完全一致。
node_exec() {
  local node="$1"; shift
  local cmd="$*"
  if is_real; then
    local ip
    ip="$(node_ip "${node}")" || die "无法解析节点 ${node} 的 InternalIP（kubectl get node ${node} -o wide）"
    # 用数组拼参数：路径含空格时 `${VAR:+-i "$VAR"}` 在分词后会被拆开，
    # 表现为 ssh 把路径前半段当主机名，报 Could not resolve hostname。
    local opts=(-p "${M15_SSH_PORT}"
      -o BatchMode=yes -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
    if [ -n "${M15_SSH_KEY}" ]; then
      opts+=(-i "${M15_SSH_KEY}")
    fi
    if [ -n "${M15_SSH_EXTRA_OPTS}" ]; then
      # 用户显式提供的附加参数按空格分词是预期行为
      # shellcheck disable=SC2206
      opts+=(${M15_SSH_EXTRA_OPTS})
    fi
    ssh "${opts[@]}" "${M15_SSH_USER}@${ip}" "${cmd}"
  else
    docker exec "${node}" sh -c "${cmd}"
  fi
}

# 控制面节点名。
# 「被测节点」与「控制面」在 real 模式下是两台不同的机器：etcd 探测、kubelet 重启
# 只能打在 CP 上，而容量/热插拔断言要打在 worker 上。kind 下二者恒等，但代码不应
# 依赖这个巧合——否则 real 模式会把 etcd 请求发到 worker，得到「证书路径不存在」。
control_plane_node() {
  if ! is_real; then
    printf '%s' "${CLUSTER_NAME}-control-plane"
    return 0
  fi
  local n=""
  n="$(kc get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
  [ -n "${n}" ] || n="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  printf '%s' "${n}"
}

# 把本机构建出的镜像送进集群。
# kind：必须 load（本地 tag 不在任何 registry 里，节点拉不到）。
# real：什么都不做——节点直接从 IMG_REGISTRY 拉；此处多此一举反而掩盖鉴权问题。
image_load() {
  local img="$1"
  if is_real; then
    info "real 模式：不装载镜像 ${img}（节点从 ${IMG_REGISTRY} 拉取，需 imagePullSecret）"
    return 0
  fi
  kind load docker-image "${img}" --name "${CLUSTER_NAME}" >/dev/null || die "kind load 失败（${img}）"
}

# 造/拔一块盘。返回非 0 表示「本环境不支持自动造盘」，调用方按 SKIP 处理而不是 FAIL。
# kind：scsi_debug 造出真正的整盘（type=disk、/sys/block 可见），与物理插拔在内核层同类事件。
# real：必须由外部提供（云盘 attach / virsh attach-disk），脚本不猜云厂商 API。
disk_inject() {
  local node="$1"
  if is_real; then
    # set -u：未提供钩子时必须走「SKIP」分支，不能因未定义变量把整个相位崩掉
    # （2026-11-11 真机实测：preflight 已 WARN 会 SKIP，到这里却 unbound variable）。
    [ -n "${M15_DISK_ATTACH_CMD:-}" ] || return 1
    # 钩子约定：$1 = 节点名，$2 = InternalIP；由用户在环境里提供实现。
    M15_DISK_ATTACH_CMD "${node}" "$(node_ip "${node}" || true)" || return 1
    return 0
  fi
  node_exec "${node}" 'modprobe scsi_debug dev_size_mb=64 num_parts=0' >/dev/null 2>&1 || return 1
}

disk_eject() {
  local node="$1"
  if is_real; then
    [ -n "${M15_DISK_DETACH_CMD:-}" ] || return 1
    M15_DISK_DETACH_CMD "${node}" "$(node_ip "${node}" || true)" || return 1
    return 0
  fi
  node_exec "${node}" 'rmmod scsi_debug' >/dev/null 2>&1 || return 0
}

# 造盘能力是否可用（决定热插拔类相位跑还是 SKIP）。
disk_inject_available() {
  if is_real; then
    [ -n "${M15_DISK_ATTACH_CMD:-}" ]
  else
    have docker
  fi
}

require_tools() {
  local missing=0 c
  local tools=(kubectl helm)
  # real 不需要 kind/docker：集群不是本机起的，镜像也不在本机 load。
  if is_real; then
    tools+=(ssh)
  else
    tools+=(kind docker)
  fi
  for c in "${tools[@]}"; do
    if have "$c"; then info "已安装: $c"; else warn "缺少: $c"; missing=1; fi
  done
  if [ "$missing" -ne 0 ]; then
    if is_real; then
      die "工具链不完整（real 模式需要 kubectl / helm / ssh）"
    else
      die "工具链不完整；本脚本应在 WSL/Linux 且具备 docker daemon 的环境运行"
    fi
  fi
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
  info "目标环境: ${M15_TARGET}$(is_real && printf '（节点经 ssh %s@<InternalIP>:%s 访问）' "${M15_SSH_USER}" "${M15_SSH_PORT}")"
  if is_single_node; then
    info "部署形态: 单节点（M15_SINGLE_NODE=1）——verify-topology-scale 将 SKIP，结论不含跨节点调度"
  fi
  require_tools

  if is_real; then
    # real：集群不是本机起的，判断依据只有「context 能否连上、版本是否达标」。
    if context_exists; then
      local minor; minor="$(server_minor)"
      if [ -z "${minor:-}" ]; then
        warn "context ${KCTX} 存在但 API server 不可达（检查 kubeconfig 凭据 / 6443 连通性）"
      else
        info "server minor: ${minor}"
        if [ "${minor}" -lt 36 ]; then
          warn "集群 minor=${minor} < 36，与目标 1.36 存在版本差（准入/VAP 语义可能不同）"
        fi
        local nn; nn="$(kc get nodes --no-headers 2>/dev/null | wc -l || echo 0)"
        info "节点数: ${nn}"
        kc get ns hlvm-system >/dev/null 2>&1 && info "hlvm-system: 已存在" || info "hlvm-system: 未创建"
        kc get crd nodevgs.storage.example.io >/dev/null 2>&1 && info "CRD: 已安装" || info "CRD: 未安装"
        kc get ns cert-manager >/dev/null 2>&1 && info "cert-manager: 已安装" || info "cert-manager: 未安装"
        kc -n hlvm-system get deploy hlvm-storage-webhook >/dev/null 2>&1 \
          && info "storage-webhook: 已部署" || info "storage-webhook: 未部署"
        # 真实集群的镜像是**拉**的，不是 load 的：凭据缺失会一路 ImagePullBackOff 到验收相位。
        if [ "${M15_GHCR_PUBLIC:-0}" = "1" ]; then
          info "imagePullSecret ghcr-pull: 已声明 M15_GHCR_PUBLIC=1（匿名拉取；preflight 会逐个实测 pull token 可达）"
        elif kc -n hlvm-system get secret ghcr-pull >/dev/null 2>&1; then
          info "imagePullSecret ghcr-pull: 已存在"
        else
          warn "imagePullSecret ghcr-pull 缺失：${IMG_REGISTRY} 为私有包，节点会 ImagePullBackOff（runbook §7）"
        fi
      fi
    else
      warn "context ${KCTX} 不存在：real 模式不会建集群，请先导出真实集群的 kubeconfig 或指定 KCTX"
    fi
  elif kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
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

# ---------------------------------------------------------------------------
# preflight：首跑前的只读体检（不改集群、不装东西、不需要 root 之外的特权）
#
# 存在理由：`check` 只回答「context 能不能连上」，而真机首跑的失败几乎都发生在别处——
# ssh 打不通、私有镜像没凭据、云盘早被格式化、节点上没有 udev。这些要到第 5~15 个相位
# 才以「产品缺陷」的样子爆出来（ImagePullBackOff / by-id 为空 / VG 建不出来），
# 归因成本极高。preflight 把它们压缩成一次扫描，每条都写清「后果 + 受影响相位」。
#
# 断言分级（本节最重要的设计决定）：
#   FAIL = 结构性缺失，本次结论必然不可信：
#          ssh 不通 / 没有 worker（被测节点会退化成 CP）/ 私有镜像无 imagePullSecret /
#          拿 :latest 跑验收（结论不可复现）/ 造盘钩子给了但不可执行（相位静默 SKIP）。
#   WARN = 能力缺失，某相位会 SKIP 或断言退化，但其余结论仍有效。
#
# **能力快照一律 WARN，绝不打 FAIL**：实测 kind 节点 dm_thin_pool=no、lvm=no、
# /dev/disk/by-id 空、swap 开着，却照样跑出 120 PASS——agent 镜像内自带工具、盘由
# scsi_debug 造。把这几个静态量当门禁，等于用一个从没验证过的代理指标卡自己，
# 还会让「kind 绿、真机红」更不可解释；它们的价值是解释性，不是判定性。
phase_preflight() {
  log "0/5 预检（只读）：首跑前的环境体检"
  require_tools

  local fail=0 pwarn=0 pass=0

  # 1) 控制面可达性 + 版本
  if ! context_exists; then
    fail_msg "FAIL: context ${KCTX} 不存在（real 模式不会建集群：先导出真实集群 kubeconfig 或设 KCTX）"
    die "预检未通过：集群不可达，后续相位无法进行（tools/集群见上）"
  fi
  local minor; minor="$(server_minor)"
  if [ -z "${minor:-}" ]; then
    fail_msg "FAIL: context ${KCTX} 存在但 API server 不可达（凭据过期 / 6443 不通 / 节点 kubelet 挂了）"
    die "预检未通过：API server 不可达"
  fi
  if [ "${minor}" -ge 36 ]; then
    info "PASS: API server 可达，minor=${minor}（≥36，与目标一致）"
    pass=$((pass + 1))
  else
    # 可达性成立，但版本差不是「通过」：给 WARN 即可，不要同时打 PASS 制造两个信号。
    pwarn=$((pwarn + 1))
    warn "API server 可达但 minor=${minor} < 36：准入/VAP 语义与目标存在版本差，断言可能因语义差异误判（集群已在服务，故不判 FAIL）"
  fi

  # 2) 节点清单 + 角色不变量
  local nodes workers cp
  nodes="$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  workers="$(kc get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  cp="$(control_plane_node)"
  local notready
  notready="$(kc get nodes -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
  info "节点: ${nodes} 个（worker=${workers}，控制面=${cp:-未识别}）"
  if [ "${nodes}" -ge 1 ]; then
    info "PASS: 集群内至少有 1 个节点"
    pass=$((pass + 1))
  else
    fail_msg "FAIL: 集群内没有任何节点"
    fail=$((fail + 1))
  fi
  if [ -n "${notready// /}" ]; then
    fail_msg "FAIL: 节点未 Ready：${notready}（后续镜像/CRD 投放会卡在这些节点上）"
    fail=$((fail + 1))
  else
    info "PASS: 全部节点 Ready"
    pass=$((pass + 1))
  fi
  # 被测节点 ≠ 控制面是 real 模式的硬不变量：kind 下二者重合是巧合（单节点默认去 taint），
  # 真机上若没有 worker，pick_test_node 会回退到 CP，容量/热插拔/拓扑断言全部失去意义。
  #
  # 单节点模式是**显式豁免**，不是自动降级：用户声明了 M15_SINGLE_NODE=1 才走到下面这枝，
  # 且必须同时满足「实测节点数确实是 1」+「结论里写明少了哪一层验证」。
  if is_single_node; then
    if [ "${nodes}" -eq 1 ]; then
      info "PASS: 单节点模式（M15_SINGLE_NODE=1）与实测节点数一致（1 个）"
      pass=$((pass + 1))
    else
      # 声明单节点却有多节点：本该验证的跨节点拓扑会被 SKIP，等于用谎报的环境换取「变少但全绿」。
      fail_msg "FAIL: M15_SINGLE_NODE=1 但实测 ${nodes} 个节点——单节点模式会跳过跨节点拓扑断言，环境与声明不符时结论不可信（要么去掉该开关，要么换单节点集群）"
      fail=$((fail + 1))
    fi
    warn "单节点模式：verify-topology-scale 将显式 SKIP（每节点独立容量账 / 跨节点回调度无对象可验），本次结论不含跨节点调度"
  elif is_real; then
    if [ "${workers}" -ge 1 ]; then
      info "PASS: 存在独立 worker（real 模式下被测节点不会退化为控制面）"
      pass=$((pass + 1))
    else
      fail_msg "FAIL: real 模式没有任何 worker 节点——被测节点会退化成控制面，容量/热插拔/拓扑断言不成立（确为单节点部署请显式设 M15_SINGLE_NODE=1，并接受拓扑相位 SKIP）"
      fail=$((fail + 1))
    fi
  fi

  # 3) 镜像供给（real 才致命：kind 的镜像是本地 load 的，不看 registry）
  #
  # 两条互斥路径，**不做静默检测**（包可见性变了不该悄悄改变结论覆盖范围）：
  #   私有包（默认）→ 必须有 hlvm-system/ghcr-pull；
  #   公开包（显式 M15_GHCR_PUBLIC=1）→ 无需 secret，但必须逐个实测匿名 pull token。
  #
  # 判据为什么用 token 端点而不是 manifest：GHCR 遵循 OCI Bearer challenge，**公开包**
  # 直接匿名 GET /v2/.../manifests/... 同样返回 401（WWW-Authenticate 要求先取 token）；
  # 实测区分只在 `ghcr.io/token?scope=...:pull`：公开 200 / 私有 401
  # （2026-11-11 用已知公开包 topolvm/topolvm 对照验证）。
  # 4 个包逐个探，避免「只公开了其中 1 个」被整体放行。tag 是否存在由部署相位验证。
  if is_real; then
    if [ "${M15_GHCR_PUBLIC:-0}" = "1" ]; then
      local repo img code bad
      repo="${IMG_REGISTRY#ghcr.io/}"
      bad=""
      for img in storage-controller storage-webhook storage-agent crd-conversion; do
        code="$(node_exec "${cp}" "curl -sS -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:${repo}/${img}:pull&service=ghcr.io'" 2>/dev/null | tail -1 || true)"
        if [ "${code}" != "200" ]; then
          bad="${bad}${bad:+ }${img}=${code:-无响应}"
        fi
      done
      if [ -z "${bad}" ]; then
        info "PASS: 4 个包的匿名 pull token 均可达（HTTP 200，${repo}/* 已公开）"
        pass=$((pass + 1))
        pwarn=$((pwarn + 1))
        warn "M15_GHCR_PUBLIC=1：跳过 imagePullSecret ghcr-pull，本次结论不覆盖 registry 鉴权链路（不得据此声称私有包部署已验收）"
      else
        fail_msg "FAIL: 声明 M15_GHCR_PUBLIC=1 但以下包匿名 pull token 不可达：${bad}——包仍私有或控制面出网异常，节点会 ImagePullBackOff"
        fail=$((fail + 1))
      fi
    elif kc -n hlvm-system get secret ghcr-pull >/dev/null 2>&1; then
      info "PASS: imagePullSecret ghcr-pull 存在"
      pass=$((pass + 1))
    else
      fail_msg "FAIL: 缺 imagePullSecret ghcr-pull——${IMG_REGISTRY} 是私有包，节点会一路 ImagePullBackOff（若已把包设为 public，显式设 M15_GHCR_PUBLIC=1）"
      fail=$((fail + 1))
    fi
    if [ "${IMG_TAG}" = "latest" ]; then
      if [ "${M15_ALLOW_LATEST:-0}" = "1" ]; then
        # 放行不等于可复现：latest 会被下一次 main 推送覆盖，绝不能拿这种结论去汇报或验收。
        pwarn=$((pwarn + 1))
        warn "IMG_TAG=latest 已按 M15_ALLOW_LATEST=1 放行：本次结论不可复现，不得用于验收/汇报"
      else
        fail_msg "FAIL: IMG_TAG=latest——latest 会被下一次 main 推送覆盖，用它跑出的验收结论无法复现"
        info "      用发布的版本标签（如 IMG_TAG=vX.Y.Z，当前为 v0.1.0-preview.2）；确要试跑 latest 时设 M15_ALLOW_LATEST=1"
        fail=$((fail + 1))
      fi
    else
      info "PASS: 镜像标签 ${IMG_TAG}（精确版本引用，结论可复现）"
      pass=$((pass + 1))
    fi
    # 静态清单把 controller/webhook 写成 :latest（kind 靠它配合本地 load）。只校验环境变量
    # 是不够的：若 bootstrap 没把集群里的实际引用对齐到 IMG_TAG，验收跑的就是 latest，
    # 而 latest 会被下一次 main 推送覆盖 ——「精确版本」就成了假断言。已部署时逐项核对。
    local want_c want_w got_c got_w
    want_c="${IMG_REGISTRY}/storage-controller:${IMG_TAG}"
    want_w="${IMG_REGISTRY}/storage-webhook:${IMG_TAG}"
    if kc -n hlvm-system get deployment hlvm-storage-controller >/dev/null 2>&1; then
      got_c="$(kc -n hlvm-system get deploy hlvm-storage-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
      got_w="$(kc -n hlvm-system get deploy hlvm-storage-webhook -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
      if [ "${got_c}" = "${want_c}" ] && [ "${got_w}" = "${want_w}" ]; then
        info "PASS: 已部署镜像与 IMG_TAG 一致（${IMG_TAG}）"
        pass=$((pass + 1))
      else
        fail_msg "FAIL: 已部署镜像与 IMG_TAG 不一致：controller=${got_c:-无} webhook=${got_w:-无}；期望 ${want_c} / ${want_w}——重跑 bootstrap 对齐"
        fail=$((fail + 1))
      fi
    fi
  fi

  # 4) 造盘钩子：给了但不可执行 = 热插拔相位静默 SKIP 而 all 仍绿，这是最难发现的一类
  local h
  for h in M15_DISK_ATTACH_CMD M15_DISK_DETACH_CMD; do
    local v="${!h:-}"
    [ -n "${v}" ] || continue
    if have "${v}"; then
      info "PASS: ${h}=${v} 可执行"
      pass=$((pass + 1))
    else
      fail_msg "FAIL: ${h}=${v} 不可执行——disk_inject 会返回非 0，热插拔相位将静默 SKIP 而 all 仍报绿"
      fail=$((fail + 1))
    fi
  done
  if [ -z "${M15_DISK_ATTACH_CMD:-}" ]; then
    if is_real; then
      pwarn=$((pwarn + 1))
      warn "未提供 M15_DISK_ATTACH_CMD：verify-device-hotplug 将 SKIP（热插拔覆盖缺失，但不算失败）"
    fi
  fi

  # 5) 逐节点能力快照（一次 node_exec 拿全，避免十几次 ssh 往返；失败即该节点不可达）
  local n snap
  for n in $(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    if ! snap="$(node_exec "${n}" 'printf "kernel=%s\n" "$(uname -r)"; printf "cgroup=%s\n" "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"; printf "swap=%s\n" "$(awk "NR>1" /proc/swaps 2>/dev/null | wc -l)"; printf "thin=%s\n" "$(grep -qw dm_thin_pool /proc/modules && echo yes || echo no)"; printf "byid=%s\n" "$(ls /dev/disk/by-id 2>/dev/null | wc -l)"; printf "lvm=%s\n" "$(command -v lvm >/dev/null && echo yes || echo no)"; printf "udev=%s\n" "$(command -v udevadm >/dev/null && echo yes || echo no)"; printf "inotify=%s\n" "$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"' 2>&1)"; then
      fail_msg "FAIL: 节点 ${n} 不可达（$(is_real && echo "ssh ${M15_SSH_USER}@$(node_ip "${n}" || echo '<IP未解析>')" || echo 'docker exec')）：节点级断言会全部跳过"
      info "      ${snap}"
      fail=$((fail + 1))
      continue
    fi
    local k cg sw thin byid lvm udev ino
    k="$(printf '%s\n' "${snap}" | sed -n 's/^kernel=//p')"
    cg="$(printf '%s\n' "${snap}" | sed -n 's/^cgroup=//p')"
    sw="$(printf '%s\n' "${snap}" | sed -n 's/^swap=//p')"
    thin="$(printf '%s\n' "${snap}" | sed -n 's/^thin=//p')"
    byid="$(printf '%s\n' "${snap}" | sed -n 's/^byid=//p')"
    lvm="$(printf '%s\n' "${snap}" | sed -n 's/^lvm=//p')"
    udev="$(printf '%s\n' "${snap}" | sed -n 's/^udev=//p')"
    ino="$(printf '%s\n' "${snap}" | sed -n 's/^inotify=//p')"
    info "PASS: 节点 ${n} 可达（kernel=${k} cgroup=${cg}）"
    pass=$((pass + 1))

    if [ "${cg}" != "cgroup2fs" ]; then
      pwarn=$((pwarn + 1))
      warn "${n}: cgroup=${cg}（非 v2）。K8s 1.36 已移除 cgroup v1 支持，kubelet 可能起不来或资源核算异常"
    fi
    if [ "${sw:-0}" -gt 0 ] 2>/dev/null; then
      pwarn=$((pwarn + 1))
      warn "${n}: 启用 ${sw} 个 swap 条目。kubelet 若 failSwapOn=true 会拒绝启动（集群已在跑则说明已设 failSwapOn: false，属已知取舍）"
    fi
    if [ "${thin}" != "yes" ]; then
      pwarn=$((pwarn + 1))
      warn "${n}: dm_thin_pool 未加载。真实 LV thin 相关相位（dmeventd/autoextend/打满）会 SKIP；确认后可 modprobe"
    fi
    if [ "${byid:-0}" -eq 0 ] 2>/dev/null; then
      pwarn=$((pwarn + 1))
      if is_real; then
        warn "${n}: /dev/disk/by-id 为空。设备 ID 将退化为 dev-<name>，6.2 的 by-id 断言不可能成立（真机出现此告警要查 udev/云盘 WWN）"
      else
        warn "${n}: /dev/disk/by-id 为空（kind 节点无 udev，属已知限制；6.2 by-id 断言在 kind 上本就不可覆盖）"
      fi
    fi
    if [ "${lvm}" != "yes" ]; then
      pwarn=$((pwarn + 1))
      warn "${n}: 节点上无 lvm 命令（agent 镜像内自带时不影响；bare-metal 自编镜像需确认 lvm2 已装）"
    fi
    if [ "${udev}" != "yes" ]; then
      pwarn=$((pwarn + 1))
      warn "${n}: 无 udevadm（/dev/disk/by-id 与热插拔事件可能都不可用）"
    fi
    if [ "${ino:-0}" -lt 512 ] 2>/dev/null; then
      pwarn=$((pwarn + 1))
      warn "${n}: inotify max_user_instances=${ino} < 512（多相位 Pod 密集创建时可能 EMFILE）"
    fi
  done

  # 6) 真实集群专属：storage-migration 相位直读 etcd，需要 CP 上的 etcd PKI 可读
  if is_real && [ -n "${cp}" ]; then
    if node_exec "${cp}" 'test -r /etc/kubernetes/pki/etcd/server.crt' >/dev/null 2>&1; then
      info "PASS: 控制面 ${cp} 上 etcd PKI 可读（verify-storage-migration 的 etcd 直读依赖）"
      pass=$((pass + 1))
    else
      pwarn=$((pwarn + 1))
      warn "控制面 ${cp} 读不到 /etc/kubernetes/pki/etcd/server.crt：verify-storage-migration 的落盘版本判定会失败（非 kubeadm 布局需调整）"
    fi
  fi

  info "数据盘深度判定（只读，逐节点）：bash scripts/real-cluster/disk-precheck.sh"

  info "预检汇总：PASS=${pass} WARN=${pwarn} FAIL=${fail}"
  if [ "${fail}" -ne 0 ]; then
    die "预检发现 ${fail} 项结构性缺失：修掉再跑，否则后面的 PASS 也不可信（见上）"
  fi
  local tail_msg=""
  if [ "${pwarn}" -gt 0 ]; then
    tail_msg="（${pwarn} 项能力缺失已列出：对应相位会 SKIP 或断言退化，其余结论仍有效）"
  fi
  info "预检通过：结构性前置全部满足${tail_msg}"
}

# ensure_node_running 确保 kind 节点容器处于运行态。
#
# 背景（实测 2026-10-30）：Docker Desktop / WSL VM 重启后，kind 节点容器**没有 restart policy**，
# 会停在 Exited (128)；但 `kind get clusters` 仍然列出该集群（它按容器标签查找，不看容器状态）。
# 于是脚本误判「集群存在」并直接进入 apply/wait，全部以 connection refused 失败，
# 日志里看不出根因；手工 `docker start` 即可恢复。
ensure_node_running() {
  # real 模式没有「本机节点容器」这一层：节点是独立主机，起不来就是起不来，
  # 脚本能做且该做的只有等 API 就绪，不要把 docker 缺失当成错误。
  if is_real; then
    local i
    for i in $(seq 1 45); do
      if kc get --raw /readyz >/dev/null 2>&1; then
        info "API server 就绪（real 模式，跳过节点容器自愈）"
        return 0
      fi
      sleep 2
    done
    die "API server 在 90s 内未就绪：检查控制面节点 kubelet / etcd / 6443 连通性"
  fi

  have docker || die "需要 docker 检查 kind 节点容器状态"
  # **必须遍历所有节点容器**，不能只 start control-plane。
  # 实测（2026-11-02）：WSL 重启后只有 CP 被拉起，worker 停在 Exited(128)，
  # 表现为 worker NotReady + 该节点上的 Pod 永久 Terminating（kubectl wait 因此无出口，
  # 整个 all 挂死在第 2/5 步，日志只停在「重建 kube-proxy」那一行）。
  local containers
  containers="$(docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null || true)"
  [ -n "${containers}" ] || die "找不到 kind 集群 ${CLUSTER_NAME} 的节点容器：\
集群元数据与容器不一致（建议 kind delete cluster --name ${CLUSTER_NAME} 后重建）"

  local c st
  for c in ${containers}; do
    st="$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo missing)"
    case "${st}" in
      running) info "节点容器 ${c}: running" ;;
      exited|created|paused)
        warn "节点容器 ${c} 状态=${st}（Docker/WSL 重启后 kind 无 restart policy，不会自愈），自动启动"
        docker start "${c}" >/dev/null \
          || die "启动 ${c} 失败；docker logs ${c} 可定位"
        ;;
      missing) warn "容器 ${c} 在节点列表里但 inspect 不到，跳过" ;;
      *) warn "节点容器 ${c} 状态异常: ${st}" ;;
    esac
  done

  local i
  for i in $(seq 1 45); do
    if kc get --raw /readyz >/dev/null 2>&1; then
      info "API server 就绪"
      break
    fi
    sleep 2
  done
  # API 就绪 ≠ 节点就绪：刚 start 的节点要几十秒才回到 Ready，期间 Pod 会被打成
  # NotReady/Terminating，验证相位读到的都是噪声。这里做一次有界等待（失败只告警）。
  local want actual
  want="$(printf '%s\n' "${containers}" | grep -c . || true)"
  for i in $(seq 1 60); do
    actual="$(kc get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)"
    if [ "${actual:-0}" -ge "${want:-1}" ]; then
      info "节点就绪 ${actual}/${want}"
      return 0
    fi
    sleep 3
  done
  warn "节点就绪 ${actual:-0}/${want:-1}（仍有 NotReady，后续断言可能受噪声影响）"
  return 0
  die "API server 在 90s 内未就绪：docker logs ${container} 可查（inotify/kube-proxy 见 runbook §7.2）"
}

# 验证阶段统一入口：节点容器自愈 → API 就绪 → 节点可读。
#
# 独立执行 verify-* 时不应依赖「先跑过 bootstrap」。实测 Docker Desktop 重启后 kind 节点
# 容器停在 Exited(128)（kind 无 restart policy），而 API 刚起来时 RBAC 尚未就绪，会瞬时
# 返回 `nodes is forbidden`；两者都会表现为「未找到任何节点」，极易误判为集群数据丢失。
NODE_NAME=""

# 被测节点选择。
# kind：沿用 items[0]（按名字排序即 control-plane），且多节点回归基线是按它建立的，不能动。
# real：必须避开控制面。真机 CP 通常不挂数据盘、也不该承载被测盘位；固定挑一个 worker，
#       「容量账 / 热插拔 / 拓扑」才反映工作负载节点的真实情况。
pick_test_node() {
  local out=""
  # 单节点模式：唯一节点既是控制面也是被测节点。显式走这枝，而不是依赖 real 分支
  # 「worker 列表为空 → 回退 items[0]」的副作用——否则以后改 worker 选择逻辑，
  # 单节点语义会被静默改掉，而脚本不会报错。
  if is_single_node; then
    out="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    printf '%s' "${out}"
    return 0
  fi
  if is_real; then
    out="$(kc get nodes -l '!node-role.kubernetes.io/control-plane' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
  fi
  if [ -z "${out}" ]; then
    out="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  printf '%s' "${out}"
}

ensure_cluster_ready() {
  context_exists || die "context ${KCTX} 不存在"
  ensure_node_running
  local i out
  for i in $(seq 1 20); do
    out="$(pick_test_node)"
    if [ -n "${out}" ]; then
      NODE_NAME="${out}"
      if is_single_node; then
        info "单节点模式：被测节点 = 控制面 ${NODE_NAME}（etcd/kubelet/容量断言全部打在同一台）"
      fi
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
  # inotify 上限是节点**内核**参数，两种目标都需要；区别只在「怎么进节点」和「改几个节点」。
  local nodes=""
  if is_real; then
    nodes="$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    [ -n "${nodes}" ] || return 0
  else
    have docker || return 0
    docker inspect "${CLUSTER_NAME}-control-plane" >/dev/null 2>&1 || return 0
    nodes="${CLUSTER_NAME}-control-plane"
  fi

  local node cur
  for node in ${nodes}; do
    cur="$(node_exec "${node}" 'sysctl -n fs.inotify.max_user_instances' 2>/dev/null || true)"
    if [ -z "${cur}" ]; then
      warn "无法读取节点 ${node} 的 inotify 限制，跳过"
      continue
    fi
    if [ "${cur}" -ge 2048 ]; then
      info "节点 ${node} inotify.max_user_instances=${cur}（充足）"
      continue
    fi

    warn "节点 ${node} inotify.max_user_instances=${cur} < 2048：kube-proxy 可能因 too many open files 崩溃"
    if ! node_exec "${node}" \
      'printf "fs.inotify.max_user_instances=2048\nfs.inotify.max_user_watches=1048576\n" > /etc/sysctl.d/99-hlvm.conf && sysctl -p /etc/sysctl.d/99-hlvm.conf' \
      >/dev/null 2>&1; then
      warn "写入 sysctl 失败（需要节点 root），请手工执行 runbook §7.2 的命令"
      continue
    fi
    info "节点 ${node} 已提升并持久化至 /etc/sysctl.d/99-hlvm.conf"
  done

  # 已经崩溃的 kube-proxy 不会自愈，必须重建才会重新编程 Service 规则。
  local bad
  bad="$(kc -n kube-system get pods -l k8s-app=kube-proxy \
    -o jsonpath='{range .items[*]}{.status.phase}/{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
    | grep -vc '^Running/true$' || true)"
  if [ "${bad:-0}" -gt 0 ]; then
    warn "检测到 kube-proxy 非就绪，重建 kube-proxy 与 CoreDNS"
    # 必须 --wait=false：kubectl delete 默认等对象消失；节点 kubelet 掉线时 Pod 会长期
    # Terminating，这里就变成一个没有超时的挂起点（2026-11-02 实测卡死 11 分钟）。
    kc -n kube-system delete pod -l k8s-app=kube-proxy --wait=false >/dev/null 2>&1 || true
    kc -n kube-system delete pod -l k8s-app=kube-dns --wait=false >/dev/null 2>&1 || true
    if kc -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-proxy --timeout=150s >/dev/null 2>&1; then
      info "kube-proxy 已恢复"
    else
      warn "kube-proxy 未在 150s 内就绪，后续验证可能整体失败"
    fi
  fi
}

# NodeDisk CRD 的存储版本已从 v1alpha1 收敛到 v1beta1（add-hardening-rollout 3.1e）。
# 这让 bootstrap 撞上一个真实的升级约束：K8s 拒绝移除「曾经是存储版本、且仍记录在
# status.storedVersions 里」的版本——
#     must remain in spec.versions until ... removes v1alpha1 from status.storedVersions
# 而 bases 现在只剩 v1beta1，等于要移除 v1alpha1，所以复用旧集群时 bootstrap 必然失败。
#
# 处理按「有没有数据」分叉，刻意不做静默破坏：
#   - 一个 NodeDisk 对象都没有 ⇒ 旧 CRD 里没有需要保全的数据，删 CRD 重建即可
#     （storedVersions 随 CRD 一起消失，这是唯一无需走迁移就能归位的路径）；
#   - 有对象 ⇒ **拒绝继续**，要求先跑 runbook 里的存储版本迁移流程
#     （双版本 -> 重写对象 -> 清理 storedVersions）。这里的集群可能有别人的数据，
#     擅自删 CRD 会连对象一起带走，代价远大于让人手动处理这一回。
ensure_nodedisk_crd_baseline() {
  local crd="nodedisks.storage.example.io"
  kc get crd "${crd}" >/dev/null 2>&1 || return 0        # 全新集群：直接 apply 即可
  local versions="" leftover=0 n=0 v=""
  versions="$(kc get crd "${crd}" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || true)"
  [ "${versions}" = "v1beta1" ] && return 0              # 已是目标基线
  # 逐个 served 版本枚举对象：不用裸资源名，避免被 discovery 缓存带到已下线的版本上。
  for v in ${versions}; do
    n="$(kc get "nodedisks.${v}.storage.example.io" --all-namespaces \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)"
    leftover=$((leftover + n))
  done
  if [ "${leftover}" -gt 0 ]; then
    die "集群里仍有 ${leftover} 个 NodeDisk（当前 CRD 版本：${versions}），而目标基线只剩 v1beta1。K8s 不允许在 status.storedVersions 未清理时移除旧版本，bootstrap 不会替你删数据——请先按 runbook 完成存储版本迁移（双版本 → 重写对象 → 清理 storedVersions）。"
  fi
  if ! kc delete crd "${crd}" --wait=true --timeout=120s >/dev/null 2>&1; then
    die "无法移除旧 NodeDisk CRD（${versions}）以切到 v1beta1 基线"
  fi
  rm -rf "${HOME}/.kube/cache/discovery" 2>/dev/null || true
  info "NodeDisk CRD 基线升级：${versions} → v1beta1（集群内无 NodeDisk 对象，删 CRD 重建）"
}

phase_bootstrap() {
  log "2/5 集群"
  if is_real; then
    # real：集群由 scripts/real-cluster/ 的 kubeadm 流程建好，这里只做「接入 + 装平台组件」。
    # 仍要 context_exists 断言：否则后续每个 kc 调用都会以难以归因的报错出现。
    info "real 模式：复用真实集群（不执行 kind create）"
    context_exists || die "context ${KCTX} 不存在；real 模式需先准备集群（见 scripts/real-cluster/README.md）"
  elif kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    info "复用已有集群 ${CLUSTER_NAME}"
    # bootstrap 可单独执行（不经过 preflight），所以单节点声明与集群规模的冲突在这里也挡一次。
    # 复用 3 节点集群跑单节点模式 = 拓扑相位被 SKIP 而环境其实可验，是最坏的那种「静默少测」。
    if is_single_node; then
      local existing
      existing="$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep -c . || true)"
      if [ "${existing}" != "1" ]; then
        die "M15_SINGLE_NODE=1 需要单节点集群，但 ${CLUSTER_NAME} 现有 ${existing} 个节点。请先 kind delete cluster --name ${CLUSTER_NAME} 再重跑（或去掉该开关）"
      fi
      info "单节点模式：集群 ${CLUSTER_NAME} 恰有 1 个节点"
    fi
  else
    info "创建 kind 集群 ${CLUSTER_NAME} (${NODE_IMAGE})，配置 ${KIND_CONFIG}"
    kind create cluster --name "${CLUSTER_NAME}" --image "${NODE_IMAGE}" --config "${KIND_CONFIG}" --wait 180s
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
  # 必须在 apply CRD 之前：旧集群的 NodeDisk 可能还是 v1alpha1 存储，直接 apply 会被护栏拒绝。
  ensure_nodedisk_crd_baseline
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
  if is_real; then
    # 静态清单的镜像写死 :latest（kind 流程靠 cp_build + image_load 命中本地镜像）。
    # real 模式不构建、不 load，直接沿用会让 preflight 的「精确版本 IMG_TAG」变成假断言：
    # 集群实际拉的是 latest，而 latest 会被下一次 main 推送覆盖，结论不可复现。
    # 显式对齐到 IMG_TAG；all 里的 phase_build 只改 imagePullPolicy，不会把 tag 覆盖回去。
    local want_c want_w
    want_c="${IMG_REGISTRY}/storage-controller:${IMG_TAG}"
    want_w="${IMG_REGISTRY}/storage-webhook:${IMG_TAG}"
    kc -n hlvm-system patch deployment hlvm-storage-controller --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${want_c}\"}]" \
      >/dev/null || die "对齐 controller 镜像标签失败（${want_c}）"
    kc -n hlvm-system patch deployment hlvm-storage-webhook --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${want_w}\"}]" \
      >/dev/null || die "对齐 webhook 镜像标签失败（${want_w}）"
    info "real 模式：controller/webhook 镜像已对齐 ${IMG_TAG}（清单默认 :latest）"
  fi
  if is_single_node; then
    # 单机部署形态：清单默认 2/2/3 副本是为多节点设计的，单节点上照样能全部 Running
    # （软 spread 不会让人 Pending），但 3 份 webhook 挤一台机器既不真实也浪费资源。
    # 这里缩到 1 副本——这是**测试环境贴合单机形态**的动作，不是产品默认值；
    # PDB 是 maxUnavailable=1，1 副本下仍允许 1 次自愿中断（不会像 minAvailable=2 那样卡死 drain）。
    kc -n hlvm-system scale deployment hlvm-storage-controller --replicas=1 >/dev/null 2>&1 \
      || warn "controller 缩容到 1 副本失败（保持清单副本数）"
    kc -n hlvm-system scale deployment hlvm-storage-webhook --replicas=1 >/dev/null 2>&1 \
      || warn "webhook 缩容到 1 副本失败（保持清单副本数）"
    info "单节点模式：controller/webhook 各 1 副本（单机部署形态；PDB maxUnavailable=1 仍允许 1 次中断）"
  fi
  if is_real; then
    if [ "${M15_GHCR_PUBLIC:-0}" = "1" ]; then
      info "bootstrap 完成（real：镜像 ${IMG_REGISTRY}:${IMG_TAG} 匿名拉取；不执行 build/load）"
    else
      info "bootstrap 完成（real：镜像 ${IMG_REGISTRY}:${IMG_TAG} 需 imagePullSecret ghcr-pull；不执行 build/load）"
    fi
  else
    info "bootstrap 完成（镜像需 build 阶段加载，否则 Deployment 拉取 GHCR 镜像）"
  fi
}

phase_build() {
  log "构建并加载镜像"
  if [ "${M15_SKIP_BUILD}" = "1" ]; then
    info "跳过构建（M15_SKIP_BUILD=1；镜像应由 CI 推 ${IMG_REGISTRY}:${IMG_TAG}）"
    if is_real; then
      # 跳过 build 时仍要把拉取策略设为 Always（镜像 tag 对齐由 phase_bootstrap 负责）——
      # 否则测试机上的旧镜像缓存可能让结论与声明的 tag 不符。
      kc -n hlvm-system patch deployment hlvm-storage-controller --type=json \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]' 2>/dev/null || true
      kc -n hlvm-system patch deployment hlvm-storage-webhook --type=json \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]' 2>/dev/null || true
      info "已把 controller/webhook 的 imagePullPolicy 设为 Always（避免命中节点旧缓存）"
    fi
    return 0
  fi
  have docker || die "docker 不可用，无法构建镜像"
  [ -f "${CP}/Dockerfile" ] || die "缺少 ${CP}/Dockerfile"
  local extra=()
  if [ -n "${RUNTIME_IMAGE}" ]; then
    extra+=(--build-arg "RUNTIME_IMAGE=${RUNTIME_IMAGE}")
    info "运行态基础镜像覆盖: ${RUNTIME_IMAGE}（仅本地验证）"
  fi
  # 构建代理由 cp_build 统一管理：首次尝试带、回退重试不带。
  # 不在调用方各自拼 --build-arg，否则「回退时去掉代理」要在每个调用点重复一次。
  if [ -n "${M15_BUILD_PROXY:-}" ]; then info "构建代理: ${M15_BUILD_PROXY}"; fi
  cp_build storage-controller "${IMG_REGISTRY}/storage-controller:${IMG_TAG}" "${extra[@]}" \
    || die "storage-controller 镜像构建失败"
  cp_build storage-webhook "${IMG_REGISTRY}/storage-webhook:${IMG_TAG}" "${extra[@]}" \
    || die "storage-webhook 镜像构建失败"
  image_load "${IMG_REGISTRY}/storage-controller:${IMG_TAG}"
  image_load "${IMG_REGISTRY}/storage-webhook:${IMG_TAG}"
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
  local fail=0

  # 1) 证书注入链路：MutatingWebhookConfiguration.caBundle 必须由 cert-manager 注入。
  local ca
  ca="$(kc get mutatingwebhookconfiguration hlvm-storage-webhook-mutating \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)"
  if [ -n "${ca}" ]; then
    info "cert-manager 已注入 caBundle（长度 ${#ca}）"
  else
    fail_msg "FAIL: caBundle 为空：cert-manager 未生效或 webhook 配置未 apply"
    fail=1
  fi

  # 1b) caBundle 必须能验证 webhook 实际在用的证书。这条是 2026-10-30 补的：
  # 当天把 webhook 证书从 selfSigned 换到固定 CA 时，MutatingWebhookConfiguration 的
  # caBundle 在 1s 内就更新了，而 Pod 挂载里的证书要等 kubelet 同步（实测约 60s）；
  # 中间这段时间 apiserver 拿新 CA 校验旧证书 → 握手失败。由于清单里
  # `failurePolicy: Ignore`，失败被**静默吞掉**：Pod 照建、只是没有被注入。
  # 而本阶段原来对「未注入」只打 warn，退出码仍是 0 —— 等于没断言。现在两处都改成失败。
  if have openssl && [ -n "${ca}" ]; then
    local tmpw; tmpw="$(mktemp -d)"
    kc -n hlvm-system get secret hlvm-storage-webhook-serving-cert \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "${tmpw}/leaf.crt" 2>/dev/null || true
    printf '%s' "${ca}" | base64 -d > "${tmpw}/ca.crt" 2>/dev/null || true
    if [ -s "${tmpw}/leaf.crt" ] && [ -s "${tmpw}/ca.crt" ] \
       && openssl verify -CAfile "${tmpw}/ca.crt" "${tmpw}/leaf.crt" >/dev/null 2>&1; then
      info "PASS: caBundle 能验证 webhook serving 证书（链匹配，不存在失配窗口）"
    else
      fail_msg "FAIL: caBundle 与 serving 证书不匹配——握手会失败，且被 failurePolicy=Ignore 静默吞掉"
      fail=1
    fi
    rm -rf "${tmpw}" 2>/dev/null || true
  else
    warn "无 openssl，跳过证书链校验（该条未覆盖）"
  fi

  # 2) 构造平台 SC + NodeVG + PVC + 引用该 PVC 的 Pod；检查 mutator 是否注入锁标签 nodeAffinity。
  #    NodeVG 用于让 PVC 校验 webhook 判定该 tier 有可用节点（否则 PVC CREATE 会被拒绝）。
  local node_name
  node_name="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  kc create namespace m15-verify --dry-run=client -o yaml | kc apply -f - >/dev/null
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1beta1
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

  # 2b) 创建 Pod 前必须等 webhook 的 Service **endpoints 就绪**。
  #     webhook 清单是 `failurePolicy: Ignore`：apiserver 调不通时会**静默放行**，Pod 照建、
  #     只是没被注入——断言失败看起来像「mutator 坏了」，实际是 webhook 刚滚动完还没接上。
  #     （2026-11-01 实测：bootstrap 滚动 webhook Deployment 后立刻跑本相位，就撞上这一条。）
  local svc_name eps i
  svc_name="$(kc get mutatingwebhookconfiguration hlvm-storage-webhook-mutating \
    -o jsonpath='{.webhooks[0].clientConfig.service.name}' 2>/dev/null || true)"
  svc_name="${svc_name:-hlvm-storage-webhook}"
  eps=""
  for i in $(seq 1 30); do
    eps="$(kc -n hlvm-system get endpoints "${svc_name}" \
      -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
    [ -n "${eps}" ] && break
    sleep 2
  done
  if [ -n "${eps}" ]; then
    info "webhook Service ${svc_name} 已有就绪 endpoints（admission 调用可达）"
  else
    warn "webhook Service ${svc_name} 无就绪 endpoints——failurePolicy=Ignore 会静默放行，注入可能落空"
  fi

  # 2c) 注入断言本身也做有界重试：endpoints 刚 ready 时首个请求仍可能落到旧连接/新 Pod 未完成
  #     证书加载的窗口。失败即删 Pod 重建（至多 3 次），避免一次窗口期抖动打挂整个 `all`。
  local expect="storage.example.io/${LOCK_TIER}-locked" aff attempt
  aff=""
  for attempt in 1 2 3; do
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
    aff="$(kc -n m15-verify get pod m15-pod \
      -o jsonpath='{.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[*].key}' 2>/dev/null || true)"
    if printf '%s' "${aff}" | grep -q "${expect}"; then break; fi
    if [ "${attempt}" -lt 3 ]; then
      warn "第 ${attempt} 次创建 Pod 未被注入（webhook 可能刚滚动完），删除重建后重试"
      kc -n m15-verify delete pod m15-pod --ignore-not-found --wait=true --timeout=30s >/dev/null 2>&1 || true
      sleep 3
    fi
  done

  if printf '%s' "${aff}" | grep -q "${expect}"; then
    info "PASS: mutator 已注入 ${expect} 的 nodeAffinity 排除表达式"
  else
    # 曾经这里是 warn，于是「证书失配 → 静默不注入」也能让本阶段退出码为 0。
    fail_msg "FAIL: 未检测到注入的锁标签表达式（实际 keys: ${aff:-<空>}）"
    fail_msg "排查：webhook Pod 是否 Ready、caBundle 与 serving 证书是否匹配（窗口期常见）、Service endpoints 是否就绪"
    fail=1
  fi

  local node
  node="$(kc -n m15-verify get pod m15-pod -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  info "Pod spec.nodeName = '${node:-<未调度>}'（kind 无 TopoLVM CSI，PVC 不绑定属预期；真实调度排除需真环境复验）"

  # 清理
  kc delete namespace m15-verify --wait=false >/dev/null 2>&1 || true
  kc delete storageclass "topolvm-${LOCK_TIER}" >/dev/null 2>&1 || true
  kc delete nodevg m15-verify-vg --wait=false >/dev/null 2>&1 || true
  if [ "${fail}" -ne 0 ]; then
    die "admission 验证未通过（见上）"
  fi
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
apiVersion: storage.example.io/v1beta1
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
apiVersion: storage.example.io/v1beta1
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
apiVersion: storage.example.io/v1beta1
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
apiVersion: storage.example.io/v1beta1
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

  # 1b) ownerReference.apiVersion 必须按 owner 类型动态取（全部 5 个 Kind 现均为 v1beta1）：GC 靠它定位 owner。
  #     单测 storage_task_controller_test.go 已覆盖此映射，这里在真实集群端到端复验（回归护栏）。
  #     2026-11-10 修正：消费者全迁 v1beta1 后旧断言仍期望 v1alpha1，会在 bases 单版本下恒 FAIL。
  local vgAPI
  vgAPI="$(kc get storagetask "${task}" -o jsonpath='{.metadata.ownerReferences[0].apiVersion}' 2>/dev/null || true)"
  if [ "${vgAPI}" = "storage.example.io/v1beta1" ]; then
    info "PASS: ownerReference.apiVersion 动态取值正确（NodeVG→v1beta1）"
  else
    fail_msg "FAIL: ownerReference.apiVersion 应为 v1beta1（实际=${vgAPI:-<空>}；若仍写 v1alpha1 会让 GC 按旧版本找不到 owner）"
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
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: ${disk}
spec:
  nodeName: ${node}
  adopt: true
  device:
    path: /dev/m15-taskgc-disk
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
    # NodeDisk 已收敛到 v1beta1(storage)：ownerReference.apiVersion 必须随之用 v1beta1，否则 GC 按
    # v1alpha1 找不到拥有者（单版本基线下根本没有 v1alpha1 NodeDisk）。真实集群端到端复验此映射。
    local diskAPI
    diskAPI="$(kc get storagetask "${dtask}" -o jsonpath='{.metadata.ownerReferences[0].apiVersion}' 2>/dev/null || true)"
    if [ "${diskAPI}" = "storage.example.io/v1beta1" ]; then
      info "PASS: ownerReference.apiVersion 动态取值正确（NodeDisk→v1beta1）"
    else
      fail_msg "FAIL: ownerReference.apiVersion 应为 v1beta1（实际=${diskAPI:-<空>}；误写 v1alpha1 会让 GC 找不到 owner）"
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
apiVersion: storage.example.io/v1beta1
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
  # 注入构建提交号（与 CI 的 HLVM_GIT_COMMIT 一致），否则 agent 启动日志里 commit=unknown。
  local commit
  commit="${M15_GIT_COMMIT:-}"
  [ -n "${commit}" ] || commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "${commit}" ] || commit="unknown"
  info "容器内 cargo build --release（首次约 1 分钟，之后走卷缓存）"
  docker run --rm \
    -v "${REPO_ROOT}/agent:/src" -w /src \
    -e CARGO_TARGET_DIR=/target -e CARGO_HOME=/usr/local/cargo \
    -e HLVM_GIT_COMMIT="${commit}" \
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
# 被测 agent 的镜像引用：kind 用本地构建 tag，real 用仓库 tag（CI 产物）。
# 抽成函数是因为 6 个相位各自声明了 img 变量——模式差异必须收敛到一处，
# 否则每加一个相位就会漏一次「real 模式还在用本地 tag」。
agent_image() {
  if is_real; then
    printf '%s' "${IMG_REGISTRY}/storage-agent:${IMG_TAG}"
  else
    printf '%s' "hlvm-storage-agent:dev"
  fi
}

ensure_agent_image() {
  local img="${1:-hlvm-storage-agent:dev}"
  # real：镜像由 CI 推到 IMG_REGISTRY，节点自己拉；本地既没有 Rust 工具链也没有必要现编。
  # 这里只做「引用是否正确」的提示，不阻断——真正的失败会在 Pod 的 ImagePullBackOff 上暴露。
  if is_real; then
    info "real 模式：agent 镜像使用 ${img}（仓库镜像，不本地构建）"
    return 0
  fi
  have docker || die "需要 docker（构建/装载本地镜像）"
  ensure_agent_binary
  info "构建本地镜像 ${img}（GHCR 包为私有，kind 内不能直接拉）"
  docker build -q -t "${img}" "${REPO_ROOT}/agent" >/dev/null || die "docker build 失败"
  image_load "${img}"
}

# 把清单里写死的 hlvm 镜像行渲染成目标 tag 后再 apply。
#
# 为什么不能用「先 apply 再 set image」：apply 那一刻 kubelet 就按清单里的 `:latest`
# 开始拉镜像（storage-agent 单层 ~396MB，真机实测 2m59s）；DaemonSet 没有 Deployment
# 那样的滚动缓冲，旧 Pod 未退场时 `rollout status --timeout=180s` 必然超时，表现得像
# 「设备插件起不来」的**产品缺陷**，实际是镜像 tag 的中间态。kind 因为已 `kind load`
# 过 `:latest`，永远暴露不到这个问题（2026-11-11 真机 verify-device-plugin 实测）。
# 保留调用处的 `set image` 作为兜底：清单若无匹配行（例如改用非 hlvm 镜像名），
# 行为退回到原来的两步走，不会比修之前更差。
apply_manifest_with_image() {
  local file="$1" img="$2"
  sed -E "s|^([[:space:]]*image:[[:space:]]*)[^[:space:]]*hlvm[^[:space:]]*|\1${img}|" "${file}" \
    | kc apply -f - >/dev/null
}

# 统一的 control-plane 镜像构建：先按调用方给的 build-arg 构建；若失败原因只是
# 默认运行态基础镜像（gcr.io/distroless/static:nonroot）拉取不到，则自动回退
# RUNTIME_IMAGE=scratch 重试一次。
#
# 为什么需要自动回退：WSL 本地 docker daemon 的代理指向 127.0.0.1:7892（无监听），
# buildkit 解析 distroless manifest 会 `Head ... EOF` / TLS handshake timeout。这个失败
# 是**环境**问题不是代码问题，但此前要靠外部 `RUNTIME_IMAGE=scratch` 环境变量规避，
# 漏设就会在某个阶段换来假失败（2026-10-30 全量 all 走到 verify-conversion 才炸）。
#
# 判据只认 manifest/网络类报错或构建超时；编译错误原样失败、不吞，避免把真实回归掩盖掉。
# 注意两个实测陷阱：
#   - 外部探测（manifest inspect / buildx imagetools）与 build 内的 load metadata 走不同
#     代理路径，实测 imagetools 3s 可达但 build 内仍 EOF，故不能用外部探测预判；
#   - 不要 `docker buildx prune -af` 清缓存来做验证：它会连 Dockerfile 第一行
#     `# syntax=docker/dockerfile:1` 的 front-end 一起清掉，制造出比真实场景更极端的失败
#     （front-end token EOF），而 front-end 与 RUNTIME_IMAGE 无关，回退到 scratch 也救不了。
# scratch 可用的前提：仓库 Go 二进制均为 CGO_ENABLED=0 静态链接（见 Dockerfile）。
# CP_RUNTIME_FALLBACK：本轮是否已判定「默认基础镜像不可达、需回退 scratch」。
# 首个 cp_build 探测一次并记住，后续镜像直接走 scratch，避免每个都白等一次长超时。
CP_RUNTIME_FALLBACK=""
# 首次默认构建的超时（秒）。离线环境 buildkit 解析 distroless manifest 可能挂起，
# TERM 后 15s 再 KILL，确保一定能退出并进入回退判定。
# 默认 480s：本环境容器内代理单请求约 5s，冷缓存下 `go mod download` 需下载全部依赖，
# 150s 实测不够（两次都超时并被误判为需要回退）。给足余量，热缓存时仍然秒级完成。
CP_BUILD_TIMEOUT="${CP_BUILD_TIMEOUT:-480}"
# 参数：$1=CMD_NAME $2=镜像tag；其余参数原样透传给 docker build（含代理等 build-arg）。
cp_build() {
  local cmd="$1" tag="$2"; shift 2
  local logf rc ver commit bdate
  # 版本三元组：与 CI 镜像保持同一注入方式，否则本地/集成验证跑的是 `dev`，
  # 「版本可追溯」只在 CI 产物上成立——排查时无法区分镜像是哪次构建。
  ver="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION" 2>/dev/null || true)"
  [ -n "${ver}" ] || ver="dev"
  # 提交号优先用 m15-wsl.sh 下传的 M15_GIT_COMMIT：WSL 副本排除了 .git，本地 git 命令必失败。
  commit="${M15_GIT_COMMIT:-}"
  [ -n "${commit}" ] || commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "${commit}" ] || commit="unknown"
  bdate="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local base_args=(-f "${CP}/Dockerfile" --build-arg "CMD_NAME=${cmd}" \
    --build-arg "VERSION=${ver}" --build-arg "COMMIT=${commit}" \
    --build-arg "BUILD_DATE=${bdate}")

  # 构建代理只用于**首次尝试**。回退/重试一律不带：
  # 走到回退说明「带代理的那次已经失败了」，沿用同一代理只会把同样的失败重演一遍
  # （2026-11-02 实测：探测 curl 200，但 go mod download 经它 read: connection reset by peer，
  #  连试 5 次 × 35s 才失败）。去掉代理后缓存命中即可构建成功，真缺依赖会给出明确错误。
  local proxy_args=()
  if [ -n "${M15_BUILD_PROXY:-}" ]; then
    proxy_args=(--build-arg "HTTP_PROXY=${M15_BUILD_PROXY}" \
                --build-arg "HTTPS_PROXY=${M15_BUILD_PROXY}" \
                --build-arg "NO_PROXY=${NO_PROXY:-}")
  fi

  # 已判定不可达：直接走 scratch（不带代理），跳过必然挂起的默认尝试。
  if [ -z "${RUNTIME_IMAGE}" ] && [ "${CP_RUNTIME_FALLBACK}" = "scratch" ]; then
    logf="$(mktemp)"
    timeout --kill-after=15s "${CP_BUILD_TIMEOUT}" \
      docker build "${base_args[@]}" "$@" --build-arg "RUNTIME_IMAGE=scratch" \
      -t "${tag}" "${CP}" >"${logf}" 2>&1
    rc=$?
    if [ "${rc}" -eq 0 ]; then rm -f "${logf}"; return 0; fi
    sed -r 's/\x1B\[[0-9;]*[mK]//g' "${logf}" >&2 | tail -40
    rm -f "${logf}"
    return "${rc}"
  fi

  # 首次：默认基础镜像，带代理，timeout 封顶。
  logf="$(mktemp)"
  timeout --kill-after=15s "${CP_BUILD_TIMEOUT}" \
    docker build "${base_args[@]}" "$@" "${proxy_args[@]}" -t "${tag}" "${CP}" >"${logf}" 2>&1
  rc=$?
  if [ "${rc}" -eq 0 ]; then rm -f "${logf}"; return 0; fi

  # 回退判定必须只认「基础镜像/front-end 解析或授权」这一类网络错误。
  # 不能把「纯超时 rc=124」也算进来：本环境慢代理下冷缓存的 `go mod download` 会超时，
  # 而回退 scratch 一样要跑 go mod download（超时照样发生），徒劳重试还会掩盖真正原因。
  # 单纯超时没有任何下列错误文本时，直接失败并打印 buildkit 输出。
  if [ -z "${RUNTIME_IMAGE}" ] \
     && grep -qiE "load metadata for|TLS handshake timeout|failed to do request|failed to authorize|failed to fetch anonymous token|resolve image config|dial tcp|proxyconnect|context deadline exceeded|i/o timeout|connection reset by peer|connection refused|no such host" "${logf}"; then
    warn "默认 distroless 基础镜像/front-end 解析失败（${cmd}, rc=${rc}），自动回退 RUNTIME_IMAGE=scratch 且不带代理；本轮后续镜像直接用 scratch"
    CP_RUNTIME_FALLBACK="scratch"
    timeout --kill-after=15s "${CP_BUILD_TIMEOUT}" \
      docker build "${base_args[@]}" "$@" --build-arg "RUNTIME_IMAGE=scratch" \
      -t "${tag}" "${CP}" >"${logf}" 2>&1
    rc=$?
    if [ "${rc}" -eq 0 ]; then rm -f "${logf}"; return 0; fi
  fi
  # 真失败：把 buildkit 输出原样吐出来（此前 >/dev/null 会让人以为是断言挂了）。
  sed -r 's/\x1B\[[0-9;]*[mK]//g' "${logf}" >&2 | tail -40
  rm -f "${logf}"
  return "${rc}"
}

# 构建 crd-conversion 镜像并装载进 kind。
#
# 抽成 helper 的原因同 ensure_agent_image：verify-conversion 与 verify-cert-rotation 都要它，
# 复制一份意味着 Dockerfile 参数（RUNTIME_IMAGE / 代理）改一次要改两处，漏改一处就会
# 在某个阶段换来一个 TLS 超时的假失败。
# 5 个 Kind 的双版本叠加清单（03b~03f）与单版本基线（bases 目录）。
#
# 为什么抽成 helper：verify-conversion / verify-cert-rotation / verify-storage-migration
# 三个相位都要「起服务 → 开双版本 → 收尾恢复」。此前只 apply 03b（NodeDisk），
# 另外 4 份清单从未被任何相位消费——代码双版本化不等于集群侧验证过。
# 恢复必须覆盖**全部 5 个**：任何一个 CRD 残留 conversion 引用而服务已被 teardown，
# 该 Kind 的 v1alpha1 读写就会全挂，且要等下一次 bootstrap 才被覆盖回来。
dual_version_crd_files() {
  printf '%s\n' \
    "${CP}/config/hardening/03b-nodedisk-dual-version.yaml" \
    "${CP}/config/hardening/03c-nodevg-dual-version.yaml" \
    "${CP}/config/hardening/03d-storagetask-dual-version.yaml" \
    "${CP}/config/hardening/03e-storagenodeops-dual-version.yaml" \
    "${CP}/config/hardening/03f-thinpoolpolicy-dual-version.yaml"
}

apply_dual_version_crds() {
  local f
  while IFS= read -r f; do
    [ -f "${f}" ] || { fail_msg "FAIL: 缺少双版本清单 ${f}"; return 1; }
    kc apply -f "${f}" >/dev/null || { fail_msg "FAIL: apply ${f} 失败"; return 1; }
  done < <(dual_version_crd_files)
}

restore_single_version_crds() {
  # bases 是目录级 apply：5 个 Kind 一次性收敛回单版本 v1beta1。
  kc apply -f "${CP}/config/crd/bases" >/dev/null 2>&1 || true
  rm -rf "${HOME}/.kube/cache/discovery" 2>/dev/null || true
}

# 多 Kind conversion smoke：verify-cert-rotation / verify-storage-migration 复用。
# 只走最短链路「v1alpha1 写 → v1beta1 读回 → 删除」，证明这两个相位里起齐的 5 份
# 双版本清单确实可用。只读空列表不算 smoke：列表为空时 apiserver 不发起转换，
# 看起来 200 实际没碰过 webhook。NodeDisk 由各相位自身的探针断言覆盖，这里覆盖
# 另外 4 个恒等映射 Kind；深度往返断言集中在 verify-conversion，不在这里重复。
smoke_all_conversion_kinds() {
  local tag="$1" entries e plural kind spec obj got rc=0
  entries=(
    "nodevgs|NodeVG|spec:\n  nodeName: m15-conv-fake-node\n  tier: smoke"
    "storagetasks|StorageTask|spec:\n  nodeName: m15-conv-fake-node\n  type: pvcreate"
    "storagenodeops|StorageNodeOps|spec:\n  nodeName: m15-conv-fake-node\n  operation: isolate"
    "thinpoolpolicies|ThinPoolPolicy|spec: {}"
  )
  # caBundle 由 cainjector 异步注入，5 个 CRD 的注入时刻可能不同。两个调用方原本只等
  # NodeDisk 一个就往下走，另外 4 个会随机因 x509 unknown authority 失败——看起来像
  # 「smoke 偶尔挂一两个 Kind」，其实是前置没等齐。这里统一等全部就绪再开跑。
  local c ca ready=0 k
  for k in $(seq 1 30); do
    ready=1
    for c in nodedisks nodevgs storagetasks storagenodeops thinpoolpolicies; do
      ca="$(kc get crd "${c}.storage.example.io" \
        -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' 2>/dev/null || true)"
      [ -n "${ca}" ] || ready=0
    done
    [ "${ready}" -eq 1 ] && break
    sleep 2
  done
  if [ "${ready}" -ne 1 ]; then
    fail_msg "FAIL: ${tag} 相位 5 个 CRD 的 caBundle 未全部注入，apiserver 会拒绝 conversion 调用"
    return 1
  fi
  for e in "${entries[@]}"; do
    IFS='|' read -r plural kind spec <<< "${e}"
    obj="m15-${tag}-${plural}"
    # 标签 hlvm.io/m15-conversion=true 与 verify-conversion 共用：各相位 cleanup
    # 按标签兜底删除，中途失败也不会留脏对象（EXIT trap 里 local 变量已销毁）。
    printf 'apiVersion: storage.example.io/v1alpha1\nkind: %s\nmetadata:\n  name: %s\n  labels:\n    hlvm.io/m15-conversion: "true"\n    m15smoke: %s\n%b\n' \
      "${kind}" "${obj}" "${tag}" "${spec}" \
      | kc apply -f - >/dev/null 2>&1 \
      || { fail_msg "FAIL: ${tag} 相位 ${kind} 以 v1alpha1 建探针失败（conversion 写入路径不通）"; rc=1; continue; }
    got="$(kc get "${plural}.v1beta1.storage.example.io" "${obj}" \
      -o 'jsonpath={.metadata.labels.m15smoke}' 2>/dev/null || true)"
    if [ "${got}" = "${tag}" ]; then
      info "PASS: ${tag} 相位 ${kind} conversion smoke 通过（v1alpha1 写 → v1beta1 读）"
    else
      fail_msg "FAIL: ${tag} 相位 ${kind} conversion smoke 失败（读到 '${got}'，期望 '${tag}'）"
      rc=1
    fi
    kc delete "${plural}.v1beta1.storage.example.io" "${obj}" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  return "${rc}"
}

# 按 label 兜底删 5 个 Kind 的探针对象（cleanup 专用，不依赖任何 local 变量）。
cleanup_conversion_probe_objects() {
  local r
  for r in nodedisks nodevgs storagetasks storagenodeops thinpoolpolicies; do
    kc delete "${r}.v1beta1.storage.example.io" -l hlvm.io/m15-conversion=true \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}

# CRD conversion webhook 的镜像引用（与 agent_image 同理）。
conversion_image() {
  if is_real; then
    printf '%s' "${IMG_REGISTRY}/crd-conversion:${IMG_TAG}"
  else
    printf '%s' "hlvm-crd-conversion:dev"
  fi
}

ensure_conversion_image() {
  local img="${1:-hlvm-crd-conversion:dev}"
  if is_real; then
    info "real 模式：conversion 镜像使用 ${img}（仓库镜像，不本地构建）"
    return 0
  fi
  have docker || die "docker 不可用，无法构建 crd-conversion 镜像"
  local extra=()
  if [ -n "${RUNTIME_IMAGE}" ]; then
    extra+=(--build-arg "RUNTIME_IMAGE=${RUNTIME_IMAGE}")
  fi
  cp_build crd-conversion "${img}" "${extra[@]}" || die "crd-conversion 镜像构建失败"
  image_load "${img}"
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
  img="$(agent_image)"
  ensure_agent_image "${img}"

  agent_cleanup() {
    kc -n hlvm-system delete ds hlvm-storage-agent --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc delete storagetask m15-agent-exec --ignore-not-found >/dev/null 2>&1 || true
    kc delete nodedisk m15-agent-disk --ignore-not-found >/dev/null 2>&1 || true
    kc delete nodedisk m15-agent-fsdisk --ignore-not-found >/dev/null 2>&1 || true
  }
  agent_cleanup

  kc apply -f "${REPO_ROOT}/control-plane/config/rbac/agent_role.yaml" >/dev/null \
    || die "apply agent RBAC 失败"
  apply_manifest_with_image "${REPO_ROOT}/agent/config/daemonset-agent.yaml" "${img}" \
    || die "apply agent DaemonSet 失败"
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
  # 多节点下 DaemonSet 每节点一个 Pod；被测节点为 NODE_NAME（control-plane），须只看该节点上的
  # agent Pod 日志——否则 `kubectl logs ds/...` 任取一个 worker Pod，会读到 node="<worker>"
  # 而误判「未解析出节点名」（agent 实际已正确解析自身节点名，节点过滤亦正常）。
  local agent_pod=""
  agent_pod="$(kc -n hlvm-system get pods -l app.kubernetes.io/component=storage-agent \
      -o jsonpath='{.items[?(@.spec.nodeName=='"\"${node}\""')].metadata.name}' 2>/dev/null | awk '{print $1}')"
  if [ -z "${agent_pod}" ]; then
    fail_msg "FAIL: 被测节点 ${node} 上无 agent Pod（DaemonSet 调度异常）"
    fail=1
  else
    logs="$(kc -n hlvm-system logs "${agent_pod}" --tail=80 2>&1 | sed -r 's/\x1B\[[0-9;]*[mK]//g' || true)"
    if printf '%s' "${logs}" | grep -q "node=\"${node}\""; then
      info "PASS: agent 解析到节点名 ${node}（Downward API 注入生效）"
    else
      fail_msg "FAIL: agent 未解析出节点名（node=unknown 时任务过滤恒不成立，Agent 会静默空转）"
      printf '%s\n' "${logs}" | tail -5
      fail=1
    fi
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
apiVersion: storage.example.io/v1beta1
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
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: m15-agent-disk
  labels:
    hlvm.storage/node: ${node}
spec:
  nodeName: ${node}
  device:
    path: /dev/sda
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
  if node_exec "${node}" "
      dd if=/dev/zero of=/tmp/m15-occ.img bs=1M count=32 2>/dev/null
      mknod ${loop_dev} b 7 77 2>/dev/null || true
      losetup -d ${loop_dev} 2>/dev/null || true
      losetup ${loop_dev} /tmp/m15-occ.img && mkfs.ext4 -q -F ${loop_dev}
    " >/dev/null 2>&1; then
    kc apply -f - >/dev/null <<EOF
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: m15-agent-fsdisk
spec:
  nodeName: ${node}
  device:
    path: ${loop_dev}
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
    node_exec "${node}" \
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
# 等待设备插件完成「本次」gRPC 注册。
#
# 为什么不能只看 rollout status / allocatable：删掉旧 DaemonSet 会让 kubelet 的 ListAndWatch
# 流断开（EOF），而 `status.allocatable` 是 kubelet 的静态上限缓存，插件断开期间**不清零**；
# rollout status 也只保证新 Pod Running，不代表它已向 kubelet 注册。此时申请设备的 Pod 会以
# `UnexpectedAdmissionError: Allocate failed due to no healthy devices present` 被拒，容器根本
# 不被创建（kubectl logs 报 `container "probe" is not available`）。
# 用 --since-time 限定在本次 apply 之后，避免上一轮注册日志掩盖这个窗口。
# 参数：$1 = 本次 apply 的起始时间（date -u +%Y-%m-%dT%H:%M:%SZ）
# 返回：0=已观察到本次注册，1=超时未观察到
wait_plugin_registered() {
  local since="$1" i
  for i in $(seq 1 60); do
    if kc -n hlvm-system logs ds/hlvm-disk-plugin --since-time="${since}" 2>/dev/null \
         | grep -q "已向 kubelet 注册设备插件"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# 部署设备插件并等「本次」注册完成。供 device-plugin 与 collector 两个阶段共用：
# 两者都会先删旧 DaemonSet 再重建，必然撞上同一个不健康窗口。
# 参数：$1 = 本地 agent 镜像 tag
deploy_plugin_and_wait() {
  local img="$1" t_apply
  # 先删已有 DS，保证 Pod 真的重建 → 必然产生「本次」注册日志，
  # 否则复用健康插件时 --since-time 等不到新日志会误判超时。
  kc -n hlvm-system delete ds hlvm-disk-plugin --ignore-not-found --wait=false >/dev/null 2>&1 || true
  t_apply="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  apply_manifest_with_image "${REPO_ROOT}/agent/config/daemonset-device-plugin.yaml" "${img}" \
    || die "apply 设备插件 DaemonSet 失败"
  kc -n hlvm-system patch ds hlvm-disk-plugin --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
    >/dev/null || die "设置 imagePullPolicy 失败"
  kc -n hlvm-system rollout status ds/hlvm-disk-plugin --timeout=180s >/dev/null 2>&1 \
    || die "设备插件 DaemonSet 未在 180s 内就绪"
  if ! wait_plugin_registered "${t_apply}"; then
    kc -n hlvm-system logs ds/hlvm-disk-plugin --tail=20 2>&1 \
      | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tail -12
    die "设备插件 rollout 完成，但 ${t_apply} 之后未见本次注册日志（设备可能仍 unhealthy）"
  fi
  # 注册日志出现后，kubelet 处理 ListAndWatch、把设备标为 healthy 仍有一小段窗口。
  sleep 3
}

phase_verify_device_plugin() {
  log "验证磁盘设备插件：kubelet 注册、节点可分配量、非特权按盘读取（含未授权对照）"
  ensure_cluster_ready
  local img="hlvm-storage-agent:dev" node="${NODE_NAME}" fail=0 i alloc logs

  img="$(agent_image)"
  ensure_agent_image "${img}"

  plugin_cleanup() {
    kc -n hlvm-system delete ds hlvm-disk-plugin --ignore-not-found --wait=false >/dev/null 2>&1 || true
    # 测试 Pod 统一打 m15-probe 标签，按标签清理：新增用例时不必再改清理清单，
    # 也避免残留 Pod 占住盘位让下一次运行莫名其妙分不到盘。
    # 必须同步等 Pod 真正消失：紧跟其后的 `verify-collector` 会立刻申请 `hlvm.io/disk`，
    # 而 kubelet 的 device allocation 是在 Pod 删除流程里归还的；`--wait=false` 会让下一个相位
    # 读到 `Available: 0` 并报 `UnexpectedAdmissionError`（看起来像容量坏了，实际是竞态）。
    kc -n hlvm-system delete pod -l hlvm.io/m15-probe=true \
      --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
  }
  plugin_cleanup

  deploy_plugin_and_wait "${img}"

  if [ "${fail}" -eq 0 ]; then
    info "PASS: 设备插件 Pod 就绪并完成本次 gRPC 注册"
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
      # /dev/vd* 必需：云主机数据盘多为 virtio（vdb/vdc），kind 内常见 sd*/nvme*。
      # 只 glob sd*/nvme* 会让 dd 根本不执行 ⇒ 既没有 READ_OK 也没有 EPERM，
      # 两条断言同时「合理地」失败，看起来像设备 cgroup 不生效（2026-11-11 真机实测）。
      command: ["sh", "-c", "for d in /dev/sd* /dev/vd* /dev/nvme*; do [ -b \"\$d\" ] || continue; dd if=\"\$d\" of=/dev/null bs=512 count=1 >/dev/null 2>&1 && echo READ_OK=\$d; done"]
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
      command: ["sh", "-c", "for d in /hostdev/sd* /hostdev/vd* /hostdev/nvme*; do [ -b \"\$d\" ] || continue; dd if=\"\$d\" of=/dev/null bs=512 count=1 2>&1; done"]
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
  nodeSelector:
    kubernetes.io/hostname: ${node}
  # 被测节点为 control-plane（被 NoSchedule taint）；nodeSelector 走调度器，须显式容忍该 taint，
  # 否则 Pod 卡 Pending 无法落到 CP（nodeName 直绑会绕过 taint，但会丢失超额即 Pending 的语义）。
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
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
  nodeSelector:
    kubernetes.io/hostname: ${node}
  # 被测节点为 control-plane（被 NoSchedule taint）；nodeSelector 走调度器，须显式容忍该 taint，
  # 否则 Pod 卡 Pending 无法落到 CP（nodeName 直绑会绕过 taint，但会丢失超额即 Pending 的语义）。
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
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

# verify-kubelet-restart：kubelet 重启后的插件自愈与 checkpoint 恢复（6.5 的 kind 可覆盖部分）。
#
# 为什么单列一个阶段：device plugin 的注册状态只存在 kubelet 内存里，而 kubelet 重启是常规
# 运维动作（升级 / 调参 / 改 cgroup）。2026-10-30 kind 实测在三条路径上都失败，表现完全一致——
# 节点 `hlvm.io/disk` 归零后**永不恢复**，只能删插件 Pod 救回：
#   ① kubelet 启动会清空 device-plugins 目录里的插件 socket → 插件失去目录项，kubelet 反向
#      连接得到 ENOENT，注册必然失败；
#   ② `kubelet.sock` 重建可能复用 inode → 只比 inode 根本感知不到「重启过」；
#   ③ 注册 RPC 无超时 → kubelet 尚未就绪时挂死，注册循环从此不再前进。
# 修复：socket 签名纳入 mtime、自身 socket 被删后重建监听、注册加 5s 超时 + 300s 兜底重注册。
#
# 覆盖边界：kind 用 `docker exec <cluster>-control-plane systemctl restart kubelet`；
# real 用 `ssh <CP> systemctl restart kubelet`（节点池滚动 / 排水不在本阶段覆盖范围）。
phase_verify_kubelet_restart() {
  log "验证 kubelet 重启：插件自愈重新注册、运行中容器不受影响、checkpoint 恢复不重复分配"
  ensure_cluster_ready
  # kubelet 重启只能打在**控制面**：real 模式被测节点是 worker，两者不同机，
  # 若沿用到 worker 上，就变成「重启 worker 的 kubelet 却断言 CP 的 checkpoint」。
  local ctr
  ctr="$(control_plane_node)"
  if [ -z "${ctr}" ]; then
    info "跳过 kubelet 重启验证：无法解析控制面节点——未覆盖"
    return 0
  fi
  if ! is_real; then
    if ! have docker || ! docker inspect "${ctr}" >/dev/null 2>&1; then
      info "跳过 kubelet 重启验证：${ctr} 不是本机 docker 容器（本阶段仅覆盖 kind 载体）——未覆盖"
      return 0
    fi
  fi

  local img="hlvm-storage-agent:dev" node="${NODE_NAME}" fail=0
  local alloc="" base="" pod="" t0="" healed=0 regs="" has="" i="" start="" dur="" ready=""
  local a_dev="" b_dev="" a_cid="" a_cid2="" a_uid="" ckpt="" phase=""
  local plugin_pod0="" plugin_pod1=""
  local dev_file="/var/lib/kubelet/device-plugins"
  # checkpoint 判据的环境能力位：1=本环境 kubelet 会落盘 PodDeviceEntries（硬断言），
  # 0=实测不落盘（子项 SKIP，需三条证据同时成立，见重启前的注释）。
  local ckpt_ok=1 ckpt_note=" / checkpoint 恢复" a_created="" a_created_epoch=0 ckpt_mtime=0 alloc_logged=0 no_entries=1

  img="$(agent_image)"
  ensure_agent_image "${img}"

  kubelet_restart_cleanup() {
    kc -n hlvm-system delete pod -l hlvm.io/m15-probe=true \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
  kubelet_restart_cleanup

  # 独立执行时插件可能没部署（上一阶段会清理自己的 DaemonSet）。
  # 与 device-plugin / collector 阶段同理：allocatable 是静态缓存、插件断开期间不清零，
  # 不能据此判断「可分配」。始终重建并等本次注册，避免 Pod A 撞上 no healthy devices。
  deploy_plugin_and_wait "${img}"

  for i in $(seq 1 45); do
    base="$(kc get node "${node}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
    if [[ "${base}" =~ ^[0-9]+$ ]] && [ "${base}" -gt 0 ]; then break; fi
    sleep 2
  done
  if [[ "${base}" =~ ^[0-9]+$ ]] && [ "${base}" -gt 0 ]; then
    info "PASS: 前置——节点可分配 hlvm.io/disk=${base}"
  else
    fail_msg "FAIL: 前置不成立（allocatable='${base}'），无法验证重启恢复"
    kc -n hlvm-system get pod -l app.kubernetes.io/component=disk-device-plugin 2>&1 | tail -3
    kubelet_restart_cleanup
    die "kubelet 重启验证中止"
  fi

  pod="$(kc -n hlvm-system get pod -l app.kubernetes.io/component=disk-device-plugin \
    -o jsonpath='{.items[?(@.spec.nodeName=='"\"${node}\""')].metadata.name}' 2>/dev/null | awk '{print $1}')"
  plugin_pod0="${pod}"

  # A 先占住一块盘：重启后若 checkpoint 恢复失效，kubelet 会把这同一块盘再分给别人。
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-kr-a
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  # 被测节点为 control-plane（被 NoSchedule taint）；nodeSelector 走调度器，须显式容忍该 taint，
  # 否则 Pod 卡 Pending 无法落到 CP（nodeName 直绑会绕过 taint，但会丢失超额即 Pending 的语义）。
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  restartPolicy: Never
  containers:
    - name: probe
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "ls /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null; sleep 900"]
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

  phase=""
  for i in $(seq 1 60); do
    phase="$(kc -n hlvm-system get pod m15-kr-a -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${phase}" = "Running" ] && break
    sleep 2
  done
  if [ "${phase}" = "Running" ]; then
    a_dev="$(kc -n hlvm-system logs m15-kr-a 2>/dev/null | head -1 || true)"
    a_cid="$(kc -n hlvm-system get pod m15-kr-a -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null || true)"
    a_uid="$(kc -n hlvm-system get pod m15-kr-a -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    a_created="$(kc -n hlvm-system get pod m15-kr-a -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
    # 容器内 /dev 的可见性取决于运行时怎么装配 /dev（runc 会重建），拿不到就回退到插件日志：
    # 插件在 Allocate 里打印 `host=<设备路径>`，这是「分配确实发生」的权威记录。
    # 同一时刻只有本阶段在申请设备，不会串到别人的分配。
    if [ -z "${a_dev}" ] && [ -n "${a_created}" ]; then
      a_dev="$(kc -n hlvm-system logs "${plugin_pod0}" --since-time="${a_created}" 2>/dev/null \
        | sed -n 's/.*host=\(\/dev\/[^[:space:]]*\).*/\1/p' | head -1 || true)"
    fi
    info "PASS: 重启前 Pod A 申请到磁盘并运行（device=${a_dev:-未知}）"
  else
    fail_msg "FAIL: Pod A 未运行（phase='${phase}'），无法验证 checkpoint 恢复"
    kc -n hlvm-system describe pod m15-kr-a 2>&1 | tail -8
    kubelet_restart_cleanup
    die "kubelet 重启验证中止"
  fi

  # kubelet 的 checkpoint 是异步落盘的：Pod 变 Running 只代表容器起来了，
  # `PodDeviceEntries` 可能还没写。真机实测 Pod A 分配后 5s 内读必然为空
  # （2026-11-11：插件日志 11:45:50 已分配 vdc，此刻读 checkpoint 是 null），
  # kind 因为盘快 / Pod 启动慢反而不暴露。这里轮询等它出现，而不是读一次就判死。
  ckpt=""
  for i in $(seq 1 30); do
    ckpt="$(node_exec "${ctr}" "cat '${dev_file}/kubelet_internal_checkpoint'" 2>/dev/null || true)"
    if [ -n "${a_uid}" ] && printf '%s' "${ckpt}" | grep -q "${a_uid}"; then break; fi
    sleep 1
  done
  if [ -n "${a_uid}" ] && printf '%s' "${ckpt}" | grep -q "${a_uid}"; then
    info "PASS: 重启前 checkpoint 已记录 Pod A 的设备分配"
  else
    # 轮询 30s 仍无，有两种截然不同的原因，不能一并 FAIL：
    #   ① 分配真的没落盘 —— 缺陷；
    #   ② 本环境 kubelet 根本不写 PodDeviceEntries（2026-11-11 真机 k8s v1.36.6 实测：
    #      文件 mtime 停在 kubelet 启动后数秒，此后设备分配不再改写，字段恒为 null）——
    #      判据不适用，SKIP 并留下证据；不为求全绿把断言改松。
    # 判定 ② 需三条证据同时成立，缺一即 FAIL（宁可误报，不可静默放过真丢失）：
    #   a. checkpoint mtime 早于 Pod A 创建时间（Pod 起来后该文件从未被改写）；
    #   b. 插件日志在 Pod A 创建之后确有「分配磁盘设备」（分配确实发生过）；
    #   c. checkpoint 全文没有任何 podDeviceEntries 条目（不是「写了别人、漏了 A」）。
    a_created_epoch=0
    if [ -n "${a_created}" ]; then a_created_epoch="$(date -d "${a_created}" +%s 2>/dev/null || echo 0)"; fi
    ckpt_mtime="$(node_exec "${ctr}" "stat -c %Y '${dev_file}/kubelet_internal_checkpoint' 2>/dev/null || echo 0" 2>/dev/null | tr -dc '0-9' || true)"
    alloc_logged="$(kc -n hlvm-system logs "${plugin_pod0}" --since-time="${a_created}" 2>/dev/null \
      | grep -c '分配磁盘设备' || true)"
    no_entries=1
    if printf '%s' "${ckpt}" | grep -Eq '"podDeviceEntries"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{'; then no_entries=0; fi
    if [ "${a_created_epoch}" -gt 0 ] && [ "${ckpt_mtime:-0}" -gt 0 ] \
       && [ "${ckpt_mtime}" -lt "${a_created_epoch}" ] \
       && [ "${alloc_logged:-0}" -ge 1 ] && [ "${no_entries}" -eq 1 ]; then
      ckpt_ok=0
      ckpt_note="；checkpoint 子项已 SKIP（本环境 kubelet 不落盘 PodDeviceEntries）"
      warn "SKIP: checkpoint 未记录 Pod A，但本环境 kubelet 不落盘 PodDeviceEntries（mtime=${ckpt_mtime} < Pod创建=${a_created_epoch}；插件已记录 ${alloc_logged} 次分配；文件内无 podDeviceEntries）——两条 checkpoint 断言跳过，不判 PASS"
    else
      fail_msg "FAIL: checkpoint 未记录 Pod A（uid='${a_uid}'，轮询 30s 后仍无；mtime=${ckpt_mtime:-?} podCreated=${a_created_epoch} allocLog=${alloc_logged:-?} 无条目=${no_entries}）"
      fail=1
    fi
  fi

  t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  info "重启 kubelet（${ctr}），T0=${t0}"
  node_exec "${ctr}" 'systemctl restart kubelet' >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    ready="$(kc get node "${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "${ready}" = "True" ] && break
    sleep 2
  done

  # 自愈判据必须用 T0 之后的新注册日志：`--tail` 会把重启前那次注册也算进来（首版即踩到，
  # 判据恒为「已自愈」）。
  start="$(date +%s)"
  # 120s 而不是 60s：kubelet 重启后，插件要先后被 socket_guard 发现「自我 socket 被换」→
  # 重建监听，再由 registration_loop 的 5s 采样发现签名变化 → 重注册。真机实测
  # kubelet.sock 11:45:56 重建、hlvm-disk.sock 11:45:57 重绑，链路是秒级，但盘多或
  # kubelet 启动慢时会拉长，60s 余量偏紧（2026-11-11）。
  for i in $(seq 1 120); do
    has="$(node_exec "${ctr}" "ls '${dev_file}'" 2>/dev/null | grep -c '^hlvm-disk.sock$' || true)"
    regs="$(kc -n hlvm-system logs "${plugin_pod0}" --since-time="${t0}" 2>/dev/null \
      | grep -c "已向 kubelet 注册" || true)"
    if [ "${has:-0}" -ge 1 ] && [ "${regs:-0}" -ge 1 ]; then healed=1; break; fi
    sleep 1
  done
  dur=$(( $(date +%s) - start ))

  if [ "${healed}" -eq 1 ]; then
    info "PASS: kubelet 重启后 ${dur}s 内插件重建监听并重新注册（无需重启插件 Pod）"
  else
    fail_msg "FAIL: 重启后 120s 内未重新注册（socket='${has:-0}' 重启后注册次数='${regs:-0}'）——节点容量会永久为 0"
    kc -n hlvm-system logs "${plugin_pod0}" --tail=20 2>&1 \
      | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tail -12
    fail=1
  fi

  for i in $(seq 1 40); do
    alloc="$(kc get node "${node}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
    if [[ "${alloc}" =~ ^[0-9]+$ ]] && [ "${alloc}" -gt 0 ]; then break; fi
    sleep 2
  done
  if [[ "${alloc}" =~ ^[0-9]+$ ]] && [ "${alloc}" -gt 0 ]; then
    info "PASS: 重启后节点容量恢复（allocatable=${alloc}）"
  else
    fail_msg "FAIL: 重启后 allocatable 未恢复（'${alloc}'）"
    fail=1
  fi

  a_cid2="$(kc -n hlvm-system get pod m15-kr-a -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null || true)"
  if [ -n "${a_cid}" ] && [ "${a_cid}" = "${a_cid2}" ]; then
    info "PASS: 运行中容器未因 kubelet 重启而重建（containerID 不变）"
  else
    fail_msg "FAIL: Pod A 容器在 kubelet 重启后被重建（'${a_cid}' -> '${a_cid2}'）"
    fail=1
  fi

  plugin_pod1="$(kc -n hlvm-system get pod -l app.kubernetes.io/component=disk-device-plugin \
    -o jsonpath='{.items[?(@.spec.nodeName=='"\"${node}\""')].metadata.name}' 2>/dev/null | awk '{print $1}')"
  if [ -n "${plugin_pod0}" ] && [ "${plugin_pod0}" = "${plugin_pod1}" ]; then
    info "PASS: 自愈来自插件进程自身（插件 Pod 未被重建：${plugin_pod1}）"
  else
    fail_msg "FAIL: 插件 Pod 被重建（'${plugin_pod0}' -> '${plugin_pod1}'）——不能证明进程级自愈"
    fail=1
  fi

  if [ "${ckpt_ok}" -ne 1 ]; then
    info "跳过「重启后 checkpoint 恢复」断言：本环境 kubelet 不落盘 PodDeviceEntries（见上）——该项未覆盖"
  else
    ckpt="$(node_exec "${ctr}" "cat '${dev_file}/kubelet_internal_checkpoint'" 2>/dev/null || true)"
    if [ -n "${a_uid}" ] && printf '%s' "${ckpt}" | grep -q "${a_uid}"; then
      info "PASS: checkpoint 恢复——重启后仍把该盘算在 Pod A 名下"
    else
      fail_msg "FAIL: 重启后 checkpoint 丢了 Pod A 的分配记录（uid='${a_uid}'）"
      fail=1
    fi
  fi

  if [ "${base}" -ge 2 ]; then
    kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-kr-b
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  # 被测节点为 control-plane（被 NoSchedule taint）；nodeSelector 走调度器，须显式容忍该 taint，
  # 否则 Pod 卡 Pending 无法落到 CP（nodeName 直绑会绕过 taint，但会丢失超额即 Pending 的语义）。
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  restartPolicy: Never
  containers:
    - name: probe
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "ls /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null; sleep 900"]
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
    phase=""
    for i in $(seq 1 45); do
      phase="$(kc -n hlvm-system get pod m15-kr-b -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [ "${phase}" = "Running" ] && break
      sleep 2
    done
    b_dev="$(kc -n hlvm-system logs m15-kr-b 2>/dev/null | head -1 || true)"
    # A 的设备未知时不能判 PASS：`b_dev != 空` 恒真，会把「无法比对」伪装成「未重复分配」。
    if [ "${phase}" = "Running" ] && [ -n "${b_dev}" ] && [ -n "${a_dev}" ] && [ "${b_dev}" != "${a_dev}" ]; then
      info "PASS: 重启后新申请拿到另一块盘（A=${a_dev} B=${b_dev}）——未重复分配"
    else
      fail_msg "FAIL: 重启后新申请未拿到不同设备（phase='${phase}' A='${a_dev:-未知}' B='${b_dev:-未知}'）——可能把同一块盘分了两次，或设备路径未采到"
      fail=1
    fi
  else
    info "跳过「不重复分配」断言：本节点仅 ${base} 个盘位（需 ≥2）——该项未覆盖"
  fi

  kubelet_restart_cleanup
  kc -n hlvm-system delete ds hlvm-disk-plugin --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ "${fail}" -ne 0 ]; then
    die "kubelet 重启验证未通过（见上）"
  fi
  info "kubelet 重启验证通过（自愈重注册 / 容器不重建 / 不重复分配${ckpt_note}）"
}

# verify-device-hotplug：设备热插拔的 ListAndWatch 增量验证（add-disk-device-plugin 6.3）。
#
# 为什么本机就能闭环：6.3 原本标注「需真实可插拔硬件」，但要验证的是「设备集合变化能被
# 插件感知并增量推送」，不是某一类具体总线。在 kind 节点容器里 `modprobe scsi_debug`
# 能造出真正的整盘（`type=disk`、`/sys/block` 下可见），与物理拔插在内核层是同一类事件
# （block device add/remove），热插拔的两个方向都能真实触发。
#
# 本阶段同时固化了 2026-10-31 实测到的缺陷：`lsblk` 读的是 sysfs，设备一注册到内核就
# 出现在列表里，而 `/dev/<name>` 由 udev 稍后建立。修复前插件照单全收，于是：
#   ① 节点 `allocatable.hlvm.io/disk` 虚高 ⇒ ② 调度器敢把「申请这块盘」的 Pod 放上来 ⇒
#   ③ kubelet 注入设备时 `lstat /dev/sde: no such file or directory`，Pod 永久停在
#      CreateContainerError —— 一个会静默吃掉 Pod 的黑洞。
# 修复（`rescan` 里的 `host_node_ready` 过滤）：宿主设备节点就绪才暴露。
# 断言按生命周期排布，避免只测一半：过早不暴露 → 节点就绪后暴露 → 真的能用 → 拔掉回落。
phase_verify_device_hotplug() {
  log "验证设备热插拔：ListAndWatch 增量推送与「设备节点就绪才暴露」"
  ensure_cluster_ready
  local img="hlvm-storage-agent:dev" node="${NODE_NAME}" fail=0
  # 注入点必须 == 被测节点：kind 下 NODE_NAME 就是 CP（与旧硬编码等价），
  # real 下是 worker——若仍硬编码 CP，就会「把盘造在控制面、断言读 worker」，必然对不上。
  local container="${NODE_NAME}"
  local i a d before="" after="" new_disk="" disk_node="" majmin=""
  local alloc0="" want=0 over=0 warned=0 got=0 hp_pod=""

  img="$(agent_image)"
  ensure_agent_image "${img}"

  # 清理要撤回两样东西：内核模块（宿主机全局可见，漏了会一直多一块盘）和自建的 /dev 节点。
  # 用 EXIT trap 兜底：本阶段任何 `die` 都是 exit，只靠末尾顺序清理一定会漏。
  hotplug_cleanup() {
    # 必须先**同步**等 Pod 真正消失，再 rmmod / 删 DS：
    # kubelet 的 device allocation 是在 Pod 删除流程里归还的。若这里 `--wait=false` 就往下走，
    # 后面的相位（`verify-collector`）立刻申请同名扩展资源时会读到 Available: 0，
    # 报 `UnexpectedAdmissionError`——看起来像容量坏了，实际是上一批 allocation 还没释放。
    kc -n hlvm-system delete pod -l hlvm.io/m15-hotplug=true \
      --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
    node_exec "${container}" 'rmmod scsi_debug' >/dev/null 2>&1 || true
    if [ -n "${disk_node:-}" ]; then
      node_exec "${container}" "rm -f '${disk_node}'" >/dev/null 2>&1 || true
    fi
    kc -n hlvm-system delete ds hlvm-disk-plugin --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
  trap hotplug_cleanup EXIT
  hotplug_cleanup

  node_alloc() { kc get node "${node}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true; }

  deploy_plugin_and_wait "${img}"

  # 0) 基准：未插新设备时的可分配量。后续每条断言都以它为对照。
  for i in $(seq 1 30); do
    alloc0="$(node_alloc)"
    if [[ "${alloc0}" =~ ^[0-9]+$ ]] && [ "${alloc0}" -gt 0 ]; then break; fi
    sleep 2
  done
  if [[ ! "${alloc0}" =~ ^[0-9]+$ ]]; then
    fail_msg "FAIL: 无法读取基准可分配 hlvm.io/disk（当前='${alloc0}'）"
    die "设备热插拔验证无法继续：基准容量未知"
  fi
  want=$((alloc0 + 1))
  info "PASS: 基准可分配 hlvm.io/disk=${alloc0}（后续全部以此对照）"

  # 1) 对照组：申请 ${want} 个设备当前必然调度不下。没有这一步，后面同一个 Pod 能起来
  #    就无法排除「本来就有余量」，增量到底是新设备带来的还是原本就有，说不清。
  hotplug_pod() {
    kc apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-hotplug-consumer
  namespace: hlvm-system
  labels:
    hlvm.io/m15-hotplug: "true"
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  # 被测节点为 control-plane（被 NoSchedule taint）；nodeSelector 走调度器，须显式容忍该 taint，
  # 否则 Pod 卡 Pending 无法落到 CP（nodeName 直绑会绕过 taint，但会丢失超额即 Pending 的语义）。
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  restartPolicy: Never
  containers:
    - name: consumer
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
      resources:
        limits:
          hlvm.io/disk: "${want}"
EOF
  }

  hotplug_pod
  over=0
  for i in $(seq 1 20); do
    a="$(kc -n hlvm-system get pod m15-hotplug-consumer -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    if [ -n "${a}" ]; then over=1; break; fi
    sleep 3
  done
  if [ "${over}" -eq 0 ]; then
    info "PASS: 插入前申请 ${want} 个设备无法调度（基准容量确为 ${alloc0}，对照组成立）"
  else
    fail_msg "FAIL: 插入前申请 ${want} 个设备竟已分配——基准容量不是 ${alloc0}，后续对照全部失效"
    fail=1
  fi
  kc -n hlvm-system delete pod m15-hotplug-consumer --ignore-not-found --wait=true \
    --timeout=60s >/dev/null 2>&1 || true

  # 2) 插入设备：在节点容器内加载 scsi_debug，造一块真实整盘。
  before="$(node_exec "${container}" 'lsblk -d -o NAME -n | tr "\n" " "' 2>/dev/null || true)"
  if ! disk_inject "${container}"; then
    if is_real; then
      warn "跳过热插拔验证：real 模式需提供 M15_DISK_ATTACH_CMD（云盘 attach / virsh attach-disk 等）——未覆盖"
    else
      warn "跳过热插拔验证：无法在 kind 节点内加载 scsi_debug（非 Linux 宿主 / 缺模块 / 无 CAP_SYS_MODULE）"
    fi
    hotplug_cleanup
    trap - EXIT
    return 0
  fi
  sleep 3
  after="$(node_exec "${container}" 'lsblk -d -o NAME -n | tr "\n" " "' 2>/dev/null || true)"
  for d in ${after}; do
    case " ${before} " in *" ${d} "*) ;; *) new_disk="${d}" ;; esac
  done
  if [ -z "${new_disk}" ]; then
    fail_msg "FAIL: modprobe 后未出现新整盘（before='${before}' after='${after}'）"
    fail=1
  else
    info "PASS: 内核已注册新整盘 ${new_disk}（lsblk 可见 type=disk，与物理拔插同类事件）"
  fi

  # 3) 核心断言：内核认下了这块盘，插件**不得**立刻暴露它。
  #    lsblk 读 sysfs，`/dev/<name>` 由 udev 稍后建立（kind 无 udev ⇒ 本例始终不建）。
  #    修复前这里就虚高，并把「申请它」的 Pod 送进 CreateContainerError 黑洞。
  #    等待窗口按生产默认的 rescan 周期给：60s 重扫 + 5s ListAndWatch tick + kubelet 同步。
  over=0
  for i in $(seq 1 25); do
    a="$(node_alloc)"
    if [[ "${a}" =~ ^[0-9]+$ ]] && [ "${a}" -gt "${alloc0}" ]; then over=1; break; fi
    sleep 6
  done
  warned=0
  # 必须定点读「被测节点」上的插件 Pod：`logs ds/hlvm-disk-plugin` 会在 DaemonSet 里任取一个 Pod，
  # 多节点集群下常常读到别的节点，而这条日志只会在插了盘的那台节点上出现 ⇒ 断言必然假阴性。
  # （单节点时代只有一个 Pod，所以这个单节点假设一直没暴露。）
  hp_pod="$(kc -n hlvm-system get pod -l app.kubernetes.io/component=disk-device-plugin \
    -o jsonpath='{.items[?(@.spec.nodeName=='"\"${node}\""')].metadata.name}' 2>/dev/null | awk '{print $1}')"
  if [ -n "${hp_pod}" ] && kc -n hlvm-system logs "${hp_pod}" --tail=120 2>/dev/null \
      | sed -r 's/\x1B\[[0-9;]*[mK]//g' | grep -q "宿主设备节点缺失"; then
    warned=1
  fi
  if [ "${over}" -eq 0 ] && [ "${warned}" -eq 1 ]; then
    info "PASS: 新盘在 /dev 无节点时未被暴露（allocatable 仍 ${alloc0}，插件日志已明示原因）"
  else
    fail_msg "FAIL: 设备节点缺失时插件行为异常（过早暴露=${over} 有明晰日志=${warned}，读取 Pod='${hp_pod:-<未找到>}'，节点=${node}）"
    if [ "${over}" -eq 1 ]; then
      fail_msg "      allocatable 已虚高到 ${a}：调度器会把申请此盘的 Pod 放上来，随后永久 CreateContainerError"
    fi
    fail=1
  fi

  # 4) udev 补上设备节点后必须纳入（证明不是「永不暴露」，而是「就绪才暴露」）。
  disk_node="/dev/${new_disk}"
  majmin="$(node_exec "${container}" "cat '/sys/block/${new_disk}/dev'" 2>/dev/null || true)"
  if [ -z "${majmin}" ]; then
    fail_msg "FAIL: 读不到 ${new_disk} 的 major:minor，无法模拟 udev 建节点"
    fail=1
  else
    local maj="${majmin%%:*}" min="${majmin##*:}"
    node_exec "${container}" "mknod '${disk_node}' b '${maj}' '${min}'" >/dev/null 2>&1 || true
    got=0
    for i in $(seq 1 25); do
      a="$(node_alloc)"
      if [[ "${a}" =~ ^[0-9]+$ ]] && [ "${a}" -ge "${want}" ]; then got=1; break; fi
      sleep 6
    done
    if [ "${got}" -eq 1 ]; then
      info "PASS: 设备节点就绪后插件暴露该盘，allocatable ${alloc0} → ${a}（ListAndWatch 增量推送生效）"
    else
      fail_msg "FAIL: 建了 ${disk_node} 后 allocatable 仍未增长（当前='${a}'，期望 ≥${want}）"
      fail=1
    fi
  fi

  # 5) 新容量必须**真的能用**：同一个申请 ${want} 个设备的 Pod，之前调度不下，现在要能
  #    真正起来（容器能创建 ⇒ kubelet 真的注入了设备，而不是又一次 admission 失败）。
  hotplug_pod
  local ph="" up=0
  for i in $(seq 1 30); do
    ph="$(kc -n hlvm-system get pod m15-hotplug-consumer -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${ph}" in Running|Succeeded) up=1; break;; esac
    sleep 5
  done
  if [ "${up}" -eq 1 ]; then
    info "PASS: 申请 ${want} 个设备的 Pod 真正 Running（新容量可用；修复前此处为 CreateContainerError）"
  else
    fail_msg "FAIL: Pod 未进入 Running（phase='${ph:-<空>}'）"
    kc -n hlvm-system describe pod m15-hotplug-consumer 2>&1 | sed -n '/Events:/,$p' | tail -8
    fail=1
  fi
  # 释放占用：否则后面的回落断言会被自己占住的盘位干扰。
  kc -n hlvm-system delete pod m15-hotplug-consumer --ignore-not-found --wait=true \
    --timeout=90s >/dev/null 2>&1 || true

  # 6) 拔出设备：allocatable 必须回落（反方向的又一次 ListAndWatch 增量）。
  node_exec "${container}" 'rmmod scsi_debug' >/dev/null 2>&1 || true
  got=0
  for i in $(seq 1 30); do
    a="$(node_alloc)"
    if [[ "${a}" =~ ^[0-9]+$ ]] && [ "${a}" -le "${alloc0}" ]; then got=1; break; fi
    sleep 6
  done
  if [ "${got}" -eq 1 ]; then
    info "PASS: 拔出后 allocatable 回落到 ${a}（设备消失同样经 ListAndWatch 增量推送）"
  else
    fail_msg "FAIL: 拔出后 allocatable 仍为 '${a}'（期望回落到 ${alloc0}）"
    fail=1
  fi

  # 7) 收尾：确认环境回到初始状态。断言通过但副作用留在机器上，等于没通过——
  #    残留的 scsi_debug 会让下一次跑集成的人看到一块莫名其妙多出来的盘。
  hotplug_cleanup
  trap - EXIT
  local mod_left disks_now before_n now_n
  mod_left="$(node_exec "${container}" 'ls /sys/module/ | grep -c "^scsi_debug$"' 2>/dev/null || true)"
  disks_now="$(node_exec "${container}" 'lsblk -d -o NAME -n | tr "\n" " "' 2>/dev/null || true)"
  before_n="$(printf '%s' "${before}" | tr -s ' ' | sed 's/^ //;s/ $//')"
  now_n="$(printf '%s' "${disks_now}" | tr -s ' ' | sed 's/^ //;s/ $//')"
  if [ "${mod_left}" = "0" ] && [ "${now_n}" = "${before_n}" ]; then
    info "PASS: 收尾干净——scsi_debug 已卸载，盘集合还原为 [${before_n}]"
  else
    fail_msg "FAIL: 收尾不干净（模块=${mod_left} 盘集合='${now_n}'，期望='${before_n}'）"
    fail=1
  fi

  if [ "${fail}" -eq 0 ]; then
    info "设备热插拔验证全部 PASS（8 条：基准 / 插入前对照 / 内核感知 / 节点缺失时不暴露 / 节点就绪后暴露 / 新容量可分配 / 拔出回落 / 收尾干净）"
  else
    die "设备热插拔验证未通过（见上）"
  fi
}

# verify-topology-scale：跨节点调度拓扑 / 容量账（add-disk-device-plugin 6.5b 的 kind 可覆盖部分）。
#
# 6.5b 原标注「需真实测试集群（kind 单节点无法覆盖）」针对的是「节点扩容缩容」——即真给集群
# 加/减带真实磁盘的节点。但 6.5b 另一半「hlvm.io/disk 与调度器的 NodeAffinity/拓扑」在 3 节点
# kind 上完全可以闭环：hlvm.io/disk 是**每节点**的扩展资源，调度器据此把申请盘位的 Pod 约束到
# 有容量的节点、且不会跨节点超额分配。本阶段就用多节点 kind 验证这一半。
#
# 为什么多节点才测得出来：单节点下「申请 N+1 必 Pending」只能验证单机容量上限；多节点才能验证
# ① 容量是**按节点**记账（耗尽一个节点不影响另一个）；② 无 nodeSelector 的申请被调度器放到
#    有容量的节点（不会落到 0 容量节点）；③ 集群整体耗尽才 Pending；④ 释放一个节点盘位后，
#    之前 Pending 的申请能跨节点落回该节点（设备真的回到 kubelet，而非数字好看）。
#
# 关键手法：把 control-plane cordon 掉，使「无选择子」的申请只能在 worker 间分配，断言才确定。
# DaemonSet 不受 cordon 影响（CP 上的插件照常运行），uncordon 在清理里兜底。
#
# 诚实边界：本阶段不验证「节点扩容缩容」（给 kind 加/减节点 + 真盘），那部分仍移交真实测试集群。
# 盘用 scsi_debug 在 worker 节点容器内造（与 6.3 热插拔同理，kind 限定）。
phase_verify_topology_scale() {
  # 单节点：本相位的四个断言全部以「两个以上节点」为前提（容量按节点独立记账、
  # 无选择子申请被放到有容量的节点、集群耗尽才 Pending、释放后跨节点回调度）。
  # 单节点上这些断言要么恒成立（没有第二个节点可比），要么失去判别力，跑出来只会是假绿。
  # 因此显式 SKIP 并**在结论里写明缺口**，而不是让它「跑通 4 条 PASS」。
  if is_single_node; then
    log "验证跨节点调度拓扑/容量账：单节点模式 → SKIP"
    warn "SKIP: M15_SINGLE_NODE=1，无跨节点拓扑可验（每节点独立容量账 / 跨节点回调度未覆盖）"
    warn "      单机容量上限（申请 N+1 必 Pending / 归还后可再分配）由 verify-device-plugin 与 verify-device-hotplug 覆盖"
    warn "      要闭环 6.5b 的跨节点部分，需 ≥2 个带独立盘位的节点（M15_SINGLE_NODE=0）"
    return 0
  fi
  log "验证跨节点调度拓扑/容量账：每节点 hlvm.io/disk 独立记账、无选择子申请落容量节点、集群耗尽才 Pending、释放后跨节点回调度"
  ensure_cluster_ready
  local img="hlvm-storage-agent:dev" fail=0
  local i n cap workers="" cap_workers="" cp_node=""
  local t0_name="m15-topo-t0" t0_node="" tx_name="m15-topo-over" total=0 running=0 over="" ev="" got_node=""
  local skip_fill=0 unsched=""

  img="$(agent_image)"
  ensure_agent_image "${img}"

  # 清理：测试 Pod 统一打标签按标签删；每个 worker 容器内卸载 scsi_debug（内核模块节点级，漏了
  # 会一直多一块盘，干扰后续阶段）；uncordon CP；最后删设备插件 DaemonSet。EXIT trap 兜底：本阶段
  # 任何 die 都是 exit，仅末尾顺序清理会漏。
  topo_cleanup() {
    # 同步等测试 Pod 消失（释放 hlvm.io/disk 的 allocation）后再卸载模块 / 删 DS，
    # 否则下一个相位（`verify-collector`）立刻申请盘位会撞上 `Available: 0`。
    kc -n hlvm-system delete pod -l hlvm.io/m15-topology=true \
      --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
    for n in ${workers:-}; do
      node_exec "${n}" 'rmmod scsi_debug' >/dev/null 2>&1 || true
    done
    [ -n "${cp_node:-}" ] && kc uncordon "${cp_node}" >/dev/null 2>&1 || true
    kc -n hlvm-system delete ds hlvm-disk-plugin --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
  trap topo_cleanup EXIT
  topo_cleanup

  deploy_plugin_and_wait "${img}"

  # control-plane 节点名（用于 cordon，把无选择子的申请逼到 worker 间分配）。
  cp_node="$(kc get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane)].metadata.name}' 2>/dev/null | awk '{print $1}')"
  if [ -n "${cp_node}" ]; then
    kc cordon "${cp_node}" >/dev/null 2>&1 || true
    info "PASS: 已 cordon control-plane ${cp_node}（无选择子申请只在 worker 间分配，断言确定）"
  fi

  # 1) 列出 worker 节点（排除 control-plane；CP 带 NoSchedule taint 且不是本阶段容量节点）。
  #    必须用 label 排除：真实集群节点名千奇百怪（ecs-xxx / k8s-master-1），按 "-control-plane"
  #    后缀过滤在 real 模式下会把 master 当 worker 一起填盘，容量账直接错。
  workers="$(kc get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')"
  if [ -z "${workers}" ]; then
    die "未找到 worker 节点（拓扑验证需要多节点集群）"
  fi

  # 2) 读取每个 worker 现有的 hlvm.io/disk 容量（基线）。kind 节点自身磁盘会被插件暴露，故
  #    worker 通常已有容量，无需注入即可验证跨节点拓扑。对基线为 0 的 worker 做一次 best-effort
  #    的 scsi_debug 注入（先 rmmod 清残留再 modprobe）；若仍 0 则排除该节点，不因此失败。
  #    注：本机实测 worker 基线容量已足够（每节点 2），scsi_debug 注入在 worker 上未稳定增量，
  #    故注入仅作 0 容量节点的兜底，不作断言。
  cap_workers=""
  for n in ${workers}; do
    cap="$(kc get node "${n}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
    [[ "${cap}" =~ ^[0-9]+$ ]] || cap=0
    if [ "${cap}" -eq 0 ]; then
      node_exec "${n}" 'rmmod scsi_debug' >/dev/null 2>&1 || true
      if disk_inject "${n}"; then
        sleep 3
        for i in $(seq 1 40); do
          cap="$(kc get node "${n}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
          [ "${cap}" = "1" ] && break
          sleep 2
        done
        [[ "${cap}" =~ ^[0-9]+$ ]] || cap=0
      fi
    fi
    if [ "${cap}" -ge 1 ]; then
      if [ "${cap}" -gt 4 ]; then
        warn "worker ${n} 盘位 ${cap} 过多，不纳入填充/耗尽断言（本环境特异性）"
        skip_fill=1
      else
        info "PASS: worker ${n} 具备 hlvm.io/disk 容量 ${cap}（插件在 worker 运行、每节点独立记账）"
        cap_workers="${cap_workers}${n} "
      fi
    else
      warn "worker ${n} 无 hlvm.io/disk 容量且注入失败，排除该节点"
    fi
  done
  cap_workers="$(printf '%s' "${cap_workers}" | sed 's/ *$//')"
  if [ -z "${cap_workers}" ]; then
    die "没有任何 worker 获得 hlvm.io/disk 容量，拓扑验证无法进行"
  fi
  info "PASS: 具备容量的 worker 节点：${cap_workers}"

  # 3) 负向拓扑：一个**无 nodeSelector、无容忍**的申请 1 盘位的 Pod，因 CP 已 cordon，必须被
  #    调度器放到有容量的 worker（不会落到 0 容量节点）。证明 hlvm.io/disk 的 NodeAffinity/拓扑生效。
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${t0_name}
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
    hlvm.io/m15-topology: "true"
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
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
  t0_node=""
  for i in $(seq 1 20); do
    t0_node="$(kc -n hlvm-system get pod "${t0_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    [ -n "${t0_node}" ] && break
    sleep 3
  done
  if [ -z "${t0_node}" ]; then
    fail_msg "FAIL: 无选择子的申请盘位 Pod 未被调度（spec.nodeName 为空）"
    fail=1
  elif printf '%s' " ${cap_workers} " | grep -q " ${t0_node} "; then
    info "PASS: 无选择子申请落到了有容量节点 ${t0_node}（调度器尊重每节点 hlvm.io/disk 容量，未落 0 容量节点）"
  else
    fail_msg "FAIL: 无选择子申请落到了非容量节点 ${t0_node}（期望 ∈ {${cap_workers}}）——拓扑约束失效"
    fail=1
  fi
  # 释放 T0 盘位，保证后续容量账干净。
  kc -n hlvm-system delete pod "${t0_name}" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true

  if [ "${skip_fill}" -eq 0 ]; then
    # 4) 每节点容量独立 + 不跨节点超额：在每个有容量 worker 上各放 cap 个 hold Pod（nodeSelector
    #    锁到该 worker），全部必须 Running；证明调度器把每个节点的 hlvm.io/disk 当作独立上限。
    total=0
    for n in ${cap_workers}; do
      cap="$(kc get node "${n}" -o jsonpath='{.status.allocatable.hlvm\.io/disk}' 2>/dev/null || true)"
      [[ "${cap}" =~ ^[0-9]+$ ]] || cap=0
      for i in $(seq 1 "${cap}"); do
        kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: m15-topo-hold-${n}-${i}
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
    hlvm.io/m15-topology: "true"
    hlvm.io/m15-role: hold
spec:
  nodeSelector:
    kubernetes.io/hostname: ${n}
  restartPolicy: Never
  containers:
    - name: hold
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
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
        total=$((total + 1))
      done
    done

    running=0
    for i in $(seq 1 120); do
      running="$(kc -n hlvm-system get pod -l hlvm.io/m15-role=hold \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | grep -c '^Running$' || true)"
      [ "${running}" = "${total}" ] && break
      sleep 2
    done
    if [ "${total}" -gt 0 ] && [ "${running}" = "${total}" ]; then
      info "PASS: 各 worker 按自身容量填满（共 ${total} 个 hold Pod 全部 Running，每节点容量独立记账）"
    else
      fail_msg "FAIL: 只有 ${running}/${total} 个 hold Pod Running（每节点容量未独立生效）"
      kc -n hlvm-system get pod -l hlvm.io/m15-role=hold -o wide 2>&1 | tail -6
      fail=1
    fi

    # 5) 集群整体耗尽：所有 worker 盘位已用满，再提一个**无 nodeSelector**的申请必须 Pending
    #    （Insufficient hlvm.io/disk）。证明记账是集群级——任一节点都无余量时才拒绝。
    kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${tx_name}
  namespace: hlvm-system
  labels:
    hlvm.io/m15-probe: "true"
    hlvm.io/m15-topology: "true"
spec:
  restartPolicy: Never
  containers:
    - name: over
      image: ${img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
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
    over=""
    for i in $(seq 1 20); do
      over="$(kc -n hlvm-system get pod "${tx_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [ "${over}" = "Running" ] && break
      sleep 2
    done
    if [ "${over}" = "Pending" ]; then
      ev="$(kc -n hlvm-system get events --field-selector involvedObject.name=${tx_name} \
        -o jsonpath='{.items[*].message}' 2>/dev/null || true)"
      if printf '%s' "${ev}" | grep -q "Insufficient hlvm.io/disk"; then
        info "PASS: 集群盘位耗尽后跨节点申请被拒（Insufficient hlvm.io/disk，集群级容量账生效）"
      else
        info "PASS: 集群盘位耗尽后跨节点申请保持 Pending（集群级容量账生效；未取到 Insufficient 事件文本）"
      fi
    else
      fail_msg "FAIL: 集群盘位已耗尽，但 ${tx_name} 未被拒绝（phase='${over}'）——集群级容量账失效"
      fail=1
    fi

    # 6) 释放一个 worker 的盘位 → 之前 Pending 的申请必须跨节点落回该节点。同时证明 ① 设备真的
    #    回到了 kubelet（不只是数字好看）；② 调度器在容量回收后能重新跨节点调度。
    n="$(printf '%s' "${cap_workers}" | awk '{print $1}')"
    kc -n hlvm-system delete pod "m15-topo-hold-${n}-1" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
    over=""
    for i in $(seq 1 90); do
      over="$(kc -n hlvm-system get pod "${tx_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [ "${over}" = "Running" ] && break
      sleep 2
    done
    if [ "${over}" = "Running" ]; then
      got_node="$(kc -n hlvm-system get pod "${tx_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
      if [ "${got_node}" = "${n}" ]; then
        info "PASS: 释放 ${n} 盘位后，Pending 申请跨节点落回 ${n}（设备真回 kubelet + 调度器重平衡）"
      else
        info "PASS: 释放盘位后 Pending 申请转为 Running（落点 ${got_node}；设备真回 kubelet）"
      fi
    else
      fail_msg "FAIL: 释放一个节点盘位后，${tx_name} 仍未 Running（phase='${over}'）——设备未真回 kubelet"
      fail=1
    fi
  else
    warn "跳过填充/耗尽/释放断言：存在 cap>4 的 worker（本环境特异性），仅验证注入增量与负向拓扑"
  fi

  # 7) 收尾：删全部测试 Pod（标签清理）+ 各 worker rmmod + uncordon CP + 删 DaemonSet。
  kc -n hlvm-system delete pod -l hlvm.io/m15-topology=true \
    --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true

  # **必须阶段内显式清理一次**：EXIT trap 要等脚本退出才跑，那时函数局部变量（cp_node / workers）
  # 已离开作用域，`${cp_node:-}` 为空 ⇒ uncordon 被静默跳过 ⇒ CP 永久留在 SchedulingDisabled，
  # 污染后续相位与下一次运行（踩过：`all` 跑完 CP 仍 cordoned，且 0 FAIL 无人察觉）。
  topo_cleanup
  trap - EXIT
  if [ -n "${cp_node}" ]; then
    unsched="$(kc get node "${cp_node}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)"
    if [ -z "${unsched}" ]; then
      info "PASS: 收尾已 uncordon ${cp_node}（CP 恢复可调度，不留状态污染）"
    else
      fail_msg "FAIL: ${cp_node} 仍为 cordon 状态（unschedulable=${unsched}），会污染后续相位"
      fail=1
    fi
  fi

  if [ "${fail}" -eq 0 ]; then
    info "跨节点拓扑/容量账验证全部 PASS（worker 注入增量 / 无选择子落容量节点 / 每节点独立填满 / 集群耗尽 Pending / 释放后跨节点回调度）"
  else
    die "跨节点拓扑/容量账验证未通过（见上）"
  fi
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

  img="$(agent_image)"
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
    # 会被 EXIT trap 调用，那时本阶段的 local 变量（disk/pf_pid）已销毁。
    # 变量还在 ⇒ 阶段中途失败，需要兜底清理；已销毁 ⇒ 已过清理点，跳过。
    # 没有这个判断，未受 `trap - EXIT` 保护的 die 会变成 `unbound variable`，
    # 并把真正的失败原因彻底掩盖（与 migration_cleanup 同一类坑）。
    [ -n "${disk:-}" ] || return 0
    [ -n "${pf_pid:-}" ] && kill "${pf_pid}" >/dev/null 2>&1 || true
    kc delete nodedisk "${disk}" --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete pod -l component=storage-collector \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  }
  # 用 EXIT 而非 RETURN：RETURN 会在每个被调函数返回时触发，会把清理插到阶段中途。
  trap 'collector_cleanup' EXIT
  collector_cleanup

  # 1) collector 依赖扩展资源授权。
  #
  # 不能只看 allocatable：verify-device-plugin 结束时会删掉 DaemonSet，kubelet 的
  # `status.allocatable` 是静态缓存、插件断开期间不清零，可能仍读到旧值 2 而跳过部署，
  # 随后 collector Pod 申请设备就会撞上「no healthy devices」准入拒绝（与 device-plugin
  # 阶段同一个坑）。这里始终重建并等「本次」注册完成，判据与 device-plugin 阶段一致。
  deploy_plugin_and_wait "${img}"
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
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: ${disk}
spec:
  nodeName: ${node}
  device:
    path: /dev/sda
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
  local slot priv hostdevs adm
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
  #    重试一次的原因见下方注释：上一个相位若用强删 Pod，kubelet 的 device allocation 归还
  #    与「本相位创建 collector」之间存在秒级竞态，表现为 kubelet 报
  #    `UnexpectedAdmissionError ... Requested: 1, Available: 0`。
  #    这类失败是**测试脚手架自身造成的**（强删持有设备的 Pod + 卸载设备模块），不是产品缺陷，
  #    因此允许「删掉重建一次」；重试成功会打印 WARN，不静默吞掉。
  wait_collector_ready() {
    kc -n hlvm-system wait --for=condition=Ready "pod/$1" --timeout=120s >/dev/null 2>&1
  }
  if wait_collector_ready "${pod}"; then
    info "PASS: collector 就绪"
  else
    adm="$(kc -n hlvm-system describe pod "${pod}" 2>/dev/null |
      sed -r 's/\x1B\[[0-9;]*[mK]//g' | grep -c 'UnexpectedAdmissionError' || true)"
    if [ "${adm:-0}" -gt 0 ]; then
      warn "collector 首次调度遭遇 kubelet 设备 allocation 未释放（UnexpectedAdmissionError），删除重建后重试一次"
      kc -n hlvm-system delete pod "${pod}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
      for i in $(seq 1 60); do
        pod="$(kc -n hlvm-system get pod -l component=storage-collector \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [ -n "${pod}" ] && break
        sleep 2
      done
    fi
    if [ -n "${pod:-}" ] && wait_collector_ready "${pod}"; then
      info "PASS: collector 就绪（重建后）"
    else
      fail_msg "FAIL: collector 未在 120s 内就绪"
      kc -n hlvm-system describe pod "${pod}" 2>&1 | tail -10
      fail=1
    fi
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
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: m15-slot-${n}
spec:
  nodeName: ${node}
  device:
    path: /dev/sda
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

# verify-conversion：CRD 双版本 + conversion webhook（add-hardening-rollout 3.1b）。
#
# 收敛后 v1beta1 是**存储版本**，v1alpha1 是老客户端兼容层。验证的是**协议与接线**：
#   - 写入路径：以 v1alpha1 写入（老客户端）→ 经 webhook 转换成 v1beta1 落盘；
#   - 读取路径：读 v1alpha1（非存储版本）→ 经 webhook 从 v1beta1 转换回来；
#   - 字段映射是否正确（v1alpha1 `spec.deviceRef` ⇄ v1beta1 `spec.device.path`）；
#   - 列表读写是否同样走转换（apiserver 对 List 是整体下发，不是逐条）；
#   - 爆炸半径论断（收敛后）：webhook 挂了 v1beta1（存储版本，控制器走它）仍可读，
#     只有显式用 v1alpha1 的老客户端读写会失败——爆炸半径限于 v1alpha1 兼容层。
#
# 注意：本阶段会**改写全部 5 个 Kind 的 CRD**（apply 03b~03f 双版本目标形态 + conversion），
# 结束时恢复 bases 目录的 5 份单版本 v1beta1；中途失败会留下带 conversion 的 CRD，
# 下次 bootstrap 会重新 apply 基础 CRD 覆盖回来。
phase_verify_conversion() {
  log "验证 CRD conversion webhook：双版本 CRD、字段映射、列表转换、webhook 依赖与爆炸半径"
  ensure_cluster_ready

  local fail=0 img="" name="m15-conv-disk" path=""
  local crd_workloads="${CP}/config/hardening/03-crd-conversion.yaml"
  [ -f "${crd_workloads}" ] || die "缺少 ${crd_workloads}"

  if kc -n cert-manager get deployment cert-manager-webhook >/dev/null 2>&1; then
    info "cert-manager 可用（证书供给与 caBundle 注入依赖它）"
  else
    die "cert-manager 未安装：先跑 bootstrap（或 helm 装 cert-manager ${CERT_MANAGER_VERSION}）"
  fi

  # 1) 构建并装载镜像。Dockerfile 以 CMD_NAME 参数化，无需新增 Dockerfile。
  img="$(conversion_image)"
  ensure_conversion_image "${img}"

  # 启用/移除 served 版本后必须清 kubectl 的 discovery 缓存。
  #
  # kubectl 缓存 discovery 约 10 分钟；缓存里一旦记下 v1beta1 是 preferredVersion，
  # 等 CRD 恢复成单版本后，裸资源名（`kubectl get nodedisk`）仍会被解析到 v1beta1，
  # 请求打到一个不存在的 API 路径上，报 404 `could not find the requested resource`
  # ——看起来像"对象被删了"，实际是客户端缓存陈旧（2026-10-30 实测：verify-conversion
  # 结束后紧接着跑 all，verify-taskgc 就因此挂掉）。缓存重建成本极低，直接删。
  clear_discovery_cache() {
    rm -rf "${HOME}/.kube/cache/discovery" 2>/dev/null || true
  }

  conversion_cleanup() {
    # 同样会被 EXIT trap 调用（见 collector_cleanup / migration_cleanup 的说明）：
    # `${name}` 为空说明本阶段的 local 变量已销毁，清理点已过，跳过而非报 unbound。
    [ -n "${name:-}" ] || return 0
    # 顺序很重要：先删测试对象（此刻 CRD 仍是双版本，v1beta1/v1alpha1 都 served），
    # 再把 CRD 收成 bases 单版本 v1beta1。反了的话对象已不在 served 版本里、删不掉会残留。
    # 对象在步骤 5/6 均以 v1beta1 存储版本落盘，用 v1beta1 全限定名删除最稳。
    # 本相位会在 5 个 Kind 上各建一个探针对象，统一带 hlvm.io/m15-conversion=true；
    # 按 label 删比逐个记名字稳（EXIT trap 里 local 变量可能已销毁）。
    for r in nodedisks nodevgs storagetasks storagenodeops thinpoolpolicies; do
      kc delete "${r}.v1beta1.storage.example.io" -l hlvm.io/m15-conversion=true \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    restore_single_version_crds
    clear_discovery_cache
    kc -n hlvm-system delete deployment hlvm-crd-conversion --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc -n hlvm-system delete service hlvm-crd-conversion --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete certificate hlvm-crd-conversion-serving-cert --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete secret hlvm-crd-conversion-serving-cert --ignore-not-found >/dev/null 2>&1 || true
    # 固定 CA 链的附属对象：先删 Certificate 再删 Issuer/secret，避免 cert-manager 继续重新签发。
    kc -n hlvm-system delete certificate hlvm-crd-conversion-ca --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete issuer hlvm-crd-conversion-ca-issuer --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete issuer hlvm-crd-conversion-selfsigned --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete secret hlvm-crd-conversion-ca --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete serviceaccount hlvm-crd-conversion --ignore-not-found >/dev/null 2>&1 || true
  }
  conversion_cleanup
  clear_discovery_cache
  trap 'conversion_cleanup; trap - EXIT' EXIT

  # 2) 先起服务，再开转换（顺序反了会让老客户端 v1alpha1 读写短暂全失败；v1beta1 存储
  #    版本读写不经 webhook 不受影响，但保持这个顺序仍是正确做法）。
  apply_manifest_with_image "${crd_workloads}" "${img}" || die "apply conversion 工作负载失败"
  # kind 用 IfNotPresent（镜像只在本地）；real 用 Always（tag=latest，避免命中节点旧缓存）。
  local m15_pull="IfNotPresent"
  if is_real; then m15_pull="Always"; fi
  kc -n hlvm-system patch deployment hlvm-crd-conversion --type=json \
    -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"${m15_pull}\"}]" \
    >/dev/null 2>&1 || true
  if kc -n hlvm-system rollout status deployment/hlvm-crd-conversion --timeout=180s >/dev/null 2>&1; then
    info "PASS: conversion 服务 2 副本就绪（GHCR 私有，kind 内用本地镜像）"
  else
    fail_msg "FAIL: conversion Deployment 未在 180s 内就绪"
    # 诊断输出本身不能再失败（pipefail 下会让 set -e 提前退出，看不到真正的错因）。
    kc -n hlvm-system get pods -l app.kubernetes.io/component=crd-conversion 2>&1 | tail -3 || true
    kc -n hlvm-system logs deployment/hlvm-crd-conversion --tail=10 2>&1 | tail -10 || true
    fail=1
  fi

  # 3) 证书供给：secret 必须由 cert-manager 签发（不是我们预先塞的假证书）。
  if kc -n hlvm-system get secret hlvm-crd-conversion-serving-cert \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | grep -q .; then
    info "PASS: cert-manager 已签发 serving 证书（tls.crt 存在）"
  else
    fail_msg "FAIL: 未拿到 serving 证书，conversion 将因 TLS 失败而不可用"
    fail=1
  fi

  # 4) 开启双版本 + conversion：5 个 Kind 全覆盖（03b~03f 一次起齐）。
  apply_dual_version_crds || die "apply 双版本 CRD 失败"

  # caBundle 由 cert-manager cainjector 异步注入，5 个 CRD 注入时间可能不同，需等全部就绪。
  local m15_crds="nodedisks nodevgs storagetasks storagenodeops thinpoolpolicies"
  local ca="" c="" ready=0
  local i
  for i in $(seq 1 30); do
    ready=1
    for c in ${m15_crds}; do
      ca="$(kc get crd "${c}.storage.example.io" \
        -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' 2>/dev/null || true)"
      [ -n "${ca}" ] || ready=0
    done
    [ "${ready}" -eq 1 ] && break
    sleep 2
  done
  if [ "${ready}" -eq 1 ]; then
    info "PASS: cert-manager 已为 5 个 CRD 全部注入 conversion caBundle"
  else
    fail_msg "FAIL: 5 个 CRD 的 caBundle 未全部注入，apiserver 会以 x509 unknown authority 拒绝调用"
    fail=1
  fi
  local strategy
  for c in ${m15_crds}; do
    strategy="$(kc get crd "${c}.storage.example.io" -o jsonpath='{.spec.conversion.strategy}' 2>/dev/null || true)"
    if [ "${strategy}" = "Webhook" ]; then
      info "PASS: ${c} conversion.strategy=Webhook（v1beta1=storage / v1alpha1=served 兼容层）"
    else
      fail_msg "FAIL: ${c} conversion.strategy 不是 Webhook（实际: ${strategy}）"
      fail=1
    fi
  done

  # 4b) 版本优先级：CRD 的 preferredVersion 由版本名优先级决定（v1beta1 > v1alpha1），
  # 与"谁是存储版本"无关。这意味着**裸资源名**（kubectl get nodedisk）从此解析到 v1beta1，
  # 既有依赖裸名的脚本会换视图——这是启用新版本最容易被忽略的一处影响，故单独断言。
  local preferred
  preferred="$(kc get --raw /apis/storage.example.io 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("preferredVersion",{}).get("version",""))' 2>/dev/null || true)"
  if [ "${preferred}" = "v1beta1" ]; then
    info "PASS: preferredVersion=v1beta1（裸资源名解析到 v1beta1，且它正是存储版本）"
  else
    fail_msg "FAIL: preferredVersion 预期 v1beta1，实际 '${preferred}'"
    fail=1
  fi

  # 5) 正向映射（写入路径转换）：以老客户端 v1alpha1 写入，apiserver 经 webhook 把它
  #    转换成 v1beta1 存储版本落盘；读 v1beta1 是存储版本、不经 webhook。
  cat <<EOF | kc apply -f - >/dev/null || die "创建 v1alpha1 NodeDisk 失败"
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: ${name}
  labels:
    hlvm.io/m15-conversion: "true"
spec:
  nodeName: ${NODE_NAME}
  deviceRef: /dev/sda
  adopt: true
EOF

  path="$(kc get nodedisks.v1beta1.storage.example.io "${name}" \
    -o jsonpath='{.spec.device.path}' 2>/dev/null || true)"
  if [ "${path}" = "/dev/sda" ]; then
    info "PASS: v1alpha1 spec.deviceRef → v1beta1 spec.device.path=/dev/sda（webhook 真实参与转换）"
  else
    fail_msg "FAIL: v1beta1 读到的 device.path 不对（实际: '${path}'）"
    fail=1
  fi

  local leaked
  leaked="$(kc get nodedisks.v1beta1.storage.example.io "${name}" \
    -o jsonpath='{.spec.deviceRef}' 2>/dev/null || true)"
  if [ -z "${leaked}" ]; then
    info "PASS: v1beta1 视图不含 spec.deviceRef（确认是结构变更而非两字段并存）"
  else
    fail_msg "FAIL: v1beta1 视图仍带 spec.deviceRef=${leaked}（可能是直接透传没有映射）"
    fail=1
  fi

  # 6) 反向（读取路径转换）：以 v1beta1 存储版本写入（不经 webhook），再以 v1alpha1
  #    读回——读非存储版本会触发 webhook 从 v1beta1 转换成 v1alpha1。
  cat <<EOF | kc apply -f - >/dev/null || die "以 v1beta1 更新 NodeDisk 失败"
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: ${name}
  labels:
    hlvm.io/m15-conversion: "true"
spec:
  nodeName: ${NODE_NAME}
  device:
    path: /dev/sdb
  adopt: true
EOF

  # 注意：**必须**显式限定版本。CRD 的 preferredVersion 由版本优先级决定
  # （v1beta1 > v1alpha1），与哪个是存储版本无关；写成裸 `nodeDisk` 会被 kubectl
  # 解析到 v1beta1，`.spec.deviceRef` 自然读不到，看起来像"转换丢了字段"（踩过）。
  local back adopt
  back="$(kc get nodedisks.v1alpha1.storage.example.io "${name}" -o jsonpath='{.spec.deviceRef}' 2>/dev/null || true)"
  adopt="$(kc get nodedisks.v1alpha1.storage.example.io "${name}" -o jsonpath='{.spec.adopt}' 2>/dev/null || true)"
  if [ "${back}" = "/dev/sdb" ] && [ "${adopt}" = "true" ]; then
    info "PASS: v1beta1 写入 → v1alpha1 读回 deviceRef=/dev/sdb、adopt=true（反向转换无损）"
  else
    fail_msg "FAIL: 反向转换结果不对（deviceRef='${back}' adopt='${adopt}'）"
    fail=1
  fi

  # 7) 列表转换：apiserver 对 List 是整体下发，逐条转换的实现在这里会露馅。
  local n_alpha n_beta
  n_alpha="$(kc get nodedisks.v1alpha1.storage.example.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)"
  n_beta="$(kc get nodedisks.v1beta1.storage.example.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)"
  if [ "${n_alpha}" = "${n_beta}" ] && [ "${n_alpha}" -ge 1 ]; then
    info "PASS: 列表转换两个版本条目数一致（v1alpha1=${n_alpha} / v1beta1=${n_beta}）"
  else
    fail_msg "FAIL: 列表条目数不一致（v1alpha1=${n_alpha} / v1beta1=${n_beta}）"
    fail=1
  fi

  # 7b) 另外 4 个 Kind：v1alpha1 ⇄ v1beta1 是 schema 恒等映射（只有 NodeDisk 是结构变更）。
  #     03c~03f 此前从未被任何相位 apply 过——单测/envtest 测过不等于集群 conversion 链路通。
  #     探针统一放 metadata.labels.m15conv：避开各 Kind 的 spec 差异与控制器写路径；
  #     spec 只填最小合法字段，且 nodeName 用**不存在的节点名**，否则 NodeOpsReconciler
  #     会真的去给节点打 isolate 标签并 cordon（这是产品行为，不该被测试脚本触发）。
  verify_identity_kind() {
    local plural="$1" kind="$2" obj="$3" spec_a="$4" spec_b="$5"
    local yaml_a yaml_b got na nb rc=0
    yaml_a="$(printf 'apiVersion: storage.example.io/v1alpha1\nkind: %s\nmetadata:\n  name: %s\n  labels:\n    hlvm.io/m15-conversion: "true"\n    m15conv: alpha-a\n%s\n' "${kind}" "${obj}" "${spec_a}")"
    yaml_b="$(printf 'apiVersion: storage.example.io/v1beta1\nkind: %s\nmetadata:\n  name: %s\n  labels:\n    hlvm.io/m15-conversion: "true"\n    m15conv: beta-b\n%s\n' "${kind}" "${obj}" "${spec_b}")"
    if ! printf '%s\n' "${yaml_a}" | kc apply -f - >/dev/null 2>&1; then
      fail_msg "FAIL: ${kind} 以 v1alpha1 创建探针对象失败（conversion 写入路径不通）"
      return 1
    fi
    got="$(kc get "${plural}.v1beta1.storage.example.io" "${obj}" \
      -o 'jsonpath={.metadata.labels.m15conv}' 2>/dev/null || true)"
    if [ "${got}" != "alpha-a" ]; then
      fail_msg "FAIL: ${kind} v1alpha1→v1beta1 探针丢失（实际 '${got}'）"; rc=1
    fi
    if ! printf '%s\n' "${yaml_b}" | kc apply -f - >/dev/null 2>&1; then
      fail_msg "FAIL: ${kind} 以 v1beta1 更新探针对象失败"
      return 1
    fi
    got="$(kc get "${plural}.v1alpha1.storage.example.io" "${obj}" \
      -o 'jsonpath={.metadata.labels.m15conv}' 2>/dev/null || true)"
    if [ "${got}" != "beta-b" ]; then
      fail_msg "FAIL: ${kind} v1beta1→v1alpha1 探针丢失（实际 '${got}'；读取路径转换不通）"; rc=1
    fi
    na="$(kc get "${plural}.v1alpha1.storage.example.io" -o 'jsonpath={.items[*].metadata.name}' 2>/dev/null | wc -w)"
    nb="$(kc get "${plural}.v1beta1.storage.example.io" -o 'jsonpath={.items[*].metadata.name}' 2>/dev/null | wc -w)"
    if [ "${na}" != "${nb}" ] || [ "${na}" -lt 1 ]; then
      fail_msg "FAIL: ${kind} 列表转换条目数不一致（v1alpha1=${na} / v1beta1=${nb}）"; rc=1
    fi
    return "${rc}"
  }

  if verify_identity_kind "nodevgs" "NodeVG" "m15-conv-vg" \
      'spec:
  nodeName: m15-conv-fake-node
  tier: conv-a' \
      'spec:
  nodeName: m15-conv-fake-node
  tier: conv-b'; then
    info "PASS: NodeVG 双版本转换链路可用（写入/读取/列表，恒等映射）"
  else
    fail=1
  fi
  if verify_identity_kind "storagetasks" "StorageTask" "m15-conv-task" \
      'spec:
  nodeName: m15-conv-fake-node
  type: pvcreate' \
      'spec:
  nodeName: m15-conv-fake-node
  type: pvcreate
  dryRun: true'; then
    info "PASS: StorageTask 双版本转换链路可用（写入/读取/列表，恒等映射）"
  else
    fail=1
  fi
  if verify_identity_kind "storagenodeops" "StorageNodeOps" "m15-conv-ops" \
      'spec:
  nodeName: m15-conv-fake-node
  operation: isolate' \
      'spec:
  nodeName: m15-conv-fake-node
  operation: isolate
  force: true'; then
    info "PASS: StorageNodeOps 双版本转换链路可用（写入/读取/列表，恒等映射）"
  else
    fail=1
  fi
  if verify_identity_kind "thinpoolpolicies" "ThinPoolPolicy" "m15-conv-policy" \
      'spec: {}' 'spec: {}'; then
    info "PASS: ThinPoolPolicy 双版本转换链路可用（写入/读取/列表，恒等映射）"
  else
    fail=1
  fi

  # 8) 破坏性反证（收敛后的爆炸半径）：webhook 下线后——
  #    v1alpha1 是非存储版本、读它需要 webhook 转换 ⇒ 必须失败（反证转换确实经 webhook）；
  #    v1beta1 是存储版本、读它不经 webhook ⇒ 必须仍可读（控制器走它，不受影响）。
  kc -n hlvm-system scale deployment/hlvm-crd-conversion --replicas=0 >/dev/null 2>&1 || true
  kc -n hlvm-system wait --for=delete pod -l app.kubernetes.io/component=crd-conversion \
    --timeout=90s >/dev/null 2>&1 || true
  if kc get nodedisks.v1alpha1.storage.example.io "${name}" >/dev/null 2>&1; then
    fail_msg "FAIL: webhook 已下线但 v1alpha1 仍可读——转换没有真正依赖 webhook，结论不成立"
    fail=1
  else
    info "PASS: webhook 下线后 v1alpha1 读失败（读取路径转换确实经由 webhook，不是本地兜底）"
  fi
  if kc get nodedisks.v1beta1.storage.example.io "${name}" -o name >/dev/null 2>&1; then
    info "PASS: 同一时刻 v1beta1（存储版本）仍可读——控制器不受影响，爆炸半径限于 v1alpha1 老客户端"
  else
    fail_msg "FAIL: webhook 下线把 v1beta1 存储版本也拖挂了，控制器会随之不可用"
    fail=1
  fi

  # 9) 恢复：服务回到 2 副本后 v1alpha1 读必须自愈（不需要重启 apiserver）。
  kc -n hlvm-system scale deployment/hlvm-crd-conversion --replicas=2 >/dev/null 2>&1 || true
  kc -n hlvm-system rollout status deployment/hlvm-crd-conversion --timeout=180s >/dev/null 2>&1 || true
  local recovered=0
  for i in $(seq 1 20); do
    if kc get nodedisks.v1alpha1.storage.example.io "${name}" -o name >/dev/null 2>&1; then
      recovered=1
      break
    fi
    sleep 2
  done
  if [ "${recovered}" -eq 1 ]; then
    info "PASS: 服务恢复后 v1alpha1 读自愈（apiserver 无需重启）"
  else
    fail_msg "FAIL: 服务恢复后 v1alpha1 仍不可读"
    fail=1
  fi

  conversion_cleanup
  clear_discovery_cache
  trap - EXIT
  if [ "${fail}" -ne 0 ]; then
    die "conversion 验证未通过（见上）"
  fi
  info "conversion 验证全部 PASS（5 个 Kind：NodeDisk 12 条结构映射深度断言 / 5 个 CRD 的 caBundle+strategy 接线 / 其余 4 个 Kind 的双向往返与列表转换 / webhook 依赖反证 / 收敛后爆炸半径 / 自愈）"
}

# verify-cert-rotation：serving 证书重建时的 CA 稳定性、caBundle 免重注入、进程热加载。
#
# 为什么单独成阶段：证书轮换此前只验到「cert-manager 会签发 + 进程会热加载」，从没验过
# 「轮换过程中控制面还可不可用」。2026-10-30 在 kind 实测（删 secret 触发重签）发现：
#   ① selfSigned Issuer 签出的 serving 证书**自己就是根**，重建即换根；
#   ② CRD 上的 caBundle 由 cainjector **异步**重注入，与证书生效不同步；
#   ③ 两者之间 8–45 次调用连续失败、服务端持续 `tls: bad certificate`，
#      而 Pod 全程 Ready、restartCount=0 —— 假 Ready，没有任何就绪或告警信号。
# 因此清单改为「固定根 CA（10 年、私钥不轮换）+ 由它签发的 serving 证书」。本阶段验证
# 修好之后的三条性质（CA 不变 / caBundle 不变 / 链路仍可验证），并用「把 Certificate 改回
# selfSigned」做反证——否则无法排除「其实什么都没变，所以当然没问题」。
phase_verify_cert_rotation() {
  log "验证 serving 证书轮换：固定 CA 使 caBundle 免重注入、证书热加载、Pod 不重启"
  ensure_cluster_ready
  have openssl || die "需要 openssl 解析与校验证书链"

  local fail=0 img="" name="m15-cert-disk"
  local crd_workloads="${CP}/config/hardening/03-crd-conversion.yaml"
  local ns="hlvm-system" cert="hlvm-crd-conversion-serving-cert" i
  [ -f "${crd_workloads}" ] || die "缺少 ${crd_workloads}"
  kc -n cert-manager get deployment cert-manager-webhook >/dev/null 2>&1 \
    || die "cert-manager 未安装：先跑 bootstrap"

  local tmpd; tmpd="$(mktemp -d)"
  # 判据一律按**内容**算指纹。不要用长度：自签证书重建后长度往往一字不差，
  # 2026-10-30 第一版就是按 caBundle 长度判断，把「CA 已变」误读成「没变」。
  crt_sha() { kc -n "${ns}" get secret "${cert}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
                | base64 -d > "${tmpd}/leaf.crt" 2>/dev/null || true
              [ -s "${tmpd}/leaf.crt" ] && sha256sum "${tmpd}/leaf.crt" | cut -c1-16 || true; }
  ca_sha()  { kc -n "${ns}" get secret "${cert}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
                | base64 -d > "${tmpd}/ca.crt" 2>/dev/null || true
              [ -s "${tmpd}/ca.crt" ] && sha256sum "${tmpd}/ca.crt" | cut -c1-16 || true; }
  bundle_sha() { kc get crd nodedisks.storage.example.io \
                   -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' 2>/dev/null \
                   | base64 -d > "${tmpd}/bundle.crt" 2>/dev/null || true
                 [ -s "${tmpd}/bundle.crt" ] && sha256sum "${tmpd}/bundle.crt" | cut -c1-16 || true; }
  bundle_verifies_leaf() { [ -s "${tmpd}/bundle.crt" ] && [ -s "${tmpd}/leaf.crt" ] \
                             && openssl verify -CAfile "${tmpd}/bundle.crt" "${tmpd}/leaf.crt" >/dev/null 2>&1; }
  verify_with_bundle() { [ -s "${tmpd}/bundle.crt" ] && [ -s "$1" ] \
                             && openssl verify -CAfile "${tmpd}/bundle.crt" "$1" >/dev/null 2>&1; }
  # 「证书生效」不能看 secret：kubelet 把 secret 挂载同步进容器最长要 1min 以上
  # （2026-10-30 实测 61s），期间 secret 里已是新证书、进程用的还是旧的。判据取服务端
  # 实际提供的证书——port-forward 到 pod 后用 s_client 抓。这也顺带证明了热加载真的生效，
  # 比 grep 内部日志字符串硬（日志格式随 controller-runtime 版本变）。
  server_leaf() {
    timeout 5 openssl s_client -connect "127.0.0.1:19443" \
      -servername hlvm-crd-conversion.hlvm-system.svc -showcerts </dev/null 2>/dev/null \
      | openssl x509 -outform PEM > "${tmpd}/srv.crt" 2>/dev/null || true
    [ -s "${tmpd}/srv.crt" ] \
      && openssl x509 -in "${tmpd}/srv.crt" -noout -fingerprint -sha256 2>/dev/null \
           | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z' | cut -c1-16 || true
  }
  pf_pid=""
  start_pf() {
    local j
    stop_pf
    kc -n "${ns}" port-forward "pod/$1" 19443:9444 >/dev/null 2>&1 &
    pf_pid=$!
    for j in $(seq 1 20); do
      [ -n "$(server_leaf)" ] && return 0
      sleep 1
    done
    return 1
  }
  # EXIT trap 里也会调用：pf_pid 需用 ${pf_pid:-} 兜底（set -u），kill 失败不能中断清理。
  stop_pf() {
    if [ -n "${pf_pid:-}" ]; then kill "${pf_pid}" 2>/dev/null || true; pf_pid=""; fi
    return 0
  }
  # 等某个指纹从 from 变成别的值（证书重建/重签是异步的，固定 sleep 会写出 flaky 断言）。
  wait_change() {
    local fn="$1" from="$2" limit="${3:-60}" j cur=""
    for j in $(seq 1 "${limit}"); do
      cur="$(${fn})"
      [ -n "${cur}" ] && [ "${cur}" != "${from}" ] && { printf '%s' "${cur}"; return 0; }
      sleep 1
    done
    printf '%s' "${cur}"; return 1
  }

  # 注意：本函数会被 EXIT trap 调用，那时函数的 local 变量（ns/cert/name）已销毁，
  # 故一律写字面量。用 "${ns}" 会得到 `ns: unbound variable` 并让清理半途而废。
  conversion_teardown() {
    # 先删 Certificate 再删 Issuer/secret：否则 cert-manager 会继续按旧 Certificate 重签。
    kc -n hlvm-system delete certificate hlvm-crd-conversion-serving-cert --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete certificate hlvm-crd-conversion-ca --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete issuer hlvm-crd-conversion-ca-issuer --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete issuer hlvm-crd-conversion-selfsigned --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete secret hlvm-crd-conversion-serving-cert --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete secret hlvm-crd-conversion-ca --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete deployment hlvm-crd-conversion --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc -n hlvm-system delete service hlvm-crd-conversion --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete serviceaccount hlvm-crd-conversion --ignore-not-found >/dev/null 2>&1 || true
    # 顺序很重要：先删测试对象（此刻 CRD 仍是双版本、两版本都 served），再把 CRD 收成
    # bases 单版本 v1beta1；反了会因 v1alpha1 不再 served 而删不掉、残留脏数据。
    # 对象以 v1beta1 存储版本落盘，用 v1beta1 全限定名删除最稳。
    kc delete nodedisks.v1beta1.storage.example.io m15-cert-disk --ignore-not-found --wait=false >/dev/null 2>&1 || true
    cleanup_conversion_probe_objects
    restore_single_version_crds
    rm -rf "${HOME}/.kube/cache/discovery" 2>/dev/null || true
  }
  conversion_teardown
  trap 'stop_pf; conversion_teardown; trap - EXIT' EXIT

  # 1) 起服务（先服务后转换，见 03-crd-conversion.yaml 的应用顺序说明）。
  img="$(conversion_image)"
  ensure_conversion_image "${img}"
  apply_manifest_with_image "${crd_workloads}" "${img}" || die "apply conversion 工作负载失败"
  # kind 用 IfNotPresent（镜像只在本地）；real 用 Always（tag=latest，避免命中节点旧缓存）。
  local m15_pull="IfNotPresent"
  if is_real; then m15_pull="Always"; fi
  kc -n "${ns}" patch deployment hlvm-crd-conversion --type=json \
    -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"${m15_pull}\"}]" \
    >/dev/null 2>&1 || true
  if kc -n "${ns}" rollout status deployment/hlvm-crd-conversion --timeout=180s >/dev/null 2>&1; then
    info "PASS: conversion 服务 2 副本就绪"
  else
    fail_msg "FAIL: conversion Deployment 未在 180s 内就绪"
    kc -n "${ns}" get pods -l app.kubernetes.io/component=crd-conversion 2>&1 | tail -3 || true
    fail=1
  fi

  # 2) 证书链形态：根 CA 必须是 CA，serving 证书必须由它签发。
  for i in $(seq 1 40); do
    [ -n "$(crt_sha)" ] && [ -n "$(ca_sha)" ] && break
    sleep 2
  done
  if openssl x509 -in "${tmpd}/ca.crt" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
    info "PASS: 根 CA 已签发且 BasicConstraints=CA:TRUE（到期 $(openssl x509 -in "${tmpd}/ca.crt" -noout -enddate | cut -d= -f2)）"
  else
    fail_msg "FAIL: 根 CA 不是 CA 证书（或未签发），固定链不成立"
    fail=1
  fi
  local issuer ca_subj
  issuer="$(openssl x509 -in "${tmpd}/leaf.crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true)"
  ca_subj="$(openssl x509 -in "${tmpd}/ca.crt" -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
  if [ -n "${issuer}" ] && [ "${issuer}" = "${ca_subj}" ]; then
    info "PASS: serving 证书由根 CA 签发（issuer=${issuer}），不再是 selfSigned 自签自证"
  else
    fail_msg "FAIL: serving 证书 issuer='${issuer}' 与根 CA subject='${ca_subj}' 不一致"
    fail=1
  fi

  # 3) 开双版本（5 个 Kind），等 caBundle 注入，确认注入的就是这个 CA（而不是 leaf 自己）。
  apply_dual_version_crds || die "apply 双版本 CRD 失败"
  for i in $(seq 1 30); do [ -n "$(bundle_sha)" ] && break; sleep 2; done
  local ca_v bundle_v
  ca_v="$(sha256sum "${tmpd}/ca.crt" | cut -c1-16)"
  bundle_v="$(sha256sum "${tmpd}/bundle.crt" 2>/dev/null | cut -c1-16 || true)"
  if [ -n "${bundle_v}" ] && [ "${bundle_v}" = "${ca_v}" ]; then
    info "PASS: caBundle 注入的就是根 CA（指纹 ${ca_v}），不是 serving 证书本身"
  else
    fail_msg "FAIL: caBundle(=${bundle_v}) 与根 CA(=${ca_v}) 不一致"
    fail=1
  fi
  if bundle_verifies_leaf; then
    info "PASS: caBundle 能验证 serving 证书（openssl verify 通过，链完整）"
  else
    fail_msg "FAIL: caBundle 无法验证 serving 证书，apiserver 会握手失败"
    fail=1
  fi

  # 3b) 多 Kind smoke：5 份双版本清单都起齐了，但不能只验 NodeDisk 就宣布全绿。
  #     这里对其余 4 个 Kind 各走一次 v1alpha1 写 → v1beta1 读，证明本相位下
  #     同一 conversion 服务对全部 Kind 都可调（证书类演练最容易只修好一个 Kind）。
  if ! smoke_all_conversion_kinds "rot"; then fail=1; fi

  # 4) 建一个对象作为转换可用性的探针（不能只看 Pod Ready：假 Ready 正是本阶段要防的）。
  cat <<EOF | kc apply -f - >/dev/null || die "创建探针 NodeDisk 失败"
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: ${name}
spec:
  nodeName: ${NODE_NAME}
  deviceRef: /dev/sda
  adopt: true
EOF

  # 只取 Running 且 Ready 的 Pod：rollout 刚结束时常有终止中的旧 Pod，用 items[0] 会
  # 拿到一个马上消失的名字（port-forward 直接 NotFound，2026-10-30 踩过）。
  local pod="" pod_uid restarts_before
  for i in $(seq 1 30); do
    pod="$(kc -n "${ns}" get pod -l app.kubernetes.io/component=crd-conversion \
             --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "${pod}" ] && kc -n "${ns}" wait --for=condition=Ready "pod/${pod}" --timeout=30s >/dev/null 2>&1; then
      break
    fi
    pod=""; sleep 2
  done
  [ -n "${pod}" ] || die "找不到 Ready 的 conversion Pod"
  pod_uid="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.metadata.uid}')"
  restarts_before="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].restartCount}')"

  local leaf0 ca0 bundle0
  leaf0="$(crt_sha)"; ca0="$(ca_sha)"; bundle0="$(bundle_sha)"
  info "基线：leaf=${leaf0} ca=${ca0} caBundle=${bundle0}（caBundle 与 CA 相同即为固定链）"

  # 5) 起 TLS 探针：读「服务端实际在用的证书」。secret 与它可能长期不一致（kubelet 异步同步），
  #    所以后面凡涉及「生效」的判定一律以此为准，不看 secret、也不 grep 内部日志。
  if start_pf "${pod}"; then
    info "PASS: 已建立 TLS 探针（port-forward 19443 → 9444，直连 conversion 容器）"
  else
    fail_msg "FAIL: port-forward 未就绪，无法读取服务端证书"
    fail=1
  fi
  local srv0; srv0="$(server_leaf)"
  info "基线：服务端=${srv0:-取不到} / secret 内=${leaf0} / CA=${ca0} / caBundle=${bundle0}"

  # 6) 删 serving 证书的 secret，模拟「证书丢失/被外部重建」——轮换链路最坏的一种入口。
  kc -n "${ns}" delete secret "${cert}" >/dev/null 2>&1 || true
  local leaf1; leaf1="$(wait_change crt_sha "${leaf0}" 90 >/dev/null 2>&1 && crt_sha || crt_sha)"
  if [ -n "${leaf1}" ] && [ "${leaf1}" != "${leaf0}" ]; then
    info "PASS: serving 证书已重新签发（secret 侧 ${leaf0} → ${leaf1}），后面的断言才有意义"
  else
    fail_msg "FAIL: 删 secret 后 serving 证书未重建（指纹仍 '${leaf1}'），无法验证轮换"
    fail=1
  fi

  # 证书真正生效要看服务端：kubelet 同步 secret 挂载实测约 61s，上限放到 180s。
  local srv1="" t0
  t0="$(date +%s)"
  for i in $(seq 1 90); do
    srv1="$(server_leaf)"
    [ -n "${srv1}" ] && [ "${srv1}" != "${srv0}" ] && break
    sleep 2
  done
  if [ -n "${srv1}" ] && [ "${srv1}" != "${srv0}" ]; then
    info "PASS: 服务端已切到新证书（${srv0} → ${srv1}，$(( $(date +%s) - t0 ))s，进程未重启）"
  else
    fail_msg "FAIL: 服务端证书未更新（仍 '${srv1}'），certwatcher 热加载未生效"
    fail=1
  fi

  local ca1 bundle1
  ca1="$(ca_sha)"; bundle1="$(bundle_sha)"
  if [ "${ca1}" = "${ca0}" ]; then
    info "PASS: 重建 serving 证书**没有**改变根 CA（指纹仍 ${ca0}）"
  else
    fail_msg "FAIL: 根 CA 变了（${ca0} → ${ca1}），固定链失效，caBundle 必然要重注入"
    fail=1
  fi
  if [ "${bundle1}" = "${bundle0}" ]; then
    info "PASS: caBundle 未变（无需 cainjector 重注入，因此没有失配窗口）"
  else
    fail_msg "FAIL: caBundle 变了（${bundle0} → ${bundle1}），存在重注入窗口"
    fail=1
  fi
  if verify_with_bundle "${tmpd}/srv.crt"; then
    info "PASS: 新服务端证书仍被当前 caBundle 验证通过（链完整）"
  else
    fail_msg "FAIL: 新服务端证书与 caBundle 不匹配"
    fail=1
  fi

  # 7) 真的能用：转换请求必须成功（这是与「Pod Ready」不同的判据）。
  #    关键：探针以 v1alpha1 写入、落盘为 v1beta1 存储版本。读 v1beta1 不经 webhook，
  #    证明不了 TLS 链路可用；必须读 v1alpha1（非存储版本，需 webhook 转换回来），
  #    才能真正验证「apiserver → webhook 的 TLS 握手在换证书后仍然通」。
  local usable=0
  for i in $(seq 1 30); do
    if kc get nodedisks.v1alpha1.storage.example.io "${name}" -o name >/dev/null 2>&1; then
      usable=1; break
    fi
    sleep 2
  done
  if [ "${usable}" -eq 1 ]; then
    info "PASS: 证书更换后 v1alpha1 转换读仍可用（TLS 链路真通，apiserver 与 Pod 都未重启）"
  else
    fail_msg "FAIL: 证书更换后 v1alpha1 转换读不可用（TLS 握手或 webhook 有问题）"
    fail=1
  fi

  # 8) 全程没有重启——换证书靠的是热加载。放在最后，顺带覆盖前面等待窗口里的意外重建。
  local pod_uid2 restarts_after
  pod_uid2="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  restarts_after="$(kc -n "${ns}" get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
  if [ "${pod_uid2}" = "${pod_uid}" ] && [ "${restarts_after}" = "${restarts_before}" ]; then
    info "PASS: 换证书全程 Pod 未重启（uid 不变、restartCount 仍 ${restarts_after}）"
  else
    fail_msg "FAIL: Pod 被重建或重启（uid ${pod_uid}→${pod_uid2} restarts ${restarts_before}→${restarts_after}）"
    fail=1
  fi
  stop_pf

  # 9) 反证：把 serving Certificate 改回 selfSigned（原来的形态），重跑同样的删除动作。
  #    如果这时的 CA 和 caBundle 都不变，说明本阶段的结论与环境无关、指标不灵敏——那才是问题。
  kc -n "${ns}" patch certificate "${cert}" --type=merge \
    -p='{"spec":{"issuerRef":{"name":"hlvm-crd-conversion-selfsigned","kind":"Issuer","group":"cert-manager.io"}}}' \
    >/dev/null 2>&1 || true
  # selfSigned 的判据：secret 里的 ca.crt 就是 leaf 自己（两者指纹相同）。
  local self_ready=0
  for i in $(seq 1 60); do
    leaf0="$(crt_sha)"; ca0="$(ca_sha)"
    if [ -n "${leaf0}" ] && [ "${leaf0}" = "${ca0}" ]; then self_ready=1; break; fi
    sleep 2
  done
  if [ "${self_ready}" -eq 1 ]; then
    info "对照：已切回 selfSigned（ca.crt 与 leaf 同指纹 ${leaf0}，即证书自证）"
  else
    fail_msg "FAIL: 未能切回 selfSigned 形态，反证无法进行"
    fail=1
  fi
  bundle0="$(bundle_sha)"
  kc -n "${ns}" delete secret "${cert}" >/dev/null 2>&1 || true
  local ca_after_self
  ca_after_self="$(wait_change ca_sha "${ca0}" 90 >/dev/null 2>&1 && ca_sha || ca_sha)"
  local bundle_after_self
  bundle_after_self="$(wait_change bundle_sha "${bundle0}" 90 >/dev/null 2>&1 && bundle_sha || bundle_sha)"
  if [ -n "${ca_after_self}" ] && [ "${ca_after_self}" != "${ca0}" ]; then
    info "PASS（反证）: selfSigned 下重建证书会换掉根（${ca0} → ${ca_after_self}）"
  else
    fail_msg "FAIL（反证）: selfSigned 下 CA 竟然没变，说明前面的「CA 不变」不能归因于固定链"
    fail=1
  fi
  if [ -n "${bundle_after_self}" ] && [ "${bundle_after_self}" != "${bundle0}" ]; then
    info "PASS（反证）: selfSigned 下 caBundle 随之变化（${bundle0} → ${bundle_after_self}），这正是失配窗口的来源"
  else
    fail_msg "FAIL（反证）: selfSigned 下 caBundle 未变，反证不成立"
    fail=1
  fi

  # 10) 恢复固定 CA 链并确认自愈（清单即真相：apply 回去必须能自己收敛）。
  kc apply -f "${crd_workloads}" >/dev/null || die "恢复固定 CA 链失败"
  local recovered=0
  for i in $(seq 1 60); do
    crt_sha >/dev/null 2>&1 || true
    ca_sha >/dev/null 2>&1 || true
    bundle_sha >/dev/null 2>&1 || true
    if bundle_verifies_leaf \
       && kc get nodedisks.v1alpha1.storage.example.io "${name}" -o name >/dev/null 2>&1; then
      recovered=1; break
    fi
    sleep 2
  done
  if [ "${recovered}" -eq 1 ]; then
    info "PASS: 恢复清单后回到固定 CA 链且转换自愈（链验证 + v1alpha1 转换读可用）"
  else
    fail_msg "FAIL: 恢复固定 CA 链后未在 120s 内自愈"
    fail=1
  fi

  conversion_teardown
  trap - EXIT
  rm -rf "${tmpd}" 2>/dev/null || true
  if [ "${fail}" -ne 0 ]; then
    die "证书轮换验证未通过（见上）"
  fi
  info "证书轮换验证全部 PASS（16 条证书链断言 + 4 条多 Kind conversion smoke：服务就绪 / CA:TRUE / serving 由 CA 签发 / caBundle=CA / 链验证 / TLS 探针就绪 / 证书重签 / 服务端证书已更换 / CA 未变 / caBundle 未变 / 新证书链仍通 / 转换可用 / Pod 未重启 / 反证 CA 变 / 反证 caBundle 变 / 恢复自愈）"
}

# verify-storage-migration：storedVersions 切换与回滚（hardening 3.1b 的最后一块）。
#
# 收敛后 baseline 的 storage=v1beta1。本阶段演练「把存储版本临时切到 v1alpha1、再回滚到
# v1beta1」的完整链路，用来证明切换/回滚/清理这套运维动作在任何方向上都成立、且判据可靠。
# 单独成阶段的三个理由：
#   1) 它改的是 CRD 的**存储版本**，破坏性比「多开一个 served 版本」大得多，必须排在 all 最后；
#   2) 判据不看 API 返回值，而是 etcd 里的原始字节——只有它能回答「这个对象现在以哪个版本落盘」；
#   3) 它同时给出回滚的实测边界（能不能退、退到什么程度算退完）。
phase_verify_storage_migration() {
  log "验证 storedVersions 迁移：切存储到 v1alpha1、控制器写入、字段完好、爆炸半径变化、回滚到 v1beta1 与残留清理"

  # etcd 在控制面上；real 模式被测节点是 worker，必须显式取 CP。
  local ctr
  ctr="$(control_plane_node)"
  if ! is_real; then
    if ! have docker || ! docker inspect "${ctr}" >/dev/null 2>&1; then
      info "跳过 storedVersions 迁移验证：${ctr} 不是本机 docker 容器（判据依赖 etcd 直读）——未覆盖"
      return 0
    fi
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    info "跳过 storedVersions 迁移验证：缺少 python3（schema 差集与字段比较需要）——未覆盖"
    return 0
  fi
  ensure_cluster_ready

  local crd="nodedisks.storage.example.io"
  local alpha="nodedisks.v1alpha1.storage.example.io"
  local beta="nodedisks.v1beta1.storage.example.io"
  local workloads="${CP}/config/hardening/03-crd-conversion.yaml"
  # bases 仍指向 NodeDisk 单文件：migration 的 schema 护栏（--dry-run=server）与
  # 「收成单版本」第 ④ 步都只针对 NodeDisk；其余 4 个 Kind 由 restore_single_version_crds 恢复。
  local bases="${CP}/config/crd/bases/storage.example.io_nodedisks.yaml"
  local img
  img="$(conversion_image)"
  local na="m15-mig-a" nc="m15-mig-c"
  local fail=0 i="" api="" sv="" missing="" n="" cpath="" beta_down=0 okc=0 diffs=""
  [ -f "${workloads}" ] || die "缺少 ${workloads}"

  # 从 etcd 直读对象原始字节并取出 apiVersion。
  #
  # 为什么不用 status.storedVersions 判断「迁移完成」：它表示「etcd 里**可能**存在的版本」，
  # 切存储的一瞬间就把新版本写进去（实测），而对象字节此时还是旧版本；而且它只增不减。
  # 唯一能回答「这个对象现在以哪个版本落盘」的，是 etcd 里那串字节。
  # 走节点容器的 etcd v3 gateway（distroless 的 etcd 容器里没有 sh，没法 exec 进去）。
  stored_api() {
    local key="$1" b64 resp
    b64=$(printf '%s' "/registry/storage.example.io/nodedisks/${key}" | base64 -w0)
    # `--noproxy '*'`：目标是节点**本地回环**的 etcd，绝不许走代理。
    # 实测（2026-10-31）：kind 节点容器可能继承宿主的 https_proxy（本项目为容器构建配的
    # 172.17.0.1:17890），curl 会拿它去 CONNECT 127.0.0.1:2379 ⇒ TLS handshake failure、
    # 响应为空 ⇒ 后续因 pipefail/set -e 直接崩脚本，表象完全不像网络问题。
    resp=$(node_exec "${ctr}" "curl -s --noproxy '*' \
      --cacert /etc/kubernetes/pki/etcd/ca.crt \
      --cert /etc/kubernetes/pki/etcd/server.crt \
      --key /etc/kubernetes/pki/etcd/server.key \
      https://127.0.0.1:2379/v3/kv/range -X POST -d '{\"key\":\"${b64}\"}'" 2>/dev/null || true)
    # 末尾 grep 无匹配会返回 1：那时 api 为空、后面的断言会明确报「存储版本为空」，
    # 比让 set -e 在这里静默崩掉、把原因藏进 EXIT trap 好得多。
    printf '%s' "${resp}" | grep -o '"value":"[^"]*"' | head -1 | cut -d'"' -f4 \
      | base64 -d 2>/dev/null | tr -c '[:print:]' '\n' 2>/dev/null \
      | grep -ao 'storage\.example\.io/v1[a-z0-9]*' | head -1 || true
  }

  # 清理顺序很关键：必须**先**让对象回到 v1beta1 存储，**再**把 CRD 收成单版本 v1beta1。
  # 反了的话（对象以 v1alpha1 落盘 + CRD 只剩 v1beta1）这些对象在 etcd 里就是无法解码的残留，
  # 后续任何列 NodeDisk 的操作都可能报错，而且不会有人再来修。
  migration_cleanup() {
    # 本函数会被 EXIT trap 调用；那时本阶段的 local 变量（crd/beta/bases/na/nc）已经销毁。
    #   变量还在 ⇒ 阶段中途失败，正是需要兜底清理的时刻；
    #   变量已销毁 ⇒ 已过清理点（正常收尾或清理过），直接返回。
    # 没有这一行，任何一条未被 `trap - EXIT` 保护的 die 都会变成 `unbound variable`，
    # 把真正的失败原因彻底掩盖——2026-10-31 就把「etcd 直读返回空」藏了整整一轮。
    [ -n "${crd:-}" ] || return 0
    if kc get crd "${crd}" -o jsonpath='{.spec.versions[1].name}' 2>/dev/null | grep -q .; then
      # ① storage 归位 v1beta1：否则后面移除 v1alpha1（演练时曾设为存储版本）会被拒。
      kc patch crd "${crd}" --type=json -p='[
        {"op":"replace","path":"/spec/versions/0/storage","value":false},
        {"op":"replace","path":"/spec/versions/1/storage","value":true}]' >/dev/null 2>&1 || true
      # ② 删掉本阶段的测试对象：数据不存在，就不存在「仍以 v1alpha1 落盘」的残留。
      #    此刻两版本都 served，v1beta1 是存储版本；用 v1beta1 全限定名删最稳（不受裸名解析影响）。
      kc delete "${beta}" -l hlvm.io/m15-migration=true         --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
      # ③ 清 storedVersions 里的 v1alpha1。这一步不是可选的收尾：
      #    K8s 明确拒绝「移除一个曾是存储版本、但 storedVersions 里还记着的版本」（原文见断言 11）。
      #    storedVersions 只增不减（写入时自动加，永不自动删），只能手动清。
      kc patch crd "${crd}" --subresource=status --type=merge         -p='{"status":{"storedVersions":["v1beta1"]}}' >/dev/null 2>&1 || true
      # ④ 此时才能把 v1alpha1 从 versions 里移除，收成 bases 单版本 v1beta1。
      kc apply -f "${bases}" >/dev/null 2>&1 || kc replace -f "${bases}" >/dev/null 2>&1 || true
    fi
    kc delete "${beta}" "${na}" "${nc}" "${nc}-2" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    # smoke 探针对象兜底清理（按 label，不依赖本阶段的 local 变量）。
    cleanup_conversion_probe_objects
    # 无论上面的 if 分支是否命中（NodeDisk 可能已是单版本），都要把另外 4 个 Kind
    # 从双版本收回 bases；否则它们会残留指向已删除服务的 conversion 引用。
    restore_single_version_crds
    rm -rf "${HOME}/.kube/cache/discovery" 2>/dev/null || true
    kc -n hlvm-system delete deployment hlvm-crd-conversion --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc -n hlvm-system delete service hlvm-crd-conversion --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete certificate hlvm-crd-conversion-serving-cert --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete secret hlvm-crd-conversion-serving-cert --ignore-not-found >/dev/null 2>&1 || true
    # 固定 CA 链的附属对象：先删 Certificate 再删 Issuer/secret，避免 cert-manager 继续重新签发。
    kc -n hlvm-system delete certificate hlvm-crd-conversion-ca --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete issuer hlvm-crd-conversion-ca-issuer --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete issuer hlvm-crd-conversion-selfsigned --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete secret hlvm-crd-conversion-ca --ignore-not-found >/dev/null 2>&1 || true
    kc -n hlvm-system delete serviceaccount hlvm-crd-conversion --ignore-not-found >/dev/null 2>&1 || true
    rm -rf "${HOME}/.kube/cache/discovery" 2>/dev/null || true
  }
  migration_cleanup
  trap 'migration_cleanup; trap - EXIT' EXIT

  # 1) 前置：转换服务 + 双版本 CRD（03b 目标形态：v1beta1=storage）。
  #    本阶段全程依赖它做转换，服务不在就无从谈起。
  #    构建/装载的差异统一交给 helper：real 模式直接用仓库镜像，不本地 build。
  ensure_conversion_image "${img}"

  apply_manifest_with_image "${workloads}" "${img}" || die "apply conversion 工作负载失败"
  # kind 用 IfNotPresent（镜像只在本地）；real 用 Always（tag=latest，避免命中节点旧缓存）。
  local m15_pull="IfNotPresent"
  if is_real; then m15_pull="Always"; fi
  kc -n hlvm-system patch deployment hlvm-crd-conversion --type=json \
    -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"${m15_pull}\"}]" \
    >/dev/null 2>&1 || true
  if kc -n hlvm-system rollout status deployment/hlvm-crd-conversion --timeout=180s >/dev/null 2>&1; then
    info "PASS: 前置——conversion 服务就绪（迁移全程依赖它转换）"
  else
    fail_msg "FAIL: conversion 服务未就绪，迁移无从验证"
    kc -n hlvm-system get pods -l app.kubernetes.io/component=crd-conversion 2>&1 | tail -3 || true
    migration_cleanup
    trap - EXIT
    die "conversion 服务未就绪"
  fi

  apply_dual_version_crds || die "apply 双版本 CRD 失败"
  for i in $(seq 1 30); do
    sv="$(kc get crd "${crd}" -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' 2>/dev/null || true)"
    [ -n "${sv}" ] && break
    sleep 2
  done

  # 1b) 多 Kind smoke：先证明 5 份清单在本相位下都可调，再开始切存储版本。
  #     切存储演练只动 NodeDisk，另外 4 个 Kind 全程保持双版本；若它们 conversion
  #     其实是坏的，本相位原有的 NodeDisk 断言不会发现（这正是之前 03c~03f 的盲区）。
  if ! smoke_all_conversion_kinds "mig"; then fail=1; fi

  # 2) schema 护栏（双向）：切存储会按目标版本的 schema 剪字段。演练要把 storage 切到
  #    v1alpha1，因此这里校验 v1beta1 的字段路径在 v1alpha1 里都有对应（spec.device.path
  #    是有意演进，除外）。转换函数写对了不代表不丢字段——apiserver 的 pruning 看的是 CRD
  #    schema，不是 Go 结构体。这条挡的是「以后给 v1beta1 加了字段、忘了映射到 v1alpha1」。
  missing="$(kc get crd "${crd}" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
vs={v["name"]:v for v in d["spec"]["versions"]}
def walk(s,pre=""):
    out=set()
    for k,v in (s.get("properties") or {}).items():
        p=f"{pre}.{k}" if pre else k
        out.add(p); out|=walk(v,p)
    it=s.get("items")
    if isinstance(it,dict): out|=walk(it,pre+"[]")
    return out
b=walk(vs["v1beta1"]["schema"]["openAPIV3Schema"])
a=walk(vs["v1alpha1"]["schema"]["openAPIV3Schema"])
# v1beta1 的 spec.device.path 在 v1alpha1 里演进成 spec.deviceRef（有意，例外）
print(",".join(sorted(b-a-{"spec.device","spec.device.path"})))
' 2>/dev/null || true)"
  if [ -z "${missing}" ]; then
    info "PASS: schema 护栏——v1beta1 的字段路径在 v1alpha1 中都有对应（仅 spec.device.path 有意演进），切存储不会剪字段"
  else
    fail_msg "FAIL: v1alpha1 schema 缺字段：${missing}（切存储时会被 apiserver 静默剪掉）"
    fail=1
  fi

  # 3) 建满字段对象：spec 五个字段 + status 全字段，后面对比才有意义。
  cat <<EOF | kc apply -f - >/dev/null || die "创建 NodeDisk 失败"
apiVersion: storage.example.io/v1alpha1
kind: NodeDisk
metadata:
  name: ${na}
  labels:
    hlvm.io/m15-migration: "true"
spec:
  nodeName: ${NODE_NAME}
  adopt: true
  deviceRef: /dev/sda
  confirmSerial: SN-MIGRATE-001
  wipePolicy: zero
EOF
  # status 必须走子资源单独写：apply spec 不会带 status。
  kc patch "${alpha}" "${na}" --subresource=status --type=merge -p='{
    "status":{
      "identity":{"serial":"SN-MIGRATE-001","wwn":"0x5000c500aabbccdd","model":"MIGRATE-DISK","byId":"ata-MIGRATE"},
      "currentDevice":"/dev/sda",
      "capacityBytes":1073741824,
      "phase":"PreChecked",
      "health":"healthy",
      "smart":{"overallStatus":"OK","criticalWarning":0,"availableSparePercent":100,"percentUsed":3,"temperatureCelsius":31,"mediaErrors":0,"unsafeShutdowns":2},
      "occupiedBy":"none",
      "isSystemDisk":false,
      "raid":{"memberOf":"md0","degraded":false},
      "vgRef":"vg-alpha"
    }}' >/dev/null 2>&1 || true

  api="$(stored_api "${na}")"
  if [ "${api}" = "storage.example.io/v1beta1" ]; then
    info "PASS: 切换前对象以 v1beta1 落盘（老客户端写 v1alpha1，经 webhook 转成存储版本 v1beta1；etcd 直读原始字节）"
  else
    fail_msg "FAIL: 切换前存储版本预期 v1beta1，实际 '${api}'"
    fail=1
  fi

  # 4) 切存储版本到 v1alpha1（演练方向：从 v1beta1 临时切到老版本，再在 13 步回滚）。
  #    test op 顺带校验版本顺序，顺序不符就整体失败，不会改错版本。
  if kc patch crd "${crd}" --type=json -p='[
      {"op":"test","path":"/spec/versions/0/name","value":"v1alpha1"},
      {"op":"test","path":"/spec/versions/1/name","value":"v1beta1"},
      {"op":"replace","path":"/spec/versions/0/storage","value":true},
      {"op":"replace","path":"/spec/versions/1/storage","value":false}]' >/dev/null 2>&1; then
    info "PASS: 存储版本已切到 v1alpha1（v1beta1 保持 served，控制器仍可写）"
  else
    fail_msg "FAIL: 切换 storage 版本失败"
    fail=1
  fi

  # 5) 判据陷阱本身固化成断言：storedVersions 立刻含 v1alpha1，但对象字节仍是 v1beta1。
  #    「看到 storedVersions 有两个版本就宣布迁移完成」是错的，必须读字节。
  sleep 2
  sv="$(kc get crd "${crd}" -o jsonpath='{.status.storedVersions}' 2>/dev/null || true)"
  api="$(stored_api "${na}")"
  if printf '%s' "${sv}" | grep -q v1alpha1 && [ "${api}" = "storage.example.io/v1beta1" ]; then
    info "PASS: storedVersions 已含 v1alpha1 而对象字节仍为 v1beta1——storedVersions 不能当迁移完成判据"
  else
    fail_msg "FAIL: 预期 storedVersions 含 v1alpha1 且对象仍 v1beta1（sv='${sv}' api='${api}'）"
    fail=1
  fi

  # 6) 迁移期间控制器仍可写：以 v1beta1（控制器走的版本）新建的对象应直接以 v1alpha1 落盘。
  #    这条是「切存储不需要停写」的依据——没有它，迁移就得停机。
  cat <<EOF | kc apply -f - >/dev/null 2>&1 || true
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: ${nc}
  labels:
    hlvm.io/m15-migration: "true"
spec:
  nodeName: ${NODE_NAME}
  device:
    path: /dev/sdc
  adopt: true
EOF
  api="$(stored_api "${nc}")"
  cpath="$(kc get "${beta}" "${nc}" -o jsonpath='{.spec.device.path}' 2>/dev/null || true)"
  if [ "${api}" = "storage.example.io/v1alpha1" ] && [ "${cpath}" = "/dev/sdc" ]; then
    info "PASS: 迁移期间控制器（v1beta1）仍可写，且自动以 v1alpha1 落盘——切存储不必停写"
  else
    fail_msg "FAIL: 控制器写入落盘版本或字段异常（api='${api}' device.path='${cpath}'）"
    fail=1
  fi

  # 7) 存量对象重写：get -o json | replace 确实会改存储版本（K8s 官方迁移姿势，此处实证）。
  #    此刻 storage=v1alpha1，从 v1beta1 视图 get 再 replace，落盘应变 v1alpha1。
  okc=0
  kc get "${beta}" "${na}" -o json 2>/dev/null > /tmp/m15-mig.json || true
  if [ -s /tmp/m15-mig.json ] && kc replace -f /tmp/m15-mig.json >/dev/null 2>&1; then
    sleep 2
    api="$(stored_api "${na}")"
    [ "${api}" = "storage.example.io/v1alpha1" ] && okc=1
  fi
  if [ "${okc}" -eq 1 ]; then
    info "PASS: 重写后存量对象以 v1alpha1 落盘（get -o json | replace 真的改存储版本）"
  else
    fail_msg "FAIL: 重写后存储版本仍是 '${api}'，存量对象没迁过去"
    fail=1
  fi

  # 8) 字段完好：两版本的 spec 规范化后必须一致，status 必须逐字段相等。
  #    只挑几个字段看是不够的——status 是转换最容易漏的地方，这里做整体比较。
  kc get "${alpha}" "${na}" -o json 2>/dev/null > /tmp/m15-mig-alpha.json || true
  kc get "${beta}" "${na}" -o json 2>/dev/null > /tmp/m15-mig-beta.json || true
  diffs="$(python3 - <<'PY' 2>/dev/null || true
import json
try:
    a=json.load(open('/tmp/m15-mig-alpha.json'))
    b=json.load(open('/tmp/m15-mig-beta.json'))
except Exception as e:
    print(f'读取失败: {e}'); raise SystemExit
sa=a.get('spec') or {}
sb=b.get('spec') or {}
norm={'nodeName':sa.get('nodeName'),'adopt':sa.get('adopt',False),
      'confirmSerial':sa.get('confirmSerial'),'wipePolicy':sa.get('wipePolicy')}
# 空 deviceRef 在 v1beta1 里等价于无 device 字段，两边都按「缺省」处理
if sa.get('deviceRef'):
    norm['device']={'path':sa['deviceRef']}
else:
    sb.pop('device',None)
# 去掉 omitempty 造成的空值差异，只比有意义的字段
sb={k:v for k,v in sb.items() if v not in (None,'',False,0)}
norm={k:v for k,v in norm.items() if v not in (None,'',False,0)}
diffs=[f'spec.{k}: alpha={norm.get(k)!r} beta={sb.get(k)!r}'
       for k in sorted(set(norm)|set(sb)) if norm.get(k)!=sb.get(k)]
if (a.get('status') or {}) != (b.get('status') or {}):
    asx=a.get('status') or {}; bsx=b.get('status') or {}
    only_a=sorted(set(asx)-set(bsx)); only_b=sorted(set(bsx)-set(asx))
    inner=[]
    for k in sorted(set(asx)&set(bsx)):
        if asx[k]!=bsx[k]: inner.append(k)
    diffs.append(f'status 差异（仅alpha={only_a} 仅beta={only_b} 值不同={inner}）')
print('; '.join(diffs))
PY
)"
  if [ -z "${diffs}" ]; then
    info "PASS: 字段完好——spec 规范化后一致、status 逐字段相等（含 smart/raid/identity 全部子字段）"
  else
    fail_msg "FAIL: 转换后有字段差异：${diffs}"
    fail=1
  fi

  # 9) 爆炸半径变化：收敛后 storage=v1beta1 时，webhook 挂了只有 v1alpha1 老客户端受影响；
  #    这里演练把 storage 切到 v1alpha1 后，v1beta1 反而成了非存储版本——webhook 挂掉时
  #    v1beta1 读也失败（控制器走它，会随之不可用）。这正是「切存储版本会翻转爆炸半径」、
  #    也是「回滚到 v1beta1 存储版本才是控制面的安全落点」的原因。
  kc -n hlvm-system scale deployment/hlvm-crd-conversion --replicas=0 >/dev/null 2>&1 || true
  kc -n hlvm-system wait --for=delete pod -l app.kubernetes.io/component=crd-conversion \
    --timeout=90s >/dev/null 2>&1 || true
  local beta_down=1
  for i in 1 2 3; do
    if kc get "${beta}" "${na}" -o name --request-timeout=10s >/dev/null 2>&1; then
      beta_down=0
      break
    fi
    sleep 2
  done
  if [ "${beta_down}" -eq 1 ]; then
    info "PASS: 切存储到 v1alpha1 后 webhook 下线连 v1beta1 也读不了——爆炸半径随存储版本翻转"
  else
    fail_msg "FAIL: webhook 已下线但 v1beta1 仍可读，说明对象没真正迁到 v1alpha1 或转换未生效"
    fail=1
  fi

  # 10) 恢复副本后自愈，不需要重启 apiserver。
  kc -n hlvm-system scale deployment/hlvm-crd-conversion --replicas=2 >/dev/null 2>&1 || true
  kc -n hlvm-system rollout status deployment/hlvm-crd-conversion --timeout=180s >/dev/null 2>&1 || true
  okc=0
  for i in $(seq 1 20); do
    if kc get "${beta}" "${na}" -o name --request-timeout=10s >/dev/null 2>&1; then
      okc=1
      break
    fi
    sleep 2
  done
  if [ "${okc}" -eq 1 ]; then
    info "PASS: 服务恢复后两个版本均可读（apiserver 无需重启）"
  else
    fail_msg "FAIL: 服务恢复后仍不可读"
    fail=1
  fi

  # 11) K8s 护栏：曾经是存储版本的版本，只要 storedVersions 还记着它，就**不能**从 spec.versions 移除。
  #     本演练把 v1beta1（收敛后 baseline 的存储版本）切走、又在 13 步回滚，v1beta1 始终是
  #     storedVersions 里的成员，因此 apply bases（单版本 v1beta1、会移除 v1alpha1）在此之前
  #     若 storedVersions 仍含 v1alpha1 就会被拒。用 server dry-run，不会真的改 CRD。
  local guard=""
  guard="$(kc apply -f "${bases}" --dry-run=server 2>&1 || true)"
  if printf '%s' "${guard}" | grep -q "must remain in spec.versions"; then
    info "PASS: K8s 拒绝在 storedVersions 未清理时移除 v1alpha1（护栏原文含 must remain in spec.versions）"
  else
    fail_msg "FAIL: 预期移除 v1alpha1 被拒，实际输出：$(printf '%s' "${guard}" | tail -1)"
    fail=1
  fi

  # 12) 清 storedVersions 残留：迁移收尾动作。清成 ['v1alpha1']（演练的目标存储版本），
  #     清完两版本仍可读、控制器版本 v1beta1 仍可新建。
  if kc patch crd "${crd}" --subresource=status --type=merge \
      -p='{"status":{"storedVersions":["v1alpha1"]}}' >/dev/null 2>&1; then
    local sv2 okr=1 okw=1
    sv2="$(kc get crd "${crd}" -o jsonpath='{.status.storedVersions}' 2>/dev/null || true)"
    kc get "${alpha}" "${na}" -o name >/dev/null 2>&1 || okr=0
    kc get "${beta}" "${na}" -o name >/dev/null 2>&1 || okr=0
    cat <<EOF | kc apply -f - >/dev/null 2>&1 || okw=0
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: ${nc}-2
spec:
  nodeName: ${NODE_NAME}
  device:
    path: /dev/sde
EOF
    if printf '%s' "${sv2}" | grep -q v1beta1 || [ "${okr}" -eq 0 ] || [ "${okw}" -eq 0 ]; then
      fail_msg "FAIL: 清理 storedVersions 后异常（storedVersions='${sv2}' 可读=${okr} 可写=${okw}）"
      fail=1
    else
      info "PASS: storedVersions 清成 ['v1alpha1'] 后两版本仍可读、控制器版本 v1beta1 仍可写（残留可安全清理）"
    fi
    kc delete "${beta}" "${nc}-2" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  else
    fail_msg "FAIL: 无法清理 status.storedVersions（需要 --subresource=status）"
    fail=1
  fi

  # 13) 回滚：storage 改回 v1beta1（收敛后的安全落点）。此时对象仍以 v1alpha1 落盘，两版本都应可读。
  if kc patch crd "${crd}" --type=json -p='[
      {"op":"replace","path":"/spec/versions/0/storage","value":false},
      {"op":"replace","path":"/spec/versions/1/storage","value":true}]' >/dev/null 2>&1; then
    sleep 2
    api="$(stored_api "${na}")"
    local ar br
    ar="$(kc get "${alpha}" "${na}" -o jsonpath='{.spec.deviceRef}' 2>/dev/null || true)"
    br="$(kc get "${beta}" "${na}" -o jsonpath='{.spec.device.path}' 2>/dev/null || true)"
    if [ "${api}" = "storage.example.io/v1alpha1" ] && [ "${ar}" = "/dev/sda" ] && [ "${br}" = "/dev/sda" ]; then
      info "PASS: 回滚 storage 到 v1beta1 后对象仍以 v1alpha1 落盘但两版本可读——回滚不需要先改数据"
    else
      fail_msg "FAIL: 回滚后状态异常（api='${api}' alpha='${ar}' beta='${br}'）"
      fail=1
    fi
  else
    fail_msg "FAIL: 回滚 storage 到 v1beta1 失败"
    fail=1
  fi

  # 14) 回滚的完成判据：重写后对象才真正回到 v1beta1 落盘。
  #     只把 storage 改回去不等于回滚完成——数据还在 v1alpha1 上，控制器读它仍依赖 webhook。
  okc=0
  kc get "${beta}" "${na}" -o json 2>/dev/null > /tmp/m15-mig-back.json || true
  if [ -s /tmp/m15-mig-back.json ] && kc replace -f /tmp/m15-mig-back.json >/dev/null 2>&1; then
    sleep 2
    api="$(stored_api "${na}")"
    [ "${api}" = "storage.example.io/v1beta1" ] && okc=1
  fi
  if [ "${okc}" -eq 1 ]; then
    info "PASS: 回滚后重写使对象回到 v1beta1 落盘（判据是字节，不是 storage 字段）"
  else
    fail_msg "FAIL: 回滚重写后存储版本仍是 '${api}'"
    fail=1
  fi

  # 15) 收尾：CRD 恢复单版本 v1beta1、无残留对象。
  migration_cleanup
  local leftovers
  leftovers="$(kc get "${beta}" -l hlvm.io/m15-migration=true \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)"
  sv="$(kc get crd "${crd}" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || true)"
  if [ "${sv}" = "v1beta1" ] && [ "${leftovers}" -eq 0 ]; then
    info "PASS: 收尾——CRD 恢复单版本 v1beta1，无残留 NodeDisk"
  else
    fail_msg "FAIL: 收尾不干净（versions='${sv}' 残留对象数=${leftovers}）"
    fail=1
  fi

  rm -rf "${HOME}/.kube/cache/discovery" 2>/dev/null || true
  trap - EXIT
  if [ "${fail}" -ne 0 ]; then
    die "storedVersions 迁移验证未通过（见上）"
  fi
  info "storedVersions 迁移验证全部 PASS（15 条迁移断言 + 4 条多 Kind conversion smoke：服务就绪 / schema 护栏 / 初始落盘 / 切存储到 v1alpha1 / 判据陷阱 / 控制器可写 / 重写生效 / 字段完好 / 爆炸半径翻转 / 自愈 / 移除护栏 / 残留清理 / 回滚到 v1beta1 / 回滚完成判据 / 收尾）"
}

phase_verify_nodedisk_convergence() {
  log "验证 NodeDisk 收敛基线（单版本 v1beta1 存储 / v1alpha1 不服务 / 裸资源名免转换读写）"
  ensure_cluster_ready

  local crd="nodedisks.storage.example.io" fail=0
  local versions
  versions="$(kc get crd "${crd}" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || true)"
  # 单版本 v1beta1 同时意味着：它是 storage 版本（K8s 要求且仅一个版本时可作存储版本）、
  # 且 v1alpha1 不存在故未被服务（老客户端显式用 v1alpha1 会被拒，而非静默读空）。
  if [ "${versions}" = "v1beta1" ]; then
    info "PASS: NodeDisk CRD 为单版本 v1beta1（无 v1alpha1 残留，杜绝裸资源名落到旧版本读空字段；且仅 v1beta1 被服务/storage）"
  else
    fail_msg "FAIL: NodeDisk CRD 版本异常（spec.versions='${versions}'，预期仅 v1beta1；双版本回潮会触发『转换丢字段』假象）"
    fail=1
  fi

  # 裸资源名 'kubectl get nodedisk' 在单版本基线下直接解析到 v1beta1，不经 webhook 即可读写。
  # 这是 ownerReference 动态 apiVersion、控制器/agent 全走 v1beta1 的前提。
  local node conv="m15-conv-probe" got path
  node="$(kc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${node}" ] || die "未找到任何节点"
  kc delete nodedisk "${conv}" --ignore-not-found >/dev/null 2>&1 || true
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: storage.example.io/v1beta1
kind: NodeDisk
metadata:
  name: ${conv}
spec:
  nodeName: ${node}
  adopt: true
  device:
    path: /dev/m15-conv-probe
EOF
  got="$(kc get nodedisk "${conv}" -o jsonpath='{.apiVersion}' 2>/dev/null || true)"
  path="$(kc get nodedisk "${conv}" -o jsonpath='{.spec.device.path}' 2>/dev/null || true)"
  if [ "${got}" = "storage.example.io/v1beta1" ] && [ "${path}" = "/dev/m15-conv-probe" ]; then
    info "PASS: 裸资源名 'kubectl get nodedisk' 解析到 v1beta1 且字段完好（免转换路径有效）"
  else
    fail_msg "FAIL: v1beta1 免转换读写异常（apiVersion='${got}' device.path='${path}'）"
    fail=1
  fi
  kc delete nodedisk "${conv}" --ignore-not-found >/dev/null 2>&1 || true

  if [ "${fail}" -ne 0 ]; then
    die "NodeDisk 收敛基线验证未通过（见上）"
  fi
  info "NodeDisk 收敛基线验证全部 PASS（单版本 v1beta1 / 仅 v1beta1 served / 裸资源名免转换读写）"
}

# ---------------------------------------------------------------------------
# backup-restore 软件栈集成（backup-restore 5.1 的前置；kind 内自包含 minio 后端）。
#
# 诚实边界（与 runbook §B 一致）：本相位只验证「Velero 安装 + 后端连通 + 最小端到端
# 备份/恢复（普通 PVC，Kopia 文件备份）」，不验证真实 LV 卷的 CSI 快照，也不验证
# RTO/RPO 真机实测——后者待真实测试集群。
#
# 任何网络/镜像前置失败 → 整相位以 SKIP 退出（return 0），不阻塞 all；但若项目自带
# backup manifests 语法校验本身失败，则仍 fail（那是我们的代码缺陷，必须暴露）。
# ---------------------------------------------------------------------------
VELERO_VERSION="${VELERO_VERSION:-v1.14.0}"
VELERO_NS="velero"
VELERO_TEST_NS="m15-velero-test"

install_velero_cli() {
  if have velero; then
    info "velero CLI 已存在"
    return 0
  fi
  local dest="${HOME}/.local/bin/velero"
  info "下载 velero CLI ${VELERO_VERSION} → ${dest}"
  local arch; arch="$(uname -m)"; case "${arch}" in
    x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  local url="https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-${arch}.tar.gz"
  local tmp; tmp="$(mktemp -d)"
  local got=0
  # m15-wsl.sh 会把 HTTPS_PROXY 改写成容器代理（172.17.0.1:17890），host 侧 curl 经它拉 github 不通；
  # 这里把 HTTPS_PROXY 临时恢复为 host 原始代理（HOST_HTTPS_PROXY 由 m15-wsl.sh 导出；回退 127.0.0.1:7890），
  # 经 env 传入（不用 --proxy，避免与 env 冲突），44MB 经代理约 60s，给足 180s。
  local host_proxy="${HOST_HTTPS_PROXY:-http://127.0.0.1:7890}"
  local prev_https="${HTTPS_PROXY:-}"; local prev_http="${HTTP_PROXY:-}"
  export HTTPS_PROXY="${host_proxy}"; export HTTP_PROXY="${host_proxy}"
  if curl -fsSL --max-time 180 "${url}" -o "${tmp}/velero.tgz" 2>/dev/null; then got=1; fi
  export HTTPS_PROXY="${prev_https}"; export HTTP_PROXY="${prev_http}"
  if [ "${got}" -ne 1 ]; then
    if curl -fsSL --max-time 60 --noproxy '*' "${url}" -o "${tmp}/velero.tgz" 2>/dev/null; then got=1; fi
  fi
  if [ "${got}" -ne 1 ]; then
    warn "velero CLI 下载失败（网络/代理），Velero 相位将跳过"
    rm -rf "${tmp}" 2>/dev/null || true
    return 1
  fi
  if ! tar -xzf "${tmp}/velero.tgz" -C "${tmp}" 2>/dev/null \
     || ! cp "${tmp}"/velero-*/velero "${dest}" 2>/dev/null; then
    warn "velero 包解压/提取失败，Velero 相位将跳过"
    rm -rf "${tmp}" 2>/dev/null || true
    return 1
  fi
  chmod +x "${dest}" 2>/dev/null || true
  rm -rf "${tmp}" 2>/dev/null || true
  info "velero CLI 已安装：${dest}"
  return 0
}

ensure_minio() {
  if kc get deploy minio -n "${VELERO_NS}" >/dev/null 2>&1; then
    info "minio 已存在，跳过安装"
    return 0
  fi
  info "部署 minio（velero 对象存储后端）"
  kc create namespace "${VELERO_NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null
  cat <<'EOF' | kc apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: velero-minio-credentials
  namespace: velero
type: Opaque
stringData:
  cloud: |
    [default]
    aws_access_key_id = minio
    aws_secret_access_key = minio123
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: velero
  labels:
    app: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:RELEASE.2024-05-28T17-19-04Z
        args: ["server", "/storage", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          value: minio
        - name: MINIO_ROOT_PASSWORD
          value: minio123
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - name: storage
          mountPath: /storage
      volumes:
      - name: storage
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: velero
spec:
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  selector:
    app: minio
EOF
  # 轮询就绪；若 kind 节点拉取 minio 镜像失败（ImagePullBackOff/ErrImagePull）则立即返回，
  # 避免在本机 kind 上对注定失败的镜像拉取空等（本环境 WSL 代理对 docker.io/minio 鉴权失败）。
  local waited=0 deadline=120
  while [ "${waited}" -lt "${deadline}" ]; do
    local ph
    ph="$(kc -n "${VELERO_NS}" get pods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{end}' 2>/dev/null || true)"
    if echo "${ph}" | grep -q "ImagePullBackOff\|ErrImagePull"; then
      warn "minio 镜像在 kind 节点拉取失败（${ph}）：本环境无法拉取 docker.io/minio（WSL 代理对其鉴权 insufficient_scope），Velero 软件栈端到端验证跳过"
      return 1
    fi
    if kc -n "${VELERO_NS}" get deploy minio -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx True; then
      break
    fi
    sleep 5; waited=$((waited+5))
  done
  if [ "${waited}" -ge "${deadline}" ]; then
    warn "minio 未在 ${deadline}s 内就绪，Velero 相位将跳过"
    return 1
  fi
  if ! kc -n "${VELERO_NS}" exec deploy/minio -- sh -c 'mc alias set local http://localhost:9000 minio minio123 >/dev/null 2>&1 && mc mb -p local/velero >/dev/null 2>&1' 2>/dev/null; then
    warn "minio bucket 创建失败，Velero 相位将跳过"
    return 1
  fi
  info "minio 就绪，bucket 'velero' 已创建"
  return 0
}

# velero 栈是否真正可用：deployment Available + node-agent DaemonSet 全就绪 + BSL Available。
# 只判 deployment 会放过「pod 起不来但 deployment 恰好满足 Available」的残损栈。
velero_stack_ready() {
  kc -n "${VELERO_NS}" get deploy velero >/dev/null 2>&1 || return 1
  kc -n "${VELERO_NS}" get deploy velero \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx True || return 1
  local desired ready
  desired="$(kc -n "${VELERO_NS}" get ds node-agent -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
  ready="$(kc -n "${VELERO_NS}" get ds node-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
  { [ -n "${desired}" ] && [ "${desired}" != "0" ] && [ "${desired}" = "${ready}" ]; } || return 1
  kc -n "${VELERO_NS}" get backupstoragelocations.velero.io default \
    -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Available || return 1
  return 0
}

ensure_velero() {
  # 「已安装」不能只看 deployment Available：2026-11-02 实测存在 deployment Ready、但 node-agent
  # DaemonSet 起不来（镜像在节点拉不到）、BSL Unavailable 的**残损栈**——此时跳过安装会让
  # 后续断言把「栈没装好」报成产品缺陷（3 条 FAIL 全由它引起）。
  # 三个组件都就绪才算可用：deployment / node-agent DaemonSet / BSL。
  if velero_stack_ready; then
    info "velero 栈已就绪（deployment + node-agent + BSL），跳过安装"
    return 0
  fi
  install_velero_cli || return 1
  ensure_minio || return 1
  local tmp; tmp="$(mktemp -d)"
  cat > "${tmp}/creds" <<'EOF'
[default]
aws_access_key_id = minio
aws_secret_access_key = minio123
EOF
  info "velero install（provider=aws/minio，kopia 文件备份，不依赖 CSI 快照）"
  if ! velero install \
      --kubecontext "${KCTX}" \
      --namespace "${VELERO_NS}" \
      --provider aws \
      --bucket velero \
      --secret-file "${tmp}/creds" \
      --use-volume-snapshots=false \
      --plugins velero/velero-plugin-for-aws:v1.11.0 \
      --backup-location-config "region=minio,s3Url=http://minio.velero.svc:9000,publicUrl=http://minio.velero.svc:9000" \
      --use-node-agent \
      --uploader-type kopia 2>&1 | tail -5; then
    warn "velero install 创建资源失败，Velero 相位将跳过"
    rm -rf "${tmp}" 2>/dev/null || true
    return 1
  fi
  rm -rf "${tmp}" 2>/dev/null || true
  # 轮询 velero 部署就绪；节点拉取 velero 镜像失败则立即返回（同 minio，本环境 WSL 代理对 docker.io/velero 鉴权失败）。
  local waited=0 deadline=150
  while [ "${waited}" -lt "${deadline}" ]; do
    local ph
    ph="$(kc -n "${VELERO_NS}" get pods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{end}' 2>/dev/null || true)"
    if echo "${ph}" | grep -q "ImagePullBackOff\|ErrImagePull"; then
      warn "velero 镜像在 kind 节点拉取失败（${ph}）：本环境无法拉取 docker.io/velero（WSL 代理对其鉴权 insufficient_scope），Velero 软件栈端到端验证跳过"
      return 1
    fi
    if kc -n "${VELERO_NS}" get deploy velero -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx True; then
      info "velero 安装完成"
      return 0
    fi
    sleep 5; waited=$((waited+5))
  done
  warn "velero deployment 未在 ${deadline}s 内就绪，跳过"
  return 1
}

phase_verify_velero() {
  log "验证 backup-restore 软件栈（Velero + minio 后端，kind 自包含）"
  ensure_cluster_ready
  export PATH="${HOME}/.local/bin:${PATH}"

  local fail=0

  # 软件栈部分：装不上则 skip（不阻塞 all），装上了则必须端到端通过。
  if ! ensure_velero; then
    warn "Velero 软件栈在本机 kind 无法部署：kind 节点容器运行时经 WSL 代理拉取 docker.io/velero 与 docker.io/minio 镜像鉴权失败（insufficient_scope），本机 kind 无法完成端到端验证"
    if [ "${fail}" -ne 0 ]; then
      die "backup manifests 语法校验存在失败项"
    fi
    info "Velero 软件栈验证 SKIP（仅项目自带 backup manifests 语法已校验）：端到端备份/恢复验证移交真实测试集群（选项 A 目标环境，镜像可正常拉取）"
    return 0
  fi

  # 0) 项目自带 backup manifests 语法校验（velero 已装，CRD 存在；00 为部署参考含 BSL/VSL 故跳过）
  log "0) 项目自带 backup manifests 语法校验（velero 已装）"
  local bdir="${CP}/config/backup"
  local bf
  for bf in 01-backup-schedule 02-mysql-prehook 03-drill-job; do
    if [ -f "${bdir}/${bf}.yaml" ]; then
      if kc apply --dry-run=client -f "${bdir}/${bf}.yaml" >/dev/null 2>&1; then
        info "PASS: config/backup/${bf}.yaml 语法可解析（kubectl --dry-run=client 通过）"
      else
        fail_msg "FAIL: config/backup/${bf}.yaml 语法/结构异常（--dry-run=client 失败）"
        fail=1
      fi
    fi
  done

  # 1) 核心组件就绪
  if kc -n "${VELERO_NS}" rollout status deployment/velero --timeout=120s >/dev/null 2>&1; then
    info "PASS: velero deployment 就绪"
  else
    fail_msg "FAIL: velero deployment 未就绪"
    fail=1
  fi
  if kc -n "${VELERO_NS}" rollout status daemonset/velero-node-agent --timeout=120s >/dev/null 2>&1; then
    info "PASS: velero node-agent DaemonSet 就绪"
  else
    fail_msg "FAIL: velero node-agent DaemonSet 未就绪"
    fail=1
  fi

  # 2) BSL Available
  local bsl
  bsl="$(kc -n "${VELERO_NS}" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${bsl}" = "Available" ]; then
    info "PASS: BackupStorageLocation/default 可用（minio 后端连通）"
  else
    fail_msg "FAIL: BSL 状态=${bsl:-<空>}，minio 后端未连通"
    fail=1
  fi

  # 3) 最小端到端：备份/恢复一个普通 PVC（kind 内 local-path 提供的 hostPath PV）。
  log "3) 最小端到端备份/恢复（普通 PVC，Kopia 文件备份）"
  kc create namespace "${VELERO_TEST_NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null
  local marker; marker="HELLO-$(date +%s)"
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: velero-pvc
  namespace: ${VELERO_TEST_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: velero-writer
  namespace: ${VELERO_TEST_NS}
spec:
  containers:
  - name: w
    image: busybox:1.36
    command: ["sh", "-c", "echo ${marker} > /data/HELLO && sleep 3600"]
    volumeMounts:
    - name: vol
      mountPath: /data
  volumes:
  - name: vol
    persistentVolumeClaim:
      claimName: velero-pvc
EOF
  if ! kc -n "${VELERO_TEST_NS}" wait --for=condition=Ready pod/velero-writer --timeout=120s >/dev/null 2>&1; then
    warn "端到端用例 Pod 未就绪（busybox 镜像拉取？），跳过备份/恢复断言"
    kc delete namespace "${VELERO_TEST_NS}" --ignore-not-found >/dev/null 2>&1 || true
    if [ "${fail}" -ne 0 ]; then die "Velero 软件栈验证未通过（见上）"; fi
    info "Velero 软件栈验证 SKIP（部署/BSL 已 PASS，端到端用例 Pod 不可用）"
    return 0
  fi
  local bk="m15-b-${marker}"; local rs="m15-r-${marker}"
  # velero CLI 在 BSL 不可用时会长时间不返回（2026-11-02 实测 restore delete 挂住 6 分钟），
  # 一律加 timeout：超时算失败，不许把整个 all 拖死。
  if timeout 420 velero backup create "${bk}" --kubecontext "${KCTX}" --include-namespaces "${VELERO_TEST_NS}" --wait >/dev/null 2>&1; then
    info "PASS: velero backup 完成（${bk}）"
  else
    fail_msg "FAIL: velero backup 未成功完成"
    fail=1
  fi
  kc -n "${VELERO_TEST_NS}" delete pod velero-writer --ignore-not-found >/dev/null 2>&1
  kc -n "${VELERO_TEST_NS}" delete pvc velero-pvc --ignore-not-found >/dev/null 2>&1
  if [ "${fail}" -eq 0 ]; then
    if timeout 300 velero restore create "${rs}" --kubecontext "${KCTX}" --from-backup "${bk}" \
        --include-resources persistentvolumeclaims,persistentvolumes --wait >/dev/null 2>&1; then
      info "PASS: velero restore 完成（${rs}，仅恢复 PVC/PV）"
    else
      fail_msg "FAIL: velero restore 未成功完成"
      fail=1
    fi
  fi
  if [ "${fail}" -eq 0 ]; then
    cat <<EOF | kc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: velero-reader
  namespace: ${VELERO_TEST_NS}
spec:
  containers:
  - name: r
    image: busybox:1.36
    command: ["sh", "-c", "cat /data/HELLO && sleep 3600"]
    volumeMounts:
    - name: vol
      mountPath: /data
  volumes:
  - name: vol
    persistentVolumeClaim:
      claimName: velero-pvc
EOF
    kc -n "${VELERO_TEST_NS}" wait --for=condition=Ready pod/velero-reader --timeout=120s >/dev/null 2>&1 || true
    local got; got="$(kc -n "${VELERO_TEST_NS}" exec pod/velero-reader -- cat /data/HELLO 2>/dev/null || true)"
    if [ "${got}" = "${marker}" ]; then
      info "PASS: 端到端备份→删除→恢复→读回数据一致（marker=${marker}）"
    else
      fail_msg "FAIL: 恢复后数据不一致（期望 ${marker}，实际 '${got:-<空>}'）"
      fail=1
    fi
  fi
  timeout 60 velero backup delete "${bk}" --kubecontext "${KCTX}" --confirm >/dev/null 2>&1 || true
  timeout 60 velero restore delete "${rs}" --kubecontext "${KCTX}" >/dev/null 2>&1 || true
  kc delete namespace "${VELERO_TEST_NS}" --ignore-not-found >/dev/null 2>&1 || true

  if [ "${fail}" -ne 0 ]; then
    die "Velero 软件栈验证未通过（见上）"
  fi
  info "Velero 软件栈验证全部 PASS（部署就绪 / BSL 可用 / 端到端备份恢复一致）"
}

usage() {
  # 动态取头部注释块：写死行号会在增删环境变量说明时被悄悄截断（只看到半段参数），
  # 而「参数说明不全」恰好是最容易误导人的一类文档缺陷。
  local end
  end="$(grep -n '^set -euo pipefail' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
  [ -n "${end}" ] || end=60
  sed -n "2,$((end - 1))p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-check}"
  # 拼错会被静默当成 kind 跑，在真实集群上是另一种含义——宁可一开始就报错。
  case "${M15_TARGET}" in
    kind|real) ;;
    *) die "M15_TARGET 只能是 kind 或 real（当前: '${M15_TARGET}'）" ;;
  esac
  case "${cmd}" in
    check)            phase_check ;;
    preflight)        phase_preflight ;;
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
    verify-kubelet-restart) phase_verify_kubelet_restart ;;
    verify-device-hotplug) phase_verify_device_hotplug ;;
    verify-topology-scale) phase_verify_topology_scale ;;
    verify-conversion)  phase_verify_conversion ;;
    verify-cert-rotation) phase_verify_cert_rotation ;;
    verify-storage-migration) phase_verify_storage_migration ;;
    verify-nodedisk-convergence) phase_verify_nodedisk_convergence ;;
    verify-velero)     phase_verify_velero ;;
    all)              phase_check
                      # kind 首跑（全新机器 / 新 CLUSTER_NAME）时集群还不存在，而 preflight
                      # 的第一条断言就是「context 存在」——先 preflight 会在建集群前直接 die，
                      # 表现为「一键 all 在干净机器上永远跑不起来」（2026-11-03 单节点首跑实测）。
                      # real 模式保持 preflight 在前：集群必须事先存在，且首跑要先单独体检。
                      if ! is_real && ! context_exists; then
                        phase_bootstrap
                        phase_preflight
                      else
                        phase_preflight
                        phase_bootstrap
                      fi
                      phase_build; phase_verify_nodedisk_convergence; phase_verify_admission; phase_verify_controller; phase_verify_lvmd; phase_verify_taskgc; phase_verify_ttl; phase_verify_agent; phase_verify_device_plugin; phase_verify_collector; phase_verify_kubelet_restart; phase_verify_device_hotplug; phase_verify_topology_scale; phase_verify_conversion; phase_verify_cert_rotation; phase_verify_storage_migration; phase_verify_velero ;;
    -h|--help|help)   usage ;;
    *) die "未知子命令: ${cmd}（可用: check/preflight/bootstrap/build/verify-admission/verify-controller/verify-lvmd/verify-taskgc/verify-ttl/verify-agent/verify-device-plugin/verify-collector/verify-kubelet-restart/verify-device-hotplug/verify-topology-scale/verify-conversion/verify-cert-rotation/verify-storage-migration/verify-nodedisk-convergence/verify-velero/all）" ;;
  esac
}

main "$@"
