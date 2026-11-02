#!/usr/bin/env bash
#
# 控制面初始化（只在 control-plane 节点执行一次，幂等）。
#
# 为什么不用 `kubeadm init` 一把梭：真实云主机上最常见的两个坑是
#   ① 云盘没挂好 / 系统盘被当数据盘，导致后面容量账对不上；
#   ② 控制面只有一个时，`--control-plane-endpoint` 留空即可，但一旦填了 DNS
#      而解析不通，kubelet 就永远 NotReady。
# 所以这里先做前置断言，再 init，最后打印 join 命令。
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.36}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CNI="${CNI:-flannel}"           # flannel | none（none 表示由你自备 CNI）
APISERVER_EXTRA_SANS="${APISERVER_EXTRA_SANS:-}"

die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "需要用 root 执行（sudo $0）"

step "1/5 前置检查"
for c in kubeadm kubelet kubectl containerd; do
  command -v "$c" >/dev/null 2>&1 || die "缺少 $c：先执行 cloud-init.yaml（或手工装）"
done
kubeadm version -o short

swap_line="$(swapon --show --noheadings || true)"
[ -z "${swap_line}" ] || die "swap 仍启用（${swap_line}）：kubelet 会拒绝启动，先 swapoff -a 并注释 /etc/fstab"

cg="$(stat -fc %T /sys/fs/cgroup)"
[ "${cg}" = "cgroup2fs" ] || die "cgroup 不是 v2（当前 ${cg}）：本项目按 cgroup v2 验证，v1 下设备插件行为不同"

systemctl is-active --quiet containerd || die "containerd 未运行"
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
  || die "containerd 未用 systemd cgroup driver（git 版本差异大，请按 cloud-init.yaml 重生成 config.toml）"

modprobe dm_thin_pool
grep -qw dm_thin_pool /proc/modules || die "dm_thin_pool 未加载：真实 LV thin pool 无法验证"

step "2/5 kubeadm init"
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "已初始化过（/etc/kubernetes/admin.conf 存在），跳过 init"
else
  args=(init
    --pod-network-cidr="${POD_CIDR}"
    --cri-socket=unix:///run/containerd/containerd.sock
    --kubernetes-version="stable-${K8S_MINOR}"
  )
  if [ -n "${APISERVER_EXTRA_SANS}" ]; then
    args+=(--apiserver-cert-extra-sans="${APISERVER_EXTRA_SANS}")
  fi
  kubeadm "${args[@]}" | tee /root/kubeadm-init.log
fi

step "3/5 等待 API 就绪"
export KUBECONFIG=/etc/kubernetes/admin.conf
for i in $(seq 1 60); do
  kubectl get --raw /readyz >/dev/null 2>&1 && break
  sleep 3
done
kubectl get --raw /readyz >/dev/null 2>&1 || die "API 90s 内未就绪：journalctl -u kubelet -n 80"
kubectl version

step "4/5 安装 CNI（${CNI}）"
case "${CNI}" in
  flannel)
    # 与 POD_CIDR 绑定：flannel 默认 10.244.0.0/16，改过 CIDR 就必须同步改它的 ConfigMap。
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    if [ "${POD_CIDR}" != "10.244.0.0/16" ]; then
      echo "注意：POD_CIDR=${POD_CIDR}，请确认 kube-flannel 的 net-conf.json 与之匹配"
    fi
    ;;
  none) echo "跳过 CNI 安装（由你自备）" ;;
  *) die "未知 CNI=${CNI}（flannel|none）" ;;
esac

step "5/5 导出 kubeconfig 并打印 join 命令"
TARGET_USER="${SUDO_USER:-root}"
if [ "${TARGET_USER}" != "root" ]; then
  install -d -o "${TARGET_USER}" -g "$(id -gn "${TARGET_USER}")" "/home/${TARGET_USER}/.kube"
  install -o "${TARGET_USER}" -g "$(id -gn "${TARGET_USER}")" -m 600 \
    /etc/kubernetes/admin.conf "/home/${TARGET_USER}/.kube/config"
  echo "已写入 /home/${TARGET_USER}/.kube/config"
fi

echo
echo "--- worker 加入命令（token 有效期 24h，过期用 kubeadm token create --print-join-command 重取）---"
kubeadm token create --print-join-command
echo
echo "下一步：在 worker 上执行 join-worker.sh，然后回到本机跑 post-install.sh"
