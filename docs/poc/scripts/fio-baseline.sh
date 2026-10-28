#!/usr/bin/env bash
# fio-baseline.sh —— POC 性能基线实测（设计 §10 阶段 0 / add-poc-decision-gate §3）
#
# 对比：裸盘 / thick LV / thin LV（首写、覆盖写、有快照）/ XFS，多种 bs 与队列深度，关注 p99 延迟。
# 输出 IOPS / 带宽 / p99 到 CSV，供 ../poc-report.md §3 与 perf-baseline-report.md 回填。
# 须在 POC 节点本地执行（fio 直写块设备/挂载点）。假设值：覆盖写损耗 ≤10%（以实测为准）。
#
# 用法：bash fio-baseline.sh <raw-dev> <mount-thick> <mount-thin> <mount-thin-snap>
set -euo pipefail

RAW="${1:-/dev/sdb}"
M_THICK="${2:-/mnt/thick}"
M_THIN="${3:-/mnt/thin}"
M_SNAP="${4:-/mnt/thin-snap}"
OUT="fio-results.csv"
echo "layer,bs,qd,mode,rw,iops,bw_mbps,clat_p99_ms" > "$OUT"

run_fio() {
  local layer="$1" bs="$2" qd="$3" mode="$4" rw="$5" target="$6"
  local out
  out=$(fio --name="$layer-$rw" --filename="$target" --direct=1 --bs="$bs" --iodepth="$qd" \
    --rw="$rw" --ioengine=libaio --numjobs=1 --size=4G --runtime=60 --time_based \
    --group_reporting --output-format=json 2>/dev/null)
  local iops bw p99
  iops=$(echo "$out" | jq '.jobs[0].read.iops // .jobs[0].write.iops // 0')
  bw=$(echo "$out" | jq '.jobs[0].read.bw // .jobs[0].write.bw // 0')
  p99=$(echo "$out" | jq '.jobs[0].read.clat.percentile."99.000000" // .jobs[0].write.clat.percentile."99.000000" // 0')
  bw=$(awk "BEGIN{printf \"%.2f\", $bw/1024}")   # KB/s -> MB/s
  p99=$(awk "BEGIN{printf \"%.3f\", $p99/1000}")  # us -> ms
  echo "$layer,$bs,$qd,$mode,$rw,$iops,$bw,$p99" >> "$OUT"
  echo "[REC] $layer $rw bs=$bs qd=$qd -> iops=$iops bw=${bw}MB/s p99=${p99}ms"
}

# 1）裸盘基线（§3.1）
for bs in 4k 8k 64k 1M; do
  for qd in 1 8 32; do
    run_fio raw "$bs" "$qd" direct randread  "$RAW"
    run_fio raw "$bs" "$qd" direct randwrite "$RAW"
  done
done

# 2）thick LV（§3.2）
for bs in 4k 64k 1M; do
  for qd in 1 32; do
    run_fio thick "$bs" "$qd" fs randread  "$M_THICK/fio"
    run_fio thick "$bs" "$qd" fs randwrite "$M_THICK/fio"
  done
done

# 3）thin LV 首写 / 覆盖写（§3.2）
for bs in 4k 64k 1M; do
  for qd in 1 32; do
    run_fio thin "$bs" "$qd" fs randwrite "$M_THIN/fio-first"   # 首写
    run_fio thin "$bs" "$qd" fs randwrite "$M_THIN/fio-over"    # 覆盖写（损耗对比点）
  done
done

# 4）thin LV 有快照下的覆盖写（§3.2）
#    前提：对 M_THIN 所在 LV 已建快照并挂载到 M_SNAP（由外部准备）
for bs in 4k 64k; do
  for qd in 1 32; do
    run_fio thin-snap "$bs" "$qd" fs randwrite "$M_SNAP/fio-snap"
  done
done

echo "==== fio 完成，结果见 $OUT，填入 poc-report.md §3 / perf-baseline-report.md ===="
