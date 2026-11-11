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
# LV 名不靠猜：TopoLVM 在 VG 里创建的 LV 名与 PV / CR 名并不相同（实测是另一个 UUID），
# 所以判据用「创建前基线 → 创建后新增」的集合差，再核对新增 LV 的尺寸。
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
WAIT_SECS="${WAIT_SECS:-180}"

KC=(kubectl --kubeconfig "$KUBECONFIG")

fails=0
pass() { echo "[pass] $*"; }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
skip() { echo "[skip] $*"; }
info() { echo "       $*"; }

LVS_RC=1
LVS_OUT=""
# 读宿主 lvs（经 lvmd Pod 的 nsenter），rc 与输出分开：执行失败绝不能当成
# 「LV 不存在」，否则回收判据会假绿（见 .workbuddy/memory 2026-11-11 的判据纪律）。
read_lvs() {
  local out rc attempt
  for attempt in 1 2 3; do
    out=$("${KC[@]}" -n "$LVMD_NS" exec "ds/$LVMD_DS" -- \
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

DRIVERS=$("${KC[@]}" get csinode "$NODE" -o jsonpath='{range .spec.drivers[*]}{.name}{"\n"}{end}' 2>/dev/null || true)
if [[ "$DRIVERS" == *topolvm.io* ]]; then
  pass "节点 $NODE 已注册 CSI 驱动 topolvm.io"
else
  fail "节点 $NODE 的 CSINode 未注册 topolvm.io（实际：${DRIVERS:-空}）"
fi

TOPO=$("${KC[@]}" get node "$NODE" -o jsonpath='{.metadata.labels.topology\.topolvm\.io/node}' 2>/dev/null || true)
if [[ -n "$TOPO" ]]; then
  pass "节点拓扑标签 topology.topolvm.io/node=$TOPO"
else
  fail "节点缺拓扑标签 topology.topolvm.io/node"
fi

CAP=$("${KC[@]}" get node "$NODE" -o json 2>/dev/null | python3 -c '
import json,sys
a=json.load(sys.stdin)["metadata"].get("annotations",{})
print(a.get("capacity.topolvm.io/hlvm-lvmd",""))
' || true)
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

PV=$("${KC[@]}" -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
info "PV 名：${PV:-<空>}"
if [[ -n "$PV" ]]; then
  SIZE_PV=$("${KC[@]}" get pv "$PV" -o jsonpath='{.spec.capacity.storage}' 2>/dev/null || true)
  info "PV 容量：${SIZE_PV:-?}"
  AFF=$("${KC[@]}" get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].key}={.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null || true)
  if [[ "$AFF" == topology.topolvm.io/node=* ]]; then
    pass "PV 节点亲和已落到拓扑键（$AFF）"
  else
    fail "PV 未见拓扑节点亲和（实际：${AFF:-空}）"
  fi
  DRIVER=$("${KC[@]}" get pv "$PV" -o jsonpath='{.spec.csi.driver}' 2>/dev/null || true)
  if [[ "$DRIVER" == "topolvm.io" ]]; then
    pass "PV csi.driver=topolvm.io"
  else
    fail "PV csi.driver=${DRIVER:-空}"
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
