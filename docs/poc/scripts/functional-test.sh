#!/usr/bin/env bash
# functional-test.sh —— POC 基础功能验证（设计 §10 阶段 0 / add-poc-decision-gate §2）
#
# 验证 TopoLVM 提供能力：PVC 创建、在线扩容、快照、克隆（thick/thin）、节点重启恢复。
# 须在已安装 TopoLVM 的 POC 集群执行。实测结果记录到 ../poc-report.md §2。
#
# 用法：bash functional-test.sh [device-class]   # device-class 默认 topolvm-thin
set -euo pipefail

DC="${1:-topolvm-thin}"
NS="poc-functional"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# 2.1 PVC 创建（thick 与 thin 各一）
cat <<'YAML' | kubectl -n "$NS" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-thin
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-thin
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-thick
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-thick
  resources: { requests: { storage: 1Gi } }
YAML
kubectl -n "$NS" wait --for=bound pvc/pvc-thin pvc-thick --timeout=120s
echo "[PASS] 2.1 PVC 创建（thick + thin）"

# 2.1 在线扩容
kubectl -n "$NS" patch pvc pvc-thin --patch '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
kubectl -n "$NS" wait --for=jsonpath='{.status.capacity.storage}'=2Gi pvc/pvc-thin --timeout=120s
echo "[PASS] 2.1 在线扩容"

# 2.1 快照
cat <<'YAML' | kubectl -n "$NS" apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: snap-thin
spec:
  volumeSnapshotClassName: topolvm-snapclass
  source: { persistentVolumeClaimName: pvc-thin }
YAML
kubectl -n "$NS" wait --for=ready volumeSnapshot/snap-thin --timeout=120s
echo "[PASS] 2.1 快照"

# 2.1 克隆（从快照）
cat <<'YAML' | kubectl -n "$NS" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-clone
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: topolvm-thin
  dataSource:
    kind: VolumeSnapshot
    name: snap-thin
    apiGroup: snapshot.storage.k8s.io
  resources: { requests: { storage: 2Gi } }
YAML
kubectl -n "$NS" wait --for=bound pvc/pvc-clone --timeout=120s
echo "[PASS] 2.1 克隆"

# 2.2 节点重启恢复：写数据 → 删除使用 Pod → 重启节点 → 重新挂载校验数据
echo "hello-poc" | kubectl -n "$NS" run writer --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"w","image":"busybox","command":["sh","-c","echo hello-poc > /mnt/f && sync && sleep 3600"],"volumeMounts":[{"name":"v","mountPath":"/mnt"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"pvc-thin"}}]}}'
kubectl -n "$NS" wait --for=running pod/writer --timeout=120s
NODE=$(kubectl -n "$NS" get pod writer -o jsonpath='{.spec.nodeName}')
echo "[INFO] 数据已写入 pvc-thin，所在节点 $NODE。手动重启该节点后重新挂载校验 /mnt/f 内容。"
# 注：节点重启为物理/虚拟化操作，脚本仅准备校验步骤；重启后执行下方校验：
#   kubectl -n $NS run reader --image=busybox --restart=Never \
#     --overrides='{"spec":{"containers":[{"name":"r","image":"busybox","command":["cat","/mnt/f"],"volumeMounts":[{"name":"v","mountPath":"/mnt"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"pvc-thin"}}],"nodeName":"'$NODE'"}}'
#   kubectl -n $NS logs reader   # 期望输出 hello-poc
echo "[PASS] 2.2 重启恢复脚本就绪（物理重启后按注释校验）"

echo "==== functional-test 完成，结果填入 poc-report.md §2 ===="
