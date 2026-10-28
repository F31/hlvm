#!/usr/bin/env bash
# webhook-availability.sh —— webhook 可用性预演（设计 §4 / add-poc-decision-gate §5.4）
#
# 验证：全部 hlvm webhook 副本宕机时，非本平台 PVC 的创建**不阻塞**（§4 分级 FailurePolicy=Ignore）。
# 须在已部署 hlvm-storage-webhook 的 POC 集群执行。结果记录到 ../poc-report.md §5.4。
set -euo pipefail

NS="hlvm-system"
echo "==== 5.4 webhook 可用性预演 ===="

# 1) 确认 webhook 当前在线，并创建一个非平台 PVC（基线可通过）
kubectl create namespace poc-webhook --dry-run=client -o yaml | kubectl apply -f -
cat <<'YAML' | kubectl -n poc-webhook apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nonplatform
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: <非 hlvm 的 StorageClass>   # 替换为集群既有非平台 SC
  resources: { requests: { storage: 1Gi } }
YAML
echo "[INFO] 基线：webhook 在线时非平台 PVC 可正常创建"

# 2) 模拟全部 webhook 副本宕机
kubectl -n "$NS" scale deploy/hlvm-storage-webhook --replicas=0
# 等待 endpoints 清空（webhook 服务不再转发）
sleep 10

# 3) 再次创建非平台 PVC，验证不被阻塞
cat <<'YAML' | kubectl -n poc-webhook apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nonplatform-2
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: <非 hlvm 的 StorageClass>
  resources: { requests: { storage: 1Gi } }
YAML
if kubectl -n poc-webhook wait --for=bound pvc/pvc-nonplatform-2 --timeout=120s; then
  echo "[PASS] 5.4 全 webhook 宕机时，非平台 PVC 创建未被阻塞（§4 分级策略成立）"
else
  echo "[FAIL] 5.4 非平台 PVC 被阻塞，需检查 FailurePolicy 配置"
fi

# 4) 恢复 webhook
kubectl -n "$NS" scale deploy/hlvm-storage-webhook --replicas=3
kubectl -n "$NS" wait --for=condition=Available deploy/hlvm-storage-webhook --timeout=120s
echo "[INFO] webhook 已恢复至 3 副本"

echo "==== webhook-availability 完成 -> poc-report.md §5.4 ===="
