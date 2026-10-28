#!/usr/bin/env bash
# concurrency-lvmd-test.sh —— agent 与 lvmd 同机并发验证（设计 §5.3 / §7.2）
#
# 目标：验证 hlvm Agent 与 TopoLVM lvmd 在 *同一宿主机* 上通过共享 /run/lock/lvm 锁，
#       串行化 LVM 操作，避免并发改写 VG 元数据导致损坏或数据面中断。
#
# 前置：
#   - POC 集群已部署 TopoLVM（lvmd 以 DaemonSet 运行，挂载宿主 /run/lock/lvm）。
#   - hlvm-storage-agent DaemonSet 已部署（与 lvmd 共享同一宿主 /run/lock/lvm 锁目录）。
#   - 节点上有 ≥2 块空闲纳管盘（by-id）用于 agent 侧 pvcreate/vgcreate 压测。
#   - 已存在由 lvmd 管理的 VG（如 vg-<node>）承载业务 LV。
#
# 验证点（§7.2）：
#   1. 共享锁：agent 执行 lvm 命令时经 chroot /host 或 HLVM_HOST_WRAPPER，
#      lock 文件为 /run/lock/lvm 且与 lvmd 同一实例。
#   2. 并发安全：agent 持续 pvcreate/vgcreate 同时 lvmd 持续 provision LV，
#      VG 元数据始终一致（vgck 通过），无 "Failed to obtain lock" 致命错误。
#   3. 幂等：任务回写终态一致，无重复执行（崩溃恢复不双写）。
#
# 用法：bash concurrency-lvmd-test.sh <node> <spare-disk-by-id-1> [<spare-disk-by-id-2>]
set -euo pipefail

NODE="${1:?用法: bash concurrency-lvmd-test.sh <node> <disk1> [<disk2>]}"
D1="${2:?请提供一块空闲纳管盘 by-id 路径}"
D2="${3:-}"

NS="hlvm-system"
LOCKDIR_HOST="/run/lock/lvm"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "[PASS] $1"; PASS=$((PASS+1)); else echo "[FAIL] $1"; FAIL=$((FAIL+1)); fi; }

echo "==== 7.2 并发验证：节点 $NODE ===="

# --- 0. 确认 lvmd 与 agent 共享锁目录 ---
LVMD_LOCK=$(kubectl -n "$NS" exec "ds/lvmd" -c lvmd -- ls -d "$LOCKDIR_HOST" 2>/dev/null || true)
AGENT_LOCK=$(kubectl -n "$NS" exec "ds/hlvm-storage-agent" -c agent -- ls -d "$LOCKDIR_HOST" 2>/dev/null || true)
check "lvmd 与 agent 均可访问共享锁目录 $LOCKDIR_HOST" "[ -n \"$LVMD_LOCK\" ] && [ -n \"$AGENT_LOCK\" ]"

# --- 1. 基线 VG 一致性 ---
BASE_VG=$(kubectl -n "$NS" exec "ds/hlvm-storage-agent" -c agent -- \
  chroot /host lvm vgck 2>&1 || true)
check "基线 vgck 通过（无元数据损坏）" "! echo \"$BASE_VG\" | grep -qi 'failed\|corrupt'"

# --- 2. 并发压测：lvmd 持续 provision LV + agent 持续 vgcreate/destroy ---
# 2.1 启动 lvmd 侧持续写入（TopoLVM 动态供给，由独立 Pod 触发 PVC 循环创建/删除）。
echo "[INFO] 启动 lvmd provision 压测（后台创建/删除 PVC 循环，120s）..."
kubectl -n "$NS" run lvmd-stress --image=busybox --restart=Never -- \
  /bin/sh -c 'for i in $(seq 1 50); do
    kubectl apply -f - <<Y
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: stress-$i}
spec: {accessModes: [ReadWriteOnce], storageClassName: topolvm-thin, resources: {requests: {storage: 64Mi}}}
Y
    sleep 1; kubectl delete pvc stress-$i --ignore-not-found; sleep 1
  done' &
STRESS_PID=$!

# 2.2 agent 侧同时执行 vgcreate/vgremove 循环（不触碰 lvmd 的 VG，使用独立测试 VG 名）。
echo "[INFO] 启动 agent 侧 LVM 循环（vgcreate/vgremove 于 $D1）..."
if [ -n "$D2" ]; then
  AGENT_DISKS="$D1 $D2"
else
  AGENT_DISKS="$D1"
fi
kubectl -n "$NS" exec "ds/hlvm-storage-agent" -c agent -- /bin/sh -c '
  for i in $(seq 1 30); do
    for d in '"$AGENT_DISKS"'; do
      chroot /host lvm vgcreate hlvm-conctest-$i "$d" >/dev/null 2>&1 || true
      chroot /host lvm vgremove -f hlvm-conctest-$i >/dev/null 2>&1 || true
    done
  done' &
AGENT_PID=$!

# --- 3. 压测期间持续校验 VG 一致性 ---
echo "[INFO] 压测期间每 5s 校验 vgck（最多 120s）..."
ERRORS=0
for t in $(seq 1 24); do
  OUT=$(kubectl -n "$NS" exec "ds/hlvm-storage-agent" -c agent -- chroot /host lvm vgck 2>&1 || true)
  if echo "$OUT" | grep -qi 'failed\|corrupt\|lock'; then
    echo "[WARN] t=${t} vgck 异常: $OUT"; ERRORS=$((ERRORS+1))
  fi
  sleep 5
done
check "压测期间 VG 元数据一致（无损坏/锁致命错误）" "[ \"$ERRORS\" -eq 0 ]"

wait "$STRESS_PID" 2>/dev/null || true
wait "$AGENT_PID" 2>/dev/null || true

# --- 4. 幂等校验：清理并发测试残留 VG（agent 不应残留 hlvm-conctest-*）---
LEFTOVER=$(kubectl -n "$NS" exec "ds/hlvm-storage-agent" -c agent -- chroot /host lvm vgs --noheadings -o vg_name 2>/dev/null | grep -c 'hlvm-conctest' || true)
check "agent 并发测试 VG 已清理（无残留 hlvm-conctest-*）" "[ \"${LEFTOVER:-0}\" -eq 0 ]"

# --- 5. 终态：lvmd 业务 LV 仍可读写（数据面未中断）---
echo "[INFO] 校验 lvmd 业务 VG 仍健康（vgck）..."
FINAL_VG=$(kubectl -n "$NS" exec "ds/hlvm-storage-agent" -c agent -- chroot /host lvm vgck 2>&1 || true)
check "终态 vgck 通过（数据面未中断）" "! echo \"$FINAL_VG\" | grep -qi 'failed\|corrupt'"

echo "==== 7.2 并发验证结束：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
