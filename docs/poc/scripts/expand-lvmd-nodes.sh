#!/usr/bin/env bash
# expand-lvmd-nodes.sh —— 把 B 链路从单 worker 扩到多 worker（ADR-006 §13）。
#
# 解决的问题（2026-11-12 真机核查）：
#   1. 三台节点各有两块 40G 空白盘，「单 worker」是软件限制而非资源限制；
#   2. lvmd DS 把 ConfigMap 名写死成 hlmd-lvmd-10-60-153-100、nodeSelector 写死 hostname，
#      无法承载第二节点（两节点 VG 名不同 ⇒ 配置不同）；改为聚合 CM + initContainer 按
#      NODE_NAME 投影后，一个 DS 可服务任意节点；
#   3. 常驻 agent 镜像是缓存的旧 CI 产物 sha-87d9160，不是当前 HEAD 产物。
#
# 顺序纪律（不能乱）：
#   建 VG → seed NodeVG 并 patch status → 清窗口期 StorageTask → 生成聚合 CM → 打标签
#   → apply 清单 → 判就绪。若先打标签，lvmd/agent 会立刻调到还没有配置的节点：
#   initContainer 取不到 key 而 CrashLoop，agent 还会消费刚下发的 vgcreate Task。
#
# 判据纪律：
#   - 能力缺失 SKIP 且不计 PASS；结构性缺失 FAIL；读不到宿主 lvs 一律 FAIL；
#   - 每条判据打印原始证据；结论以「exit 0 + 无 [FAIL] + SUMMARY 行」为准；
#   - 所有 $(...) 赋值带 || true（set -e 下无兜底的命令替换会静默退出且无日志）；
#   - 写盘前置必须证「裸盘」：无 FSTYPE / 无挂载 / 无 PV 签名 / 无同名 VG，
#     且必须显式 CONFIRM_WRITE=1；VG 已存在则幂等跳过，绝不重复 pvcreate。
#
# 用法（在 WSL 内、仓库根执行）：
#   CONFIRM_WRITE=1 bash docs/poc/scripts/expand-lvmd-nodes.sh
#   CONFIRM_WRITE=1 NEW_NODES=10-60-166-202 bash ...
#   STEP=prepare|deploy|verify ... bash ...     # 真机首跑建议逐相位
#   DRY_RUN=1 ... bash ...                      # 只做前置与基线，不写不改
#   AGENT_IMAGE=...:sha-<commit> ... bash ...   # 临时 CI 产物（默认取发布版 :v<VERSION>）
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/hlvm-real.conf}"
SSH_KEY="${SSH_KEY:-/home/jinfeng105/.ssh/hlvm-real}"
NODES="${NODES:-10-60-153-100,10-60-166-202}"
NEW_NODES="${NEW_NODES:-10-60-166-202}"
# VG 名**不能从节点名推导**：历史命名里 10-60-153-100 → hlvm-lvmd-vg-153（第三段），
# 而 10-60-166-202 → hlvm-lvmd-vg-202（第四段）。任何 awk -F- '{print $NF}' 之类的
# 推导都会得到 hlvm-lvmd-vg-100 这种不存在的名字，进而写错 CR / 读错宿主 lvs。
NODE_VG_MAP="${NODE_VG_MAP:-10-60-153-100=hlvm-lvmd-vg-153,10-60-166-202=hlvm-lvmd-vg-202}"
LABEL_KEY="${LABEL_KEY:-hlvm.io/lvmd}"
LABEL_VALUE="${LABEL_VALUE:-true}"
LVMD_NS="${LVMD_NS:-hlvm-system}"
LVMD_DS="${LVMD_DS:-hlvm-lvmd}"
CSI_NODE_DS="${CSI_NODE_DS:-topolvm-node}"
AGENT_DS="${AGENT_DS:-hlvm-storage-agent}"
# 默认镜像从仓库根 VERSION 单一事实源推导为发布版 :v<VERSION>（集成/生产一律
# :vX.Y.Z）。旧默认值写死 sha-52bda85，发版后立刻过时，2026-11-12 verify 首跑
# 因此报「DS 镜像不符」假红（ADR-006 §15）。需要临时 CI 产物时显式传 AGENT_IMAGE。
HLVM_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || true)"
if [[ -z "$HLVM_VERSION" ]]; then
  echo "[error] 读不到 $REPO_ROOT/VERSION；请显式设置 AGENT_IMAGE" >&2
  exit 1
fi
AGENT_IMAGE="${AGENT_IMAGE:-ghcr.io/f31/hlvm/storage-agent:v${HLVM_VERSION}}"
DISK_BY_ID="${DISK_BY_ID:-/dev/disk/by-id/virtio-UCLOUD_DISK_VDB}"
THINPOOL_SIZE="${THINPOOL_SIZE:-36G}"
POOLMETA_SIZE="${POOLMETA_SIZE:-1G}"
CONFIRM_WRITE="${CONFIRM_WRITE:-0}"
DRY_RUN="${DRY_RUN:-0}"
STEP="${STEP:-all}"
READY_WAIT="${READY_WAIT:-420}"
TASK_RECHECK_WAIT="${TASK_RECHECK_WAIT:-35}"
PURGE_WINDOW_TASKS="${PURGE_WINDOW_TASKS:-0}"
RUN_E2E="${RUN_E2E:-1}"
EXPECT_IMAGE_SHA="${EXPECT_IMAGE_SHA:-}"

K=(kubectl --kubeconfig "$KUBECONFIG")
PASS=0
FAIL=0
SKIP=0
trap 'echo "[error] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

pass() { echo "    [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "    [FAIL] $*"; FAIL=$((FAIL + 1)); }
skip() { echo "    [SKIP] $*（不计 PASS）"; SKIP=$((SKIP + 1)); }
info() { echo "       $*"; }
finish() {
  echo "SUMMARY: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP} RESULT=$(if ((FAIL > 0)); then echo FAIL; elif ((SKIP > 0)); then echo PARTIAL; else echo PASS; fi)"
  ((FAIL == 0)) || exit 1
  exit 0
}
step_wanted() {
  [[ "$STEP" == "all" || "$STEP" == "$1" ]]
}

# 节点名 → VG 名（显式映射，见 NODE_VG_MAP 注释）；无映射返回空，由调用方判 FAIL。
declare -A VG_BY_NODE
IFS=',' read -r -a VG_PAIRS <<< "$NODE_VG_MAP" || true
for pair in "${VG_PAIRS[@]}"; do
  IFS='=' read -r _node _vg <<< "$pair" || true
  [[ -n "${_node:-}" && -n "${_vg:-}" ]] && VG_BY_NODE["$_node"]="$_vg"
done
vg_of_node() { echo "${VG_BY_NODE[$1]:-}"; }

# 节点名 → InternalIP（SSH 目标）。取不到返回空，由调用方判 FAIL。
ip_of_node() {
  "${K[@]}" get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
}

# 按节点定点取 Ready Pod —— 绝不 `kubectl exec/logs ds/...` 任取（§13 判据纪律）。
ready_pod_on_node() {
  local ns="$1" selector="$2" node="$3"
  "${K[@]}" -n "$ns" get pods -l "$selector" \
    -o jsonpath='{range .items[?(@.spec.nodeName=="'"${node}"'")]}{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}|{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$2=="True" && $3=="" {print $1; exit}' || true
}

ssh_node() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=10 root@"$ip" "$@"
}

echo "== 0. 前置与基线 =="
echo "    kubeconfig=$KUBECONFIG nodes=$NODES new=$NEW_NODES step=$STEP"
echo "    image=$AGENT_IMAGE disk=$DISK_BY_ID confirm_write=$CONFIRM_WRITE dry_run=$DRY_RUN"
[[ -f "$KUBECONFIG" ]] || { fail "kubeconfig 不存在：$KUBECONFIG"; finish; }
[[ -f "$SSH_KEY" ]] || { fail "SSH key 不存在：$SSH_KEY（建 VG 的唯一写通道）"; finish; }
[[ -f "$REPO_ROOT/control-plane/config/lvmd/daemonset.yaml" ]] || { fail "仓库清单缺失（REPO_ROOT=$REPO_ROOT）"; finish; }
command -v python3 >/dev/null 2>&1 || { fail "缺少 python3（生成聚合 CM / 解析 CR）"; finish; }
pass "本地依赖齐备"

# 镜像边界（§13/§15）：默认发布版 :v<VERSION>，也接受 CI 产物 :sha-<commit>；
# 两者都必须可溯源，绝不放行此前只缓存在节点上的 sha-87d9160 / sha-7e76f95。
# 旧门禁只认 sha-<commit>，与「集成/生产一律 :vX.Y.Z」的发布纪律冲突，也是
# 2026-11-12 verify 首跑要显式传 AGENT_IMAGE 才不假红的根因之一。
IMAGE_REPO="${AGENT_IMAGE%:*}"
IMAGE_TAG="${AGENT_IMAGE##*:}"
if [[ "$IMAGE_REPO" != "ghcr.io/f31/hlvm/storage-agent" ]]; then
  fail "AGENT_IMAGE 仓库不符（实际 $IMAGE_REPO）"
  finish
fi
case "$IMAGE_TAG" in
  v*)
    if [[ "$IMAGE_TAG" != "v$HLVM_VERSION" ]]; then
      fail "发布版 tag $IMAGE_TAG 与仓库 VERSION $HLVM_VERSION 不一致"
      finish
    fi
    pass "镜像为发布版 :v${HLVM_VERSION}（与 VERSION 单一事实源一致）"
    ;;
  sha-*)
    IMAGE_SHA="${EXPECT_IMAGE_SHA:-$(printf '%s' "$IMAGE_TAG" | sed -n 's/^sha-\([0-9a-f]\{7,\}\)$/\1/p' || true)}"
    if [[ -z "$IMAGE_SHA" ]]; then
      fail "sha tag 格式非法：$IMAGE_TAG"
      finish
    fi
    case "$IMAGE_SHA" in
      87d9160|7e76f95) fail "仍在用节点缓存的旧镜像 sha-$IMAGE_SHA（不是 CI 产物）"; finish ;;
    esac
    GIT_DIR_OK="$(git -C "$REPO_ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)"
    if [[ "$GIT_DIR_OK" == "true" ]]; then
      if ! git -C "$REPO_ROOT" cat-file -e "${IMAGE_SHA}^{commit}" 2>/dev/null; then
        fail "镜像 commit ${IMAGE_SHA} 在仓库中不存在（无法证明是本项目 CI 产物）"
        finish
      fi
      PROD_DIFF="$(git -C "$REPO_ROOT" diff "${IMAGE_SHA}" -- agent/src agent/Cargo.toml agent/Cargo.lock 2>/dev/null || true)"
      if [[ -z "$PROD_DIFF" ]]; then
        pass "镜像 commit ${IMAGE_SHA} 存在，且 agent 产品代码与当前工作树无差异"
      else
        fail "镜像 commit ${IMAGE_SHA} 与当前工作树的 agent 产品代码有差异，不能声称当前代码已上线"
        finish
      fi
    else
      info "WSL 同步副本不含 .git：跳过 git 层等价校验（GHCR manifest 与 CHANGELOG 的 diff 证据另行给出）"
    fi
    pass "镜像为 CI 产物 sha-${IMAGE_SHA}（已排除旧缓存 tag）"
    ;;
  *)
    fail "AGENT_IMAGE=$AGENT_IMAGE 既不是 :v<VERSION> 也不是 :sha-<commit>"
    finish
    ;;
esac

IFS=',' read -r -a NODE_ARR <<< "$NODES"
IFS=',' read -r -a NEW_ARR <<< "$NEW_NODES"
for n in "${NODE_ARR[@]}"; do
  READY="$("${K[@]}" get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "$READY" == "True" ]] || { fail "节点 $n 非 Ready（${READY:-空}）"; finish; }
  IP="$(ip_of_node "$n" || true)"
  [[ -n "$IP" ]] || { fail "节点 $n 取不到 InternalIP"; finish; }
  NVG="$(vg_of_node "$n" || true)"
  [[ -n "$NVG" ]] || { fail "节点 $n 在 NODE_VG_MAP 里没有 VG 名映射"; finish; }
  info "node=$n ip=$IP vg=$NVG"
done
pass "${#NODE_ARR[@]} 个目标节点 Ready 且可解析 InternalIP"

BASE_TASKS="$("${K[@]}" get storagetasks -o name 2>/dev/null | wc -l || true)"
BASE_PVC="$("${K[@]}" get pvc -A -o name 2>/dev/null | wc -l || true)"
info "基线：storagetasks=${BASE_TASKS:-?} pvc=${BASE_PVC:-?}"
if [[ "${BASE_TASKS:-1}" != "0" ]]; then
  # 重跑 prepare 时，基线里的 Task 往往正是上一轮 seed 窗口遗留、待阶段 2 清理的那条。
  # 不能直接放行：必须显式 PURGE_WINDOW_TASKS=1，且阶段 2 会逐条核验「目标节点 +
  # vgcreate + 无审批」特征，任一不符即拒绝清理。
  if [[ "$PURGE_WINDOW_TASKS" == "1" ]]; then
    info "基线存在 ${BASE_TASKS} 条 StorageTask（预期为上轮 seed 窗口遗留）；已显式批准进入阶段 2 核验清理"
    pass "基线 Task 进入受控清理流程（不是无条件放行）"
  else
    fail "扩容前已存在 ${BASE_TASKS} 条 StorageTask；先人工确认后设 PURGE_WINDOW_TASKS=1 重跑"
    finish
  fi
else
  pass "扩容前无非终态 StorageTask（基线 0）"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  skip "DRY_RUN=1：只读前置已通过，未执行任何写操作"
  finish
fi

# ---------------------------------------------------------------------------
# 1. 新节点建 VG（唯一走 SSH 的写操作；判据读全部走 kubectl）
# ---------------------------------------------------------------------------
if step_wanted prepare; then
echo "== 1. 新节点建 VG + thinpool =="
if [[ "$CONFIRM_WRITE" != "1" ]]; then
  fail "写盘需显式 CONFIRM_WRITE=1（目标盘 ${DISK_BY_ID} 将被 pvcreate/vgcreate）"
  finish
fi

# 远端脚本用 base64 传输，避开多层 SSH 引号；注释禁用反引号。
REMOTE_LVM="$(cat <<'EOS'
set -eu
VG="$1"; DISK="$2"; SIZE="$3"; META="$4"
DEV="$(readlink -f "$DISK")"
test -b "$DEV" || { echo "DISK_NOT_BLOCK: $DISK -> $DEV" >&2; exit 3; }
# 幂等分支必须排在裸盘检查之前：重跑时目标盘已经是 PV、已有文件系统吗？
# 没有文件系统，但 pvs 会命中，若先查 PV 会把「已完成」误判成「盘被占用」。
VG_ALREADY=0
if vgs --noheadings -o vg_name "$VG" 2>/dev/null | awk '{print $1}' | grep -qx "$VG"; then
  echo "VG_EXISTS=1 (幂等跳过写盘) vg=$VG"
  VG_ALREADY=1
fi
if [ "$VG_ALREADY" = "0" ]; then
  FSTYPE="$(lsblk -no FSTYPE "$DEV" 2>/dev/null | head -1 || true)"
  MOUNTP="$(lsblk -no MOUNTPOINT "$DEV" 2>/dev/null | head -1 || true)"
  if [ -n "$FSTYPE" ] || [ -n "$MOUNTP" ]; then
    echo "DISK_NOT_EMPTY: dev=$DEV fstype=${FSTYPE} mount=${MOUNTP}" >&2; exit 4
  fi
  if pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -qx "$DEV"; then
    echo "DISK_ALREADY_PV: $DEV" >&2; exit 5
  fi
  pvcreate -y "$DISK" >/dev/null
  vgcreate "$VG" "$DISK" >/dev/null
  lvcreate -y --thinpool thinpool -L "$SIZE" --poolmetadatasize "$META" "$VG" >/dev/null
  echo "VG_CREATED=1 vg=$VG disk=$DISK"
fi
echo "VGS=$(vgs --noheadings --units b --nosuffix -o vg_uuid,vg_size,vg_free "$VG" | awk '{print $1" "$2" "$3}')"
echo "LVS=$(lvs --noheadings -o lv_name,lv_size --units b "$VG" | awk '{print $1"("$2")"}' | tr '\n' ' ')"
EOS
)"
REMOTE_B64="$(printf '%s' "$REMOTE_LVM" | base64 -w0 || true)"
[[ -n "$REMOTE_B64" ]] || { fail "远端脚本 base64 编码失败"; finish; }

declare -A VG_FACTS
for n in "${NEW_ARR[@]}"; do
  VG="$(vg_of_node "$n" || true)"
  IP="$(ip_of_node "$n" || true)"
  echo "    -- $n ($IP) vg=$VG --"
  OUT="$(ssh_node "$IP" "echo ${REMOTE_B64} | base64 -d | bash -s -- ${VG} ${DISK_BY_ID} ${THINPOOL_SIZE} ${POOLMETA_SIZE}" 2>&1 || true)"
  printf '%s\n' "$OUT" | sed 's/^/         /'
  if [[ -z "$OUT" ]] || ! printf '%s' "$OUT" | grep -qE 'VG_CREATED=1|VG_EXISTS=1'; then
    fail "$n 建 VG 失败（SSH 输出未见成功标记，可能盘非空或链路不可达）"
    finish
  fi
  if ! printf '%s' "$OUT" | grep -q 'thinpool'; then
    fail "$n 的 VG 里看不到 thinpool（VGS/LVS 输出异常）"
    finish
  fi
  VGS_LINE="$(printf '%s\n' "$OUT" | sed -n 's/^VGS=//p' | head -1 || true)"
  if [[ -z "${VGS_LINE:-}" ]]; then
    fail "$n 取不到 vg_uuid/vg_size/vg_free，无法 patch NodeVG.status"
    finish
  fi
  read -r VG_UUID VG_TOTAL VG_FREE <<< "$VGS_LINE" || true
  if [[ -z "${VG_UUID:-}" || -z "${VG_TOTAL:-}" || -z "${VG_FREE:-}" ]]; then
    fail "$n 取不到 vg_uuid/vg_size/vg_free，无法 patch NodeVG.status"
    finish
  fi
  VG_FACTS["$n"]="${VG_UUID}|${VG_TOTAL}|${VG_FREE}"
  pass "$n 宿主 VG 就绪（uuid=${VG_UUID:0:12}… total=${VG_TOTAL}B free=${VG_FREE}B）"
done
fi

# ---------------------------------------------------------------------------
# 2. seed NodeVG + patch status + 清理窗口期 Task
# ---------------------------------------------------------------------------
if step_wanted prepare; then
echo "== 2. seed NodeVG 并写入 status =="
for n in "${NEW_ARR[@]}"; do
  VG="$(vg_of_node "$n" || true)"
  SEED="$REPO_ROOT/control-plane/config/lvmd/nodevg-seed-${VG#hlvm-lvmd-vg-}.yaml"
  [[ -f "$SEED" ]] || { fail "缺 NodeVG seed 清单：$SEED"; finish; }
  "${K[@]}" apply -f "$SEED" >/dev/null || { fail "apply $SEED 失败"; finish; }
  # apply 到 patch 之间的窗口控制器可能下发 vgcreate Task（vgExists 尚为 false）。
  # 立刻写 status，随后显式扫描并清理，确认不重建后才允许 agent 调到该节点。
  IFS='|' read -r U T F <<< "${VG_FACTS[$n]}"
  PATCH="{\"status\":{\"vgExists\":true,\"vgUUID\":\"${U}\",\"totalBytes\":${T},\"freeBytes\":${F},\"capacityStatus\":\"available\"}}"
  "${K[@]}" patch nodevg "$VG" --subresource=status --type=merge -p "$PATCH" >/dev/null \
    || { fail "patch NodeVG $VG status 失败"; finish; }
  GOT="$("${K[@]}" get nodevg "$VG" -o jsonpath='{.status.vgExists}' 2>/dev/null || true)"
  [[ "$GOT" == "true" ]] || { fail "NodeVG $VG status.vgExists=${GOT:-空}"; finish; }
  pass "$n NodeVG $VG 已 seed 且 vgExists=true"

  # 等控制器渲染出该节点的 per-node ConfigMap；读不到就是结构性缺失。
  CM="hlmd-lvmd-$n"
  CM_OK=""
  for i in $(seq 1 30); do
    CM_OK="$("${K[@]}" -n "$LVMD_NS" get cm "$CM" -o jsonpath='{.data.lvmd\.yaml}' 2>/dev/null || true)"
    [[ -n "$CM_OK" ]] && break
    sleep 2
  done
  [[ -n "$CM_OK" ]] || { fail "控制器未渲染 $CM（LvmdConfigReconciler 未生效）"; finish; }
  if printf '%s' "$CM_OK" | grep -qw "$VG"; then pass "$CM 已由控制器渲染且指向 $VG"; else fail "$CM 未指向 $VG"; finish; fi
done

echo "    -- 窗口期 StorageTask 扫描 --"
TASKS_JSON="$("${K[@]}" get storagetasks -o json 2>/dev/null || true)"
WINDOW="$(printf '%s' "${TASKS_JSON:-{\}}" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("PARSE_ERROR"); sys.exit(0)
nodes=set(sys.argv[1:])
for t in d.get("items",[]):
    s=t.get("spec",{}); st=t.get("status",{}) or {}
    if st.get("phase") in ("Succeeded","Failed"): continue
    ttype=s.get("type",""); node=s.get("nodeName",""); approved=s.get("approvedBy","") or ""
    # 只认「新建 NodeVG 的窗口期 vgcreate」：带审批、别的类型、别的节点一律 SAFE=false。
    safe = (ttype=="vgcreate" and not approved and node in nodes)
    print("%s|node=%s|type=%s|phase=%s|approvedBy=%s|SAFE=%s" % (
        t["metadata"]["name"], node, ttype, st.get("phase","<absent>"),
        approved or "<absent>", "true" if safe else "false"))
' "${NEW_ARR[@]}" 2>/dev/null || true)"
if printf '%s' "$WINDOW" | grep -q 'PARSE_ERROR'; then
  fail "StorageTask 列表解析失败"; finish
elif printf '%s' "$WINDOW" | grep -q 'SAFE=false'; then
  fail "存在不符合窗口期特征的 StorageTask（非 vgcreate / 带审批 / 非目标节点），拒绝自动清理"
  finish
elif [[ -n "$WINDOW" ]]; then
  printf '%s\n' "$WINDOW" | sed 's/^/       /'
  if [[ "$PURGE_WINDOW_TASKS" != "1" ]]; then
    fail "seed 窗口产生非终态 StorageTask；请人工确认后设 PURGE_WINDOW_TASKS=1 重跑（agent 上线会消费）"
    finish
  fi
  while IFS='|' read -r tname _rest; do
    [[ -n "$tname" ]] || continue
    "${K[@]}" delete storagetask "$tname" --wait=true --timeout=30s >/dev/null 2>&1 || true
    info "deleted: $tname"
  done <<< "$WINDOW"
fi
if [[ "$PURGE_WINDOW_TASKS" == "1" ]]; then
  info "观察 ${TASK_RECHECK_WAIT}s 确认控制器不重建（vgExists=true 是前提）"
  sleep "$TASK_RECHECK_WAIT"
fi
REMAIN="$("${K[@]}" get storagetasks -o name 2>/dev/null | wc -l || true)"
if [[ "${REMAIN:-1}" == "0" ]]; then
  pass "打标签前 StorageTask 恒为 0（观察 ${TASK_RECHECK_WAIT}s，agent 无从误消费）"
else
  fail "仍有 ${REMAIN} 条 StorageTask（控制器会重建，禁止继续）"; finish
fi
fi

# ---------------------------------------------------------------------------
# 3. 从 per-node ConfigMap 生成聚合 CM（真相源仍是控制面渲染结果）
# ---------------------------------------------------------------------------
if step_wanted deploy; then
echo "== 3. 生成聚合 ConfigMap hlvm-lvmd-all =="
ALL_YAML="$("${K[@]}" -n "$LVMD_NS" get cm -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
prefix="hlmd-lvmd-"
entries={}
for cm in d.get("items",[]):
    name=cm.get("metadata",{}).get("name","")
    if not name.startswith(prefix): continue
    node=name[len(prefix):]
    body=(cm.get("data") or {}).get("lvmd.yaml")
    if not body: continue
    entries[node]=body
if not entries: sys.exit(3)
print("apiVersion: v1")
print("kind: ConfigMap")
print("metadata:")
print("  name: hlvm-lvmd-all")
print("  namespace: hlvm-system")
print("  labels:")
print("    app.kubernetes.io/name: hlvm-lvmd")
print("    app.kubernetes.io/component: lvmd-config")
print("  annotations:")
print("    hlvm.dev/managed: \"false\"")
print("data:")
for node in sorted(entries):
    print("  %s: |" % node)
    for line in entries[node].splitlines():
        print("    " + line)
' 2>/dev/null || true)"
[[ -n "$ALL_YAML" ]] || { fail "集群里没有可用的 hlmd-lvmd-* ConfigMap，无法生成聚合 CM"; finish; }
printf '%s\n' "$ALL_YAML" | "${K[@]}" apply -f - >/dev/null || { fail "apply 聚合 CM 失败"; finish; }
ALL_KEYS="$("${K[@]}" -n "$LVMD_NS" get cm hlvm-lvmd-all -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(" ".join(sorted((d.get("data") or {}).keys())))
' 2>/dev/null || true)"
info "聚合 CM keys: ${ALL_KEYS:-<空>}"
for n in "${NODE_ARR[@]}"; do
  PER="$("${K[@]}" -n "$LVMD_NS" get cm "hlmd-lvmd-$n" -o jsonpath='{.data.lvmd\.yaml}' 2>/dev/null || true)"
  # 节点名含连字符，jsonpath 会把 `{.data.10-60-153-100}` 解析成算术表达式；
  # 必须走 json + python 按字符串取 key。
  AGG="$("${K[@]}" -n "$LVMD_NS" get cm hlvm-lvmd-all -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print((d.get("data") or {}).get(sys.argv[1],""))
' "$n" 2>/dev/null || true)"
  if [[ -n "$PER" && "$PER" == "$AGG" ]]; then
    pass "节点 $n 的聚合 CM 内容与 per-node 渲染逐字节一致"
  else
    fail "节点 $n 聚合 CM 内容与 per-node CM 不一致（per=${#PER}B agg=${#AGG}B）"
    finish
  fi
done
fi

# ---------------------------------------------------------------------------
# 4. 打标签 + apply 清单
# ---------------------------------------------------------------------------
if step_wanted deploy; then
echo "== 4. 打标签并 apply 多节点清单 =="
for n in "${NODE_ARR[@]}"; do
  "${K[@]}" label node "$n" "${LABEL_KEY}=${LABEL_VALUE}" --overwrite >/dev/null \
    || { fail "给 $n 打标签失败"; finish; }
done
pass "${#NODE_ARR[@]} 个节点已打 ${LABEL_KEY}=${LABEL_VALUE}"

"${K[@]}" apply -f "$REPO_ROOT/control-plane/config/lvmd/daemonset.yaml" >/dev/null \
  || { fail "apply lvmd DaemonSet 失败"; finish; }
"${K[@]}" apply -f "$REPO_ROOT/control-plane/config/csi/40-node.yaml" >/dev/null \
  || { fail "apply CSI node DaemonSet 失败"; finish; }
pass "lvmd / CSI node 清单已 apply（标签选择器 + 按节点投影）"

# deploy-agent-real.sh 的前置是「本节点上有 Ready 的 lvmd Pod」（定点读宿主 VG）。
# 新节点首次要拉 initContainer 的 with-sidecar 镜像，这里显式等，避免下游脚本
# 把「还没就绪」误判成「宿主读不到 VG」这种无据结论。
for n in "${NODE_ARR[@]}"; do
  LP=""
  for i in $(seq 1 $((READY_WAIT / 5))); do
    LP="$(ready_pod_on_node "$LVMD_NS" "app.kubernetes.io/name=hlvm-lvmd" "$n" || true)"
    [[ -n "$LP" ]] && break
    sleep 5
  done
  if [[ -z "$LP" ]]; then
    fail "$n 上 ${READY_WAIT}s 内无 Ready lvmd Pod，停止后续部署"
    "${K[@]}" -n "$LVMD_NS" get pods -l app.kubernetes.io/name=hlvm-lvmd -o wide 2>&1 | head -8 | sed 's/^/       /' || true
    finish
  fi
  pass "$n 上 lvmd Pod Ready：$LP"
done

# agent DS 由 deploy-agent-real.sh 逐节点验收时 apply（幂等），此处不重复渲染。
for n in "${NODE_ARR[@]}"; do
  echo "    -- 逐节点部署/验收 agent：$n --"
  OUT="$(NODE="$n" VG="$(vg_of_node "$n")" KUBECONFIG="$KUBECONFIG" \
    AGENT_IMAGE="$AGENT_IMAGE" NODE_LABEL_KEY="$LABEL_KEY" NODE_LABEL_VALUE="$LABEL_VALUE" \
    PURGE_ORPHAN_TASKS=0 bash "$SCRIPT_DIR/deploy-agent-real.sh" 2>&1 || true)"
  printf '%s\n' "$OUT" | tail -28 | sed 's/^/       /'
  if printf '%s' "$OUT" | grep -q 'SUMMARY: .*FAIL=0.*RESULT=PASS'; then
    pass "$n agent 部署 + MODE=pod 真实写门禁全 PASS"
  else
    fail "$n agent 部署/门禁未全绿（见上方输出）"
    printf '%s\n' "$OUT" | grep -E '\[FAIL\]|\[error\]' | tail -8 | sed 's/^/       /' || true
  fi
done
fi

# ---------------------------------------------------------------------------
# 5. 三 DS × 两节点就绪（按「目标节点存在 Ready Pod」判，不信 rollout status）
# ---------------------------------------------------------------------------
if step_wanted verify; then
echo "== 5. 多节点就绪 / 容量 / 镜像 =="
declare -A DS_SELECTOR
DS_SELECTOR["$LVMD_DS"]="app.kubernetes.io/name=hlvm-lvmd"
DS_SELECTOR["$CSI_NODE_DS"]="app.kubernetes.io/name=topolvm,app.kubernetes.io/component=node"
DS_SELECTOR["$AGENT_DS"]="app.kubernetes.io/component=storage-agent"
for ds in "$LVMD_DS" "$CSI_NODE_DS" "$AGENT_DS"; do
  SEL="${DS_SELECTOR[$ds]}"
  DESIRED="$("${K[@]}" -n "$LVMD_NS" get ds "$ds" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
  info "ds=$ds desired=${DESIRED:-?} selector=$SEL"
  for n in "${NODE_ARR[@]}"; do
    POD=""
    for i in $(seq 1 $((READY_WAIT / 5))); do
      POD="$(ready_pod_on_node "$LVMD_NS" "$SEL" "$n" || true)"
      [[ -n "$POD" ]] && break
      sleep 5
    done
    if [[ -n "$POD" ]]; then
      pass "$ds 在 $n 上有 Ready Pod：$POD"
    else
      fail "$ds 在 $n 上 ${READY_WAIT}s 内无 Ready Pod"
      "${K[@]}" -n "$LVMD_NS" get pods -l "$SEL" -o wide 2>&1 | head -8 | sed 's/^/       /' || true
    fi
  done
done

DS_IMAGE="$("${K[@]}" -n "$LVMD_NS" get ds "$AGENT_DS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ "$DS_IMAGE" == "$AGENT_IMAGE" ]]; then
  pass "常驻 agent DS 镜像与期望一致（发布版 / CI 产物）：$DS_IMAGE"
else
  fail "常驻 agent DS 镜像不符（实际 ${DS_IMAGE:-空}，期望 $AGENT_IMAGE）"
fi

for n in "${NODE_ARR[@]}"; do
  CAP="$("${K[@]}" get node "$n" -o json 2>/dev/null | python3 -c '
import json,sys
try: a=json.load(sys.stdin)["metadata"].get("annotations",{})
except Exception: a={}
print(a.get("capacity.topolvm.io/hlvm-lvmd",""))
' 2>/dev/null || true)"
  if [[ -n "${CAP:-}" && "${CAP}" != "0" ]]; then
    pass "$n 容量注解 capacity.topolvm.io/hlvm-lvmd=${CAP}（$((CAP / 1048576)) MiB）"
  else
    fail "$n 容量注解缺失或为 0（实际 ${CAP:-空}）"
  fi
  TOPO="$("${K[@]}" get node "$n" -o jsonpath='{.metadata.labels.topology\.topolvm\.io/node}' 2>/dev/null || true)"
  [[ -n "$TOPO" ]] && pass "$n 拓扑标签=$TOPO" || fail "$n 缺拓扑标签 topology.topolvm.io/node"
done

CSISC="$("${K[@]}" -n "$LVMD_NS" get csistoragecapacity -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
for i in d.get("items",[]):
    topo=i.get("nodeTopology") or {}
    vals=[]
    # TopoLVM 0.42 的 external-provisioner 用 matchLabels（实测），
    # 兼容旧形态 matchLabelExpressions，避免把「取不到值」当成空拓扑还判 PASS。
    for k,v in (topo.get("matchLabels") or {}).items():
        if k.endswith("/node"): vals.append(v)
    for t in (topo.get("matchLabelExpressions") or []):
        vals += t.get("values") or []
    print("%s|%s|%s|%s" % (i["metadata"]["name"], i.get("storageClassName") or "",
                            ",".join(vals), i.get("capacity") or ""))
' 2>/dev/null || true)"
info "CSIStorageCapacity: ${CSISC:-<空>}"
CSISC_N="$(printf '%s\n' "$CSISC" | grep -c . || true)"
if [[ "${CSISC_N:-0}" -ge "${#NODE_ARR[@]}" ]]; then
  pass "CSIStorageCapacity 条目数 ${CSISC_N} ≥ 目标节点数 ${#NODE_ARR[@]}"
else
  fail "CSIStorageCapacity 只有 ${CSISC_N:-0} 条，少于目标节点数（多节点容量未上报）"
fi
# 逐节点核对：必须存在「storageClass=hlvm-b + 拓扑值=该节点 + capacity 非零」的条目，
# 光数条目数不够（两个条目可能都指向同一个节点）。
for n in "${NODE_ARR[@]}"; do
  HIT="$(printf '%s\n' "$CSISC" | awk -F'|' -v sc=hlvm-b -v node="$n" \
    '$2==sc && $3 ~ node && $4!="" {print $1"|"$3"|"$4; exit}' || true)"
  if [[ -n "$HIT" ]]; then
    pass "$n 有独立 CSIStorageCapacity 条目（$HIT）"
  else
    fail "$n 没有拓扑指向该节点且容量非零的 CSIStorageCapacity"
  fi
done
fi

# ---------------------------------------------------------------------------
# 6. 逐节点 PVC E2E（WFFC + 拓扑亲和，验证各自 VG 真的供给）
# ---------------------------------------------------------------------------
if step_wanted verify && [[ "$RUN_E2E" == "1" ]]; then
echo "== 6. 逐节点 PVC 端到端回归 =="
for n in "${NODE_ARR[@]}"; do
  VG="$(vg_of_node "$n" || true)"
  OUT="$(NODE="$n" VG="$VG" KUBECONFIG="$KUBECONFIG" \
    bash "$SCRIPT_DIR/pvc-supply-e2e.sh" 2>&1 || true)"
  printf '%s\n' "$OUT" | grep -E '^\[pass\]|^\[FAIL\]|^\[skip\]|^结论|^       (PV 名|VG 基线|挂载类型)' | tail -22 | sed 's/^/       /' || true
  if printf '%s' "$OUT" | grep -q '结论：PASS'; then
    pass "$n / $VG PVC→LV→写入→回收 全 PASS"
  else
    fail "$n / $VG PVC E2E 未 PASS"
    printf '%s\n' "$OUT" | grep -E '\[FAIL\]|\[error\]' | tail -8 | sed 's/^/       /' || true
  fi
done
fi

# ---------------------------------------------------------------------------
# 7. 终态
# ---------------------------------------------------------------------------
if step_wanted verify; then
echo "== 7. 终态核对 =="
FINAL_TASKS="$("${K[@]}" get storagetasks -o name 2>/dev/null | wc -l || true)"
FINAL_PVC="$("${K[@]}" get pvc -A -o name 2>/dev/null | grep -v velero | wc -l || true)"
info "storagetasks=${FINAL_TASKS:-?} pvc(非 velero)=${FINAL_PVC:-?}"
[[ "${FINAL_TASKS:-1}" == "0" ]] && pass "终态无残留 StorageTask" || fail "终态残留 ${FINAL_TASKS} 条 StorageTask"
for n in "${NODE_ARR[@]}"; do
  P="$(ready_pod_on_node "$LVMD_NS" "app.kubernetes.io/name=hlvm-lvmd" "$n" || true)"
  [[ -z "$P" ]] && { fail "$n 无 Ready lvmd Pod，跳过多节点 lvs 残留判据"; continue; }
  LVS="$("${K[@]}" -n "$LVMD_NS" exec "$P" -c lvmd -- nsenter -t 1 -m -u -i -n -p -- \
    lvm lvs --noheadings -o lv_name "$(vg_of_node "$n")" 2>&1 || true)"
  info "$n LV: $(printf '%s' "$LVS" | awk 'NF{print $1}' | tr '\n' ' ')"
  if [[ -z "$LVS" ]]; then
    fail "$n 读不到宿主 lvs（不做无据判定）"
  elif printf '%s' "$LVS" | grep -q 'thinpool' && ! printf '%s' "$LVS" | grep -qE 'hlvm-gate-|pvc-'; then
    pass "$n VG 只剩 thinpool，无门禁/PVC 残留 LV"
  else
    fail "$n VG 存在残留 LV"
  fi
done
fi

finish
