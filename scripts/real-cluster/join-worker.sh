#!/usr/bin/env bash
#
# worker 加入集群（每台 worker 执行一次，幂等）。
#
# 用法：
#   sudo ./join-worker.sh "<kubeadm join ... 完整命令>"
# 或者在控制面把命令写进文件后：sudo ./join-worker.sh --from-file /tmp/join.sh
#
# 幂等：已加入（/etc/kubernetes/kubelet.conf 存在）就直接退出，不会重复 join 造成
# 证书/配置错乱——重跑整个部署流程时这一点很关键。
set -euo pipefail

die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "需要用 root 执行（sudo $0）"

step "1/3 前置检查"
for c in kubeadm kubelet containerd; do
  command -v "$c" >/dev/null 2>&1 || die "缺少 $c：先执行 cloud-init.yaml"
done
systemctl is-active --quiet containerd || die "containerd 未运行"
[ -z "$(swapon --show --noheadings || true)" ] || die "swap 仍启用：先 swapoff -a 并注释 /etc/fstab"
[ "$(stat -fc %T /sys/fs/cgroup)" = "cgroup2fs" ] || die "cgroup 不是 v2"
modprobe dm_thin_pool
grep -qw dm_thin_pool /proc/modules || die "dm_thin_pool 未加载"

if [ -f /etc/kubernetes/kubelet.conf ]; then
  step "已加入过（/etc/kubernetes/kubelet.conf 存在），跳过 join"
  systemctl status kubelet --no-pager | head -5 || true
  exit 0
fi

# 参数解析：支持直接传命令串，或从文件读（避免 shell 引号被运维工具吃掉）
JOIN_CMD=""
if [ "${1:-}" = "--from-file" ]; then
  [ -f "${2:-}" ] || die "--from-file 需要存在的文件路径"
  JOIN_CMD="$(cat "$2")"
else
  JOIN_CMD="$*"
fi
[ -n "${JOIN_CMD}" ] || die "缺少 join 命令。在控制面执行：kubeadm token create --print-join-command"

# 显式指定 cri-socket：containerd 与 docker 并存时 kubeadm 会因检测到多个 endpoint 直接失败。
case "${JOIN_CMD}" in
  *--cri-socket*) ;;
  *) JOIN_CMD="${JOIN_CMD} --cri-socket=unix:///run/containerd/containerd.sock" ;;
esac

step "2/3 kubeadm join"
# shellcheck disable=SC2086  # join 命令本身需要按空格分词
eval "${JOIN_CMD}"

step "3/3 等待 kubelet 就绪"
for i in $(seq 1 40); do
  if systemctl is-active --quiet kubelet; then break; fi
  sleep 3
done
systemctl is-active --quiet kubelet || die "kubelet 未运行：journalctl -u kubelet -n 80"
echo "kubelet 已运行；请在控制面确认该节点 Ready：kubectl get nodes"
