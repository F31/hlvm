#!/usr/bin/env bash
#
# M15 × hnb 联合测试编排（WSL 内执行）
#
# 目的：把「hlvm 与 hnb 不能同时跑」这条纪律固化成机制，而不是靠人记。
#   两侧都会写集群级状态：hlvm 会 cordon / 重启 kubelet / 临时切 CRD 双版本再恢复 /
#   增删设备插件 DS；hnb 的 hnbctl install / uninstall -all -data 会增删 TopoLVM、
#   StorageClass、PVC、LV。两侧还共享同一 WSL 内核的 inotify 配额——runbook §7.2 记录过
#   多 kind 集群耗尽 128 导致 kube-proxy CrashLoop、全部 verify-* 误报为「代码回归」。
#   因此本脚本只做**串行**：baseline → hlvm → 收尾断言 → hnb，任一步不满足即停。
#
# 用法（在 WSL 内，经 SSH 调用以拿到可靠退出码；不要经 wsl.exe 桥接判 $?）：
#   bash /mnt/e/projects/hlvm/scripts/m15-joint.sh baseline
#   bash /mnt/e/projects/hlvm/scripts/m15-joint.sh hlvm
#   bash /mnt/e/projects/hlvm/scripts/m15-joint.sh hnb
#   bash /mnt/e/projects/hlvm/scripts/m15-joint.sh all
#
# 环境变量：
#   M15_SINGLE_NODE    必须按实测节点数显式声明（1 / 0）；实测单节点却未声明会 FAIL
#   IMG_TAG            默认 v$(cat VERSION)；禁止 latest（结论不可复现）
#   KCTX               hlvm 集群 context，默认 kind-hlvm-kind
#   HNB_KUBECONFIG     hnb 集群独立 kubeconfig；hnb-s4-clean 不在默认 kubeconfig 里
#   HNB_SMOKE_CMD      hnb 侧冒烟命令（必填才执行）；未设 → 显式 SKIP，结论不含 hnb
#   HNB_REPO           hnb 源工作树，默认 /mnt/e/projects/hnb（只读取 commit）
#   HLVM_JOINT_LOG_DIR 日志目录，默认 <repo>/joint-logs
#
# 诚实边界：本脚本验证的是「两套测试能否在同一台主机上顺序、可复现地跑完」，
#   **不验证 hlvm → hnb 的 CSI / PVC 端到端集成**：hlvm M15 至今未部署 TopoLVM CSI，
#   kind 内 PVC 不绑定（见 runbook §10.19）。hnb 相位未配置就 SKIP，绝不假装两边都测过。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${HLVM_JOINT_LOG_DIR:-${REPO_ROOT}/joint-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOCK_FILE="${LOG_DIR}/.joint.lock"
MARKER="${LOG_DIR}/hlvm-cleanup.ok"
KCTX="${KCTX:-kind-hlvm-kind}"
IMG_TAG="${IMG_TAG:-v$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)}"
HNB_REPO="${HNB_REPO:-/mnt/e/projects/hnb}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fail_msg() { printf '\033[1;31m[error] FAIL:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null \
  || die "未检测到 WSL 内核；本脚本应在 WSL 内执行（见 scripts/m15-wsl.sh 的说明）"
command -v flock >/dev/null 2>&1 || die "缺少 flock（util-linux），无法保证错峰互斥"
command -v kubectl >/dev/null 2>&1 || die "缺少 kubectl"

take_lock() {
  mkdir -p "${LOG_DIR}"
  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "另一个 joint 实例正在运行（锁 ${LOCK_FILE}）——错峰纪律禁止并行"
}

baseline_snapshot() {
  local out="${LOG_DIR}/baseline-${RUN_ID}.txt"
  log "环境基线快照（只读）"
  {
    printf '== 运行 ==\n'
    printf 'run_id: %s\n' "${RUN_ID}"
    printf 'utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n== 代码基线 ==\n'
    printf 'hlvm HEAD: %s\n' "$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'hlvm VERSION: %s\n' "$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)"
    printf 'hlvm dirty files (行尾归一化): %s\n' "$(git -C "${REPO_ROOT}" diff --ignore-space-at-eol --numstat 2>/dev/null | wc -l || true)"
    printf 'hlvm untracked: %s\n' "$(git -C "${REPO_ROOT}" ls-files --others --exclude-standard 2>/dev/null | wc -l || true)"
    printf 'git core.autocrlf (本机): %s\n' "$(git -C "${REPO_ROOT}" config --get core.autocrlf 2>/dev/null || echo '<未设置>')"
    printf 'hlvm IMG_TAG: %s\n' "${IMG_TAG}"
    if [ -d "${HNB_REPO}" ]; then
      printf 'hnb HEAD: %s\n' "$(git -C "${HNB_REPO}" rev-parse HEAD 2>/dev/null || echo unknown)"
      printf 'hnb status: %s\n' "$(git -C "${HNB_REPO}" status -sb 2>/dev/null | head -1)"
    else
      printf 'hnb HEAD: <未找到 %s>\n' "${HNB_REPO}"
    fi
    printf '\n== 主机 / 内核 ==\n'
    printf 'inotify.max_user_instances: %s\n' "$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo unknown)"
    printf 'inotify.max_user_watches: %s\n' "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo unknown)"
    free -m | head -2
    printf 'cpus: %s\n' "$(nproc)"
    printf '\n== kind / kubeconfig ==\n'
    printf 'clusters:\n'
    kind get clusters 2>/dev/null || true
    printf 'contexts:\n'
    kubectl config get-contexts -o name 2>/dev/null || true
    printf 'hlvm nodes:\n'
    kubectl --context "${KCTX}" get nodes --no-headers 2>/dev/null || true
    printf 'hlvm kube-proxy:\n'
    kubectl --context "${KCTX}" -n kube-system get pods -l k8s-app=kube-proxy --no-headers 2>/dev/null || true
    printf '\n== hnb 接入 ==\n'
    printf 'HNB_KUBECONFIG: %s\n' "${HNB_KUBECONFIG:-<未设置>}"
    printf 'HNB_SMOKE_CMD: %s\n' "${HNB_SMOKE_CMD:-<未设置>}"
  } | tee "${out}"
  info "快照已写入 ${out}"
}

assert_baseline() {
  local fail=0
  local ino nodes kp hnb_ctx cur_tag
  cur_tag="v$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)"
  ino="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
  if [ "${ino}" -lt 2048 ]; then
    fail_msg "inotify.max_user_instances=${ino} < 2048：多集群并存会耗尽实例，kube-proxy 会 CrashLoop（runbook §7.2）"
    info "      WSL VM 重启会把该值重置回 128；先跑 m15 bootstrap 让 ensure_kernel_limits 修复"
    fail=$((fail+1))
  fi

  nodes="$(kubectl --context "${KCTX}" get nodes --no-headers 2>/dev/null | wc -l || true)"
  [ "${nodes}" -gt 0 ] || { fail_msg "context ${KCTX} 下没有任何节点（API server 不可达或 context 不存在）"; fail=$((fail+1)); }
  kp="$(kubectl --context "${KCTX}" -n kube-system get pods -l k8s-app=kube-proxy --no-headers 2>/dev/null \
        | awk 'NR==1 {print $3}' || true)"
  if [ -n "${kp}" ] && [ "${kp}" != "Running" ]; then
    fail_msg "kube-proxy 状态为 ${kp}（非 Running）：集群内 ClusterIP 可能不可达，断言会集体误报"
    fail=$((fail+1))
  elif [ -z "${kp}" ]; then
    fail_msg "未找到 kube-proxy Pod；无法确认集群内网络可用"
    fail=$((fail+1))
  fi

  # 单节点必须显式声明，禁止静默降级（与 m15-integration.sh 同一纪律）。
  if [ "${nodes}" -eq 1 ] && [ "${M15_SINGLE_NODE:-}" != "1" ]; then
    fail_msg "实测 1 个节点但未显式声明 M15_SINGLE_NODE=1；m15 preflight 会判 FAIL，且不得自动降级"
    fail=$((fail+1))
  fi
  if [ "${nodes}" -gt 1 ] && [ "${M15_SINGLE_NODE:-}" = "1" ]; then
    fail_msg "实测 ${nodes} 个节点却声明 M15_SINGLE_NODE=1：声明与拓扑不符，结论不可信"
    fail=$((fail+1))
  fi

  # Windows git 常设 core.autocrlf=true、WSL git 未设；同一 /mnt/e 工作树在两侧会给出
  # 不同的 porcelain 结论（实测 WSL 把 8 个文件的整文件行尾差异报成 M）。
  # 用 --ignore-space-at-eol 判「真实未提交改动」：m15-wsl.sh 同步的是工作树，
  # 有真实改动时跑出来的结论不对应任何 commit，不可复现。
  local dirty untracked
  dirty="$(git -C "${REPO_ROOT}" diff --ignore-space-at-eol --numstat 2>/dev/null | wc -l || true)"
  untracked="$(git -C "${REPO_ROOT}" ls-files --others --exclude-standard 2>/dev/null | wc -l || true)"
  if [ "${dirty}" -gt 0 ]; then
    fail_msg "hlvm 工作树有 ${dirty} 个文件的真实未提交改动：m15-wsl.sh 同步工作树，结论不对应 HEAD"
    fail=$((fail+1))
  fi
  [ "${untracked}" -eq 0 ] || warn "hlvm 有 ${untracked} 个未跟踪文件（多为本地日志，确认不参与构建才继续）"

  case "${IMG_TAG}" in
    latest|*":latest"|"") fail_msg "IMG_TAG='${IMG_TAG}' 不可复现；请用版本标签（当前 ${cur_tag}）"
                          fail=$((fail+1)) ;;
  esac

  if [ -z "${HNB_KUBECONFIG:-}" ]; then
    hnb_ctx="$(kubectl config get-contexts -o name 2>/dev/null | grep -c 'hnb-s4-clean' || true)"
    if [ "${hnb_ctx}" -eq 0 ]; then
      warn "默认 kubeconfig 里没有 hnb-s4-clean 的 context，且 HNB_KUBECONFIG 未设置"
      info "      hnb S4 用的是独立 kubeconfig（/root/hnb-s4-candidate/kubeconfig）；hnb 相位需显式提供"
    fi
  elif [ ! -r "${HNB_KUBECONFIG}" ]; then
    fail_msg "HNB_KUBECONFIG=${HNB_KUBECONFIG} 不可读"
    fail=$((fail+1))
  fi

  [ "${fail}" -eq 0 ] || die "基线检查失败（${fail} 项）——不进入测试相位"
  info "PASS: 基线满足（inotify=${ino}，节点=${nodes}，kube-proxy=${kp}，IMG_TAG=${IMG_TAG}）"
}

run_hlvm() {
  rm -f "${MARKER}"
  local out="${LOG_DIR}/hlvm-${RUN_ID}.log" rc
  log "相位 1/2：hlvm m15 all（此相位期间禁止任何 hnb 测试）"
  set +e
  M15_SINGLE_NODE="${M15_SINGLE_NODE:-0}" IMG_TAG="${IMG_TAG}" KCTX="${KCTX}" \
    bash "${REPO_ROOT}/scripts/m15-wsl.sh" all 2>&1 | tee "${out}"
  rc=${PIPESTATUS[0]}
  set -e
  info "hlvm 退出码 ${rc}（日志 ${out}）"
  [ "${rc}" -eq 0 ] || die "hlvm m15 all 失败（rc=${rc}）——不进入 hnb 相位"
  if grep -nE 'FAIL:|\[error\]' "${out}" >/dev/null 2>&1; then
    die "hlvm 日志里出现 FAIL / [error] 行——即使退出码为 0 也判失败（见 runbook §10.12 静默失败清单）"
  fi
  info "PASS: hlvm m15 all 退出码 0 且日志无 FAIL / [error]"
}

assert_hlvm_cleanup() {
  local fail=0 crd vers n ds
  log "hlvm 收尾断言（确认不会污染 hnb 相位）"
  local unsched
  unsched="$(kubectl --context "${KCTX}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.unschedulable}{"\n"}{end}' 2>/dev/null || true)"
  if printf '%s\n' "${unsched}" | grep -q '=true'; then
    fail_msg "仍有节点处于 cordon（SchedulingDisabled）：${unsched}"
    fail=$((fail+1))
  fi

  # conversion / cert-rotation / storage-migration 三个相位会临时切双版本，收尾必须恢复单版本。
  for crd in nodedisks nodevgs storagetasks storagenodeops thinpoolpolicies; do
    vers="$(kubectl --context "${KCTX}" get crd "${crd}.storage.example.io" \
            -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || true)"
    n="$(printf '%s\n' "${vers}" | wc -w)"
    if [ "${n}" -ne 1 ] || [ "${vers}" != "v1beta1" ]; then
      fail_msg "CRD ${crd}.storage.example.io 未恢复为单版本 v1beta1（实际: '${vers:-<不存在>}'）"
      fail=$((fail+1))
    fi
  done

  ds="$(kubectl --context "${KCTX}" -n hlvm-system get ds -l app.kubernetes.io/component=disk-device-plugin \
        --no-headers 2>/dev/null | wc -l || true)"
  if [ "${ds}" -ne 0 ]; then
    fail_msg "设备插件 DaemonSet 仍存在（${ds} 个）：m15 all 收尾应已清理，残留会占用节点盘位"
    fail=$((fail+1))
  fi

  [ "${fail}" -eq 0 ] || die "hlvm 收尾断言失败（${fail} 项）——不进入 hnb 相位"
  printf '%s\n' "${RUN_ID}" > "${MARKER}"
  info "PASS: 未 cordon / 5 个 CRD 单版本 v1beta1 / 设备插件已清理"
}

run_hnb() {
  local out="${LOG_DIR}/hnb-${RUN_ID}.log" rc kubecfg="${HNB_KUBECONFIG:-}"
  log "相位 2/2：hnb 冒烟"
  if [ -z "${HNB_SMOKE_CMD:-}" ]; then
    warn "SKIP: 未设置 HNB_SMOKE_CMD —— 本次结论不含 hnb 侧，不得表述为「hlvm × hnb 联调通过」"
    printf 'SKIP: HNB_SMOKE_CMD 未设置（run_id=%s）\n' "${RUN_ID}" > "${out}"
    return 0
  fi
  [ -f "${MARKER}" ] || die "hlvm 相位未完成或收尾断言未通过（缺 ${MARKER}）——禁止抢跑 hnb"
  if [ -n "${kubecfg}" ] && [ ! -r "${kubecfg}" ]; then
    die "HNB_KUBECONFIG=${kubecfg} 不可读"
  fi
  info "hlvm 收尾标记: $(cat "${MARKER}")；hnb kubeconfig: ${kubecfg:-<默认>}"
  info "命令: ${HNB_SMOKE_CMD}"
  set +e
  if [ -n "${kubecfg}" ]; then
    env KUBECONFIG="${kubecfg}" bash -c "${HNB_SMOKE_CMD}" 2>&1 | tee "${out}"
  else
    bash -c "${HNB_SMOKE_CMD}" 2>&1 | tee "${out}"
  fi
  rc=${PIPESTATUS[0]}
  set -e
  info "hnb 退出码 ${rc}（日志 ${out}）"
  [ "${rc}" -eq 0 ] || die "hnb 冒烟失败（rc=${rc}）"
  info "PASS: hnb 冒烟退出码 0"
}

summary() {
  log "联合测试汇总（run_id=${RUN_ID}）"
  info "日志目录: ${LOG_DIR}"
  if [ -z "${HNB_SMOKE_CMD:-}" ]; then
    info "结论范围: 仅 hlvm 侧；hnb 相位显式 SKIP，不声称两边都测过"
  else
    info "结论范围: hlvm 全量 + hnb 冒烟（顺序执行，非并行）"
  fi
  info "未覆盖: hlvm → hnb 的 CSI / PVC 端到端集成（hlvm M15 未部署 TopoLVM CSI）"
}

main() {
  case "${1:-all}" in
    baseline) take_lock; baseline_snapshot; assert_baseline ;;
    hlvm)     take_lock; baseline_snapshot; assert_baseline; run_hlvm; assert_hlvm_cleanup ;;
    hnb)      take_lock; run_hnb ;;
    all)      take_lock; baseline_snapshot; assert_baseline; run_hlvm
              assert_hlvm_cleanup; run_hnb; summary ;;
    -h|--help|help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "未知子命令: $1（可用: baseline / hlvm / hnb / all）" ;;
  esac
}

main "$@"
