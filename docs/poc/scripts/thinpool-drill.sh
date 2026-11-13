#!/usr/bin/env bash
# thinpool-drill.sh —— thin pool 打满 / dmeventd 自动扩容 / out-of-data-space 恢复演练
#
# 对应：设计 §9.1（thinpool 打满）、§3.3（dmeventd 自动扩容参数）、§4.1 观察点，
#       以及 poc-report.md §4.1 需要记录的四件事：
#       扩容时延、成功率、IO 是否 hang/报错、文件系统可恢复性。
#
# 【与 fault-injection.sh 的关系】
#   fault-injection.sh 是「命令框架 + 人工观察」的清单，不产出判据；
#   本脚本把其中可在单节点自动化的一节（4.1）做成**带判据**的演练：
#   每一步都是「断言 + 证据」，最后给 PASS/FAIL/SKIP 与 SUMMARY，rc 0|1。
#   坏盘热拔（4.2）/ 节点断电（4.3）依赖物理或虚拟化操作，仍留在原脚本。
#
# 【口径】
#   - 在隔离 kind 上跑（loop + 稀疏文件后端）时，**只验证行为与判据**，
#     IOPS/带宽/时延数字不得作为性能评审依据（见 fio-baseline.sh 头部说明）。
#   - 演练会**真的把池写满**，期间同池内的其他 PVC 会受影响 ⇒ 只能在隔离环境执行。
#     脚本在检测到集群内存在非演练 PVC/PV 时会拒绝执行（ALLOW_BUSY_VG=1 可强制）。
#
# 用法（节点本地 root；kind 用 docker exec -i 喂 stdin）：
#   VG=hlvm-poc-vg POOL=thinpool bash thinpool-drill.sh
#   # 已有 VG 但空间不足时缩短 B 卷：SIZE_A=8G SIZE_B=26G
#
# 环境变量：
#   VG POOL            默认 hlvm-poc-vg / thinpool
#   SIZE_A SIZE_B      默认 12G / auto。auto = 2×当前池容量：薄卷是虚拟大小，
#                     不占实际空间，但能保证「无论 dmeventd 连续扩容几次」都写得到 100%
#                     （扩容次数由 VG 剩余空间决定，显式给死尺寸很容易只写到大半就撞 FS 上限）
#   BASE               挂载根，默认 /mnt/tpdrill
#   THRESHOLD PERCENT  期望的 lvm.conf autoextend 参数，默认 70 / 20
#   CONFIGURE_AUTOEXTEND=1  由脚本写入 lvm.conf 并 lvchange --monitor y（结束恢复）
#   POLL               轮询秒，默认 2
#   KEEP=1             保留 LV 以便排查（默认清理；池留满会导致同池后续 PVC 失败）
#   ALLOW_BUSY_VG=1    绕过「VG 上已有非演练卷」的拒绝
set -uo pipefail

VG="${VG:-hlvm-poc-vg}"
POOL="${POOL:-thinpool}"
SIZE_A="${SIZE_A:-12G}"
SIZE_B="${SIZE_B:-auto}"
BASE="${BASE:-/mnt/tpdrill}"
THRESHOLD="${THRESHOLD:-70}"
PERCENT="${PERCENT:-20}"
CONFIGURE_AUTOEXTEND="${CONFIGURE_AUTOEXTEND:-1}"
POLL="${POLL:-1}"
KEEP="${KEEP:-0}"
ALLOW_BUSY_VG="${ALLOW_BUSY_VG:-0}"

LV_A="tpdrill-a"
LV_B="tpdrill-b"
M_A="$BASE/a"
M_B="$BASE/b"
LVM_CONF=/etc/lvm/lvm.conf
LVM_CONF_BAK=/etc/lvm/lvm.conf.tpdrill.bak

PASS=0
FAIL=0
SKIP=0
DD_PID=""
declare -a OBS=()          # 关键观察点，最后汇总打印

pass() { PASS=$((PASS + 1)); printf '  [pass] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  [skip] %s（能力缺失不计 PASS）\n' "$*"; }
obs()  { OBS+=("$*"); printf '  [obs] %s\n' "$*"; }

pool_attr() { lvs --noheadings -o lv_attr "$VG/$POOL" 2>/dev/null | tr -d ' '; }
# 统一取整数字节：--units b 仍可能带小数，直接参与 [ -gt ] 会报 integer expression expected
pool_size_bytes() { lvs --noheadings --units b --nosuffix -o lv_size "$VG/$POOL" 2>/dev/null | awk '{printf "%d", $1}'; }
data_pct() { lvs --noheadings -o data_percent "$VG/$POOL" 2>/dev/null | tr -d ' '; }
meta_pct() { lvs --noheadings -o metadata_percent "$VG/$POOL" 2>/dev/null | tr -d ' '; }
vg_free_bytes() { vgs --noheadings --units b --nosuffix -o vg_free "$VG" 2>/dev/null | awk '{printf "%d", $1}'; }
health() { lvs --noheadings -o lv_health_status "$VG/$POOL" 2>/dev/null | tr -d ' '; }
dm_escape() { printf '%s' "$1" | sed 's/-/--/g'; }          # dm 名里 vg/lv 内的 '-' 要变 '--'

# umount 后并不代表 dm 设备立刻空闲：-l（lazy）只是摘掉挂载点，
# 有进程仍持有引用时设备依旧 busy，xfs_repair 会报 "Device or resource busy"。
umount_wait() {
  local m="$1" dev i
  dev="/dev/$VG/$LV_B"
  [ "$m" = "$M_A" ] && dev="/dev/$VG/$LV_A"
  for i in 1 2 3 4 5; do
    mountpoint -q "$m" 2>/dev/null || break
    umount "$m" 2>/dev/null && break
    sleep 2
  done
  if mountpoint -q "$m" 2>/dev/null; then
    umount -l "$m" 2>/dev/null || true
    for i in $(seq 1 15); do
      mountpoint -q "$m" 2>/dev/null || break
      sleep 1
    done
  fi
  for i in $(seq 1 15); do
    if [ "$(dmsetup info -c --noheadings -o open "$dev" 2>/dev/null | tr -d ' ')" = "0" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  local rc=$?
  [ -n "$DD_PID" ] && kill "$DD_PID" 2>/dev/null || true
  for m in "$M_B" "$M_A"; do
    mountpoint -q "$m" 2>/dev/null && { umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; }
  done
  if [ "$KEEP" != "1" ]; then
    # 先删 A 再删 B：A 的空间先回到池里，B 的排队 IO 才有机会落地（否则 B 删不掉）
    lvremove -y "$VG/$LV_A" >/dev/null 2>&1 || true
    lvremove -y "$VG/$LV_B" >/dev/null 2>&1 || true
    if [ -f "$LVM_CONF_BAK" ]; then
      cp -f "$LVM_CONF_BAK" "$LVM_CONF" 2>/dev/null || true
      rm -f "$LVM_CONF_BAK" 2>/dev/null || true
    fi
  else
    printf '  [warn] KEEP=1：保留 %s/%s 与 %s/%s，且未恢复 lvm.conf；池可能仍处高位\n' "$VG" "$LV_A" "$VG" "$LV_B"
  fi
  exit "$rc"
}

summary() {
  printf '\n  ---- 关键观察点 ----\n'
  local o
  for o in "${OBS[@]:-}"; do [ -n "$o" ] && printf '   * %s\n' "$o"; done
  printf '  [info] 池终态：size=%s data=%s%% meta=%s%% health=%s\n' \
    "$(pool_size_bytes)" "$(data_pct)" "$(meta_pct)" "${health:-none}"
  printf 'SUMMARY PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
  if [ "$FAIL" -gt 0 ]; then exit 1; fi
  # 一个都没跑通（全 SKIP）不算通过
  if [ "$PASS" -eq 0 ]; then
    printf '  FAIL: 无任何判据真正执行（全 SKIP 不等于通过）\n'
    exit 1
  fi
  exit 0
}

trap cleanup EXIT

# ---------------------------------------------------------------- P0 前提
printf '== P0 前提检查（%s/%s）\n' "$VG" "$POOL"
for b in lvs vgs dd mkfs.xfs; do
  command -v "$b" >/dev/null 2>&1 || { fail "缺命令 $b（lvm2/xfsprogs）"; summary; }
done
ATTR=$(pool_attr)
case "$ATTR" in
  t*|T*) pass "thin pool 存在（attr=$ATTR）" ;;
  *) fail "找不到 thin pool $VG/$POOL（attr=${ATTR:-空}）"; summary ;;
esac
SIZE0=$(pool_size_bytes)
FREE0=$(vg_free_bytes)
[ -n "$SIZE0" ] && [ "$SIZE0" -gt 0 ] 2>/dev/null || { fail "读不到池容量"; summary; }
[ -n "$FREE0" ] || FREE0=0
obs "初始：池 $(awk "BEGIN{printf \"%.1f\", $SIZE0/1073741824}")GiB，VG free $(awk "BEGIN{printf \"%.2f\", $FREE0/1073741824}")GiB，data=$(data_pct)% meta=$(meta_pct)%"
# dmesg 会保留**历史**内核消息（上一轮演练的 out-of-data-space 还在环里），
# 不复位基准就会把旧消息当成本轮证据 —— 这是典型的假绿来源。
DMESG_BASE=$(dmesg 2>/dev/null | wc -l)
DMESG_BASE=${DMESG_BASE:-0}
dmesg_new() { dmesg 2>/dev/null | tail -n +$((DMESG_BASE + 1)); }

# 隔离性：同 VG 上若已有非演练 LV，写满会牵连别人
OTHERS=$(lvs --noheadings -o lv_name "$VG" 2>/dev/null | tr -d ' ' | grep -v -E "^($POOL|\[|${LV_A}|${LV_B})" | tr '\n' ' ')
if [ -n "$OTHERS" ] && [ "$ALLOW_BUSY_VG" != "1" ]; then
  fail "VG $VG 上还有非演练卷：$OTHERS（写满会牵连；隔离环境或用 ALLOW_BUSY_VG=1）"
  summary
elif [ -n "$OTHERS" ]; then
  obs "VG 上有其他卷（已按 ALLOW_BUSY_VG=1 强制继续）：$OTHERS"
else
  pass "VG 内只有 thin pool，可安全演练"
fi

# 容量关系：B 卷必须能"吃下"扩容后的全部剩余池空间，否则只会停在扩容后的高位、
# 永远打不满。dmeventd 可能连续扩容多次（每次 +PERCENT%，直到 VG 无空间），
# 因此默认 SIZE_B=auto ⇒ 2×池容量，用薄卷的"虚拟大小"兜住任意次扩容；
# 显式给 SIZE_B 时只做下限校验（A+B 至少超过当前池容量）。
to_bytes() { awk "BEGIN{print int($1*1073741824)}"; }
if [ "$SIZE_B" = "auto" ]; then
  SIZE_B="$(awk "BEGIN{printf \"%d\", int($SIZE0*2/1073741824)+1}")G"
fi
A_B=$(to_bytes "${SIZE_A%G}"); B_B=$(to_bytes "${SIZE_B%G}")
AFTER_SIZE=$(awk "BEGIN{printf \"%d\", $SIZE0 * (100 + $PERCENT) / 100}")
if [ $((A_B + B_B)) -le "$SIZE0" ]; then
  fail "SIZE_A+SIZE_B=$(( (A_B + B_B) / 1073741824 ))GiB 未超过当前池容量 $(( SIZE0 / 1073741824 ))GiB，无法打满"
  summary
fi
pass "容量关系成立：A=${SIZE_A} + B=${SIZE_B}（扩容后池预计 ≥$(( AFTER_SIZE / 1073741824 ))GiB）"

# ---------------------------------------------------------------- P1 dmeventd 配置
printf '== P1 dmeventd 自动扩容配置\n'
HAVE_DMEVENTD=0
pgrep -x dmeventd >/dev/null 2>&1 && HAVE_DMEVENTD=1
if [ "$CONFIGURE_AUTOEXTEND" = "1" ]; then
  [ -f "$LVM_CONF_BAK" ] || cp -f "$LVM_CONF" "$LVM_CONF_BAK"
  if grep -q 'thin_pool_autoextend_threshold' "$LVM_CONF"; then
    sed -i "s/^[[:space:]]*thin_pool_autoextend_threshold.*/    thin_pool_autoextend_threshold = ${THRESHOLD}/" "$LVM_CONF"
    sed -i "s/^[[:space:]]*thin_pool_autoextend_percent.*/    thin_pool_autoextend_percent = ${PERCENT}/" "$LVM_CONF"
  else
    # 插到 activation { 之后一行
    awk -v t="$THRESHOLD" -v p="$PERCENT" '
      {print}
      /^[[:space:]]*activation[[:space:]]*\{/ && !done {
        printf "    thin_pool_autoextend_threshold = %s\n    thin_pool_autoextend_percent = %s\n", t, p
        done=1
      }' "$LVM_CONF" >"$LVM_CONF.tmp" && mv -f "$LVM_CONF.tmp" "$LVM_CONF"
  fi
  if grep -q "thin_pool_autoextend_threshold = ${THRESHOLD}" "$LVM_CONF"; then
    pass "lvm.conf 已写入 autoextend threshold=${THRESHOLD}% percent=${PERCENT}%"
  else
    fail "lvm.conf 写入 autoextend 参数失败"
  fi
else
  obs "CONFIGURE_AUTOEXTEND=0：使用现场已有 lvm.conf 配置"
fi

if lvchange --monitor y "$VG/$POOL" >/dev/null 2>&1; then
  pass "已开启 $VG/$POOL 的 dmeventd 监控"
else
  skip "lvchange --monitor y 失败（kind 无 udev 时 dmeventd 可能不可用）"
fi
if [ "$HAVE_DMEVENTD" = "1" ]; then
  pass "dmeventd 进程存在（pid=$(pgrep -x dmeventd | head -1)）"
else
  skip "dmeventd 进程不存在 ⇒ 自动扩容相位无法覆盖"
fi

# ---------------------------------------------------------------- P2 造卷
printf '== P2 建演练卷 %s/%s、%s/%s\n' "$VG" "$LV_A" "$VG" "$LV_B"
mkdir -p "$M_A" "$M_B"
# 上一轮中断可能留下挂载中的演练卷；先摘挂载点再删，否则 lvremove 报 in use
for m in "$M_A" "$M_B"; do
  if mountpoint -q "$m" 2>/dev/null; then
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
  fi
done
lvremove -y "$VG/$LV_B" >/dev/null 2>&1 || true
lvremove -y "$VG/$LV_A" >/dev/null 2>&1 || true
lvcreate -y -V "$SIZE_A" -T "$VG/$POOL" -n "$LV_A" >/dev/null || { fail "建 $LV_A 失败"; summary; }
lvcreate -y -V "$SIZE_B" -T "$VG/$POOL" -n "$LV_B" >/dev/null || { fail "建 $LV_B 失败"; summary; }
mkfs.xfs -f -q "/dev/$VG/$LV_A" || { fail "mkfs $LV_A 失败"; summary; }
mkfs.xfs -f -q "/dev/$VG/$LV_B" || { fail "mkfs $LV_B 失败"; summary; }
mount "/dev/$VG/$LV_A" "$M_A" || { fail "mount $LV_A 失败"; summary; }
mount "/dev/$VG/$LV_B" "$M_B" || { fail "mount $LV_B 失败"; summary; }
pass "两卷已建并挂载（A=$SIZE_A B=$SIZE_B）"

# ---------------------------------------------------------------- P3 灌满 A
printf '== P3 灌满 A（%s）作为基线占用\n' "$SIZE_A"
DATA_PRE=$(data_pct); DATA_PRE=${DATA_PRE:-0}
T0=$(date +%s)
timeout 900 dd if=/dev/zero of="$M_A/fill" bs=1M oflag=direct status=none 2>/dev/null
DDRC=$?
T1=$(date +%s)
DATAA=$(data_pct); DATAA=${DATAA:-0}
DELTA=$(awk "BEGIN{printf \"%.2f\", $DATAA - $DATA_PRE}")
obs "灌 A 用时 $((T1 - T0))s，dd rc=$DDRC，data 由 ${DATA_PRE}% 升到 ${DATAA}%"
# 文件系统写满时 dd 以 rc=1（ENOSPC）退出，这是**期望**结果，不是失败；
# 判据落在「池占用是否真的涨了」上，避免把 dd 的 rc 当门禁。
if awk "BEGIN{exit !($DELTA >= $A_B * 0.85 / 1073741824)}"; then
  pass "A 已写满（池 data +${DELTA}%，≈${SIZE_A}；dd rc=$DDRC 属 ENOSPC 正常返回）"
else
  fail "A 写入量不足：池 data 仅 +${DELTA}%（期望 ≈${SIZE_A}）"
fi

# ---------------------------------------------------------------- P4 dmeventd 扩容
printf '== P4 灌 B 触发 dmeventd 自动扩容（阈值 %s%% / 增量 %s%%）\n' "$THRESHOLD" "$PERCENT"
EXPECT_SIZE=$(awk "BEGIN{printf \"%d\", $SIZE0 * (100 + $PERCENT) / 100}")
LAST_SIZE="$SIZE0"
MAX_DATA=0
EXT_EVENTS=0
EXT_BAD=0
HIT_100=0
EXT_T0=""
timeout 1800 dd if=/dev/zero of="$M_B/fill" bs=1M oflag=direct status=none 2>/dev/null &
DD_PID=$!
START=$(date +%s)
while kill -0 "$DD_PID" 2>/dev/null; do
  CUR=$(pool_size_bytes)
  DP=$(data_pct)
  case "$DP" in ''|*[!0-9.]*) DP=0 ;; esac
  awk "BEGIN{exit !($DP > $MAX_DATA)}" && MAX_DATA=$DP
  if [ -n "$CUR" ] && [ "$CUR" != "$LAST_SIZE" ]; then
    EXT_EVENTS=$((EXT_EVENTS + 1))
    ELAPSED=$(( $(date +%s) - START ))
    [ -z "$EXT_T0" ] && EXT_T0=$ELAPSED
    INC=$(awk "BEGIN{printf \"%.1f\", ($CUR - $LAST_SIZE) * 100 / $LAST_SIZE}")
    # 轮询可能把连续多次 +PERCENT% 合并成一个观测增量（一次 +43% 实为两次 +20%），
    # 所以判据是「≈ k×PERCENT」，并据此把事件数算成 k 次，而不是死磕单次 +20%。
    K=$(awk "BEGIN{printf \"%d\", ($INC + $PERCENT / 2) / $PERCENT}")
    [ "$K" -ge 1 ] || K=1
    DEV=$(awk "BEGIN{printf \"%.1f\", $INC - $K * $PERCENT}")
    obs "池扩容 #$EXT_EVENTS：$(awk "BEGIN{printf \"%.1f\", $LAST_SIZE/1073741824}")GiB → $(awk "BEGIN{printf \"%.1f\", $CUR/1073741824}")GiB（+${INC}%≈${K}×${PERCENT}%，第 ${ELAPSED}s，样本 data=${DP}%）"
    EXT_EVENTS=$((EXT_EVENTS + K - 1))
    awk "BEGIN{exit !($DEV <= 3 && $DEV >= -3)}" || EXT_BAD=$((EXT_BAD + 1))
    LAST_SIZE="$CUR"
  fi
  awk "BEGIN{exit !($DP >= 99.5)}" && HIT_100=1
  # 池已满就不必再等 dd（dm-thin 可能把 IO 排队挂住）
  if [ "$HIT_100" = "1" ] && [ $(( $(date +%s) - START )) -gt 20 ]; then break; fi
  sleep "$POLL"
done
DDRC_B=0
if kill -0 "$DD_PID" 2>/dev/null; then
  kill "$DD_PID" 2>/dev/null || true
  DDRC_B=124
else
  wait "$DD_PID" 2>/dev/null || DDRC_B=$?
fi
DD_PID=""

DATA_B=$(data_pct); DATA_B=${DATA_B:-0}
SIZE1=$(pool_size_bytes); SIZE1=${SIZE1:-0}
obs "灌 B 结束：dd rc=$DDRC_B，data=${DATA_B}%，池 $(awk "BEGIN{printf \"%.1f\", $SIZE1/1073741824}")GiB，峰值 data=${MAX_DATA}%"

if [ "$HAVE_DMEVENTD" = "1" ] && [ "$EXT_EVENTS" -ge 1 ] && [ "$SIZE1" -gt 0 ]; then
  if [ "$EXT_BAD" -eq 0 ]; then
    pass "dmeventd 自动扩容生效：${SIZE0}B → ${SIZE1}B，共 ${EXT_EVENTS} 次，每次均 ≈+${PERCENT}%（首轮预期 ${EXPECT_SIZE}B）"
    obs "自动扩容时延：从开始灌 B 到首次扩容 ≈${EXT_T0}s（loop 后端，非性能结论）"
  else
    fail "有 ${EXT_BAD}/${EXT_EVENTS} 次扩容增量偏离 +${PERCENT}%（${SIZE0}B → ${SIZE1}B）"
  fi
else
  skip "未观察到自动扩容（dmeventd 不可用或 VG 无空闲空间），扩容链路未覆盖"
fi

# ---------------------------------------------------------------- P5 out-of-space
printf '== P5 打满池 → out-of-data-space\n'
DMESG_HIT=0
# 内核原文是 "out-of-data-space"（带连字符），写成 "out of data space" 会永远不命中；
# 且必须只在本轮新增的行里找（历史消息会冒充证据）
dmesg_new | grep -Eqi "out-of-data-space|out of data space" && DMESG_HIT=1
if [ "$HIT_100" = "1" ] || awk "BEGIN{exit !(${DATA_B:-0} >= 99.5)}"; then
  pass "池 data 达到 100%（观测峰值 ${MAX_DATA}%）"
else
  fail "池未打到 100%（data=${DATA_B}%）；检查 SIZE_A+SIZE_B 与 VG 空间"
fi
HL=$(health)
if [ -n "$HL" ]; then
  obs "lv_health_status=$HL"
  case "$HL" in
    *out_of_data*) pass "lv_health_status 报出 out_of_data（打满的权威判据，不依赖 dmesg）" ;;
    *) skip "lv_health_status=$HL（未报 out_of_data）" ;;
  esac
fi
POOLSTAT=$(dmsetup status "$(dm_escape "$VG")-$(dm_escape "$POOL")-tpool" 2>/dev/null || true)
if [ -n "$POOLSTAT" ]; then
  obs "dm status：$(printf '%s' "$POOLSTAT" | awk '{for(i=1;i<=NF;i++) if($i ~ /queue_if_no_space|error|rw|ro/) printf "%s ", $i}')"
  case "$POOLSTAT" in
    *queue_if_no_space*) obs "池带 queue_if_no_space ⇒ 打满后写入被**排队挂起**（不是立即 EIO）" ;;
    *error_if_no_space*) obs "池为 error_if_no_space ⇒ 打满后写入立即报错" ;;
  esac
fi
if [ "$DMESG_HIT" = "1" ]; then
  pass "内核报出 out-of-data-space（本轮新增 dmesg 命中）"
  obs "dmesg: $(dmesg_new | grep -Ei "out-of-data-space|out of data space" | tail -1 | cut -c1-160)"
else
  # 池带 queue_if_no_space 时内核只挂起写入，不会打 "switching to out-of-data-space"，
  # 这不是能力缺失；本轮的 out-of-space 证据由 lv_health_status / dm status 提供。
  skip "本轮 dmesg 无 out-of-data-space 记录（queue_if_no_space 模式下内核不打该切换消息，以 lv_health_status 为准）"
fi
# dmeventd 扩容元数据（与 data 扩容是两条链路，出现即记录）
META_LINE=$(dmesg_new | grep -i "growing the metadata device" | tail -1 | cut -c1-140)
if [ -n "$META_LINE" ]; then
  pass "元数据自动扩容也生效（dmesg：$META_LINE）"
  obs "meta% 终值=$(meta_pct)%（初始 10.5%）"
else
  obs "未见 metadata 自动扩容（meta%=$(meta_pct)%）"
fi
obs "打满时 IO 行为：dd rc=$DDRC_B（124=写入被 dm 排队、脚本终止；非 0 其它值=报错返回）"

# ---------------------------------------------------------------- P6 恢复
printf '== P6 恢复：卸载 → 释放空间 → xfs_repair → 复写\n'
# 顺序很关键：池满且 dm 带 queue_if_no_space 时，B 的在途 IO 被**排队挂住**，
# 直接 umount B 会卡死（-l 只摘挂载点，dm open 计数不归零）。
# 正确顺序：先卸未受影响的 A 并删除 —— 释放出的池空间让排队 IO 落地，
# 之后 B 才可能真正空闲下来。上一轮就是先卸 B，卡在 "dm open != 0"。
if umount_wait "$M_A"; then
  pass "A 已卸载"
else
  fail "A 卸载后仍有引用"
fi

# 池满时 lvm 元数据操作仍可进行，但命令可能被 dm 排队拖住 ⇒ 加超时并保留错误输出
LVREMOVE_LOG=/tmp/lvremove-a.log
timeout 300 lvremove -y "$VG/$LV_A" >"$LVREMOVE_LOG" 2>&1
LR_RC=$?
if [ "$LR_RC" -eq 0 ]; then
  pass "已释放 A（lvremove rc=0）"
else
  fail "释放 A 失败（rc=$LR_RC）：$(tail -2 "$LVREMOVE_LOG" | tr '\n' ';')"
fi
DATA_AFTER=$(data_pct); DATA_AFTER=${DATA_AFTER:-100}
obs "释放 A 后 data=${DATA_AFTER}%"
if awk "BEGIN{exit !($DATA_AFTER < 95)}"; then
  pass "释放空间后池占用回落（${DATA_AFTER}%），排队 IO 具备落地条件"
else
  fail "释放 A 后池仍高位（${DATA_AFTER}%），无法继续"
fi

if umount_wait "$M_B"; then
  pass "B 已卸载且 dm 设备无引用"
else
  fail "B 卸载后仍有引用（dm open != 0），修复无法进行"
  summary
fi

# 修复前必须确认设备真的空闲，否则 xfs_repair 的 rc!=0 会被误判成「检出损坏」（假证据）
xfs_repair -n "/dev/$VG/$LV_B" >/tmp/xfs-n.log 2>&1
NRC=$?
if grep -qi "busy" /tmp/xfs-n.log; then
  fail "xfs_repair -n 无法独占设备（Device or resource busy），本轮不能作为损坏证据"
elif [ "$NRC" -ne 0 ]; then
  pass "xfs_repair -n 检出不一致（rc=$NRC）⇒ 打满确实留下了文件系统损伤"
  obs "xfs_repair -n 摘要：$(grep -Ei "error|corrupt|bad|would" /tmp/xfs-n.log | head -3 | tr '\n' ';')"
else
  obs "xfs_repair -n 未报错（该组合下打满主要表现是 IO 挂起而非结构损坏）"
fi

timeout 600 xfs_repair "/dev/$VG/$LV_B" >/tmp/xfs-fix.log 2>&1
FRC=$?
if [ "$FRC" -eq 0 ]; then
  pass "xfs_repair 修复成功（rc=0）"
else
  fail "xfs_repair 失败（rc=$FRC）：$(tail -3 /tmp/xfs-fix.log | tr '\n' ';')"
fi

if mount "/dev/$VG/$LV_B" "$M_B" 2>/dev/null; then
  pass "修复后可重新挂载"
  # B 的 FS 在打满时已被写到上限：先删掉填充文件腾出空间，再验证「可写」，
  # 否则 64MiB 复写失败其实是 ENOSPC（FS 满），会被误读成「修复失败」。
  rm -f "$M_B/fill" 2>/dev/null || true
  sync
  DDLOG=/tmp/dd-after.log
  if timeout 120 dd if=/dev/zero of="$M_B/after" bs=1M count=64 oflag=direct status=none 2>"$DDLOG"; then
    SZ=$(stat -c %s "$M_B/after" 2>/dev/null || echo 0)
    if [ "$SZ" = "67108864" ]; then
      pass "清理后复写 64MiB 成功且大小正确（$SZ）"
    else
      fail "复写后大小异常：$SZ（期望 67108864）"
    fi
  else
    fail "修复后复写失败（rc=$?）：$(tail -2 "$DDLOG" | tr '\n' ';')"
  fi
  umount_wait "$M_B" >/dev/null 2>&1 || true
else
  fail "修复后仍无法挂载"
fi

# ---------------------------------------------------------------- P7 收尾
printf '== P7 收尾\n'
lvremove -y "$VG/$LV_B" >/dev/null 2>&1 && pass "演练卷已删除" || fail "删除 $VG/$LV_B 失败"
DATAF=$(data_pct)
obs "清理后 data=${DATAF}%，池容量=$(awk "BEGIN{printf \"%.1f\", $(pool_size_bytes)/1073741824}")GiB"
if awk "BEGIN{exit !(${DATAF:-0} > 5)}"; then
  fail "清理后池占用仍 ${DATAF}%（有残留）"
else
  pass "清理后池占用回落到 ${DATAF}%"
fi
if [ -f "$LVM_CONF_BAK" ]; then
  cp -f "$LVM_CONF_BAK" "$LVM_CONF" && rm -f "$LVM_CONF_BAK"
  pass "lvm.conf 已恢复原样"
fi

summary
