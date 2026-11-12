#!/usr/bin/env bash
# drift-reconcile-e2e.sh —— ADR-006 §16「三方对账」真机端到端判据。
#
# 判据目标（缺一不可，任何一条都不能靠「读不到=没有」凑绿）：
#   0. 前置：控制器/agent 均运行发布版 :v<VERSION>；本节点 NodeVG 有新鲜的
#      lastLVReportTime，且 logicalVolumes 中不含 thin-pool 自身；
#   1. 正常态：建 PVC/Pod（SC 是 WFFC，无消费者 PVC 恒 Pending）→ PV Bound →
#      Agent 上报的 LV 名 = spec.csi.volumeHandle → 基线之后**零** StorageDrift 告警；
#   2. 漂移注入：宿主手工 lvcreate 一颗普通 LV → Agent 上报 → 控制器发出
#      unmanaged-lv 告警事件（message 含该 LV 名），且**不得**出现 missing-lv 双向误报；
#   3. 漂移消除：lvremove 后 Agent 清单移除该 LV，告警计数在观察窗口内不再增长；
#   4. 回收：删 Pod/PVC → PV 与宿主 LV 消失，NodeVG 清单不含业务 LV，无残留。
#
# 判据纪律（沿用 m15-integration.sh / pvc-supply-e2e.sh）：
#   - 能力缺失（无 agent Pod、无宿主 wrapper、未上报）一律 SKIP 且**不计 PASS**；
#   - 所有 kubectl 字段读取走 kc_get 三次重试，严格区分「读取失败」与「值确实为空」；
#   - 多节点下绝不 `kubectl exec/logs ds/...` 任取 Pod，一律按 spec.nodeName 定点；
#   - 结论以收尾 DRIFT_E2E_RESULT 行 + 退出码为准（0=PASS / 1=FAIL / 2=SKIP）。
#
# 诚实边界：DetectDrift 在 managed 为空（无 PV）时按既有契约直接返回空，故漂移注入
# **必须在 PVC/PV 存在期间**进行；「空集群里手工 lvcreate 会被检出」不成立，不得声称覆盖。
#
# 用法（WSL 内、仓库根）：
#   export KUBECONFIG=$HOME/.kube/hlvm-real.conf
#   bash docs/poc/scripts/drift-reconcile-e2e.sh
#   NODE=10-60-166-202 VG=hlvm-lvmd-vg-202 bash ...
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/hlvm-real.conf}"
NODE="${NODE:-10-60-153-100}"
VG="${VG:-hlvm-lvmd-vg-153}"
SC="${SC:-hlvm-b}"
NS="${NS:-hlvm-drift-poc}"
SIZE="${SIZE:-1Gi}"
THINPOOL="${THINPOOL:-thinpool}"
AGENT_NS="${AGENT_NS:-hlvm-system}"
CTRL_NS="${CTRL_NS:-hlvm-system}"
AGENT_DS="${AGENT_DS:-hlvm-storage-agent}"
CTRL_DEPLOY="${CTRL_DEPLOY:-hlvm-storage-controller}"
PVC="${PVC:-hlvm-drift-pvc}"
POD="${POD:-hlvm-drift-pod}"
MANUAL_SIZE="${MANUAL_SIZE:-64M}"
WAIT_SECS="${WAIT_SECS:-240}"
REPORT_WAIT_SECS="${REPORT_WAIT_SECS:-150}"
SETTLE_SECS="${SETTLE_SECS:-90}"
EXPECTED_WRAPPER="nsenter -t 1 -m -u -i -n -p --"

KC=(kubectl --kubeconfig "$KUBECONFIG")
HLVM_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || true)"
MANUAL_LV="hlvm-drift-$$"

fails=0 passes=0 skips=0
VERDICT="PASS"
FORCED_SKIP=0
PVC_CREATED=0
MANUAL_CREATED=0
WRAPPER=""
W=()

pass() { echo "[pass] $*"; passes=$((passes + 1)); }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
skip() { echo "[skip] $*"; skips=$((skips + 1)); }
info() { echo "       $*"; }

trap 'echo "[error] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# kc_get：3 次重试；成功返回 0（值允许为空，由调用方判「确实缺失」），
# 3 次全失败返回 1，调用方必须报「读取失败、判据未覆盖」。
kc_get() {
  local __var="$1"; shift
  local __rc __val __i
  for __i in 1 2 3; do
    __val="$("${KC[@]}" "$@" 2>/dev/null)" && __rc=0 || __rc=$?
    if ((__rc == 0)); then
      printf -v "$__var" '%s' "$__val"
      return 0
    fi
    sleep 2
  done
  printf -v "$__var" ''
  return 1
}

# 定点取本节点上 Ready 且未在删除中的 agent Pod（绝不 ds/ 任取）。
agent_pod_on_node() {
  "${KC[@]}" -n "$AGENT_NS" get pods -l app.kubernetes.io/component=storage-agent \
    -o jsonpath='{range .items[?(@.spec.nodeName=="'"${NODE}"'")]}{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$2=="True" && $3=="" {print $1; exit}' || true
}

# 宿主 lvm：只使用 agent Pod 里真实注入的 HLVM_HOST_WRAPPER（不另设），
# 复用 §5.3 锁同源路径；写路径不追加 --reportformat json。
# 双层 timeout（与 host-wrapper-gate.sh 一致）：内层在宿主命名空间侧杀 lvm 进程本身，
# 外层防 kubectl exec 连接泄漏留下持 VG flock 的孤儿进程。
host_lvm() {
  local pod
  pod="$(agent_pod_on_node || true)"
  if [[ -z "$pod" ]]; then
    echo "[error] 节点 ${NODE} 上无 Ready 的 agent Pod" >&2
    return 1
  fi
  timeout 60 "${KC[@]}" -n "$AGENT_NS" exec "$pod" -c agent -- \
    "${W[@]}" timeout -k 5 30 lvm "$@"
}

# 读取宿主 lvs（名称列），执行失败与「确实没有」严格分开。
host_lv_names() {
  local pod out rc
  pod="$(agent_pod_on_node || true)"
  [[ -n "$pod" ]] || return 1
  out="$(timeout 60 "${KC[@]}" -n "$AGENT_NS" exec "$pod" -c agent -- "${W[@]}" \
    timeout -k 5 20 lvm lvs -o lv_name,vg_name --reportformat json 2>/dev/null)" && rc=0 || rc=$?
  ((rc == 0)) || return 1
  printf '%s' "$out" | grep -o '"lv_name":"[^"]*"' | sed 's/.*:"//; s/"$//' || true
}

# StorageDrift 事件转 `ts|count|message` 行；读取失败显式返回 1。
#
# ts 优先取 `lastTimestamp`，为空时回退 `metadata.creationTimestamp`：新版 k8s 事件
# 走 events.k8s.io 语义，lastTimestamp 可能不再填充，只读它会把「所有告警」都读成
# 「零告警」——这正是零误报判据最危险的假绿来源，故必须兜底。
drift_events() {
  local out=""
  kc_get out get events -A --field-selector reason=StorageDrift \
    -o jsonpath='{range .items[*]}{.lastTimestamp}{"|"}{.metadata.creationTimestamp}{"|"}{.count}{"|"}{.message}{"\n"}{end}' || return 1
  awk -F'|' 'length($0) == 0 { next }
  {
    ts = ($1 != "" ? $1 : $2)
    n  = ($3 == "" ? 1 : $3)
    printf "%s|%s|%s\n", ts, n, $4
  }' <<< "$out"
}

# 只保留时间戳 >= since 的事件（RFC3339 UTC 同格式可字典序比较）。
events_since() {
  local since="$1" out=""
  out="$(drift_events)" || return 1
  awk -F'|' -v s="$since" '$1 >= s {print}' <<< "$out"
}

# 事件计数总和（用于「清理后告警不再增长」判据）。
event_count_sum() {
  local out=""
  out="$(drift_events)" || return 1
  awk -F'|' 'length($0) == 0 { next } {n=($2==""?1:$2); s+=n} END {print s+0}' <<< "$out"
}

# 控制器两个副本的日志合并（leader election 只对 leader 有效，不能 logs deploy 任取）。
controller_logs() {
  local pods="" p out=""
  kc_get pods -n "$CTRL_NS" get pods -l app.kubernetes.io/component=storage-controller \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' || return 1
  for p in $pods; do
    out+="$("${KC[@]}" -n "$CTRL_NS" logs "$p" -c manager --since=10m 2>/dev/null || true)"$'\n'
  done
  printf '%s' "$out"
}

lv_report_names() {
  local out=""
  kc_get out get nodevg "$VG" \
    -o jsonpath='{range .status.logicalVolumes[*]}{.name}{"\n"}{end}' || return 1
  printf '%s' "$out"
}

wait_for_lv_in_report() {
  local needle="$1" deadline=$((SECONDS + REPORT_WAIT_SECS)) names=""
  while ((SECONDS < deadline)); do
    if names="$(lv_report_names)"; then
      if grep -qxF "$needle" <<< "$names"; then return 0; fi
    fi
    sleep 5
  done
  return 1
}

wait_for_lv_absent_in_report() {
  local needle="$1" deadline=$((SECONDS + REPORT_WAIT_SECS)) names=""
  while ((SECONDS < deadline)); do
    if names="$(lv_report_names)"; then
      if ! grep -qxF "$needle" <<< "$names"; then return 0; fi
    fi
    sleep 5
  done
  return 1
}

cleanup() {
  trap - EXIT
  if [[ "$MANUAL_CREATED" == "1" ]]; then
    if host_lvm lvremove -y "${VG}/${MANUAL_LV}" >/dev/null 2>&1; then
      info "cleanup: 已删除手工 LV ${MANUAL_LV}"
      MANUAL_CREATED=0
    else
      fail "cleanup: 手工 LV ${MANUAL_LV} 删除失败（需人工核实宿主）"
    fi
  fi
  if [[ "$PVC_CREATED" == "1" ]]; then
    "${KC[@]}" -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
    "${KC[@]}" -n "$NS" delete pvc "$PVC" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
    PVC_CREATED=0
  fi
}

finish() {
  local rc=0
  # FAIL 优先于 SKIP：结构性失败不能被「能力未覆盖」吞掉。
  if [[ "$FORCED_SKIP" == "1" ]]; then VERDICT="SKIP"; rc=2; fi
  if ((fails > 0)); then VERDICT="FAIL"; rc=1; fi
  echo "==================== 汇总 ===================="
  echo "DRIFT_E2E_RESULT=${VERDICT} PASS=${passes} FAIL=${fails} SKIP=${skips}"
  exit "$rc"
}
trap cleanup EXIT

echo "=== ADR-006 §16 三方对账真机 E2E (node=$NODE vg=$VG version=$HLVM_VERSION) ==="
[[ -n "$HLVM_VERSION" ]] || { fail "读不到仓库根 VERSION"; finish; }

# ---------------------------------------------------------------------------
# 0. 前置（结构性缺失判 FAIL；能力缺失判 SKIP，绝不计 PASS）
# ---------------------------------------------------------------------------
NODE_JSON=""
if ! kc_get NODE_JSON get node "$NODE" -o jsonpath='{.metadata.name}'; then
  fail "读取节点 $NODE 失败（判据未覆盖）"; finish
fi
[[ "$NODE_JSON" == "$NODE" ]] || { fail "节点 $NODE 不存在"; finish; }

VG_NODE=""
if ! kc_get VG_NODE get nodevg "$VG" -o jsonpath='{.spec.nodeName}'; then
  skip "NodeVG $VG 不存在或未接入（本轮未覆盖三方对账）"; FORCED_SKIP=1; finish
fi
[[ "$VG_NODE" == "$NODE" ]] || { fail "NodeVG $VG 的 nodeName=$VG_NODE 与 NODE 不符"; finish; }

CTRL_IMAGE=""
AGENT_IMAGE=""
if ! kc_get CTRL_IMAGE -n "$CTRL_NS" get deploy "$CTRL_DEPLOY" \
     -o jsonpath='{.spec.template.spec.containers[0].image}'; then
  fail "读取控制器镜像失败（判据未覆盖）"; finish
fi
if ! kc_get AGENT_IMAGE -n "$AGENT_NS" get ds "$AGENT_DS" \
     -o jsonpath='{.spec.template.spec.containers[0].image}'; then
  skip "常驻 agent DS 不存在（本轮未覆盖 LV 上报）"; FORCED_SKIP=1; finish
fi
if [[ "$CTRL_IMAGE" == *":v${HLVM_VERSION}" && "$AGENT_IMAGE" == *":v${HLVM_VERSION}" ]]; then
  pass "控制器与 agent 均为发布版 :v${HLVM_VERSION}"
else
  fail "镜像门禁不符（controller=$CTRL_IMAGE agent=$AGENT_IMAGE，期望 :v${HLVM_VERSION}）"
fi

if ! kc_get WRAPPER -n "$AGENT_NS" get ds "$AGENT_DS" \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HLVM_HOST_WRAPPER")].value}'; then
  fail "读取 agent DS 的 HLVM_HOST_WRAPPER 失败（判据未覆盖）"; finish
fi
if [[ "$WRAPPER" == "$EXPECTED_WRAPPER" ]]; then
  pass "agent wrapper 与推荐值逐字一致"
else
  fail "agent wrapper 不符（实际 ${WRAPPER:-空}）"
fi
read -ra W <<< "$WRAPPER"

AGENT_POD="$(agent_pod_on_node || true)"
if [[ -n "$AGENT_POD" ]]; then
  pass "本节点存在 Ready 的 agent Pod：$AGENT_POD"
else
  skip "本节点无 Ready agent Pod（本轮未覆盖宿主 lvs 采集）"; FORCED_SKIP=1; finish
fi

REPORT_TS=""
if ! kc_get REPORT_TS get nodevg "$VG" -o jsonpath='{.status.lastLVReportTime}'; then
  fail "读取 lastLVReportTime 失败（判据未覆盖）"; finish
fi
if [[ -z "$REPORT_TS" ]]; then
  skip "NodeVG 尚无 LV 上报（agent 未上线 §16 代码，本轮未覆盖）"; FORCED_SKIP=1; finish
fi
REPORT_EPOCH="$(date -u -d "$REPORT_TS" +%s 2>/dev/null || true)"
NOW_EPOCH="$(date -u +%s)"
if [[ -n "$REPORT_EPOCH" ]] && ((NOW_EPOCH - REPORT_EPOCH <= 180)); then
  pass "LV 上报新鲜（${REPORT_TS}，滞后 $((NOW_EPOCH - REPORT_EPOCH))s）"
else
  skip "LV 上报不新鲜或时间无法解析（$REPORT_TS），本轮未覆盖"; FORCED_SKIP=1; finish
fi

BASE_NAMES="$(lv_report_names)" || { fail "读取 LV 上报清单失败（判据未覆盖）"; finish; }
if grep -qxF "$THINPOOL" <<< "$BASE_NAMES"; then
  fail "agent 上报未过滤 thin-pool 自身（会造成稳定 unmanaged-lv 误报）"
else
  pass "LV 上报清单不含 thin-pool 自身"
fi
info "基线 logicalVolumes: $(tr '\n' ' ' <<< "${BASE_NAMES:-空}")"

# ---------------------------------------------------------------------------
# 1. 正常态：PVC + Pod → PV Bound → Agent 上报 → 零漂移告警
# ---------------------------------------------------------------------------
BASELINE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"${KC[@]}" create namespace "$NS" --dry-run=client -o yaml 2>/dev/null \
  | "${KC[@]}" apply -f - >/dev/null 2>&1 || true
PVC_CREATED=1
"${KC[@]}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NS
spec:
  storageClassName: $SC
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: $SIZE
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE
  containers:
    - name: c
      image: ghcr.io/topolvm/topolvm-with-sidecar:0.42.0
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $PVC
EOF
info "PVC/Pod 已提交（SC=$SC size=$SIZE node=$NODE；WFFC 必须带消费者）"

PHASE=""
PHASE_READ_FAIL=0
deadline=$((SECONDS + WAIT_SECS))
while ((SECONDS < deadline)); do
  PHASE=""
  if ! kc_get PHASE -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}'; then
    PHASE_READ_FAIL=1
    break
  fi
  [[ "$PHASE" == "Bound" ]] && break
  sleep 5
done
if [[ "$PHASE" == "Bound" ]]; then
  pass "PVC Bound"
elif [[ "$PHASE_READ_FAIL" == "1" ]]; then
  fail "读取 PVC phase 连续失败（Bound 判据未覆盖）"; finish
else
  fail "PVC 未 Bound（phase=${PHASE:-空}）"; finish
fi

PV_NAME=""
VOLUME_HANDLE=""
if ! kc_get PV_NAME -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}'; then
  fail "读取 PVC volumeName 失败（判据未覆盖）"; finish
fi
if ! kc_get VOLUME_HANDLE get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}'; then
  fail "读取 PV volumeHandle 失败（判据未覆盖）"; finish
fi
[[ -n "$PV_NAME" && -n "$VOLUME_HANDLE" ]] || { fail "PV 名/volumeHandle 确实为空"; finish; }
info "PV=$PV_NAME volumeHandle=$VOLUME_HANDLE（宿主 LV 名）"

if wait_for_lv_in_report "$VOLUME_HANDLE"; then
  pass "agent 已把业务 LV 上报到 NodeVG.status.logicalVolumes"
else
  fail "agent 未上报业务 LV（${REPORT_WAIT_SECS}s 内）；三方对账的 lvs 一侧未覆盖"
  finish
fi

if EVENTS="$(events_since "$BASELINE_TS")"; then
  # 空集必须计 0：here-string 会把 "" 变成一行空行，不跳过就会把「没有告警」
  # 误判成「1 条告警」（2026-11-12 真机首跑即踩到，属判据假红而非产品误报）。
  NEW_COUNT="$(awk -F'|' 'length($0) == 0 { next } {n=($2==""?1:$2); s+=n} END {print s+0}' <<< "$EVENTS")"
  if [[ "$NEW_COUNT" == "0" ]]; then
    pass "正常态零 StorageDrift 告警（基线 $BASELINE_TS 之后）"
  else
    fail "正常态出现 $NEW_COUNT 条漂移告警（疑似误报）：$(tr '\n' ' ' <<< "$EVENTS")"
  fi
else
  fail "读取 StorageDrift 事件失败（零误报判据未覆盖）"
fi

# ---------------------------------------------------------------------------
# 2. 漂移注入：手工 lvcreate 必须命中 unmanaged-lv，且不得出现双向误报
# ---------------------------------------------------------------------------
INJECT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if host_lvm lvcreate -y -n "$MANUAL_LV" -L "$MANUAL_SIZE" "$VG" >/dev/null 2>&1; then
  MANUAL_CREATED=1
  pass "宿主手工创建普通 LV：$MANUAL_LV ($MANUAL_SIZE)"
else
  fail "宿主 lvcreate 失败（漂移注入未生效）"; finish
fi

if wait_for_lv_in_report "$MANUAL_LV"; then
  pass "agent 已上报手工 LV（未把它当内部 LV 过滤掉）"
else
  fail "agent 未上报手工 LV；漂移检测不可能命中"; finish
fi

SINCE_EVENTS=""
DRIFT_FOUND=0
deadline=$((SECONDS + REPORT_WAIT_SECS))
while ((SECONDS < deadline)); do
  if SINCE_EVENTS="$(events_since "$INJECT_TS")"; then
    if grep -q "$MANUAL_LV" <<< "$SINCE_EVENTS" && grep -q 'unmanaged-lv' <<< "$SINCE_EVENTS"; then
      DRIFT_FOUND=1
      break
    fi
  fi
  sleep 5
done
if [[ "$DRIFT_FOUND" == "1" ]]; then
  pass "控制器发出 unmanaged-lv 漂移告警（事件含 $MANUAL_LV）"
  info "事件证据: $(grep "$MANUAL_LV" <<< "$SINCE_EVENTS" | head -1)"
  # 只有在确实读到过事件时才谈「没有 missing-lv」；空集不能当作「未出现」。
  if grep -q 'missing-lv' <<< "$SINCE_EVENTS"; then
    fail "同时出现 missing-lv（PV→LV 名映射错误导致的双向误报）"
  else
    pass "未出现 missing-lv 双向误报"
  fi
else
  fail "注入后未出现 unmanaged-lv 告警（事件读取失败或三方对账未生效）"
  skip "事件为空，missing-lv 双向误报判据未覆盖（不得计 PASS）"
fi

if LOGS="$(controller_logs)"; then
  if grep -q 'drift-detector 告警' <<< "$LOGS" && grep -q "$MANUAL_LV" <<< "$LOGS"; then
    pass "控制器日志含 drift-detector 告警且 LV 名正确"
  else
    fail "控制器日志缺少对应告警（多副本日志已合并）"
  fi
else
  fail "读取控制器 Pod 列表失败（日志判据未覆盖）"
fi

# ---------------------------------------------------------------------------
# 3. 漂移消除：lvremove → 上报移除 → 告警计数在观察窗口内不再增长
# ---------------------------------------------------------------------------
if host_lvm lvremove -y "${VG}/${MANUAL_LV}" >/dev/null 2>&1; then
  MANUAL_CREATED=0
  pass "宿主手工 LV 已删除"
else
  fail "lvremove 失败（残留需人工清理）"
fi
if wait_for_lv_absent_in_report "$MANUAL_LV"; then
  pass "agent 上报清单已移除手工 LV"
else
  fail "agent 上报仍含手工 LV（陈旧清单会让告警永不停）"
fi

COUNT_BEFORE="$(event_count_sum)" || { fail "读取事件计数失败（判据未覆盖）"; finish; }
info "清理后观察 ${SETTLE_SECS}s（基线告警计数=$COUNT_BEFORE）"
sleep "$SETTLE_SECS"
COUNT_AFTER="$(event_count_sum)" || { fail "读取事件计数失败（判据未覆盖）"; finish; }
if [[ "$COUNT_BEFORE" == "$COUNT_AFTER" ]]; then
  pass "清理后告警计数不再增长（$COUNT_BEFORE → $COUNT_AFTER）"
else
  fail "清理后仍在告警（$COUNT_BEFORE → $COUNT_AFTER），疑似陈旧清单或未重新对账"
fi

# ---------------------------------------------------------------------------
# 4. 回收：删 Pod/PVC → PV 与宿主 LV 消失，终态无残留
# ---------------------------------------------------------------------------
"${KC[@]}" -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
"${KC[@]}" -n "$NS" delete pvc "$PVC" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
PVC_CREATED=0
if wait_for_lv_absent_in_report "$VOLUME_HANDLE"; then
  pass "PVC 回收后 agent 清单不再含业务 LV"
else
  fail "PVC 回收后 agent 清单仍含业务 LV"
fi
if HOST_NAMES="$(host_lv_names)"; then
  if grep -qxF "$MANUAL_LV" <<< "$HOST_NAMES"; then
    fail "宿主仍残留手工 LV $MANUAL_LV"
  else
    pass "宿主无残留手工 LV"
  fi
else
  fail "读取宿主 lvs 失败（残留判据未覆盖）"
fi
FINAL_TS=""
kc_get FINAL_TS get nodevg "$VG" -o jsonpath='{.status.lastLVReportTime}' || true
[[ -n "$FINAL_TS" ]] && pass "终态仍有 LV 上报（$FINAL_TS）" || fail "终态上报时间戳丢失"

cleanup
trap - EXIT
finish
