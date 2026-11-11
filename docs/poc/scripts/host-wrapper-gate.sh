#!/usr/bin/env bash
# host-wrapper-gate.sh —— 设计 §5.3「宿主 lvm 共享锁」的 **写路径** 门禁
#
# 背景（ADR-006 §11，2026-11-11 真机实测）：旧门禁只跑一次 lvm version，
# 只读、不取锁，因此 HLVM_HOST_WRAPPER=chroot /host 在写路径上会永久挂死
# （chroot 不切 IPC 命名空间，lvm/libdm 的 udev 同步用 SysV 信号量，宿主 udev
# 与容器 IPC NS 互不可见）却仍被判 PASS。本门禁把断言升级为一次真实写：
#     lvcreate -> lvs 核对 -> lvremove -> 残留 0
#
# 两种运行模式：
#   MODE=probe（默认）—— 自起一次性 Pod（agent 镜像 + WRAPPER env +
#     /host,/dev,/run/lock/lvm 挂载 + hostPID/privileged），跑完删除。用于独立复跑、
#     真机取证，不依赖常驻 agent DaemonSet（真机当前就没有）。
#   MODE=pod —— 对已存在的 agent Pod 执行；**只从 Pod 内读 HLVM_HOST_WRAPPER**，
#     绝不另设，保证验的就是 agent 真实 env。m15-integration.sh 灰度相位用这个。
#
# 命令构造忠实复刻 agent/src/lvm/mod.rs::lvm_argv_with 的 split_whitespace 语义：
#     W=${HLVM_HOST_WRAPPER:-}; set -- $W; "$@" lvm <args>
# 唯一偏差：写路径不追加 --reportformat json（与 executor::execute 一致，lvcreate 无需报表）。
#
# 防挂死（血泪）：timeout 放在 **wrapper 之后**，即宿主命名空间侧，用宿主的
# timeout -k，杀的是宿主 lvm 进程本身；外层再包一层本地 timeout，避免 kubectl
# exec 连接泄漏留下孤儿 lvm 持有 VG flock。远端脚本不开 set -e，所有失败显式判定，
# 避免出现「无日志静默退出」的假绿。
#
# 判据纪律：能力缺失（无宿主 timeout / 无可写 VG）SKIP 且 **不计 PASS**；
# wrapper 未注入属结构性缺失，判 FAIL；读不到 lvs 判 FAIL，不做「读不到 = 没有」
# 的无据判定；每条判据打印原始证据；结论以 GATE_RESULT 行 + 退出码为准。
#
# 退出码：0=PASS，1=FAIL，2=SKIP（SKIP 非零，防止被当成通过；调用方须读 GATE_RESULT）。
#
# 用法：
#   KUBECONFIG=~/.kube/hlvm-real.conf NODE=10-60-153-100 \
#       VG=hlvm-lvmd-vg-153 bash host-wrapper-gate.sh
#   MODE=pod KUBECTX=kind-hlvm POD_NAME=hlvm-storage-agent-x \
#       bash host-wrapper-gate.sh
#   WRAPPER='chroot /host' ... bash host-wrapper-gate.sh   # 负向对照，预期 FAIL
set -Eeuo pipefail

KUBECONFIG="${KUBECONFIG:-}"
KUBECTX="${KUBECTX:-}"
MODE="${MODE:-probe}"
WRAPPER="${WRAPPER:-nsenter -t 1 -m -u -i -n -p --}"
AGENT_IMAGE="${AGENT_IMAGE:-ghcr.io/f31/hlvm/storage-agent:sha-7e76f95}"
NODE="${NODE:-10-60-153-100}"
VG="${VG:-}"
PROBE_NS="${PROBE_NS:-hlvm-pvc-poc}"
PROBE_POD="${PROBE_POD:-hlvm-wrapper-gate}"
POD_NS="${POD_NS:-hlvm-system}"
POD_NAME="${POD_NAME:-}"
POD_CONTAINER="${POD_CONTAINER:-agent}"
LV_SIZE="${LV_SIZE:-64M}"
WRITE_TIMEOUT="${WRITE_TIMEOUT:-25}"
EXEC_TIMEOUT="${EXEC_TIMEOUT:-120}"
LV_NAME="hlvm-gate-$$"

K=(kubectl)
if [[ -n "$KUBECTX" ]]; then K+=(--context "$KUBECTX"); fi
if [[ -n "$KUBECONFIG" ]]; then K+=(--kubeconfig "$KUBECONFIG"); fi

trap 'echo "[error] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

GATE_SCRIPT="$(mktemp /tmp/hlvm-wrapper-gate.XXXXXX.sh || true)"
PROBE_CREATED=0
cleanup() {
  if [[ "$PROBE_CREATED" == "1" ]]; then
    "${K[@]}" -n "$PROBE_NS" delete pod "$PROBE_POD" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  if [[ -n "$GATE_SCRIPT" ]]; then rm -f "$GATE_SCRIPT" || true; fi
}
trap cleanup EXIT

report() {
  # $1 = PASS|FAIL|SKIP，$2 = 原因，$3 = 附加证据
  echo "GATE_RESULT=$1 reason=$2 ${3:-}"
  case "$1" in
    PASS) echo "HOST_WRAPPER_GATE: PASS（真实写路径已验证，可推进 B 链路）"; exit 0 ;;
    FAIL) echo "HOST_WRAPPER_GATE: FAIL（禁止据此推进 lvmd 并发）"; exit 1 ;;
    *)    echo "HOST_WRAPPER_GATE: SKIP（能力缺失，未覆盖写路径，不计 PASS）"; exit 2 ;;
  esac
}

echo "== 0. 准备执行载体（MODE=$MODE）=="
case "$MODE" in
  probe)
    echo "    node=$NODE image=$AGENT_IMAGE wrapper=$WRAPPER"
    "${K[@]}" -n "$PROBE_NS" delete pod "$PROBE_POD" \
      --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
    cat <<YAML | "${K[@]}" apply -f - >/dev/null || report FAIL "PROBE_APPLY_FAILED"
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  namespace: ${PROBE_NS}
spec:
  restartPolicy: Never
  hostPID: true
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  containers:
    - name: agent
      image: ${AGENT_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      env:
        - name: HLVM_HOST_WRAPPER
          value: "${WRAPPER}"
      volumeMounts:
        - {name: host, mountPath: /host}
        - {name: dev, mountPath: /dev}
        - {name: run-lock-lvm, mountPath: /run/lock/lvm}
  volumes:
    - {name: host, hostPath: {path: /}}
    - {name: dev, hostPath: {path: /dev}}
    - {name: run-lock-lvm, hostPath: {path: /run/lock/lvm}}
YAML
    PROBE_CREATED=1
    READY=""
    for i in $(seq 1 45); do
      READY="$("${K[@]}" -n "$PROBE_NS" get pod "$PROBE_POD" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
      [[ "$READY" == "true" ]] && break
      sleep 2
    done
    if [[ "$READY" != "true" ]]; then
      "${K[@]}" -n "$PROBE_NS" describe pod "$PROBE_POD" 2>&1 | tail -12 || true
      report FAIL "PROBE_NOT_READY"
    fi
    EXEC_NS="$PROBE_NS"
    EXEC_POD="$PROBE_POD"
    EXEC_CONTAINER="agent"
    ;;
  pod)
    if [[ -z "$POD_NAME" ]]; then report FAIL "MODE_POD_REQUIRES_POD_NAME"; fi
    EXEC_NS="$POD_NS"
    EXEC_POD="$POD_NAME"
    EXEC_CONTAINER="$POD_CONTAINER"
    echo "    pod=$EXEC_NS/$EXEC_POD (container=$EXEC_CONTAINER)"
    ;;
  *) report FAIL "UNKNOWN_MODE_$MODE" ;;
esac

# 单引号 heredoc：注释禁用反引号，所有 $ 都保留给远端 sh 展开。
cat > "$GATE_SCRIPT" <<'EOS'
set -u
VG="$1"; LV="$2"; T="$3"; SZ="$4"
W=${HLVM_HOST_WRAPPER:-}
if [ -z "$W" ]; then
  echo "WRAPPER=<unset>"
  echo "RESULT=FAIL reason=NO_WRAPPER（结构性缺失：agent 未注入 HLVM_HOST_WRAPPER）"
  exit 1
fi
echo "WRAPPER=$W"

# 忠实复刻 lvm_argv_with 的 split_whitespace：wrapper token 放在命令最前面。
# 函数内的 set -- 只改函数自身位置参数，不影响调用方。
run_host() { set -- $W "$@"; "$@"; }
cleanup_lv() {
  if [ -n "${VG:-}" ]; then
    run_host timeout -k 5 "$T" lvm lvremove -y "$VG/$LV" >/dev/null 2>&1 || true
  fi
}
# 任何出口都尝试清场：timeout -k 可能在 LV 已落盘之后才杀掉 lvm，
# 此时 CREATE_RC != 0 但测试 LV 会留在业务 VG 上（2026-11-12 负向对照实测）。
trap cleanup_lv EXIT

check_remain() {
  AFTER=$(run_host timeout -k 5 "$T" lvm lvs --noheadings -o lv_name "$VG" 2>/dev/null || true)
  printf '%s\n' "$AFTER" | grep -cw "$LV" || true
}

# 前置能力：宿主侧必须有 timeout（timeout 置于 wrapper 之后，杀的是宿主 lvm 进程）。
if ! run_host sh -c 'command -v timeout >/dev/null 2>&1'; then
  echo "RESULT=SKIP reason=NO_HOST_TIMEOUT"
  exit 2
fi

# 静态信息（只读、不取锁）——仅作证据，绝不计 PASS。
VER=$(run_host lvm version 2>&1 | head -1 || true)
echo "INFO_VERSION=${VER:-<empty>}"

# 选一个真正可写的 VG：显式指定优先，否则取 free >= 64MiB 的第一个。
if [ -z "$VG" ]; then
  VG=$(run_host timeout -k 5 "$T" lvm vgs --noheadings --units b -o vg_name,vg_free 2>/dev/null \
    | awk '$2+0 >= 67108864 {print $1; exit}' || true)
fi
if [ -z "$VG" ]; then
  echo "RESULT=SKIP reason=NO_WRITABLE_VG"
  exit 2
fi
echo "INFO_VG=$VG INFO_LV=$LV INFO_SIZE=$SZ"

# 预清理同名 LV（上次异常退出可能留下），保证基线干净。
cleanup_lv

# 1) 真实写：这是旧门禁漏掉的取锁路径。
OUT=$(run_host timeout -k 5 "$T" lvm lvcreate -y -n "$LV" -L "$SZ" "$VG" 2>&1) && RC=0 || RC=$?
echo "CREATE_RC=$RC"
echo "CREATE_OUT=${OUT:-<empty>}"
if [ "$RC" != "0" ]; then
  cleanup_lv
  echo "CLEANUP_REMAIN=$(check_remain)"
  echo "RESULT=FAIL reason=CREATE_RC_$RC"
  echo "HINT=若 VG 被锁死，经宿主 PID1 执行 pkill -9 -x lvm 后重试（见 ADR-006 11.5）"
  exit 1
fi

# 2) 宿主 lvs 必须真的看得见这颗 LV（读不到一律 FAIL，不做无据判定）。
LIST=$(run_host timeout -k 5 "$T" lvm lvs --noheadings -o lv_name "$VG" 2>&1) && LRC=0 || LRC=$?
echo "LVS_RC=$LRC"
echo "LVS_LIST=$(printf '%s' "$LIST" | tr '\n' ' ')"
if [ "$LRC" != "0" ]; then
  cleanup_lv
  echo "CLEANUP_REMAIN=$(check_remain)"
  echo "RESULT=FAIL reason=LVS_UNREADABLE"
  exit 1
fi
if ! printf '%s\n' "$LIST" | grep -qw "$LV"; then
  cleanup_lv
  echo "CLEANUP_REMAIN=$(check_remain)"
  echo "RESULT=FAIL reason=LV_NOT_VISIBLE"
  exit 1
fi

# 3) 清理并确认残留 0。
cleanup_lv
REMAIN=$(check_remain)
echo "REMAIN=${REMAIN:-0}"
if [ "${REMAIN:-0}" != "0" ]; then echo "RESULT=FAIL reason=LV_LEFTOVER"; exit 1; fi

echo "RESULT=PASS vg=$VG lv=$LV"
exit 0
EOS

echo "== 1. 执行真实写门禁（宿主侧 timeout -k 5 ${WRITE_TIMEOUT}s，外层 ${EXEC_TIMEOUT}s）=="
GATE_OUT="$(timeout "$EXEC_TIMEOUT" "${K[@]}" -n "$EXEC_NS" exec -i "$EXEC_POD" \
  -c "$EXEC_CONTAINER" -- sh -s "$VG" "$LV_NAME" "$WRITE_TIMEOUT" "$LV_SIZE" \
  < "$GATE_SCRIPT" 2>&1)" && GATE_RC=0 || GATE_RC=$?
printf '%s\n' "$GATE_OUT" | sed 's/^/       /'
echo "EXEC_RC=$GATE_RC"

RESULT="$(printf '%s\n' "$GATE_OUT" | sed -n 's/^RESULT=\([A-Z]*\).*/\1/p' | head -1 || true)"
REASON="$(printf '%s\n' "$GATE_OUT" | sed -n 's/^RESULT=[A-Z]* reason=\([^ ]*\).*/\1/p' | head -1 || true)"

case "${RESULT:-}" in
  PASS) if [[ "$GATE_RC" == "0" ]]; then report PASS "REAL_WRITE_OK"; else report FAIL "PASS_BUT_EXEC_RC_$GATE_RC"; fi ;;
  FAIL) report FAIL "${REASON:-REMOTE_FAIL}" ;;
  SKIP) report SKIP "${REASON:-REMOTE_SKIP}" ;;
  *)    report FAIL "NO_RESULT_LINE(exec_rc=$GATE_RC)" ;;
esac
