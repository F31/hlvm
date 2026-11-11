#!/usr/bin/env bash
# lvmd-lock-verify.sh —— lvmd 与宿主 lvm 的「同一份二进制 + 同一把锁」验证（ADR-006 §10.6 / 设计 §5.3）
#
# 与 concurrency-lvmd-test.sh 的分工：
#   - 本脚本**不需要 agent 部署**，只验证 lvmd 侧机制：lvmd 的 lvm 子进程确实落在宿主命名空间里，
#     用的是宿主 /sbin/lvm 与宿主 /run/lock/lvm（静态身份判据），再做一轮宿主 vs 容器内并发实测。
#   - concurrency-lvmd-test.sh 需要 agent + lvmd 同时在位，压的是业务级并发与元数据一致性。
#
# 用法：bash lvmd-lock-verify.sh <node-ip> [lvmd-task-id] [vg-name]
#   不传 lvmd-task-id 时按 lvmd 进程 PID 反查 containerd task。
set -uo pipefail

NODE="${1:?用法: bash lvmd-lock-verify.sh <node-ip> [lvmd-task-id] [vg-name]}"
TASK="${2:-}"
VG="${3:-hlvm-lvmd-vg-153}"
KEY="${M15_SSH_KEY:-$HOME/.ssh/hlvm-real}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

remote() { ssh -n $SSH_OPTS -i "$KEY" "root@${NODE}" "$1"; }

# lvmd 进程 PID → containerd task id（两者在 hostPID 下同 PID）
if [ -z "$TASK" ]; then
  TASK=$(remote "P=\$(pgrep -x lvmd | head -1); /usr/bin/ctr -n k8s.io tasks ls | awk -v p=\"\$P\" '\$2==p{print \$1}'")
fi
[ -n "$TASK" ] || { echo "FAIL: 找不到 lvmd 进程/task（lvmd 是否已部署？）"; exit 1; }
echo "lvmd task = $TASK   vg = $VG"

NS="nsenter -m -u -i -n -p -t 1"
pod() { remote "/usr/bin/ctr -n k8s.io tasks exec --exec-id chk\$RANDOM $TASK /usr/bin/$NS $1"; }

echo
echo "=== 1. /run/lock/lvm 身份（宿主 vs 容器内 nsenter）==="
H=$(remote "stat -c '%d %i' /run/lock/lvm")
P=$(pod "bin/stat -c '%d %i' /run/lock/lvm")
echo "host : $H"
echo "pod  : $P"
[ "$H" = "$P" ] && echo "PASS: 同一锁目录" || { echo "FAIL: 锁目录不同，互斥不成立"; exit 1; }

echo
echo "=== 2. lvm 二进制身份 ==="
HL=$(remote "sha256sum /sbin/lvm | cut -c1-32")
PL=$(pod "usr/bin/sha256sum /sbin/lvm | cut -c1-32")
echo "host : $HL"
echo "pod  : $PL"
[ "$HL" = "$PL" ] && echo "PASS: 同一 lvm 二进制" || { echo "FAIL: 二进制不同"; exit 1; }

echo
echo "=== 3. 宿主 vs 容器内并发 lvcreate（各 5 个 64M）==="
remote "set -u
VG=$VG; N=5
for n in \$(seq 1 \$N); do /sbin/lvremove -y \$VG/ckhost\$n >/dev/null 2>&1; /usr/bin/ctr -n k8s.io tasks exec --exec-id pre\$n $TASK /usr/bin/$NS /sbin/lvremove -y \$VG/ckpod\$n >/dev/null 2>&1; done
for n in \$(seq 1 \$N); do
  ( /sbin/lvcreate -y -n ckhost\$n -L 64M \$VG >/tmp/ck-h-\$n.log 2>&1; echo \"host\$n rc=\$?\" > /tmp/ck-h-\$n.rc ) &
  ( /usr/bin/ctr -n k8s.io tasks exec --exec-id run\$n $TASK /usr/bin/$NS /sbin/lvcreate -y -n ckpod\$n -L 64M \$VG >/tmp/ck-p-\$n.log 2>&1; echo \"pod\$n rc=\$?\" > /tmp/ck-p-\$n.rc ) &
done
wait
cat /tmp/ck-h-*.rc /tmp/ck-p-*.rc
echo -n 'created: ckhost='; /sbin/lvs --noheadings -o lv_name \$VG | grep -c ckhost
echo -n '         ckpod ='; /sbin/lvs --noheadings -o lv_name \$VG | grep -c ckpod
echo -n 'bad logs: '; grep -il 'lock\|fail\|error' /tmp/ck-h-*.log /tmp/ck-p-*.log 2>/dev/null | wc -l
for n in \$(seq 1 \$N); do /sbin/lvremove -y \$VG/ckhost\$n >/dev/null 2>&1; /usr/bin/ctr -n k8s.io tasks exec --exec-id clr\$n $TASK /usr/bin/$NS /sbin/lvremove -y \$VG/ckpod\$n >/dev/null 2>&1; done
echo -n 'remaining: '; /sbin/lvs --noheadings -o lv_name \$VG | grep -c ck || true
"

echo
echo "注：本脚本证明「同一把锁 + 并发不出错」，不度量锁等待时序；只覆盖宿主 lvm 视图。"
echo "    agent 真实调用栈的进程级判据见 agent-lvmd-lock-verify.sh。"
echo "    §5.3 写路径门禁见 host-wrapper-gate.sh：chroot /host 不切 IPC NS 会挂死，"
echo "    须用 nsenter -t 1 -m -u -i -n -p --（ADR-006 §11 真机实测）。"
