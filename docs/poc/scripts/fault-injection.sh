#!/usr/bin/env bash
# fault-injection.sh —— POC 故障注入验证（设计 §9 / add-poc-decision-gate §4）
#
# 覆盖：thinpool 打满(§4.1/§9.1)、坏盘热拔(§4.2/§9.3)、节点断电恢复(§4.3/§9.2)、
#       lvextend 参数与 out-of-data-space 恢复核实(§4.4)。
# 须在 POC 节点执行，部分步骤为物理/虚拟化操作，脚本仅提供命令框架与观察点。
# 结果记录到 ../poc-report.md §4。
set -uo pipefail

VG="${VG:-vg-pool}"           # 待测 VG
POOL="${POOL:-thinpool}"      # thin pool LV 名
DEV="${DEV:-/dev/sdc}"        # 用于热拔的待测盘（by-id 推荐）
NODE="${NODE:-node-1}"

echo "==== 4.1 thinpool 打满（§9.1）===="
# 突发写入打满 pool（用 dd/fio 灌满 thin LV，或 lvextend 到超分配上限）
fio --name=fill --filename=/mnt/thin/fill --direct=1 --bs=1M --iodepth=32 --rw=write \
  --ioengine=libaio --size=100% --runtime=600 --time_based --group_reporting 2>/dev/null &
FIO_PID=$!
# 观察前兆（dmeventd 扩容、容量告警）与 IO 行为
watch -n 5 "lvs -a $VG; dmesg | tail -5"
# 记录：dmeventd 扩容时延、成功率、IO 是否 hang/报错、文件系统可恢复性（XFS 修复需先停写+备份）
kill $FIO_PID 2>/dev/null || true
echo "[OBSERVE] 4.1 记录 dmeventd 扩容时延/成功率/IO 行为/可恢复性 -> poc-report.md §4.1"

echo "==== 4.2 坏盘热拔（§9.3）===="
# 注入：从系统移除块设备（虚拟化平台 detach，或测试机 echo delete）
#   echo 1 > /sys/block/$(basename "$DEV")/device/delete
echo "[INJECT] 热拔 $DEV（pooled 与 per-disk 各验证一块）"
# 观察：Critical 告警文案准确；无 RAID 时 pooled 布局该 VG 全部 LV 不可恢复；
#       经审批 vgreduce --removemissing（--force 仅确认后）。
echo "[OBSERVE] 4.2 记录告警准确性与剧本可执行性 -> poc-report.md §4.2"

echo "==== 4.3 节点断电与恢复（§9.2）===="
# 物理/虚拟化断电 $NODE；恢复后观察：失联判定(默认 30min) -> StorageNodeOps(isolate)
#   + 存储故障标签；多副本重建工单；旧节点恢复不自动删残留 LV（隔离期 7d）。
echo "[INJECT] 强制断电 $NODE"
echo "[OBSERVE] 4.3 记录失联判定/重建流程/隔离期行为 -> poc-report.md §4.3"

echo "==== 4.4 lvextend 参数与 out-of-data-space 恢复核实（Runbook 依据）===="
# 核实扩容命令与 dmeventd 自动扩容参数（设计 §3.3）
echo "## 手动扩池（dmeventd 之外的兜底）："
echo "   lvextend -L +<size> $VG/$POOL"
echo "## 扩元数据（metadata 打满时）："
echo "   lvextend --poolmetadatasize +<size> $VG/$POOL"
echo "## thin_pool_autoextend_* 行为（lvm.conf activation）："
echo "   thin_pool_autoextend_threshold / thin_pool_autoextend_percent"
echo "## out-of-data-space 内核行为：pool 转只读/错误返回 -> 先扩容再恢复 -> thin_check -> XFS 修复(业务停写+先备份)"
lvs -a "$VG" 2>/dev/null || true
echo "[OBSERVE] 4.4 记录参数准确性与恢复步骤 -> poc-report.md §4.4 / runbook"

echo "==== fault-injection 脚本就绪（物理注入步骤由人工在 POC 环境执行）===="
