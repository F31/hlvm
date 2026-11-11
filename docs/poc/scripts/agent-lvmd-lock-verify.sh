#!/usr/bin/env bash
# agent-lvmd-lock-verify.sh —— agent × lvmd 「进程级锁同源」判据（ADR-006 §1.3 / 设计 §5.3）
#
# 补的是 ADR-006 §10 明确留下的最后一公里：lvmd-lock-verify.sh 只证了「宿主 lvm 视图」
# 同源同锁，agent 真实调用栈没有参与。本脚本让 **agent 镜像 + agent 的 env + agent 的挂载**
# 与 lvmd 并发写同一个 VG，把结论推到 agent 的 lvm 调用栈这一层。
#
# 关键设计：
#   - 不部署常驻 agent DaemonSet（真机无常驻 agent；agent 是唯一 PV/VG 写路径，起主循环会
#     触发 reconcile，对本判据是无关变量且有副作用）。改为一次性 probe Pod：
#       同镜像 + 按 WRAPPER 注入 HLVM_HOST_WRAPPER + /host,/dev,/run/lock/lvm 挂载
#     —— 与 agent/config/daemonset-agent.yaml 的挂载/env 约定完全一致。
#   - 不硬编码调用栈：从 Pod 内读 HLVM_HOST_WRAPPER，按 agent lvm::lvm_argv_with
#     的 split_whitespace 语义现场拼命令（前缀 + lvm + 参数），复现真实调用栈。
#     唯一偏差：lvm_json 会在读路径末尾追加 --reportformat json，本脚本的 lvcreate 写路径
#     不加（lvcreate 无需 JSON 报表）；该 flag 不改变二进制与锁的选择，不影响锁同源结论。
#   - 全部走 kubectl exec（agent Pod 的 wrapper、lvmd Pod 的 nsenter）。**不用 SSH**：
#     WSL→云主机 22 端口会被 Clash TUN 的 fake-ip 劫持（Connection closed by 198.18.x.x），
#     把判据架在那条链路上会出现「读不到 ≠ 不存在」的假绿。
#   - agent 基础镜像 kindest/node 不含 lvm 二进制 ⇒ 「裸 lvm 失败、wrapper 构造的 lvm 成功」
#     本身就是 wrapper 生效的强证据。
#
# 真机结论（2026-11-11，详见 ADR-006 §11）：
#   - WRAPPER='chroot /host'（旧配置，2026-11-12 已废弃）：静态身份判据全 PASS，
#     但**单路写 LV 即超时**（rc=124、无输出，持 VG flock 卡在 __do_semtimedop）。
#     chroot 只切文件系统根、不切 IPC 命名空间，lvm/libdm 的 udev 同步用 SysV 信号量
#     ⇒ 跨 NS 失效。4.0 预检会立刻 FAIL 并给出诊断，绝不让 10 路并发把 VG 锁死。
#     用这个 WRAPPER 复跑是**负向对照**，预期 FAIL，不是脚本 bug。
#   - WRAPPER='nsenter -t 1 -m -u -i -n -p --'：单路写 LV rc=0、10/10 并发 PASS；
#     修法已落地为 M15 灰度默认值与本脚本默认值（ADR-006 §11.6）。
#
# 判据纪律（与 m15-integration.sh / pvc-supply-e2e.sh 一致）：
#   - 能力缺失一律 [skip] 且**不计 PASS**；环境不具备时结论为 SKIP，绝不写 PASS；
#   - 读不到宿主 lvs 一律 [FAIL]，不做「读不到 = 没有」的无据判定；
#   - 每条判据打印原始证据（dev/inode、sha256、版本号、逐路 rc、lvs 计数）；
#   - 结论以「exit 0 + 无 [FAIL] + 汇总行」为准，不靠 PASS 计数。
#
# 用法：
#   bash docs/poc/scripts/agent-lvmd-lock-verify.sh
#   NODE=10-60-153-100 VG=hlvm-lvmd-vg-153 AGENT_IMAGE=... bash ...
#   WRAPPER='chroot /host' bash ...   # 负向对照：预期 4.0 预检 FAIL
set -Eeuo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/hlvm-real.conf}"
NODE="${NODE:-10-60-153-100}"
VG="${VG:-hlvm-lvmd-vg-153}"
LVMD_NS="${LVMD_NS:-hlvm-system}"
LVMD_DS="${LVMD_DS:-hlvm-lvmd}"
PROBE_NS="${PROBE_NS:-hlvm-pvc-poc}"
PROBE_POD="${PROBE_POD:-hlvm-lock-probe}"
AGENT_IMAGE="${AGENT_IMAGE:-ghcr.io/f31/hlvm/storage-agent:sha-52bda85}"
# 默认验收修法后的配置（与 M15 灰度注入值一致）；负向对照用 WRAPPER='chroot /host'
# 复跑，预期 4.0 预检 FAIL（ADR-006 §11）。
WRAPPER="${WRAPPER:-nsenter -t 1 -m -u -i -n -p --}"
N="${N:-5}"
WAIT_SECS="${WAIT_SECS:-120}"

KC=(kubectl --kubeconfig "$KUBECONFIG")

fails=0
skips=0
pass() { echo "[pass] $*"; }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
skip() { echo "[skip] $*"; skips=$((skips + 1)); }
info() { echo "       $*"; }
on_err() { echo "[FAIL] 命令失败：${BASH_COMMAND}（line $LINENO）"; fails=$((fails + 1)); }
trap on_err ERR

TMPDIR_LOCAL=$(mktemp -d)
cleanup_local() { rm -rf "$TMPDIR_LOCAL"; }

# 清理型 delete：显式调用后再 trap - EXIT，避免 EXIT trap 里局部变量已离开作用域
# （.workbuddy/memory 2026-11-11：uncordon 曾被静默跳过）。
cleanup_probe() {
  "${KC[@]}" -n "$PROBE_NS" delete pod "$PROBE_POD" --ignore-not-found \
    --wait=true --timeout=90s >/dev/null 2>&1 || true
}
finish() {
  cleanup_probe
  cleanup_local
  trap - EXIT
}
trap finish EXIT

# agent Pod 内执行一段脚本（stdin 喂 sh -s，避开多层 SSH/kubectl 引号）
agent_exec() { "${KC[@]}" -n "$PROBE_NS" exec -i "pod/$PROBE_POD" -- sh -s; }
# lvmd Pod 内经 nsenter 落到宿主 PID1 命名空间执行 —— 与 lvmd 自己的 lvm 子进程同视角。
# 必须指向前置阶段按 NODE 定点取到的 LVMD_POD：多节点 DS 下 `exec ds/...` 会任取一个 Pod，
# 可能落到另一节点，读不到本节点 VG 而把「锁冲突」判成别的东西（ADR-006 §13）。
lvmd_host() { "${KC[@]}" -n "$LVMD_NS" exec -i "pod/$LVMD_POD" -c lvmd -- \
  nsenter -t 1 -m -u -i -n -p -- sh -s; }

echo "== 0. 前置检查 =="
"${KC[@]}" get ns "$PROBE_NS" >/dev/null 2>&1 || "${KC[@]}" create ns "$PROBE_NS" >/dev/null
pass "namespace $PROBE_NS 就绪"

if ! "${KC[@]}" -n "$LVMD_NS" get ds "$LVMD_DS" >/dev/null 2>&1; then
  skip "lvmd DaemonSet $LVMD_DS 不存在（B 链路未部署）"
  echo "结论：SKIP（未覆盖 agent×lvmd 锁同源）"
  exit 0
fi
# DS 的 READY 列是状态缓存，重启窗口会假绿；必须确认目标节点上存在 Ready 的 Pod。
LVMD_POD=$("${KC[@]}" -n "$LVMD_NS" get pods -l app.kubernetes.io/name="$LVMD_DS" \
  -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
node=sys.argv[1]
for p in d.get("items",[]):
    if p.get("spec",{}).get("nodeName")!=node: continue
    cs=p.get("status",{}).get("containerStatuses",[])
    if cs and all(c.get("ready") for c in cs): print(p["metadata"]["name"])
' "$NODE" 2>/dev/null || true)
if [[ -z "$LVMD_POD" ]]; then
  skip "节点 $NODE 上没有 Ready 的 lvmd Pod（DS READY 列不可作判据）"
  echo "结论：SKIP（未覆盖 agent×lvmd 锁同源）"
  exit 0
fi
pass "节点 $NODE 上 lvmd Pod $LVMD_POD 全部容器 Ready"

# 宿主 VG 必须真实存在且可读；读不到就不往下做（否则并发失败会被误读成「锁冲突」）。
VG_SEEN=$(printf 'lvm vgs --noheadings -o vg_name %s\n' "$VG" | lvmd_host 2>/dev/null || true)
if [[ "$VG_SEEN" != *"$VG"* ]]; then
  skip "宿主读不到 VG $VG（实际输出：${VG_SEEN:-空}）；无法建立并发前提"
  echo "结论：SKIP（未覆盖 agent×lvmd 锁同源）"
  exit 0
fi
pass "宿主 VG 可读：$VG"

echo
echo "== 1. 起 agent 调用栈复现 Pod =="
cleanup_probe
cat <<EOF | "${KC[@]}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $PROBE_POD
  namespace: $PROBE_NS
  labels:
    app.kubernetes.io/name: hlvm-lock-probe
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  hostPID: true
  containers:
    - name: agent
      image: $AGENT_IMAGE
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      env:
        - name: HLVM_HOST_WRAPPER
          value: "$WRAPPER"
      volumeMounts:
        - name: host
          mountPath: /host
        - name: dev
          mountPath: /dev
        - name: run-lock-lvm
          mountPath: /run/lock/lvm
  volumes:
    - name: host
      hostPath:
        path: /
    - name: dev
      hostPath:
        path: /dev
    - name: run-lock-lvm
      hostPath:
        path: /run/lock/lvm
EOF

deadline=$((SECONDS + WAIT_SECS))
READY=no
while ((SECONDS < deadline)); do
  READY=$("${KC[@]}" -n "$PROBE_NS" get pod "$PROBE_POD" \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  [[ "$READY" == "true" ]] && break
  sleep 3
done
if [[ "$READY" != "true" ]]; then
  skip "probe Pod 未就绪（镜像可能未缓存或节点无法调度）："
  "${KC[@]}" -n "$PROBE_NS" describe pod "$PROBE_POD" 2>&1 | tail -12 || true
  echo "结论：SKIP（未覆盖 agent×lvmd 锁同源）"
  exit 0
fi
pass "probe Pod Ready（image=$AGENT_IMAGE，node=$NODE）"

echo
echo "== 2. wrapper 语义：容器里没有 lvm，必须靠 agent 的命令构造 =="
cat > "$TMPDIR_LOCAL/identity.sh" <<'EOS'
set -u
W="${HLVM_HOST_WRAPPER:-}"
echo "WRAPPER=$W"
# 复现 lvm::lvm_argv_with：wrapper 按空白切分前缀，再追加 "lvm" 与参数。
set -- $W
if command -v lvm >/dev/null 2>&1; then
  echo "BARE_LVM=present ($(command -v lvm))"
else
  echo "BARE_LVM=absent"
  echo "BARE_LVM_RC=$(lvm version >/dev/null 2>&1; echo $?)"
fi
if [ -z "$W" ]; then
  echo "WRAPPED_VERSION=NO_WRAPPER"; exit 0
fi
V=$("$@" lvm version 2>&1); RC=$?
echo "WRAPPED_RC=$RC"
printf '%s\n' "$V" | grep -i 'LVM version' | head -1 | sed 's/^/WRAPPED_VERSION=/'
echo "WRAPPED_VGS=$("$@" lvm vgs --noheadings -o vg_name 2>/dev/null | tr '\n' ',' )"
# 身份判据直接读 /host 挂载点，与 wrapper 形态解耦（chroot / nsenter 都适用）。
echo "LOCK_ID=$(stat -c '%d %i' /host/run/lock/lvm 2>/dev/null)"
echo "LVM_SHA=$(sha256sum /host/sbin/lvm 2>/dev/null | cut -c1-32)"
EOS
IDENT=$(agent_exec < "$TMPDIR_LOCAL/identity.sh" 2>/dev/null || true)
printf '%s\n' "$IDENT" | sed 's/^/       /'
WRAPPER_SEEN=$(printf '%s\n' "$IDENT" | sed -n 's/^WRAPPER=//p' | head -1 || true)
if [[ "$WRAPPER_SEEN" == "$WRAPPER" ]]; then
  pass "HLVM_HOST_WRAPPER 已注入（$WRAPPER_SEEN）"
else
  fail "HLVM_HOST_WRAPPER 未按预期注入（实际：${WRAPPER_SEEN:-空}，期望：$WRAPPER）"
fi
if printf '%s\n' "$IDENT" | grep -q '^BARE_LVM=absent'; then
  pass "agent 镜像内无裸 lvm 二进制（wrapper 是唯一通路）"
else
  info "agent 镜像内存在裸 lvm，wrapper 生效性以版本/视图判据为准"
fi
if printf '%s\n' "$IDENT" | grep -qiE '^WRAPPED_VERSION=[[:space:]]*LVM version:'; then
  pass "按 agent 的 split_whitespace 语义构造的命令调到宿主 lvm"
else
  fail "wrapper 构造的 lvm version 未成功（agent 调用栈不可用）"
fi
if printf '%s\n' "$IDENT" | grep -q "WRAPPED_VGS=.*$VG"; then
  pass "agent 调用栈读到宿主 VG 视图（含 $VG）"
else
  fail "agent 调用栈读不到宿主 VG $VG"
fi

echo
echo "== 3. 静态身份：agent 的宿主视图 vs lvmd 的宿主视图 =="
cat > "$TMPDIR_LOCAL/lvmd_identity.sh" <<'EOS'
echo "LOCK_ID=$(stat -c '%d %i' /run/lock/lvm 2>/dev/null)"
echo "LVM_SHA=$(sha256sum /sbin/lvm 2>/dev/null | cut -c1-32)"
EOS
LVMD_IDENT=$(lvmd_host < "$TMPDIR_LOCAL/lvmd_identity.sh" 2>/dev/null || true)
printf '%s\n' "$LVMD_IDENT" | sed 's/^/       /'
A_LOCK=$(printf '%s\n' "$IDENT" | sed -n 's/^LOCK_ID=//p' | head -1 || true)
L_LOCK=$(printf '%s\n' "$LVMD_IDENT" | sed -n 's/^LOCK_ID=//p' | head -1 || true)
A_SHA=$(printf '%s\n' "$IDENT" | sed -n 's/^LVM_SHA=//p' | head -1 || true)
L_SHA=$(printf '%s\n' "$LVMD_IDENT" | sed -n 's/^LVM_SHA=//p' | head -1 || true)
if [[ -n "$A_LOCK" && "$A_LOCK" == "$L_LOCK" ]]; then
  pass "锁目录同一份：/run/lock/lvm dev+inode = $A_LOCK"
else
  fail "锁目录不一致（agent=${A_LOCK:-空} / lvmd=${L_LOCK:-空}）"
fi
if [[ -n "$A_SHA" && "$A_SHA" == "$L_SHA" ]]; then
  pass "lvm 二进制同一份：/sbin/lvm sha256[0:32] = $A_SHA"
else
  fail "lvm 二进制不一致（agent=${A_SHA:-空} / lvmd=${L_SHA:-空}）"
fi

echo
echo "== 4. 并发：agent 调用栈 $N 路 × lvmd 宿主视图 $N 路，同写 $VG =="
# 并发放在 WSL 侧：每路一个**独立的短 kubectl exec**，命令结束即返回。
# 刻意不用「exec -i ... sh -s + 容器内后台子进程」：后台进程只要还持有 exec 的 stdout
# 管道，kubectl 就等不到 EOF，判据会无限挂起（真机实测踩过，见 ADR-006 §11）。
# 另：未加引号的 heredoc 里禁用反引号——会触发命令替换并执行注释里的文字。
# 每路 -y 必带：无 TTY 的 exec 里 lvcreate 遇到同名残留会弹交互提示并挂住。

echo "-- 4.0 单路写能力预检（防止 10 路一起把 VG 锁死）"
# 真机实测（ADR-006 §11）：`chroot /host` 只切文件系统根、不切 IPC 命名空间，
# lvm/libdm 的 udev 同步用 SysV 信号量 ⇒ 单路 lvcreate 就可能持锁卡在
# __do_semtimedop。若不先探一次，10 路并发会把整个 VG 的 lvm 操作全部堵住。
AGENT_CREATE='NAME=$0; V=$1; W=$HLVM_HOST_WRAPPER; set -- $W; exec "$@" lvm lvcreate -y -n "$NAME" -L 64M "$V"'
PRE_RC=0
PRE_OUT=$(timeout 30 "${KC[@]}" -n "$PROBE_NS" exec "pod/$PROBE_POD" -- \
  sh -c "$AGENT_CREATE" "ckpre" "$VG" 2>&1) || PRE_RC=$?
info "预检 rc=$PRE_RC 输出=${PRE_OUT:-<空>}"
if [[ "$PRE_RC" != "0" ]]; then
  fail "单路 wrapper 写 LV 失败/超时（rc=$PRE_RC），并发阶段不再执行"
  info "诊断：宿主 lslocks 若显示 V_<vg> 被 WRITE 持有、其余 WRITE* 等待，且持锁进程"
  info "wchan=__do_semtimedop，即为 chroot 不切 IPC NS 导致 udev 同步信号量失效。"
  info "修法（已落地为默认值）：HLVM_HOST_WRAPPER 改 nsenter -t 1 -m -u -i -n -p --（ADR-006 §11.6）。"
  # timeout 不会杀掉容器内孤儿 lvm；必须显式清理，否则 VG 一直处于锁死状态。
  "${KC[@]}" -n "$LVMD_NS" exec "pod/$LVMD_POD" -c lvmd -- \
    nsenter -t 1 -m -u -i -n -p -- sh -c \
    'pkill -9 -x lvm 2>/dev/null || true; sleep 1; lvm lvremove -y "$0/ckpre" >/dev/null 2>&1' \
    "$VG" >/dev/null 2>&1 || true
  echo
  echo "== 汇总 =="
  echo "结论：FAIL（进程级并发未覆盖：wrapper 单路写能力预检不通过）"
  exit 1
fi
pass "单路 wrapper 写 LV 成功（ckpre）"
"${KC[@]}" -n "$LVMD_NS" exec "pod/$LVMD_POD" -c lvmd -- \
  nsenter -t 1 -m -u -i -n -p -- lvm lvremove -y "$VG/ckpre" >/dev/null 2>&1 || true

# 先串行清同名 LV，建立干净基线。
for n in $(seq 1 "$N"); do
  "${KC[@]}" -n "$PROBE_NS" exec "pod/$PROBE_POD" -- \
    sh -c 'NAME=$0; V=$1; W=$HLVM_HOST_WRAPPER; set -- $W; "$@" lvm lvremove -y "$V/$NAME" >/dev/null 2>&1' \
    "ckagent$n" "$VG" >/dev/null 2>&1 || true
  "${KC[@]}" -n "$LVMD_NS" exec "pod/$LVMD_POD" -c lvmd -- \
    nsenter -t 1 -m -u -i -n -p -- lvm lvremove -y "$VG/cklvmd$n" >/dev/null 2>&1 || true
done

# AGENT_CREATE 已在 4.0 预检中定义：从 env 取 wrapper，按空白切分前缀，追加 lvm 与参数。
PIDS=()
for n in $(seq 1 "$N"); do
  (
    timeout 90 "${KC[@]}" -n "$PROBE_NS" exec "pod/$PROBE_POD" -- \
      sh -c "$AGENT_CREATE" "ckagent$n" "$VG" > "$TMPDIR_LOCAL/agent-$n.log" 2>&1
    echo $? > "$TMPDIR_LOCAL/agent-$n.rc"
  ) &
  PIDS+=("$!")
  (
    timeout 90 "${KC[@]}" -n "$LVMD_NS" exec "pod/$LVMD_POD" -c lvmd -- \
      nsenter -t 1 -m -u -i -n -p -- lvm lvcreate -y -n "cklvmd$n" -L 64M "$VG" \
      > "$TMPDIR_LOCAL/lvmd-$n.log" 2>&1
    echo $? > "$TMPDIR_LOCAL/lvmd-$n.rc"
  ) &
  PIDS+=("$!")
done
WAIT_RC=0
for p in "${PIDS[@]}"; do wait "$p" || WAIT_RC=1; done

for side in agent lvmd; do
  Z=0; BAD=0; RCLINES=""
  for n in $(seq 1 "$N"); do
    R=$(cat "$TMPDIR_LOCAL/$side-$n.rc" 2>/dev/null || echo "<missing>")
    RCLINES="$RCLINES $side$n=$R"
    if [[ "$R" == "0" ]]; then Z=$((Z + 1)); fi
    if grep -Eiq 'lock|fail|error' "$TMPDIR_LOCAL/$side-$n.log" 2>/dev/null; then
      BAD=$((BAD + 1))
    fi
  done
  info "逐路 rc:$RCLINES"
  if [[ "$Z" == "$N" ]]; then
    pass "$side 侧 $Z/$N 路 lvcreate rc=0"
  else
    fail "$side 侧 rc=0 只有 $Z/$N（期望 $N）"
  fi
  if [[ "$BAD" == "0" ]]; then
    pass "$side 侧无 lock/fail/error 日志"
  else
    fail "$side 侧 $BAD 个日志含可疑关键字"
  fi
done
if ((WAIT_RC != 0)); then
  fail "并发阶段有本地 exec job 异常退出，结论不可信"
fi

LVS_NOW=$("${KC[@]}" -n "$LVMD_NS" exec "pod/$LVMD_POD" -c lvmd -- \
  nsenter -t 1 -m -u -i -n -p -- lvm lvs --noheadings -o lv_name "$VG" 2>/dev/null || true)
if [[ -z "$LVS_NOW" ]]; then
  fail "并发后读不到宿主 lvs，不做无据判定"
else
  info "宿主 lvs：$(printf '%s\n' "$LVS_NOW" | awk 'NF{print $1}' | tr '\n' ' ')"
  for side in agent lvmd; do
    C=$(printf '%s\n' "$LVS_NOW" | awk 'NF{print $1}' | grep -c "^ck$side" || true)
    if [[ "$C" == "$N" ]]; then
      pass "$side 侧宿主 lvs 可见 $C 颗 LV"
    else
      fail "$side 侧宿主 lvs 可见 ${C:-0} 颗，期望 $N"
    fi
  done
fi

echo
echo "== 5. 清场：10 颗测试 LV 全部移除 =="
CLEAN_SCRIPT='VG=$0; N=$1;
for n in $(seq 1 $N); do
  lvm lvremove -y "$VG/ckagent$n" >/dev/null 2>&1
  lvm lvremove -y "$VG/cklvmd$n" >/dev/null 2>&1
done
rm -f /tmp/ck*.log /tmp/ck*.rc
L=$(lvm lvs --noheadings -o lv_name "$VG" 2>/dev/null)
echo "REMAIN=$(printf "%s\n" "$L" | awk "NF{print \$1}" | grep -c "^ck" || true)"
echo "LV_TOTAL=$(printf "%s\n" "$L" | awk "NF{print \$1}" | wc -l)"'
CLEAN_OUT=$("${KC[@]}" -n "$LVMD_NS" exec "pod/$LVMD_POD" -c lvmd -- \
  nsenter -t 1 -m -u -i -n -p -- sh -c "$CLEAN_SCRIPT" "$VG" "$N" 2>/dev/null || true)
printf '%s\n' "$CLEAN_OUT" | sed 's/^/       /'
REMAIN=$(printf '%s\n' "$CLEAN_OUT" | sed -n 's/^REMAIN=//p' | head -1 || true)
if [[ -z "$REMAIN" ]]; then
  fail "清场后读不到宿主 lvs，不做无据判定"
elif [[ "$REMAIN" == "0" ]]; then
  pass "清场后测试 LV 残留 0（VG 回到判据前状态）"
else
  fail "清场后仍有 $REMAIN 颗测试 LV 残留"
fi

echo
echo "== 汇总 =="
if ((skips > 0 && fails == 0)); then
  echo "结论：SKIP（$skips 项未覆盖，本轮不宣称 PASS）"
  exit 0
elif ((fails == 0)); then
  echo "结论：PASS（agent 调用栈与 lvmd 同二进制、同锁目录、并发写无冲突）"
  exit 0
else
  echo "结论：FAIL（$fails 项判据不通过）"
  exit 1
fi
