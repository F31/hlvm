#!/usr/bin/env bash
# pvc-supply-e2e.sh —— B 链路（TopoLVM CSI）端到端判据：PVC → PV → Pod 挂载 → LV 落 VG → 回收。
#
# 判据纪律（与 scripts/m15-integration.sh 一致）：
#   - 能力缺失一律 [skip] 并写明未覆盖，绝不记 PASS；
#   - 任一步失败即 [FAIL]，脚本最终以退出码表达结论；
#   - 每条判据都打印可复核的原始证据（PV 名、LV 名、节点亲和、写入校验和）。
#
# 依赖：WSL 侧 kubectl（指向真机集群）。宿主视角的 lvs 走 lvmd DaemonSet 的
# `nsenter -t 1`（hostPID 生效），等价于宿主命令，但不需要再开一条 SSH——
# WSL 到云主机的 22 端口会被 Clash TUN 的 fake-ip 间歇劫持，把判据建立在
# 集群内执行路径上更稳，而且这正是 lvmd 自己的视角。
#
# 多节点纪律（ADR-006 §13）：`kubectl exec ds/<ds>` 会在 DaemonSet 里**任取**一个 Pod，
# 双节点下有一半概率读到另一个节点的 VG，从而把「LV 不存在」当成事实，得出假结论。
# 故 read_lvs 必须按 NODE 定点取「该节点上 Ready 的 lvmd Pod」再 exec。
#
# LV 名不靠猜：TopoLVM 在 VG 里创建的 LV 名与 PV / CR 名并不相同（实测是另一个 UUID），
# 所以判据用「创建前基线 → 创建后新增」的集合差，再核对新增 LV 的尺寸。
#
# thin 判据（ADR-006 §14，2026-11-12 真机 A/B 实证）：只查「VG 内新增 1 颗 LV +
# 尺寸」会**假绿** —— lvmd device-class 缺 `type: thin` 时 TopoLVM 按 thick 供给，
# 同样会新增 1 颗同尺寸 LV，但容量只报 vg_free（2GiB）、thin-pool 完全不参与。
# 故必须再核对新增 LV 的 pool_lv 指向 thin-pool（实测 thin: Vwi-aotz-- / thick: -wi-a-----）。
#
# 用法：
#   bash docs/poc/scripts/pvc-supply-e2e.sh
#   NODE=10-60-166-202 VG=xxx SC=hlvm-b SIZE=2Gi bash ...
set -Eeuo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/hlvm-real.conf}"
NODE="${NODE:-10-60-153-100}"
SC="${SC:-hlvm-b}"
NS="${NS:-hlvm-pvc-poc}"
VG="${VG:-hlvm-lvmd-vg-153}"
SIZE="${SIZE:-1Gi}"
LVMD_NS="${LVMD_NS:-hlvm-system}"
LVMD_DS="${LVMD_DS:-hlvm-lvmd}"
THINPOOL="${THINPOOL:-thinpool}"
WAIT_SECS="${WAIT_SECS:-180}"

KC=(kubectl --kubeconfig "$KUBECONFIG")

# 读取 kubectl 字段：3 次重试，严格区分「命令执行失败」与「值确实为空」（ADR-006 §15）。
# 旧写法 `字段=$("${KC[@]}" ... 2>/dev/null || true)` 把偶发 API 失败（弱网 / API server
# 抖动）伪装成「对象不存在 / 标签缺失」，2026-11-12 verify 第二轮实测因此假红：
# 同一轮里 PVC 仍 Bound、PV 亲和仍落到 topology.topolvm.io/node，事后复查标签存在。
# 成功返回 0（值允许是空串，由调用方判「确实缺失」）；3 次全失败返回 1，
# 调用方必须报「读取失败」，绝不能报「不存在」。
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

fails=0
pass() { echo "[pass] $*"; }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
skip() { echo "[skip] $*"; }
info() { echo "       $*"; }

LVS_RC=1
LVS_OUT=""
LVMD_POD=""
# 定点取本节点上 Ready 且未在删除中的 lvmd Pod；取不到就明确失败，绝不退回 ds/ 任取。
lvmd_pod_on_node() {
  "${KC[@]}" -n "$LVMD_NS" get pods -l app.kubernetes.io/name=hlvm-lvmd \
    -o jsonpath='{range .items[?(@.spec.nodeName=="'"${NODE}"'")]}{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$2=="True" && $3=="" {print $1; exit}' || true
}

# 读宿主 lvs（经 lvmd Pod 的 nsenter），rc 与输出分开：执行失败绝不能当成
# 「LV 不存在」，否则回收判据会假绿（见 .workbuddy/memory 2026-11-11 的判据纪律）。
read_lvs() {
  local out rc attempt pod
  pod="$(lvmd_pod_on_node || true)"
  if [[ -z "$pod" ]]; then
    LVS_RC=1
    LVS_OUT="节点 ${NODE} 上没有 Ready 的 lvmd Pod（拒绝用 ds/${LVMD_DS} 任取）"
    return 1
  fi
  LVMD_POD="$pod"
  for attempt in 1 2 3; do
    out=$("${KC[@]}" -n "$LVMD_NS" exec "$pod" -c lvmd -- \
      nsenter -t 1 -m -u -i -n -p /sbin/lvm \
      lvs --noheadings -o lv_name,pool_lv,lv_size --units b "$VG" 2>&1) && rc=0 || rc=$?
    if ((rc == 0)); then LVS_RC=0; LVS_OUT="$out"; return 0; fi
    LVS_RC=$rc; LVS_OUT="$out"
    sleep 3
  done
  return 1
}

lv_names() { echo "$LVS_OUT" | awk 'NF {print $1}' | sort; }
lv_size_of() { echo "$LVS_OUT" | awk -v n="$1" '$1 == n {print $NF}'; }

# 读指定 LV 的 pool_lv（ADR-006 §14 的 thin 判据）。用显式 '|' 分隔符，避免
# pool_lv 为空时 awk 把尺寸列误当成 pool 列 —— 那正是上一版假绿的成因之一。
lv_pool_of() {
  local out rc name="$1"
  if [[ -z "${LVMD_POD:-}" ]]; then
    echo "<no-lvmd-pod>"; return 1
  fi
  out=$("${KC[@]}" -n "$LVMD_NS" exec "$LVMD_POD" -c lvmd -- \
    nsenter -t 1 -m -u -i -n -p /sbin/lvm \
    lvs --noheadings --separator '|' -o lv_name,pool_lv "$VG" 2>&1) && rc=0 || rc=$?
  if ((rc != 0)); then echo "<read-error>"; return 1; fi
  echo "$out" | awk -F'|' -v n="$name" '
    {gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2);
     if ($1 == n) {print $2; exit}}'
}

to_bytes() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1].strip()
units = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4,
         "K": 1000, "M": 1000**2, "G": 1000**3, "T": 1000**4}
for suf, mul in units.items():
    if s.endswith(suf):
        print(int(float(s[: -len(suf)]) * mul))
        raise SystemExit
print(int(float(s)))
PY
}

on_err() { echo "[FAIL] 命令失败：${BASH_COMMAND}（line $LINENO）"; fails=$((fails + 1)); }
trap on_err ERR

# ---------- 0. 前置条件 ----------
echo "== 0. 前置检查 =="
"${KC[@]}" get ns "$NS" >/dev/null 2>&1 || "${KC[@]}" create ns "$NS" >/dev/null
pass "namespace $NS 就绪"

if ! "${KC[@]}" get sc "$SC" >/dev/null 2>&1; then
  skip "StorageClass $SC 不存在，B 链路未部署"
  echo "结论：SKIP（未覆盖 PVC 供给）"
  exit 0
fi
pass "StorageClass $SC 存在"

if ! "${KC[@]}" get csidriver topolvm.io >/dev/null 2>&1; then
  skip "CSIDriver topolvm.io 不存在，CSI 未部署"
  echo "结论：SKIP（未覆盖 PVC 供给）"
  exit 0
fi
pass "CSIDriver topolvm.io 存在"

if kc_get DRIVERS get csinode "$NODE" -o jsonpath='{range .spec.drivers[*]}{.name}{"\n"}{end}'; then
  if [[ "$DRIVERS" == *topolvm.io* ]]; then
    pass "节点 $NODE 已注册 CSI 驱动 topolvm.io"
  else
    fail "节点 $NODE 的 CSINode 未注册 topolvm.io（已成功读取，实际：${DRIVERS:-空}）"
  fi
else
  fail "读取 CSINode $NODE 连续 3 次失败；判据未覆盖，不能把读不到判成未注册"
fi

if kc_get TOPO get node "$NODE" -o jsonpath='{.metadata.labels.topology\.topolvm\.io/node}'; then
  if [[ -n "$TOPO" ]]; then
    pass "节点拓扑标签 topology.topolvm.io/node=$TOPO"
  else
    fail "节点缺拓扑标签 topology.topolvm.io/node（已成功读取，值为空）"
  fi
else
  fail "读取节点 $NODE 拓扑标签连续 3 次失败；判据未覆盖，不能把读不到判成标签缺失"
fi

if kc_get NODE_JSON get node "$NODE" -o json; then
  CAP="$(printf '%s' "$NODE_JSON" | python3 -c '
import json,sys
a=json.load(sys.stdin)["metadata"].get("annotations",{})
print(a.get("capacity.topolvm.io/hlvm-lvmd",""))
' || true)"
else
  CAP=""
  fail "读取节点 $NODE 注解连续 3 次失败；容量判据未覆盖"
fi
if [[ -z "$CAP" || "$CAP" == "0" ]]; then
  fail "节点容量注解 capacity.topolvm.io/hlvm-lvmd 缺失或为 0（lvmd 未报容量）"
else
  pass "节点容量注解 capacity.topolvm.io/hlvm-lvmd=$CAP 字节（$((CAP / 1048576)) MiB）"
fi

# 基线：创建 PVC 之前 VG 里的 LV 集合（用于事后做集合差，不依赖 LV 命名规则）
BASELINE_OK=0
BASELINE=""
if read_lvs; then
  BASELINE_OK=1
  BASELINE=$(lv_names)
  info "VG 基线 LV：$(echo "$BASELINE" | tr '\n' ' ')"
else
  skip "基线读不到宿主 lvs（rc=$LVS_RC）：$(echo "$LVS_OUT" | tail -1)"
fi

# ---------- 1. 建 PVC + 消费 Pod ----------
echo "== 1. 创建 PVC 与消费 Pod =="
POD="pvc-consumer"
PVC="pvc-poc"
"${KC[@]}" -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
"${KC[@]}" -n "$NS" delete pvc "$PVC" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true

cat <<EOF | "${KC[@]}" apply -f - >/dev/null
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
pass "PVC/Pod 已提交（SC=$SC size=$SIZE node=$NODE）"

deadline=$((SECONDS + WAIT_SECS))
PHASE=""
while ((SECONDS < deadline)); do
  PHASE=$("${KC[@]}" -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$PHASE" == "Bound" ]] && break
  sleep 5
done
if [[ "$PHASE" == "Bound" ]]; then
  pass "PVC 已 Bound"
else
  fail "PVC 未在 ${WAIT_SECS}s 内 Bound（当前 phase=${PHASE:-空}）"
  "${KC[@]}" -n "$NS" describe pvc "$PVC" 2>&1 | tail -15 || true
  "${KC[@]}" -n "hlvm-system" get events --sort-by=.lastTimestamp 2>/dev/null | tail -8 || true
fi

if kc_get PV -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}'; then
  info "PV 名：${PV:-<空>}"
else
  PV=""
  fail "读取 PVC $PVC 的 volumeName 连续 3 次失败；PV 侧 3 条判据未覆盖"
fi
if [[ -n "$PV" ]]; then
  if kc_get SIZE_PV get pv "$PV" -o jsonpath='{.spec.capacity.storage}'; then
    info "PV 容量：${SIZE_PV:-?}"
  else
    fail "读取 PV $PV 容量连续 3 次失败；判据未覆盖"
  fi
  if kc_get AFF get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].key}={.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}'; then
    if [[ "$AFF" == topology.topolvm.io/node=* ]]; then
      pass "PV 节点亲和已落到拓扑键（$AFF）"
    else
      fail "PV 未见拓扑节点亲和（已成功读取，实际：${AFF:-空}）"
    fi
  else
    fail "读取 PV $PV 节点亲和连续 3 次失败；判据未覆盖"
  fi
  if kc_get DRIVER get pv "$PV" -o jsonpath='{.spec.csi.driver}'; then
    if [[ "$DRIVER" == "topolvm.io" ]]; then
      pass "PV csi.driver=topolvm.io"
    else
      fail "PV csi.driver=${DRIVER:-空}（已成功读取）"
    fi
  else
    fail "读取 PV $PV csi.driver 连续 3 次失败；判据未覆盖"
  fi
fi

# ---------- 2. Pod 挂载可用 ----------
echo "== 2. Pod 挂载可用 =="
deadline=$((SECONDS + WAIT_SECS))
ST=""
while ((SECONDS < deadline)); do
  ST=$("${KC[@]}" -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$ST" == "Running" ]] && break
  sleep 5
done
if [[ "$ST" == "Running" ]]; then
  pass "Pod Running"
  if "${KC[@]}" -n "$NS" exec "$POD" -c c -- sh -c 'dd if=/dev/urandom of=/data/blob bs=1M count=16 2>/dev/null && sync && sha256sum /data/blob | cut -d" " -f1' > /tmp/pvc_write_sum 2>/dev/null; then
    SUM=$(cat /tmp/pvc_write_sum)
    pass "容器内写入 16 MiB 成功（sha256=${SUM:0:16}…）"
    MOUNTFS=$("${KC[@]}" -n "$NS" exec "$POD" -c c -- sh -c 'grep " /data " /proc/mounts | cut -d" " -f3' 2>/dev/null || true)
    info "挂载类型：${MOUNTFS:-?}"
  else
    fail "容器内写入失败"
  fi
else
  fail "Pod 未 Running（当前 phase=${ST:-空}）"
  "${KC[@]}" -n "$NS" describe pod "$POD" 2>&1 | tail -20 || true
fi

# ---------- 3. LogicalVolume CR ----------
echo "== 3. LogicalVolume CR =="
LVCR=$("${KC[@]}" get logicalvolume -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i in d.get("items",[]):
    s=i.get("spec",{})
    print(i["metadata"]["name"], s.get("name",""), s.get("nodeName",""), s.get("deviceClass",""), s.get("size",""))
' || true)
if [[ -n "$LVCR" ]]; then
  echo "$LVCR" | sed 's/^/         /'
  pass "LogicalVolume CR 已创建（控制器→node 的 LV 编排生效）"
  info "注意：CR 的 spec.name 与 VG 里真实 LV 名不同，故 LV 判据用下面的集合差"
else
  skip "未见 LogicalVolume CR（若 LV 已直建则不算失败，但需人工确认路径）"
fi

# ---------- 4. 宿主 VG 里新增的那颗 LV ----------
echo "== 4. 宿主 VG 内 LV =="
LV_NEW=""
if ! read_lvs; then
  skip "经 lvmd nsenter 读取宿主 lvs 失败（rc=$LVS_RC）：$(echo "$LVS_OUT" | tail -1)"
  fail "无法从宿主确认 LV 是否落地（B 链路核心判据未覆盖）"
elif ((BASELINE_OK == 0)); then
  info "当前 LV："
  echo "$LVS_OUT" | sed 's/^/         /'
  fail "没有基线可比，无法判定新增 LV（前置检查已报基线读取失败）"
else
  info "当前 LV："
  echo "$LVS_OUT" | sed 's/^/         /'
  if ! echo "$LVS_OUT" | grep -q "thinpool"; then
    fail "宿主视角没看到基线 thinpool（VG/LV 状态异常）"
  fi
  NOW=$(lv_names)
  LV_NEW=$(comm -13 <(echo "$BASELINE") <(echo "$NOW") | sed '/^$/d')
  NEW_COUNT=$(echo "$LV_NEW" | grep -c . || true)
  if ((NEW_COUNT == 1)); then
    LV_NEW=$(echo "$LV_NEW" | head -1)
    pass "VG 内新增 1 颗 LV：$LV_NEW"
    WANT=$(to_bytes "$SIZE")
    GOT=$(lv_size_of "$LV_NEW")
    if [[ "$GOT" == "${WANT}B" ]]; then
      pass "新增 LV 尺寸与 PVC 请求一致（$GOT = $SIZE）"
    else
      fail "新增 LV 尺寸不符（实际 ${GOT:-?}，期望 ${WANT}B）"
    fi
    LV_POOL="$(lv_pool_of "$LV_NEW" || true)"
    if [[ "$LV_POOL" == "$THINPOOL" ]]; then
      pass "新增 LV 落在 thin-pool（pool_lv=$LV_POOL，确为 thin volume）"
    else
      fail "新增 LV 未落在 thin-pool：pool_lv='${LV_POOL:-<空>}'，期望 '$THINPOOL'；device-class 缺 type: thin 会让 TopoLVM 退化成 thick LV（ADR-006 §14）"
    fi
  elif ((NEW_COUNT == 0)); then
    fail "VG 内没有新增 LV（PV 已 Bound 却没落 LV）"
  else
    fail "VG 内新增了 $NEW_COUNT 颗 LV（期望 1 颗）：$(echo "$LV_NEW" | tr '\n' ' ')"
  fi
fi

# ---------- 5. 回收 ----------
echo "== 5. 删除并验证回收 =="
"${KC[@]}" -n "$NS" delete pod "$POD" --wait=true --timeout=120s >/dev/null 2>&1 || true
"${KC[@]}" -n "$NS" delete pvc "$PVC" --wait=true --timeout=180s >/dev/null 2>&1 || true

deadline=$((SECONDS + WAIT_SECS))
GONE=unknown
if [[ -z "$PV" ]]; then
  fail "上一步没有取到 PV 名，无法判定 PV 回收"
else
  while ((SECONDS < deadline)); do
    if ! "${KC[@]}" get pv "$PV" >/dev/null 2>&1; then GONE=yes; break; fi
    sleep 5
  done
  case "$GONE" in
    yes) pass "PV $PV 已删除" ;;
    *) fail "PV $PV 仍在（${WAIT_SECS}s 内未回收）" ;;
  esac
fi

if [[ -z "$LV_NEW" ]]; then
  skip "没有拿到新增 LV 名，回收只能用 PV 判据（已在上方给出）"
else
  deadline=$((SECONDS + WAIT_SECS))
  LVGONE=unknown
  while ((SECONDS < deadline)); do
    if read_lvs; then
      if echo "$LVS_OUT" | awk '{print $1}' | grep -qx -- "$LV_NEW"; then
        LVGONE=no
      else
        LVGONE=yes
        break
      fi
    fi
    sleep 5
  done
  case "$LVGONE" in
    yes) pass "VG 内 LV $LV_NEW 已回收" ;;
    no) fail "VG 内 LV $LV_NEW 仍残留" ;;
    *) fail "回收判据读不到宿主 lvs（rc=$LVS_RC，经 lvmd nsenter），不做无据判定" ;;
  esac
fi

# ---------- 汇总 ----------
echo "== 汇总 =="
if ((fails == 0)); then
  echo "结论：PASS（B 链路端到端供给闭环）"
  exit 0
else
  echo "结论：FAIL（$fails 项判据不通过）"
  exit 1
fi
