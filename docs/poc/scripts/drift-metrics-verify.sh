#!/usr/bin/env bash
# drift-metrics-verify.sh —— ADR-006 §17.6「对账可观测性」真机判据。
#
# 判据目标（缺一不可）：
#   1. 正向：每个 NodeVG 都有 storage_controller_lv_report_present=1 且时间戳新鲜
#      （age ≤ MAX_AGE_OK），正常态无 >0 漂移条目；
#   2. 停摆可判：让**一个** worker 的 agent 停写（taint 不可容忍 + 删该节点 Pod，DS 不会
#      重建）→ 时间戳冻结、年龄越过阈值 → 触发 reconcile 后
#      skipped_total{reason="report_stale"} 增长，且**不新增** StorageDrift 事件；
#   3. 恢复：移除 taint 后 agent 回来、时间戳重新刷新（age ≤ MAX_AGE_OK）。
#
# 为什么停摆阶段要造一个 PV（fixture）：控制面只对「有 PV 的节点」调用 reporter
# （`nodes` 由 managed 推导），无 PV 的集群里 `report_stale` 分支根本不可达。
# fixture 走 `hlvm.dev/node` 注解兼容路径，只用于让代码路径可达，不验证 PV→LV 映射
# （后者由 drift-reconcile-e2e.sh 用真实 PVC/Pod 覆盖）。fixture 必须在恢复上报**之前**
# 删除，否则新鲜清单会把不存在的 LV 判成 missing-lv 误报。
#
# 判据纪律（沿用 drift-reconcile-e2e.sh）：
#   - 指标抓 leader 副本：controller-runtime leader election 下只有 leader 更新指标；
#   - 端口转发在长等待里会静默失效，故每次测量前重建；
#   - 能力缺失（取不到 leader / /metrics 不可达 / 无法加 taint）一律 SKIP，绝不计 PASS；
#   - EXIT trap 无条件删除 fixture、移除 taint（否则 agent 永远回不来）。
#
# 诚实边界：本脚本证明「指标能反映上报停摆」，**不证明** Prometheus 真的求值了
# alert-rules-drift.yaml（仓库未接 Prometheus）；事件仍是主要证据载体。
#
# 用法（WSL 内、仓库根）：
#   export KUBECONFIG=$HOME/.kube/hlvm-real.conf
#   bash docs/poc/scripts/drift-metrics-verify.sh
#   SKIP_STALL=1 bash docs/poc/scripts/drift-metrics-verify.sh   # 只跑只读正向判据
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/hlvm-real.conf}"
CTRL_NS="${CTRL_NS:-hlvm-system}"
AGENT_NS="${AGENT_NS:-hlvm-system}"
CTRL_DEPLOY="${CTRL_DEPLOY:-hlvm-storage-controller}"
AGENT_DS="${AGENT_DS:-hlvm-storage-agent}"
SVC_PORT="${SVC_PORT:-8080}"
LOCAL_PORT="${LOCAL_PORT:-18081}"
MAX_AGE_OK="${MAX_AGE_OK:-90}"        # 正向：上报年龄上限（agent 30s 采样 / 60s 保活）
STALL_MIN_AGE="${STALL_MIN_AGE:-200}" # 停摆：年龄下限（须 > DefaultLVReportMaxAge=180）
STALL_WAIT="${STALL_WAIT:-300}"
RESTORE_WAIT="${RESTORE_WAIT:-240}"
SKIP_STALL="${SKIP_STALL:-0}"
TAINT_KEY="${TAINT_KEY:-hlvm.io/agent-stopped}"
FIXTURE_PV="${FIXTURE_PV:-hlvm-drift-metrics-$$}"

KC=(kubectl --kubeconfig "$KUBECONFIG")
HLVM_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || true)"
METRICS_FILE="/tmp/hlvm-drift-metrics-$$.txt"

passes=0 fails=0 skips=0
VERDICT="PASS"
PF_PID=""
TAINTED_NODE=""
FIXTURE_CREATED=0
ANNOTATED_VG=""

pass() { echo "[pass] $*"; passes=$((passes + 1)); }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
skip() { echo "[skip] $*"; skips=$((skips + 1)); }
info() { echo "       $*"; }

trap 'echo "[error] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

finish() {
  local rc=0
  if ((fails > 0)); then VERDICT="FAIL"; rc=1; fi
  if [[ "$VERDICT" == "PASS" && "$passes" -eq 0 ]]; then VERDICT="SKIP"; rc=2; fi
  echo "==================== 汇总 ===================="
  echo "DRIFT_METRICS_RESULT=${VERDICT} PASS=${passes} FAIL=${fails} SKIP=${skips}"
  exit "$rc"
}

pf_stop() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}

cleanup() {
  local rc=$?
  pf_stop
  if [[ -n "$ANNOTATED_VG" ]]; then
    "${KC[@]}" -n "$CTRL_NS" annotate nodevg "$ANNOTATED_VG" hlvm.dev/force-reconcile- >/dev/null 2>&1 || true
  fi
  if ((FIXTURE_CREATED == 1)); then
    "${KC[@]}" delete pv "$FIXTURE_PV" --wait=true --timeout=60s >/dev/null 2>&1 || true
    info "已删除 fixture PV $FIXTURE_PV"
  fi
  if [[ -n "$TAINTED_NODE" ]]; then
    "${KC[@]}" taint node "$TAINTED_NODE" "${TAINT_KEY}-" >/dev/null 2>&1 || true
    info "已移除 taint ${TAINT_KEY} on ${TAINTED_NODE}（rc=$rc）"
  fi
  rm -f "$METRICS_FILE"
}

leader_pod() {
  "${KC[@]}" -n "$CTRL_NS" get lease "$CTRL_DEPLOY" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null \
    | cut -d_ -f1 || true
}

# 重建端口转发并抓一份 /metrics（长等待后转发会静默失效，故每次测量前重建）。
metrics_refresh() {
  local pod i
  pod="$(leader_pod)"
  if [[ -z "$pod" ]]; then
    info "取不到 leader Pod（lease ${CTRL_DEPLOY} 缺失）"
    return 1
  fi
  pf_stop
  "${KC[@]}" -n "$CTRL_NS" port-forward "pod/${pod}" "${LOCAL_PORT}:${SVC_PORT}" \
    >/tmp/pf-drift-metrics.log 2>&1 &
  PF_PID=$!
  for i in $(seq 1 20); do
    if curl -sf --max-time 5 "http://127.0.0.1:${LOCAL_PORT}/metrics" -o "$METRICS_FILE" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  info "抓取 /metrics 失败（leader=${pod}）"
  return 1
}

# metric_get <完整选择器>：返回**整数**样本值（Prometheus 文本格式对大数用科学计数法
# 1.794463357e+09，直接正则判数字会误判「缺失」）；序列不存在时输出空串。
metric_get() {
  awk -v s="$1" 'index($0, s) == 1 {printf "%.0f\n", $NF; exit}' "$METRICS_FILE"
}

nodevg_rows() {
  "${KC[@]}" get nodevg -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

drift_event_count() {
  local out
  out="$("${KC[@]}" get events -A --field-selector reason=StorageDrift \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || return 1
  if [[ -z "$out" ]]; then
    echo 0
    return 0
  fi
  awk 'END {print NR}' <<< "$out"
}

agent_pods_on() {
  "${KC[@]}" -n "$AGENT_NS" get pods -l app.kubernetes.io/component=storage-agent \
    --field-selector "spec.nodeName=$1" --no-headers 2>/dev/null | wc -l
}

trap cleanup EXIT

echo "=== 前置 ==="
info "VERSION=${HLVM_VERSION} leader=$(leader_pod)"
DEPLOY_IMG="$("${KC[@]}" -n "$CTRL_NS" get deploy "$CTRL_DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
info "controller image=${DEPLOY_IMG}"
if ! metrics_refresh; then
  skip "/metrics 入口不可用（端口转发/leader/rbac），本轮判据未覆盖"
  finish
fi
pass "leader /metrics 可抓取"

# ---------- 1. 正向：每个 NodeVG 都有新鲜上报 ----------
ROWS="$(nodevg_rows)"
if [[ -z "$ROWS" ]]; then
  fail "集群内没有 NodeVG（判据前提不成立）"
  finish
fi
while IFS='|' read -r node vg; do
  [[ -n "$vg" ]] || continue
  pres="$(metric_get "storage_controller_lv_report_present{node=\"${node}\",vg=\"${vg}\"}")"
  ts="$(metric_get "storage_controller_lv_report_timestamp_seconds{node=\"${node}\",vg=\"${vg}\"}")"
  if [[ "$pres" != "1" ]]; then
    fail "${node}/${vg} present=${pres:-<缺失>}，期望 1（指标未接线或 Agent 从未上报）"
    continue
  fi
  if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
    fail "${node}/${vg} 时间戳缺失或非数字（present=1 但无时间戳，指标自相矛盾）"
    continue
  fi
  age=$(( $(date +%s) - ts ))
  if ((age < 0)); then
    fail "${node}/${vg} 时间戳在未来（age=${age}s，时钟漂移）"
    continue
  fi
  if ((age > MAX_AGE_OK)); then
    fail "${node}/${vg} 上报年龄 ${age}s > ${MAX_AGE_OK}s（对账已不覆盖）"
    continue
  fi
  pass "${node}/${vg} present=1 age=${age}s"
done <<< "$ROWS"

DRIFT_HOT="$(awk 'index($0, "storage_controller_drift_items{") == 1 && $NF + 0 > 0 {print; exit}' "$METRICS_FILE")"
if [[ -n "$DRIFT_HOT" ]]; then
  fail "存在 >0 的漂移条目（正常态应为 0）：${DRIFT_HOT}"
else
  pass "正常态无 >0 漂移条目"
fi

if [[ "$SKIP_STALL" == "1" ]]; then
  skip "SKIP_STALL=1：未验证停摆/恢复（不得据此称 §17.6 全覆盖）"
  finish
fi

# ---------- 2. 停摆 ----------
FIRST="$(awk -F'|' 'NF>=2 && $2!="" {print; exit}' <<< "$ROWS")"
FIRST_NODE="${FIRST%%|*}"
FIRST_VG="${FIRST##*|}"
SKIP_BEFORE="$(metric_get 'storage_controller_drift_reconcile_skipped_total{reason="report_stale"}')"
SKIP_BEFORE="${SKIP_BEFORE:-0}"
EVENTS_BEFORE="$(drift_event_count)" || EVENTS_BEFORE=""
info "停摆判据节点=${FIRST_NODE} vg=${FIRST_VG}（skipped 基线=${SKIP_BEFORE}）"

# 只让一个 worker 停写：taint 不被 DS 容忍 ⇒ DS 不会在该节点重建 Pod。
if ! "${KC[@]}" taint node "$FIRST_NODE" "${TAINT_KEY}=true:NoSchedule" --overwrite >/dev/null 2>&1; then
  fail "无法给 ${FIRST_NODE} 加 taint（rbac/准入），停摆判据未覆盖"
  finish
fi
TAINTED_NODE="$FIRST_NODE"
if ! "${KC[@]}" -n "$AGENT_NS" delete pod -l app.kubernetes.io/component=storage-agent \
  --field-selector "spec.nodeName=${FIRST_NODE}" --wait=true --timeout=120s >/dev/null 2>&1; then
  fail "删除 ${FIRST_NODE} 上的 agent Pod 失败或超时"
  finish
fi
for _ in $(seq 1 12); do
  if (( $(agent_pods_on "$FIRST_NODE") == 0 )); then break; fi
  sleep 5
done
if (( $(agent_pods_on "$FIRST_NODE") != 0 )); then
  fail "${FIRST_NODE} 上仍有 agent Pod，停摆判据不可信"
  finish
fi
pass "${FIRST_NODE} 的 agent 已停写（taint + 删 Pod，DS 未重建）"

# 等时间戳自然变旧（不伪造 status，避免把「改数据」当成「能观测」）。
STALLED=0
age=""
for _ in $(seq 1 $((STALL_WAIT / 10))); do
  if ! metrics_refresh; then sleep 10; continue; fi
  ts="$(metric_get "storage_controller_lv_report_timestamp_seconds{node=\"${FIRST_NODE}\",vg=\"${FIRST_VG}\"}")"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    age=$(( $(date +%s) - ts ))
    if ((age > STALL_MIN_AGE)); then STALLED=1; break; fi
  fi
  sleep 10
done
if ((STALLED == 1)); then
  pass "${FIRST_NODE}/${FIRST_VG} 时间戳冻结且 age=${age}s > ${STALL_MIN_AGE}s（停摆可观测）"
else
  fail "等待 ${STALL_WAIT}s 后上报年龄仍未越过 ${STALL_MIN_AGE}s（age=${age:-<缺失>}）"
  finish
fi

# fixture PV：让 `nodes`（由 managed 推导）非空，report_stale 分支才可达。
# 此刻上报已过期 ⇒ 控制器整轮放弃，不会把 fixture 判成 missing-lv。
if cat <<EOF | "${KC[@]}" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${FIXTURE_PV}
  annotations:
    hlvm.dev/node: "${FIRST_NODE}"
    hlvm.dev/vg: "${FIRST_VG}"
spec:
  capacity:
    storage: 1Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/hlvm-drift-metrics-noop
EOF
then
  FIXTURE_CREATED=1
  pass "已建 fixture PV ${FIXTURE_PV}（使 report_stale 分支可达）"
else
  fail "创建 fixture PV 失败，跳过计数不可达"
  finish
fi

if "${KC[@]}" -n "$CTRL_NS" annotate nodevg "$FIRST_VG" \
  "hlvm.dev/force-reconcile=$(date +%s)" --overwrite >/dev/null 2>&1; then
  ANNOTATED_VG="$FIRST_VG"
  pass "已注解 ${FIRST_VG} 触发 reconcile"
else
  fail "注解 NodeVG 失败，无法验证跳过计数"
  finish
fi
sleep 15
if ! metrics_refresh; then
  fail "触发后抓取 /metrics 失败"
  finish
fi
SKIP_AFTER="$(metric_get 'storage_controller_drift_reconcile_skipped_total{reason="report_stale"}')"
SKIP_AFTER="${SKIP_AFTER:-0}"
if ((SKIP_AFTER > SKIP_BEFORE)); then
  pass "skipped_total{reason=\"report_stale\"} ${SKIP_BEFORE} → ${SKIP_AFTER}（放弃对账已计数）"
else
  fail "skipped_total{reason=\"report_stale\"} 未增长（${SKIP_BEFORE} → ${SKIP_AFTER}），静默停摆仍不可观测"
fi

EVENTS_AFTER="$(drift_event_count)" || EVENTS_AFTER=""
if [[ -z "$EVENTS_BEFORE" || -z "$EVENTS_AFTER" ]]; then
  skip "StorageDrift 事件读取失败，「停摆期间不得新增告警」未覆盖"
elif ((EVENTS_AFTER > EVENTS_BEFORE)); then
  fail "停摆期间新增了 StorageDrift 事件（${EVENTS_BEFORE} → ${EVENTS_AFTER}）：stale 清单被当成漂移"
else
  pass "停摆期间未新增 StorageDrift 事件（${EVENTS_BEFORE} → ${EVENTS_AFTER}）"
fi

# ---------- 3. 恢复 ----------
# 顺序关键：先删 fixture 再恢复上报，否则新鲜清单会把不存在的 LV 判成 missing-lv。
if "${KC[@]}" delete pv "$FIXTURE_PV" --wait=true --timeout=60s >/dev/null 2>&1; then
  FIXTURE_CREATED=0
  pass "已删除 fixture PV"
else
  fail "删除 fixture PV 失败（恢复上报后会产生 missing-lv 误报）"
  finish
fi
"${KC[@]}" taint node "$FIRST_NODE" "${TAINT_KEY}-" >/dev/null 2>&1 || true
TAINTED_NODE=""
pass "已移除 taint，等待 agent 重建"

RECOVERED=0
age=""
for _ in $(seq 1 $((RESTORE_WAIT / 10))); do
  if ! metrics_refresh; then sleep 10; continue; fi
  ts="$(metric_get "storage_controller_lv_report_timestamp_seconds{node=\"${FIRST_NODE}\",vg=\"${FIRST_VG}\"}")"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    age=$(( $(date +%s) - ts ))
    if ((age <= MAX_AGE_OK)) && (( $(agent_pods_on "$FIRST_NODE") >= 1 )); then
      RECOVERED=1
      break
    fi
  fi
  sleep 10
done
if ((RECOVERED == 1)); then
  pass "${FIRST_NODE}/${FIRST_VG} 上报恢复（age=${age}s ≤ ${MAX_AGE_OK}s，Pod 已重建）"
else
  fail "恢复 ${RESTORE_WAIT}s 后上报仍不新鲜（age=${age:-<缺失>}）"
fi

finish
