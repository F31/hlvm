#!/usr/bin/env bash
# deploy-agent-real.sh —— 真机部署常驻 hlvm-storage-agent（POC 多节点）
#
# 为什么需要独立脚本（ADR-006 §12，2026-11-12 真机发现）：
#   手工 seed NodeVG 时控制面会下发一条 vg-<name>-vgcreate StorageTask。真机此前
#   没有常驻 agent，这条任务从未被消费：status 缺失、ttl 为空、无 approvedBy。
#   一旦 agent 上线，run_task_reconciler 每 10s 轮询就会立刻取走它。本例因缺
#   approvedBy 被 executor::plan_execution 判 Rejected（不会真写盘），但仍会回写
#   Failed 并污染 NodeVG 状态；换一条带审批的任务，就可能真的把承载 B 链路的 PV
#   当成空闲盘执行 vgcreate。故部署前必须**显式扫描并处理孤儿任务**，默认 FAIL，
#   绝不静默删除——这是「前提不成立就不做无据判定」的判据纪律。
#
# 本脚本做四件事：
#   1. 前置：节点 Ready、lvmd DS 在位、VG 只读可见、NodeVG.vgExists=true；
#      扫描本节点所有非终态 StorageTask（孤儿），有则 FAIL（PURGE_ORPHAN_TASKS=1
#      才显式删除，删除后观察 RECHECK_WAIT 秒确认控制器不重建）。
#   2. apply 常驻 DaemonSet：hostPID + privileged + /host,/dev,/run/lock/lvm
#      挂载 + NODE_NAME Downward API + HLVM_HOST_WRAPPER=nsenter ...，
#      nodeSelector 用 hlvm.io/lvmd=true 标签（覆盖全部已建 VG 的 worker）。
#      脚本按 NODE 逐节点验收，扩容脚本对每个节点调用一次（DS apply 幂等）。
#   3. 判据：目标节点上真有 Ready 的 agent Pod（不用 rollout status，它会假绿）；
#      DS env 与推荐 wrapper 逐字一致；调用 host-wrapper-gate.sh MODE=pod 做真实写；
#      agent 日志含节点名解析与回写循环、无 discovery 失败、RESTARTS=0。
#      宿主 VG 只读一律经**本节点** lvmd Pod，绝不 `exec ds/...` 任取（§13 判据纪律）。
#   4. 汇总：exit 0 + 无 [FAIL] + SUMMARY 行。能力缺失 SKIP 且不计 PASS。
#
# 用法：
#   KUBECONFIG=~/.kube/hlvm-real.conf bash docs/poc/scripts/deploy-agent-real.sh
#   PURGE_ORPHAN_TASKS=1 ... bash deploy-agent-real.sh   # 显式删除孤儿任务后部署
#   bash deploy-agent-real.sh --cleanup                  # 撤掉常驻 DS 并等待 Pod 消失
#   NODE=10-60-153-100 VG=hlvm-lvmd-vg-153 AGENT_IMAGE=... bash ...
#   NODE=10-60-166-202 VG=hlvm-lvmd-vg-202 AGENT_IMAGE=... bash ...   # 第二节点
#   NODE_LABEL_KEY/NODE_LABEL_VALUE：默认 hlvm.io/lvmd / true，与 lvmd、CSI node 共用。
#
# 依赖：kubectl / python3。全部走 kubectl，**不用 SSH**：WSL 到云主机 22 端口
# 会被 Clash TUN 的 fake-ip 劫持，把判据架在那条链路上会出现读不到的假绿。
# 例外：expand-lvmd-nodes.sh 里的一次性建 VG 写操作走 SSH（判据读仍全走 kubectl）。
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
GATE="${SCRIPT_DIR}/host-wrapper-gate.sh"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/hlvm-real.conf}"
NODE="${NODE:-10-60-153-100}"
VG="${VG:-hlvm-lvmd-vg-153}"
NODE_VG="${NODE_VG:-${VG}}"
LVMD_NS="${LVMD_NS:-hlvm-system}"
LVMD_DS="${LVMD_DS:-hlvm-lvmd}"
AGENT_NS="${AGENT_NS:-hlvm-system}"
DS_NAME="${DS_NAME:-hlvm-storage-agent}"
AGENT_IMAGE="${AGENT_IMAGE:-ghcr.io/f31/hlvm/storage-agent:sha-52bda85}"
NODE_LABEL_KEY="${NODE_LABEL_KEY:-hlvm.io/lvmd}"
NODE_LABEL_VALUE="${NODE_LABEL_VALUE:-true}"
WRAPPER="${WRAPPER:-nsenter -t 1 -m -u -i -n -p --}"
PURGE_ORPHAN_TASKS="${PURGE_ORPHAN_TASKS:-0}"
RECHECK_WAIT="${RECHECK_WAIT:-35}"
READY_WAIT="${READY_WAIT:-180}"
LOG_TAIL="${LOG_TAIL:-120}"

K=(kubectl --kubeconfig "$KUBECONFIG")

# 多节点下 `kubectl exec ds/<ds>` 会任取一个 Pod；宿主 lvs/vgs 必须定点到 NODE 上的
# lvmd Pod，否则读到另一节点的 VG 就会把「读不到」误当事实（ADR-006 §13 判据纪律）。
lvmd_pod_on_node() {
  "${K[@]}" -n "$LVMD_NS" get pods -l app.kubernetes.io/name=hlvm-lvmd \
    -o jsonpath='{range .items[?(@.spec.nodeName=="'"${NODE}"'")]}{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$2=="True" && $3=="" {print $1; exit}' || true
}

PASS=0
FAIL=0
SKIP=0

trap 'echo "[error] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR
pass() { echo "    [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "    [FAIL] $*"; FAIL=$((FAIL + 1)); }
skip() { echo "    [SKIP] $*（不计 PASS）"; SKIP=$((SKIP + 1)); }
finish() {
  echo "SUMMARY: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP} RESULT=$(if ((FAIL > 0)); then echo FAIL; elif ((SKIP > 0)); then echo PARTIAL; else echo PASS; fi)"
  ((FAIL == 0)) || exit 1
  exit 0
}

# ---------------------------------------------------------------------------
# --cleanup：撤掉常驻 DS，等待目标节点上 Pod 真正消失（--wait=true 不适用 DS Pod）
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" ]]; then
  echo "== cleanup: 删除 ${AGENT_NS}/${DS_NAME} =="
  "${K[@]}" -n "$AGENT_NS" delete ds "$DS_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    N="$("${K[@]}" -n "$AGENT_NS" get pods -l app.kubernetes.io/component=storage-agent \
      -o jsonpath='{range .items[?(@.spec.nodeName=="'"${NODE}"'")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | wc -l || true)"
    [[ "${N:-0}" == "0" ]] && break
    sleep 2
  done
  echo "    remaining_pods_on_${NODE}=${N:-?}"
  echo "SUMMARY: cleanup done (RC=$(if [[ "${N:-0}" == "0" ]]; then echo 0; else echo 1; fi))"
  [[ "${N:-0}" == "0" ]] || exit 1
  exit 0
fi

echo "== 0. 执行前提 =="
echo "    kubeconfig=$KUBECONFIG node=$NODE vg=$VG image=$AGENT_IMAGE"
echo "    wrapper=$WRAPPER"
[[ -f "$KUBECONFIG" ]] || { fail "kubeconfig 不存在：$KUBECONFIG"; finish; }
[[ -f "$GATE" ]] || { fail "门禁脚本不存在：$GATE"; finish; }
command -v python3 >/dev/null 2>&1 || { fail "缺少 python3（解析 CR 状态用）"; finish; }

NODE_READY="$("${K[@]}" get node "$NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [[ "$NODE_READY" == "True" ]]; then pass "节点 $NODE Ready"; else fail "节点 $NODE 非 Ready（实际 ${NODE_READY:-空}）"; finish; fi

LVMD_READY="$("${K[@]}" -n "$LVMD_NS" get ds "$LVMD_DS" \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
if [[ "${LVMD_READY:-0}" -ge 1 ]]; then pass "lvmd DS 在位（numberReady=$LVMD_READY）"; else fail "lvmd DS 不在位"; finish; fi

AGENT_SA="$("${K[@]}" -n "$AGENT_NS" get sa hlvm-agent -o name 2>/dev/null || true)"
if [[ -n "$AGENT_SA" ]]; then pass "ServiceAccount hlvm-agent 存在"; else fail "缺 ServiceAccount hlvm-agent（Pod 会 Pending）"; finish; fi

# 宿主视图读 VG：读不到一律 FAIL，不能把「读不到」当成「没有」。
LVMD_POD="$(lvmd_pod_on_node || true)"
if [[ -z "$LVMD_POD" ]]; then
  fail "节点 $NODE 上没有 Ready 的 lvmd Pod（拒绝用 ds/$LVMD_DS 任取）"; finish
fi
echo "    lvmd_pod=${LVMD_POD} node=${NODE}"
VGS_OUT="$("${K[@]}" -n "$LVMD_NS" exec "$LVMD_POD" -c lvmd -- \
  nsenter -t 1 -m -u -i -n -p -- lvm vgs --noheadings -o vg_name,vg_free --units b "$VG" 2>&1 || true)"
echo "    HOST_VGS=${VGS_OUT:-<empty>}"
if printf '%s' "$VGS_OUT" | grep -qw "$VG"; then pass "宿主 lvm 可见 $VG"; else fail "宿主 lvm 读不到 $VG"; finish; fi

VG_EXISTS="$("${K[@]}" get nodevg "$NODE_VG" -o jsonpath='{.status.vgExists}' 2>/dev/null || true)"
if [[ "$VG_EXISTS" == "true" ]]; then
  pass "NodeVG $NODE_VG status.vgExists=true（删除孤儿 Task 后不会被重新下发）"
else
  fail "NodeVG $NODE_VG vgExists=${VG_EXISTS:-空}；删 Task 可能被控制器重建，拒绝继续"
  finish
fi

# ---------------------------------------------------------------------------
# 1. 孤儿 StorageTask 扫描（本轮核心安全前置）
# ---------------------------------------------------------------------------
echo "== 1. 扫描本节点非终态 StorageTask =="
TASKS_JSON="$("${K[@]}" get storagetasks -o json 2>/dev/null || true)"
ORPHANS="$(printf '%s' "$TASKS_JSON" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("PARSE_ERROR"); sys.exit(0)
node=sys.argv[1]
out=[]
for t in d.get("items",[]):
    s=t.get("spec",{}); st=t.get("status",{}) or {}
    if s.get("nodeName")!=node: continue
    phase=st.get("phase")
    if phase in ("Succeeded","Failed"): continue
    out.append("%s|type=%s|phase=%s|ttl=%s|approvedBy=%s|disks=%s" % (
        t["metadata"]["name"], s.get("type",""), phase or "<absent>",
        s.get("ttl","") or "<empty>", s.get("approvedBy","") or "<absent>",
        ",".join(s.get("disks",[])) or "<none>"))
print("\n".join(out))
' "$NODE" 2>/dev/null || true)"
if [[ -z "${TASKS_JSON}" ]]; then
  fail "无法列出 StorageTask（kubectl 读不到，不做无据判定）"; finish
elif printf '%s' "$ORPHANS" | grep -q 'PARSE_ERROR'; then
  fail "StorageTask 列表解析失败"; finish
elif [[ -z "$ORPHANS" ]]; then
  pass "本节点无非终态 StorageTask"
else
  echo "    发现孤儿任务："
  printf '%s\n' "$ORPHANS" | sed 's/^/      /'
  ORPHAN_N="$(printf '%s\n' "$ORPHANS" | wc -l || true)"
  if [[ "$PURGE_ORPHAN_TASKS" != "1" ]]; then
    fail "存在 ${ORPHAN_N:-?} 条非终态任务；agent 上线会立即消费。请人工确认后设 PURGE_ORPHAN_TASKS=1 重跑"
    finish
  fi
  info_purge=0
  while IFS='|' read -r tname _rest; do
    [[ -n "$tname" ]] || continue
    "${K[@]}" delete storagetask "$tname" --wait=true --timeout=30s >/dev/null 2>&1 || true
    echo "      deleted: $tname"
    info_purge=$((info_purge + 1))
  done <<< "$ORPHANS"
  echo "    已显式删除 ${info_purge} 条，观察 ${RECHECK_WAIT}s 是否被控制器重建"
  sleep "$RECHECK_WAIT"
  REMAIN="$("${K[@]}" get storagetasks -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); node=sys.argv[1]; n=0
for t in d.get("items",[]):
    s=t.get("spec",{}); st=t.get("status",{}) or {}
    if s.get("nodeName")==node and st.get("phase") not in ("Succeeded","Failed"): n+=1
print(n)
' "$NODE" 2>/dev/null || true)"
  if [[ "${REMAIN:-1}" == "0" ]]; then pass "孤儿任务删除后未被重建（观察 ${RECHECK_WAIT}s）"; else fail "孤儿任务被重建（remain=${REMAIN:-?}）"; finish; fi
fi

# ---------------------------------------------------------------------------
# 2. apply 常驻 DaemonSet（单节点 POC 边界）
# ---------------------------------------------------------------------------
echo "== 2. 部署常驻 agent DaemonSet =="
# 未加引号 heredoc 用于变量展开；**注释里禁用反引号**，否则会触发命令替换。
cat <<YAML | "${K[@]}" apply -f - >/dev/null || { fail "apply DaemonSet 失败"; finish; }
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${DS_NAME}
  namespace: ${AGENT_NS}
  labels:
    app.kubernetes.io/name: hlvm
    app.kubernetes.io/component: storage-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: hlvm
      app.kubernetes.io/component: storage-agent
  template:
    metadata:
      labels:
        app.kubernetes.io/name: hlvm
        app.kubernetes.io/component: storage-agent
    spec:
      serviceAccountName: hlvm-agent
      hostPID: true
      nodeSelector:
        ${NODE_LABEL_KEY}: "${NODE_LABEL_VALUE}"
      containers:
        - name: agent
          image: ${AGENT_IMAGE}
          imagePullPolicy: IfNotPresent
          args: ["--mode=agent"]
          securityContext:
            privileged: true
            readOnlyRootFilesystem: false
            allowPrivilegeEscalation: true
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
            - name: HLVM_NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
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
pass "DaemonSet 已 apply（nodeSelector=${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}，本次验收节点 $NODE）"

# 等 DS 收敛（ADR-006 §13 实测）：apply 改了 pod template（hostname → 标签选择器）会触发
# 滚动更新，旧 Pod 随后被替换。若此时拿旧 Pod 名去 exec，会报
# "cannot exec into a container in a completed pod" —— 门禁失败但并非产品缺陷。
# 故先等 generation/updated/ready 收敛，再定点取 Pod，且门禁前重新取一次。
wait_ds_converged() {
  local gen obs desired updated ready
  for i in $(seq 1 $((READY_WAIT / 3))); do
    gen="$("${K[@]}" -n "$AGENT_NS" get ds "$DS_NAME" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)"
    obs="$("${K[@]}" -n "$AGENT_NS" get ds "$DS_NAME" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)"
    desired="$("${K[@]}" -n "$AGENT_NS" get ds "$DS_NAME" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
    updated="$("${K[@]}" -n "$AGENT_NS" get ds "$DS_NAME" -o jsonpath='{.status.updatedNumberScheduled}' 2>/dev/null || true)"
    ready="$("${K[@]}" -n "$AGENT_NS" get ds "$DS_NAME" -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
    if [[ -n "$gen" && "$gen" == "$obs" && "${desired:-0}" -gt 0 \
          && "${updated:-0}" == "$desired" && "${ready:-0}" == "$desired" ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}
if wait_ds_converged; then
  pass "DS 滚动更新已收敛（observedGeneration / updatedNumberScheduled / numberReady 一致）"
else
  fail "DS 在 ${READY_WAIT}s 内未收敛，拒绝用一个可能即将被替换的 Pod 跑门禁"
  finish
fi

agent_pod_on_node() {
  "${K[@]}" -n "$AGENT_NS" get pods -l app.kubernetes.io/component=storage-agent \
    -o jsonpath='{range .items[?(@.spec.nodeName=="'"${NODE}"'")]}{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$2=="True" && $3=="" {print $1; exit}' || true
}

# 就绪判据：目标节点上存在 Ready 且未在删除中的 Pod，绝不信 rollout status。
AGENT_POD=""
for i in $(seq 1 $((READY_WAIT / 3))); do
  AGENT_POD="$(agent_pod_on_node || true)"
  [[ -n "$AGENT_POD" ]] && break
  sleep 3
done
if [[ -n "$AGENT_POD" ]]; then pass "目标节点存在 Ready 的 agent Pod：$AGENT_POD"; else fail "${READY_WAIT}s 内目标节点无 Ready agent Pod"; finish; fi

DS_ENV="$("${K[@]}" -n "$AGENT_NS" get ds "$DS_NAME" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HLVM_HOST_WRAPPER")].value}' 2>/dev/null || true)"
if [[ "$DS_ENV" == "$WRAPPER" ]]; then pass "DS env wrapper 与推荐值逐字一致"; else fail "DS env wrapper 不符（实际 ${DS_ENV:-空}）"; fi
HOSTPID="$("${K[@]}" -n "$AGENT_NS" get ds "$DS_NAME" -o jsonpath='{.spec.template.spec.hostPID}' 2>/dev/null || true)"
if [[ "$HOSTPID" == "true" ]]; then pass "hostPID=true（nsenter -t 1 前提）"; else fail "hostPID=${HOSTPID:-空}"; fi

# ---------------------------------------------------------------------------
# 3. MODE=pod 门禁 + 主循环证据
# ---------------------------------------------------------------------------
echo "== 3. MODE=pod 真实写门禁（复用 host-wrapper-gate.sh）=="
# 门禁前重新定点：即使前面已收敛，Pod 仍可能因探针/节点事件被重建。
AGENT_POD_NOW="$(agent_pod_on_node || true)"
if [[ -z "$AGENT_POD_NOW" ]]; then
  fail "门禁前目标节点 $NODE 上无 Ready 且未在删除中的 agent Pod"
  finish
fi
if [[ "$AGENT_POD_NOW" != "$AGENT_POD" ]]; then
  info "门禁前重新定点 Pod：$AGENT_POD -> $AGENT_POD_NOW"
  AGENT_POD="$AGENT_POD_NOW"
fi
GATE_OUT="$(KUBECONFIG="$KUBECONFIG" MODE=pod POD_NS="$AGENT_NS" POD_NAME="$AGENT_POD" \
  VG="$VG" bash "$GATE" 2>&1 || true)"
printf '%s\n' "$GATE_OUT" | sed 's/^/       /'
GATE_RESULT="$(printf '%s\n' "$GATE_OUT" | sed -n 's/^GATE_RESULT=\([A-Z]*\).*/\1/p' | head -1 || true)"
case "${GATE_RESULT:-}" in
  PASS) pass "agent 真实 Pod 完成 lvcreate/lvs/lvremove（§5.3 写路径）" ;;
  SKIP) skip "门禁能力缺失（无可写 VG 或无宿主 timeout）" ;;
  *)    fail "门禁未通过（GATE_RESULT=${GATE_RESULT:-空}）" ;;
esac

echo "== 4. agent 主循环证据 =="
LOGS="$("${K[@]}" -n "$AGENT_NS" logs "$AGENT_POD" -c agent --tail="$LOG_TAIL" 2>&1 \
  | sed -r 's/\x1B\[[0-9;]*[mK]//g' || true)"
if printf '%s' "$LOGS" | grep -q "node=\"${NODE}\""; then pass "日志含节点名 ${NODE}（Downward API 生效）"; else fail "日志未见节点名解析"; fi
if printf '%s' "$LOGS" | grep -q "进入 StorageTask 回写协调循环"; then pass "已进入 StorageTask 回写协调循环（kube 客户端/RBAC 生效）"; else fail "未进入回写循环"; fi
if printf '%s' "$LOGS" | grep -q "discovery 失败"; then fail "日志含 discovery 失败"; else pass "磁盘发现无报错"; fi
RESTARTS="$("${K[@]}" -n "$AGENT_NS" get pod "$AGENT_POD" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
if [[ "${RESTARTS:-1}" == "0" ]]; then pass "agent Pod RESTARTS=0"; else fail "agent Pod RESTARTS=${RESTARTS:-空}"; fi

# 宿主 VG 未被门禁或主循环改动：只剩原有 LV，无 hlvm-gate-* 残留。
# 重新定点取 Pod：滚动更新后 Pod 名可能已变，不能复用前置阶段拿到的名字。
LVMD_POD="$(lvmd_pod_on_node || true)"
if [[ -z "$LVMD_POD" ]]; then
  fail "节点 $NODE 上没有 Ready 的 lvmd Pod，无法核对门禁残留"; finish
fi
LVS_AFTER="$("${K[@]}" -n "$LVMD_NS" exec "$LVMD_POD" -c lvmd -- \
  nsenter -t 1 -m -u -i -n -p -- lvm lvs --noheadings -o lv_name "$VG" 2>&1 || true)"
echo "    HOST_LVS_AFTER=$(printf '%s' "$LVS_AFTER" | tr '\n' ' ')"
if printf '%s' "$LVS_AFTER" | grep -q 'hlvm-gate-'; then fail "宿主残留门禁测试 LV"; else pass "宿主无门禁测试 LV 残留"; fi

finish
