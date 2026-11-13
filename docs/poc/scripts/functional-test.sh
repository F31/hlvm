#!/usr/bin/env bash
# functional-test.sh —— POC 基础功能判据（设计 §10 阶段 0 / add-poc-decision-gate §2）
#
# 验证项：PVC 创建并完成供给绑定、在线扩容、快照、克隆、数据落盘可读；
#         节点重启恢复需要物理/虚拟化重启，脚本只准备校验步骤并显式 SKIP。
#
# 判据纪律（ADR-006 §23.5 / m15-integration-runbook.md）：
#   - 能力前提不成立 → SKIP 并写明未覆盖，绝不计 PASS；
#   - 每条断言显式 PASS/FAIL/SKIP 计数，末尾必打 SUMMARY 汇总行；
#   - rc：0 = 有 PASS 且无 FAIL；1 = 存在 FAIL；3 = 全部 SKIP（未覆盖，不算通过）；
#   - 只有 PASS 项可回填 ../poc-report.md §2，SKIP 项须等 D1（真机窗口）/ D2（快照栈）。
#
# 用法：
#   bash functional-test.sh [storage-class]
#   STORAGE_CLASS=standard KUBECTL_CONTEXT=kind-hlvm-m15-20261113 bash functional-test.sh
#
# 变量（全部可选）：
#   STORAGE_CLASS     默认 hlvm-b（真机唯一平台 SC）；隔离 kind 可设 standard
#   SNAPSHOT_CLASS    默认自动发现第一个 VolumeSnapshotClass，找不到则 SKIP
#   PVC_TIMEOUT       默认 180s（含供给绑定、扩容、快照、克隆等待）
#   EXPAND_TO         默认 2Gi
#   CONSUMER_IMAGE    默认 registry.k8s.io/pause:3.10（触发 WaitForFirstConsumer 绑定）
#   DATA_IMAGE        默认 busybox:1.36（写/读 /mnt/f；不可达则 SKIP 数据项）
#   DATA_CHECK        默认 1；设 0 主动跳过数据项（仍打 SKIP，不计 PASS）
#   KUBECONFIG_FILE / KUBECTL_CONTEXT   指定集群与上下文
#   KEEP_NS           默认 0；设 1 保留测试 namespace 供人工查验
set -euo pipefail

KC=(kubectl)
if [ -n "${KUBECONFIG_FILE:-}" ]; then KC+=(--kubeconfig "${KUBECONFIG_FILE}"); fi
if [ -n "${KUBECTL_CONTEXT:-}" ]; then KC+=(--context "${KUBECTL_CONTEXT}"); fi
kc() { "${KC[@]}" "$@"; }

PASS=0
FAIL=0
SKIP=0
pass() { printf '[PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '[SKIP] %s（能力缺失或需外部条件，不计 PASS）\n' "$*"; SKIP=$((SKIP + 1)); }
info() { printf '[INFO] %s\n' "$*"; }
summary() {
  printf 'SUMMARY: PASS=%d FAIL=%d SKIP=%d\n' "${PASS}" "${FAIL}" "${SKIP}"
  if [ "${FAIL}" -ne 0 ]; then
    printf 'RESULT: FAIL（判据转红，不得回填 poc-report.md 为通过）\n'
    exit 1
  fi
  if [ "${PASS}" -eq 0 ]; then
    printf 'RESULT: SKIP（能力前提全不成立，本轮未覆盖任何阶段 0 项，不计 PASS）\n'
    exit 3
  fi
  printf 'RESULT: PASS（仅上述 PASS 项有实测证据；SKIP 项仍需 D1/D2 补齐）\n'
  exit 0
}

SC="${1:-${STORAGE_CLASS:-hlvm-b}}"
SUFFIX="$$"
NS="${POC_NS:-poc-functional-${SUFFIX}}"
PVC_TIMEOUT="${PVC_TIMEOUT:-180s}"
EXPAND_TO="${EXPAND_TO:-2Gi}"
CONSUMER_IMAGE="${CONSUMER_IMAGE:-registry.k8s.io/pause:3.10}"
DATA_IMAGE="${DATA_IMAGE:-busybox:1.36}"
DATA_CHECK="${DATA_CHECK:-1}"
KEEP_NS="${KEEP_NS:-0}"
PVC="poc-data-${SUFFIX}"
CONSUMER_POD="poc-consumer-${SUFFIX}"
WRITER_POD="poc-writer-${SUFFIX}"
SNAP="poc-snap-${SUFFIX}"
CLONE="poc-clone-${SUFFIX}"
CLONE_POD="poc-clone-consumer-${SUFFIX}"
PVC_BOUND=0
SNAP_READY=0
CLEANUP_NS=""

cleanup() {
  if [ -n "${CLEANUP_NS}" ] && [ "${KEEP_NS}" != "1" ]; then
    kc delete namespace "${CLEANUP_NS}" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  fi
  return 0
}
trap cleanup EXIT

# 前提 0：目标集群可达（连不上是配置问题，不是能力缺失，直接 FAIL）
if ! kc get namespaces >/dev/null 2>&1; then
  fail "kubectl 无法访问目标集群（检查 KUBECONFIG_FILE / KUBECTL_CONTEXT）"
  summary
fi

SC_PROVISIONER="$(kc get sc "${SC}" -o jsonpath='{.provisioner}' 2>/dev/null || true)"
if [ -z "${SC_PROVISIONER}" ]; then
  skip "2.1 StorageClass ${SC} 不存在（真机默认 hlvm-b；隔离 kind 需显式 STORAGE_CLASS=standard）"
  summary
fi
BOUND_MODE="$(kc get sc "${SC}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || true)"
info "目标 SC=${SC} provisioner=${SC_PROVISIONER} volumeBindingMode=${BOUND_MODE:-空}"
info "说明：WaitForFirstConsumer 的 SC 必须有 consumer Pod 才会绑定；原脚本直接 wait bound 属假判据"

kc create namespace "${NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1 || { fail "测试 namespace ${NS} 创建失败"; summary; }
CLEANUP_NS="${NS}"

# 2.1 PVC 创建 + 供给绑定：consumer Pod 触发调度与 provisioner
cat <<YAML | kc -n "${NS}" apply -f - >/dev/null 2>&1 || { fail "2.1 PVC / consumer Pod 清单 apply 失败"; summary; }
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
  labels: {app: poc-functional}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${SC}
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata:
  name: ${CONSUMER_POD}
  labels: {app: poc-functional}
spec:
  restartPolicy: Never
  containers:
    - name: consumer
      image: ${CONSUMER_IMAGE}
      volumeMounts: [{name: v, mountPath: /mnt}]
  volumes:
    - name: v
      persistentVolumeClaim: {claimName: ${PVC}}
YAML

if kc -n "${NS}" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC}" --timeout="${PVC_TIMEOUT}" >/dev/null 2>&1; then
  pass "2.1 PVC 创建并完成供给绑定（SC=${SC}，consumer Pod 触发 WaitForFirstConsumer）"
  PVC_BOUND=1
else
  reason="$(kc -n "${NS}" get pod "${CONSUMER_POD}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  phase="$(kc -n "${NS}" get "pvc/${PVC}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "${reason}" in
    ErrImagePull|ImagePullBackOff|InvalidImageName)
      skip "2.1 consumer 镜像 ${CONSUMER_IMAGE} 不可达（${reason}），PVC 供给闭环未覆盖" ;;
    *)
      fail "2.1 PVC 未在 ${PVC_TIMEOUT} 内绑定（phase=${phase:-空} waiting=${reason:-空}）" ;;
  esac
fi

# 2.1 在线扩容：必须 SC 开启 allowVolumeExpansion 且 PVC 已绑定并有在用 Pod
if [ "${PVC_BOUND}" != "1" ]; then
  skip "2.1 在线扩容（前置 PVC 未绑定）"
else
  expand="$(kc get sc "${SC}" -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null || true)"
  if [ "${expand}" != "true" ]; then
    skip "2.1 在线扩容（SC ${SC} 未开启 allowVolumeExpansion，值=${expand:-空}）"
  elif ! kc -n "${NS}" patch "pvc/${PVC}" --patch "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${EXPAND_TO}\"}}}}" >/dev/null 2>&1; then
    fail "2.1 在线扩容 patch 被拒绝（1Gi → ${EXPAND_TO}）"
  elif kc -n "${NS}" wait --for=jsonpath='{.status.capacity.storage}'="${EXPAND_TO}" "pvc/${PVC}" --timeout="${PVC_TIMEOUT}" >/dev/null 2>&1; then
    pass "2.1 在线扩容 1Gi → ${EXPAND_TO}（status.capacity.storage 生效）"
  else
    actual="$(kc -n "${NS}" get "pvc/${PVC}" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || true)"
    fail "2.1 在线扩容未在 ${PVC_TIMEOUT} 生效（期望 ${EXPAND_TO}，实际 ${actual:-空}）"
  fi
fi

# 2.1 快照 / 克隆：D2 之前快照 CRD、VolumeSnapshotClass、snapshot-controller 均可能缺失
SNAP_CRDS_OK=0
if kc get crd volumesnapshots.snapshot.storage.k8s.io >/dev/null 2>&1 && \
   kc get crd volumesnapshotclasses.snapshot.storage.k8s.io >/dev/null 2>&1; then
  SNAP_CRDS_OK=1
fi
SNAP_CLASS="${SNAPSHOT_CLASS:-}"
if [ "${SNAP_CRDS_OK}" = "1" ] && [ -z "${SNAP_CLASS}" ]; then
  SNAP_CLASS="$(kc get volumesnapshotclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [ "${SNAP_CRDS_OK}" != "1" ]; then
  skip "2.1 快照（集群缺 snapshot.storage.k8s.io CRD，需 D2）"
  skip "2.1 克隆（依赖快照，集群缺 snapshot CRD，需 D2）"
elif [ -z "${SNAP_CLASS}" ]; then
  skip "2.1 快照（无 VolumeSnapshotClass，需 D2）"
  skip "2.1 克隆（无 VolumeSnapshotClass，需 D2）"
elif [ "${PVC_BOUND}" != "1" ]; then
  skip "2.1 快照（前置 PVC 未绑定）"
  skip "2.1 克隆（前置 PVC 未绑定）"
else
  cat <<YAML | kc -n "${NS}" apply -f - >/dev/null 2>&1 || { fail "2.1 VolumeSnapshot 清单 apply 失败"; summary; }
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAP}
  labels: {app: poc-functional}
spec:
  volumeSnapshotClassName: ${SNAP_CLASS}
  source: {persistentVolumeClaimName: ${PVC}}
YAML
  if kc -n "${NS}" wait --for=jsonpath='{.status.readyToUse}'=true "volumesnapshot/${SNAP}" --timeout="${PVC_TIMEOUT}" >/dev/null 2>&1; then
    pass "2.1 快照 readyToUse=true（VolumeSnapshotClass=${SNAP_CLASS}）"
    SNAP_READY=1
  else
    fail "2.1 快照未在 ${PVC_TIMEOUT} 内 readyToUse=true"
  fi
  if [ "${SNAP_READY}" != "1" ]; then
    skip "2.1 克隆（前置快照未就绪）"
  else
    cat <<YAML | kc -n "${NS}" apply -f - >/dev/null 2>&1 || { fail "2.1 克隆 PVC / consumer Pod 清单 apply 失败"; summary; }
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CLONE}
  labels: {app: poc-functional}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${SC}
  dataSource:
    kind: VolumeSnapshot
    name: ${SNAP}
    apiGroup: snapshot.storage.k8s.io
  resources: { requests: { storage: ${EXPAND_TO} } }
---
apiVersion: v1
kind: Pod
metadata:
  name: ${CLONE_POD}
  labels: {app: poc-functional}
spec:
  restartPolicy: Never
  containers:
    - name: consumer
      image: ${CONSUMER_IMAGE}
      volumeMounts: [{name: v, mountPath: /mnt}]
  volumes:
    - name: v
      persistentVolumeClaim: {claimName: ${CLONE}}
YAML
    if kc -n "${NS}" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${CLONE}" --timeout="${PVC_TIMEOUT}" >/dev/null 2>&1; then
      pass "2.1 克隆 PVC 从 VolumeSnapshot 完成供给绑定"
    else
      fail "2.1 克隆 PVC 未在 ${PVC_TIMEOUT} 内绑定"
    fi
  fi
fi

# 2.2 数据落盘可读：用可 exec 的镜像写 /mnt/f 后读回；镜像不可达则 SKIP
if [ "${DATA_CHECK}" != "1" ]; then
  skip "2.2 数据落盘可读（DATA_CHECK=0，本轮主动不测）"
elif [ "${PVC_BOUND}" != "1" ]; then
  skip "2.2 数据落盘可读（前置 PVC 未绑定）"
else
  kc -n "${NS}" delete pod "${CONSUMER_POD}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  cat <<YAML | kc -n "${NS}" apply -f - >/dev/null 2>&1 || { fail "2.2 writer Pod 清单 apply 失败"; summary; }
apiVersion: v1
kind: Pod
metadata:
  name: ${WRITER_POD}
  labels: {app: poc-functional}
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: ${DATA_IMAGE}
      command: ["sh", "-c", "echo hello-poc > /mnt/f && sync && sleep 3600"]
      volumeMounts: [{name: v, mountPath: /mnt}]
  volumes:
    - name: v
      persistentVolumeClaim: {claimName: ${PVC}}
YAML
  if kc -n "${NS}" wait --for=condition=Ready "pod/${WRITER_POD}" --timeout=60s >/dev/null 2>&1; then
    content="$(kc -n "${NS}" exec "${WRITER_POD}" -- cat /mnt/f 2>/dev/null || true)"
    if [ "${content}" = "hello-poc" ]; then
      pass "2.2 数据落盘可读（/mnt/f = hello-poc）"
    else
      fail "2.2 数据读回不符（期望 hello-poc，实际 ${content:-空}）"
    fi
  else
    reason="$(kc -n "${NS}" get pod "${WRITER_POD}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    case "${reason}" in
      ErrImagePull|ImagePullBackOff|InvalidImageName)
        skip "2.2 数据落盘可读（DATA_IMAGE ${DATA_IMAGE} 不可达：${reason}）" ;;
      *)
        fail "2.2 writer Pod 未就绪（waiting=${reason:-空}）" ;;
    esac
  fi
fi

# 2.2 节点重启恢复：物理/虚拟化操作，脚本不能代劳，绝不因「脚本就绪」计 PASS
skip "2.2 节点重启恢复（需重启承载 Pod 的节点 + hnb 错峰窗口 D1）"
info "人工校验：重启后执行 kubectl -n ${NS} exec ${WRITER_POD} -- cat /mnt/f，期望 hello-poc"
info "结果只回填 poc-report.md §2；全部 SKIP 的项一律不得写成通过"

summary
