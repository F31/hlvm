#!/usr/bin/env bash
# setup-kind-thinpool.sh —— 在隔离 kind 集群准备 TopoLVM 快照所需的 LVM thin pool
#
# 背景（ADR-006 §23.5 D2）：TopoLVM 的 CreateSnapshot **只支持 thin-pool 卷**。
# 隔离 kind 节点默认没有 lvm2、没有 VG/thin pool，/dev 是 tmpfs 且没有 udev。
#
# 【重要：kind 节点共享宿主内核的 loop 设备与 dm 设备】
#   三个 kind 节点是同一内核上的容器，losetup 绑定是内核全局的，各节点 /dev/loop*
#   又都预置存在 ⇒ 多节点各造一份同名 VG 会互相扫到 PV、LVM 元数据串扰，
#   vgs 甚至读不出来（本轮实测：4 个 loop 绑定 / 3 个 PV UUID / vgs 为空）。
#   因此本脚本**只在一个节点**建 VG，且 lvm.conf 的 filter 精确到该节点的
#   loop 设备，不扫其他节点遗留的 PV。
#
# 仅用于隔离 POC 集群；**禁止在真机执行**。幂等：重复执行不重建已有 VG。
#
# 用法（WSL 宿主上执行）：
#   KIND_NODE=hlvm-m15-20261113-worker bash setup-kind-thinpool.sh
#
# 变量：
#   KIND_NODE   必填；kind 节点容器名（只在此节点建 VG）
#   ALL_NODES   可选；清理时要遍历的全部节点名（空格分隔）
#   VG          默认 hlvm-poc-vg
#   POOL        默认 thinpool
#   IMG_SIZE    默认 24G（VG 后端稀疏文件；必须 > POOL_SIZE + 元数据开销）
#   POOL_SIZE   默认 16G（thin pool 大小）。必须足够容纳
#               PVC 2Gi + 快照 2Gi + 克隆 2Gi，否则
#               csi-provisioner 报 "no enough space left on VG: free=0"（overprovision-ratio=1.00）。
set -euo pipefail

KIND_NODE="${KIND_NODE:-}"
if [ -z "${KIND_NODE}" ]; then
  echo "FAIL: 必须显式指定 KIND_NODE（禁止默认操作未知节点）" >&2
  exit 1
fi
VG="${VG:-hlvm-poc-vg}"
POOL="${POOL:-thinpool}"
IMG_SIZE="${IMG_SIZE:-24G}"
POOL_SIZE="${POOL_SIZE:-16G}"

# ---- 阶段 1：在全部节点清理本 POC 自己造的 LVM 状态（不碰 K8s / 业务数据） ----
ALL_NODES="${ALL_NODES:-${KIND_NODE}}"
for n in ${ALL_NODES}; do
  docker exec -i "${n}" bash -s -- "${VG}" <<'CLEAN' 2>/dev/null || true
set -u
VG="$1"
vgchange -an "${VG}" >/dev/null 2>&1 || true
vgremove -ff -y "${VG}" >/dev/null 2>&1 || true
for l in $(losetup -a 2>/dev/null | grep 'hlvm-poc' | cut -d: -f1); do
  pvremove -ff -y "$l" >/dev/null 2>&1 || true
  losetup -d "$l" >/dev/null 2>&1 || true
done
rm -f /var/lib/hlvm-poc/disk0.img 2>/dev/null || true
rm -f /etc/lvm/archive/${VG}_* /etc/lvm/backup/${VG} 2>/dev/null || true
CLEAN
done

# ---- 阶段 2：只在目标节点重建，filter 精确限定 ----
docker exec -i "${KIND_NODE}" bash -s -- "${VG}" "${POOL}" "${IMG_SIZE}" "${POOL_SIZE}" <<'INNER'
set -euo pipefail
VG="$1"; POOL="$2"; IMG_SIZE="$3"; POOL_SIZE="$4"

echo "=== 1. lvm2 安装（Debian trixie，南大镜像；apt 代理 17890 已失效） ==="
if ! command -v lvm >/dev/null 2>&1; then
  printf 'Types: deb\nURIs: https://mirrors.nju.edu.cn/debian\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: https://mirrors.nju.edu.cn/debian-security\nSuites: trixie-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/debian.sources
  rm -f /etc/apt/apt.conf.d/*proxy* 2>/dev/null || true
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends lvm2 >/dev/null
fi
lvm version | head -2

echo "=== 2. loop 文件 → PV → VG → thin pool ==="
modprobe dm_thin_pool 2>/dev/null || true
modprobe loop 2>/dev/null || true
mkdir -p /var/lib/hlvm-poc
IMG=/var/lib/hlvm-poc/disk0.img
[ -f "${IMG}" ] || truncate -s "${IMG_SIZE}" "${IMG}"
LOOP=$(losetup -f --show "${IMG}" 2>/dev/null || true)
[ -n "${LOOP}" ] || { echo "FAIL: 无法分配 loop 设备" >&2; exit 1; }
if [ ! -b "${LOOP}" ]; then
  MINOR=$(echo "${LOOP}" | sed 's/.*loop//')
  mknod "${LOOP}" b 7 "${MINOR}" 2>/dev/null || true
fi

# kind 节点 /dev 是 tmpfs 且无 udev：必须关 udev_sync/udev_rules，
# 且 filter 只认本节点这一个 loop 设备，避免扫到其他节点共享内核的 PV。
mkdir -p /etc/lvm
cat > /etc/lvm/lvm.conf <<CONF
devices {
    dir = "/dev"
    scan = [ "/dev" ]
    filter = [ "a|${LOOP}$|", "r|.*|" ]
}
activation {
    udev_sync = 0
    udev_rules = 0
    verify_udev_operations = 0
}
global {
    use_lvmetad = 0
    locking_type = 1
}
CONF

pvcreate -y "${LOOP}" >/dev/null
vgcreate "${VG}" "${LOOP}" >/dev/null
# --zero n：tmpfs /dev 下 LVM wipe 找不到 dm 节点，必须禁用 zeroing
lvcreate --zero n -y -T -L "${POOL_SIZE}" -n "${POOL}" "${VG}" >/dev/null

echo "=== 3. 严格判据 ==="
ATTR=$(lvs --noheadings -o lv_attr "${VG}/${POOL}" 2>/dev/null | tr -d ' ' || true)
case "${ATTR}" in
  t*|T*) echo "THIN_POOL_OK ${VG}/${POOL} attr=${ATTR}" ;;
  *) echo "FAIL: ${VG}/${POOL} 不是 thin pool（attr=${ATTR:-空}）" >&2; exit 1 ;;
esac
VGNAME=$(vgs --noheadings -o vg_name "${VG}" 2>/dev/null | tr -d ' ')
[ "${VGNAME}" = "${VG}" ] || { echo "FAIL: vgs 读不到 ${VG}（读到 ${VGNAME:-空}）" >&2; exit 1; }
echo "VG_OK ${VGNAME} loop=${LOOP}"
vgs "${VG}" | tail -1
INNER
