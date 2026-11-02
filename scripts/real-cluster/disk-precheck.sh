#!/usr/bin/env bash
#
# 数据盘预检（**只读**，不分区、不建 PV、不格式化）。
#
# 在每台 worker 上跑，或在控制面用 post-install.sh 批量 ssh 跑。
# 目的：在跑 M15 之前回答一个问题——「这块云盘能不能被 hlvm 当裸块设备纳管」。
# 常见的不合格原因（都会让后面的 LVM 相位以难以归因的方式失败）：
#   - 云盘被云厂商默认格式化并挂到 /mnt：blkid 有签名 + 已挂载；
#   - 云盘被做成 swap / 被 LVM 或 RAID 占用；
#   - 误把系统盘当数据盘（容量账会离谱）。
set -uo pipefail

die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

MIN_GIB="${MIN_GIB:-20}"

command -v lsblk >/dev/null || die "缺少 lsblk"
echo "=== 节点: $(hostname) ==="

echo
echo "--- 1) cgroup / 内核模块（LVM thin 前提）---"
echo "cgroup:  $(stat -fc %T /sys/fs/cgroup)"
if grep -qw dm_thin_pool /proc/modules; then
  echo "dm_thin_pool: 已加载"
else
  warn "dm_thin_pool 未加载（modprobe dm_thin_pool 后再验）"
fi
if command -v udevadm >/dev/null; then echo "udev: 存在"; else warn "udev 不存在：/dev/disk/by-id 会缺失"; fi

echo
echo "--- 2) 块设备清单 ---"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,ROTA,MODEL

echo
echo "--- 3) 候选数据盘（可纳管）---"
# 判据：整盘（type=disk）、整盘及其分区都无文件系统签名、不参与系统挂载、容量 >= MIN_GIB。
candidates=0
while read -r dev; do
  [ -n "${dev}" ] || continue
  [ "$(lsblk -dno TYPE "${dev}" 2>/dev/null)" = "disk" ] || continue

  bytes="$(blockdev --getsize64 "${dev}" 2>/dev/null || echo 0)"
  [ "${bytes}" -ge $((MIN_GIB * 1024 * 1024 * 1024)) ] || continue
  size_gib=$((bytes / 1024 / 1024 / 1024))

  # 该盘（含分区）上的挂载点：命中系统目录就说明是系统盘
  mps="$(lsblk -rno MOUNTPOINT "${dev}" 2>/dev/null | grep -v '^$' || true)"
  if printf '%s\n' "${mps}" | grep -qE '^(/|/boot|/var|/home|/usr|\[SWAP\])'; then
    echo "  SKIP ${dev} (${size_gib}GiB)：参与系统挂载（$(printf '%s' "${mps}" | tr '\n' ' ')）"
    continue
  fi
  if [ -n "${mps}" ]; then
    warn "${dev} (${size_gib}GiB) 已挂载到 $(printf '%s' "${mps}" | tr '\n' ' ')：需先 umount"
    continue
  fi

  # 整盘或其分区的签名（云厂商常预格式化为 ext4）
  sigs="$(lsblk -rno FSTYPE "${dev}" 2>/dev/null | grep -v '^$' || true)"
  if [ -n "${sigs}" ]; then
    warn "${dev} (${size_gib}GiB) 有文件系统签名 '$(printf '%s' "${sigs}" | tr '\n' ' ')':hlvm 会判 occupiedBy=filesystem 并拒绝纳管（需 wipefs -a）"
    continue
  fi

  byid="$(ls -l /dev/disk/by-id/ 2>/dev/null \
    | awk -v d="../../$(basename "${dev}")" '$NF==d {print $9}' | head -1)"
  if [ -n "${byid}" ]; then
    echo "  OK   ${dev}  ${size_gib}GiB  by-id=${byid}"
  else
    warn "${dev} (${size_gib}GiB) 无 /dev/disk/by-id 条目：设备 ID 会退化为 dev-$(basename "${dev}")，6.2 的 by-id 断言将不成立"
  fi
  candidates=$((candidates + 1))
done < <(lsblk -dpno NAME 2>/dev/null)

echo
if [ "${candidates}" -eq 0 ]; then
  warn "本节点没有可纳管的数据盘：拓扑/容量类相位会因容量为 0 而排除该节点"
else
  echo "可纳管数据盘: ${candidates} 块"
fi

echo
echo "--- 4) /mnt、/data 类挂载（确认数据盘没被自动挂载）---"
findmnt -Rno TARGET,SOURCE,FSTYPE 2>/dev/null | grep -E '^/(mnt|data|var/lib/(hlvm|lvm))' || echo "（无 /mnt、/data 类挂载）"
