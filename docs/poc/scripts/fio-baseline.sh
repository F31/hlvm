#!/usr/bin/env bash
# fio-baseline.sh —— POC 性能基线实测（设计 §10 阶段 0 / add-poc-decision-gate §3）
#
# 对比层：raw（裸盘）/ thick（线性 LV + XFS）/ thin（thin LV + XFS，首写·覆盖写）/
#         thin-snap（快照卷 CoW 写）。输出 IOPS / 带宽 / p99 到 CSV。
#
# 【口径警告 —— 必须先读】
#   只有**真实块设备**（POC 节点上直连 SSD/NVMe，且未承载任何 LVM 元数据）上的数字
#   才有容量/性能评审意义。ADR-006 §23.5 D2 的隔离 kind 集群用 loop + 稀疏文件承载
#   VG/thin pool，and 三个 kind 节点共享同一宿主内核与磁盘：
#     - 每次 IO 都要再穿过一层 loop → 宿主文件系统，数字只反映 loop/dm 链路开销；
#     - 宿主页缓存与宿主盘上的其他负载会污染结果，重复跑波动大；
#     - 多节点并行会互相抢同一块宿主盘。
#   ⇒ kind 结果**不能作为性能评审依据**，只用于：
#     1) 验证本脚本的采集链路与判据可用（能否跑通、能否稳定取到 iops/bw/p99）；
#     2) 生成结构化 CSV/JSON，供报告模板回填时的字段校验；
#     3) 验证「首写 vs 覆盖」这类**相对**关系在同一后端内是否存在可观测差异。
#   kind / loop 后端必须显式 KIND_BACKEND=1；summary 会打印口径标注，避免数字被误引用。
#
# 判据（任何一条不满足即 FAIL，缺能力只 SKIP 不计 PASS）：
#   - 每次 fio 退出码 0，JSON 可解析；
#   - **被测方向的** iops > 0，bw > 0，p99 > 0（写任务读 `.read.iops` 恒为 0，见下）；
#   - CSV 行数 = 1 表头 + 实际完成行数；行内容与 (layer,bs,qd,rw) 计划一致；
#   - 承载 PV 的设备拒绝裸写（会毁掉 LVM 元数据）——按 SKIP 处理并说明。
#
# 修复的历史缺陷：
#   旧版用 `jq '.read.iops // .write.iops'` 取值。jq 的 `//` 只在 false/null 时回退，
#   而写任务的 `.read.iops` 是 **0（真值）**，所以写方向一律被记成 0 —— 旧 CSV 里
#   写行的 iops 全是 0，看起来像「写性能为 0」，实际是取值 bug。现按 rw 方向取值。
#
# 用法（节点本地，root）：
#   bash fio-baseline.sh
#   RAW=/dev/sdb M_THICK=/mnt/thick M_THIN=/mnt/thin M_SNAP=/mnt/thin-snap bash fio-baseline.sh
#   # kind（自动建三层目标并清理；PREP 需 VG/POOL 已存在）：
#   PREP=1 VG=hlvm-poc-vg POOL=thinpool KIND_BACKEND=1 BS_LIST="4k 1M" RUNTIME=10 SIZE=512M \
#     M_THICK=/mnt/fio/thick M_THIN=/mnt/fio/thin M_SNAP=/mnt/fio/snap bash fio-baseline.sh
#
# 环境变量：
#   RAW M_THICK M_THIN M_SNAP   各层目标；留空或不是挂载点 ⇒ 该层 SKIP
#   LAYERS       默认 raw,thick,thin,thin-snap（可裁剪）
#   BS_LIST      默认 "4k 64k 1M"
#   QD_LIST      默认 "1 32"
#   RUNTIME      每 cell 秒数，默认 60（kind 建议 10）
#   SIZE         每 cell 工作集，默认 4G（kind 建议 512M）
#   OUT          CSV 路径，默认 ./fio-results.csv；JSONDIR 非空则保留每次的原始 JSON
#   PREP=1       按 VG/POOL 建 thick LV / thin LV / 快照并 mkfs+mount（CLEANUP 默认 1）
#   VG POOL THICK_SIZE(2G) THIN_SIZE(4G)
#   KIND_BACKEND=1  声明跑在 loop 后端上（只影响口径标注，不改变判据）
set -uo pipefail

RAW="${RAW:-}"
M_THICK="${M_THICK:-}"
M_THIN="${M_THIN:-}"
M_SNAP="${M_SNAP:-}"
LAYERS="${LAYERS:-raw,thick,thin,thin-snap}"
BS_LIST="${BS_LIST:-4k 64k 1M}"
QD_LIST="${QD_LIST:-1 32}"
RUNTIME="${RUNTIME:-60}"
SIZE="${SIZE:-4G}"
OUT="${OUT:-fio-results.csv}"
JSONDIR="${JSONDIR:-}"
FIO_BIN="${FIO_BIN:-fio}"
KIND_BACKEND="${KIND_BACKEND:-0}"

PREP="${PREP:-0}"
VG="${VG:-hlvm-poc-vg}"
POOL="${POOL:-thinpool}"
THICK_SIZE="${THICK_SIZE:-2G}"
THIN_SIZE="${THIN_SIZE:-4G}"
LV_THICK="${LV_THICK:-fio-thick}"
LV_THIN="${LV_THIN:-fio-thin}"
LV_SNAP="${LV_SNAP:-fio-snap}"
CLEANUP="${CLEANUP:-}"

PASS=0
FAIL=0
SKIP=0
ROWS_DONE=0
ROWS_FAILED=0
MOUNTED=()
declare -A LAYER_SKIP_REASON=()

pass() { PASS=$((PASS + 1)); printf '  [pass] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  [skip] %s\n' "$*"; }

summary() {
  printf '  [info] 完成 %s 个 cell（失败 %s），CSV=%s\n' "$ROWS_DONE" "$ROWS_FAILED" "$OUT"
  if [ "$KIND_BACKEND" = "1" ]; then
    printf '  [info] 口径：本机为 loop + 稀疏文件后端（%s），数字**不得**作为性能/容量评审依据\n' \
      "KIND_BACKEND=1"
  fi
  printf 'SUMMARY PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
  if [ "$ROWS_DONE" -eq 0 ]; then
    printf '  FAIL: 没有任何 cell 真正跑成功（全部 SKIP 不等于通过）\n'
    exit 1
  fi
  exit 0
}

# ---------------------------------------------------------------- PREP / 清理
do_prep() {
  command -v mkfs.xfs >/dev/null 2>&1 || { fail "PREP 需要 mkfs.xfs（apt install xfsprogs）"; return 1; }
  vgs "$VG" >/dev/null 2>&1 || { fail "PREP: VG $VG 不存在"; return 1; }
  if [ -z "$M_THICK" ] || [ -z "$M_THIN" ] || [ -z "$M_SNAP" ]; then
    fail "PREP: 必须同时给出 M_THICK/M_THIN/M_SNAP 三个挂载点"
    return 1
  fi

  lvremove -y "$VG/$LV_SNAP" >/dev/null 2>&1 || true
  lvremove -y "$VG/$LV_THIN" >/dev/null 2>&1 || true
  lvremove -y "$VG/$LV_THICK" >/dev/null 2>&1 || true

  printf '== PREP：在 %s/%s 上建 thick/thin/snapshot 三层目标\n' "$VG" "$POOL"
  lvcreate -y -L "$THICK_SIZE" -n "$LV_THICK" "$VG" >/dev/null || { fail "PREP: 建 thick LV 失败"; return 1; }
  mkfs.xfs -f -q "/dev/$VG/$LV_THICK" || { fail "PREP: mkfs thick 失败"; return 1; }
  mkdir -p "$M_THICK"
  mount "/dev/$VG/$LV_THICK" "$M_THICK" || { fail "PREP: mount thick 失败"; return 1; }
  MOUNTED+=("$M_THICK")
  pass "PREP thick LV ${THICK_SIZE} 挂到 $M_THICK"

  lvcreate -y -V "$THIN_SIZE" -T "$VG/$POOL" -n "$LV_THIN" >/dev/null || { fail "PREP: 建 thin LV 失败"; return 1; }
  mkfs.xfs -f -q "/dev/$VG/$LV_THIN" || { fail "PREP: mkfs thin 失败"; return 1; }
  mkdir -p "$M_THIN"
  mount "/dev/$VG/$LV_THIN" "$M_THIN" || { fail "PREP: mount thin 失败"; return 1; }
  MOUNTED+=("$M_THIN")
  pass "PREP thin LV ${THIN_SIZE} 挂到 $M_THIN"

  # 快照卷与源卷 UUID 相同：XFS 必须 nouuid，否则 mount 直接拒绝。
  # 另：lvcreate -s 建出的薄快照带 ACTIVATION_SKIP 标志（lvs attr 末位 k），
  # 光 lvchange -ay 会被跳过（"ACTIVATION_SKIP flag set ... skipping activation"），
  # 必须 -K/--ignoreactivationskip 才会真正建出 /dev/<vg>/<lv>。
  lvcreate -y -s -n "$LV_SNAP" "$VG/$LV_THIN" >/dev/null || { fail "PREP: 建快照失败"; return 1; }
  lvchange -ay -K "$VG/$LV_SNAP" >/dev/null 2>&1 || { fail "PREP: 激活快照失败（需 -ay -K）"; return 1; }
  mkdir -p "$M_SNAP"
  mount -o nouuid "/dev/$VG/$LV_SNAP" "$M_SNAP" || { fail "PREP: mount 快照失败（XFS 需 nouuid）"; return 1; }
  MOUNTED+=("$M_SNAP")
  pass "PREP 快照卷挂到 $M_SNAP（nouuid）"
  return 0
}

do_cleanup() {
  local m
  for m in "${MOUNTED[@]:-}"; do
    [ -n "$m" ] || continue
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
  done
  if [ "$PREP" = "1" ]; then
    lvremove -y "$VG/$LV_SNAP" >/dev/null 2>&1 || true
    lvremove -y "$VG/$LV_THIN" >/dev/null 2>&1 || true
    lvremove -y "$VG/$LV_THICK" >/dev/null 2>&1 || true
  fi
}

if [ "$PREP" = "1" ]; then
  CLEANUP="${CLEANUP:-1}"
  trap 'do_cleanup' EXIT
fi

# ---------------------------------------------------------------- 层可用性
is_mountpoint() { mountpoint -q "$1" 2>/dev/null; }

# 承载 PV 的块设备绝不能裸写：会覆盖 LVM 元数据，直接毁 VG。
is_pv() {
  local dev="$1" p
  command -v pvs >/dev/null 2>&1 || return 1
  while read -r p; do
    [ -n "$p" ] || continue
    [ "$(readlink -f "$p")" = "$(readlink -f "$dev")" ] && return 0
  done < <(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ')
  return 1
}

layer_available() {
  local layer="$1" reason=""
  case "$layer" in
    raw)
      if [ -z "$RAW" ]; then reason="RAW 未设置"
      elif [ ! -b "$RAW" ]; then reason="RAW=$RAW 不是块设备"
      elif is_pv "$RAW"; then reason="RAW=$RAW 承载 PV，裸写会破坏 LVM 元数据（拒绝）"
      fi ;;
    thick) [ -n "$M_THICK" ] || reason="M_THICK 未设置"
           [ -n "$reason" ] || is_mountpoint "$M_THICK" || reason="M_THICK=$M_THICK 不是挂载点" ;;
    thin)  [ -n "$M_THIN" ] || reason="M_THIN 未设置"
           [ -n "$reason" ] || is_mountpoint "$M_THIN" || reason="M_THIN=$M_THIN 不是挂载点" ;;
    thin-snap) [ -n "$M_SNAP" ] || reason="M_SNAP 未设置"
           [ -n "$reason" ] || is_mountpoint "$M_SNAP" || reason="M_SNAP=$M_SNAP 不是挂载点" ;;
    *) reason="未知层 $layer" ;;
  esac
  if [ -n "$reason" ]; then
    LAYER_SKIP_REASON["$layer"]="$reason"
    skip "层 $layer 不参与本轮：$reason"
    return 1
  fi
  return 0
}

want_layer() {
  case ",$LAYERS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- 单 cell
# p99 单位：fio>=3 的 JSON 只有 `clat_ns`（纳秒）；老版本是 `clat`（微秒）。
p99_ns_of() {
  local json="$1" dir="$2" v
  v=$(jq -r --arg d "$dir" '.jobs[0][$d].clat_ns.percentile."99.000000" // empty' <<<"$json" 2>/dev/null || true)
  if [ -n "$v" ] && [ "$v" != "null" ]; then printf '%s' "$v"; return 0; fi
  v=$(jq -r --arg d "$dir" '.jobs[0][$d].clat.percentile."99.000000" // empty' <<<"$json" 2>/dev/null || true)
  if [ -n "$v" ] && [ "$v" != "null" ]; then
    # 老格式单位是微秒，换算成纳秒后统一出口
    awk "BEGIN{printf \"%.0f\", $v*1000}"
    return 0
  fi
  return 1
}

run_fio() {
  local layer="$1" bs="$2" qd="$3" rw="$4" target="$5" label="${6:-}"
  [ -n "$label" ] || label="$layer"
  local name="${label}-${rw}-bs${bs}-qd${qd}" dir json rc iops bw p99_ns p99_ms bw_mb
  case "$rw" in
    *read*) dir=read ;;
    *)      dir=write ;;
  esac

  json=$("$FIO_BIN" --name="$name" --filename="$target" --direct=1 --bs="$bs" --iodepth="$qd" \
    --rw="$rw" --ioengine=libaio --numjobs=1 --size="$SIZE" --runtime="$RUNTIME" --time_based \
    --group_reporting --output-format=json 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    fail "$name 运行失败（rc=$rc，无输出）"
    ROWS_FAILED=$((ROWS_FAILED + 1))
    return 1
  fi
  if [ -n "$JSONDIR" ]; then
    mkdir -p "$JSONDIR"
    printf '%s' "$json" >"$JSONDIR/$name.json"
  fi
  if ! jq -e '.jobs[0]' >/dev/null 2>&1 <<<"$json"; then
    fail "$name JSON 不可解析（缺 .jobs[0]）"
    ROWS_FAILED=$((ROWS_FAILED + 1))
    return 1
  fi

  iops=$(jq -r --arg d "$dir" '.jobs[0][$d].iops // 0' <<<"$json" 2>/dev/null || echo 0)
  bw=$(jq -r --arg d "$dir" '.jobs[0][$d].bw // 0' <<<"$json" 2>/dev/null || echo 0)  # KiB/s
  if ! p99_ns=$(p99_ns_of "$json" "$dir"); then
    fail "$name 取不到 $dir 的 p99"
    ROWS_FAILED=$((ROWS_FAILED + 1))
    return 1
  fi

  bw_mb=$(awk "BEGIN{printf \"%.2f\", $bw/1024}")
  p99_ms=$(awk "BEGIN{printf \"%.3f\", $p99_ns/1000000}")

  local mode="fs"
  [ "$layer" = "raw" ] && mode="direct"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$label" "$bs" "$qd" "$mode" "$rw" "$iops" "$bw_mb" "$p99_ms" >>"$OUT"
  ROWS_DONE=$((ROWS_DONE + 1))

  # 判据：被测方向的三个量都必须 > 0
  local bad=""
  awk "BEGIN{exit !($iops > 0)}" || bad="$bad iops=$iops"
  awk "BEGIN{exit !($bw > 0)}" || bad="$bad bw=$bw"
  awk "BEGIN{exit !($p99_ns > 0)}" || bad="$bad p99=$p99_ns"
  if [ -n "$bad" ]; then
    fail "$name 采集值不合法：$bad（读到 0 说明取值字段/方向错了，不是「性能为 0」）"
    ROWS_FAILED=$((ROWS_FAILED + 1))
    return 1
  fi
  pass "$name iops=${iops} bw=${bw_mb}MB/s p99=${p99_ms}ms"
  return 0
}

# ---------------------------------------------------------------- 主流程
printf '== fio 基线（runtime=%ss size=%s layers=%s bs=[%s] qd=[%s]）\n' \
  "$RUNTIME" "$SIZE" "$LAYERS" "$BS_LIST" "$QD_LIST"
command -v "$FIO_BIN" >/dev/null 2>&1 || { fail "找不到 fio（$FIO_BIN）"; summary; }
command -v jq >/dev/null 2>&1 || { fail "找不到 jq"; summary; }

if [ "$PREP" = "1" ]; then
  if ! do_prep; then summary; fi
fi

printf 'layer,bs,qd,mode,rw,iops,bw_mbps,clat_p99_ms\n' >"$OUT"

# 1）裸盘基线：direct 直写设备
if want_layer raw && layer_available raw; then
  for bs in $BS_LIST; do
    for qd in $QD_LIST; do
      run_fio raw "$bs" "$qd" randread  "$RAW"
      run_fio raw "$bs" "$qd" randwrite "$RAW"
    done
  done
fi

# 2）thick LV（线性映射 + XFS）
if want_layer thick && layer_available thick; then
  for bs in $BS_LIST; do
    for qd in $QD_LIST; do
      run_fio thick "$bs" "$qd" randread  "$M_THICK/fio"
      run_fio thick "$bs" "$qd" randwrite "$M_THICK/fio"
    done
  done
fi

# 3）thin LV：首写（新文件）与覆盖写（同一文件复写，池内 CoW）
if want_layer thin && layer_available thin; then
  for bs in $BS_LIST; do
    run_fio thin "$bs" "1" randwrite "$M_THIN/fio-first-$bs" thin-first   # 首写：每个 bs 一个新文件
    for qd in $QD_LIST; do
      run_fio thin "$bs" "$qd" randwrite "$M_THIN/fio-over-$bs" thin-over  # 覆盖写：与首写同一文件
    done
  done
fi

# 4）有快照时的写（写快照卷 ⇒ CoW 分配）
if want_layer thin-snap && layer_available thin-snap; then
  for bs in $BS_LIST; do
    for qd in $QD_LIST; do
      run_fio thin-snap "$bs" "$qd" randwrite "$M_SNAP/fio-snap"
    done
  done
fi

# 行数判据：表头之外的行必须等于成功 cell 数
lines=$(wc -l <"$OUT" | tr -d ' ')
expected=$((ROWS_DONE + 1))
if [ "$lines" -ne "$expected" ]; then
  fail "CSV 行数不符：期望 $expected（含表头），实际 $lines"
fi

# 首写/覆盖对比只做「记录」，不做门禁：
#   loop 后端上两者的差异主要来自宿主文件系统与页缓存，不能据此断言 thin CoW 损耗 ≤10%。
if [ "$KIND_BACKEND" = "1" ]; then
  printf '  [info] 首写/覆盖对比仅为记录：loop 后端不足以支撑「CoW 损耗 ≤10%%」的结论\n'
fi

summary
