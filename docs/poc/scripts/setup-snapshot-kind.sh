#!/usr/bin/env bash
# setup-snapshot-kind.sh —— 在隔离 kind 集群补齐 D2 的 snapshot 栈与 CSI 快照判据前提
#
# 用途（ADR-006 §23.5 D2）：
#   1. 安装 external-snapshotter v8.2.0 的 3 个 CRD + snapshot-controller；
#   2. apply 重渲染后带 csi-snapshotter 的 topolvm-controller；
#   3. apply VolumeSnapshotClass；
#   4. 逐项判据验证，能力缺失一律 SKIP 且不计 PASS。
#
# 纪律：
#   - 只操作显式传入的 KUBECTL_CONTEXT，绝不默认真机；
#   - 显式 PASS/FAIL/SKIP 计数 + SUMMARY 汇总行；rc 0=通过 1=有 FAIL 3=全 SKIP；
#   - apply 全部兜底成 FAIL，避免 set -euo pipefail 下静默退出零日志；
#   - 本脚本不删除任何资源（幂等 apply），清理需人工执行。
#
# 用法：
#   KUBECTL_CONTEXT=kind-hlvm-m15-20261113 bash setup-snapshot-kind.sh
#
# 变量（全部可选）：
#   KUBECTL_CONTEXT   必填语义上要求指定；未给则拒绝执行（防止误连真机）
#   SNAPSHOT_DIR      默认脚本所在目录的 ../snapshot
#   WAIT_TIMEOUT      默认 180s
set -euo pipefail

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
    printf 'RESULT: FAIL（snapshot 栈未就绪，不得据此回填 poc-report.md）\n'
    exit 1
  fi
  if [ "${PASS}" -eq 0 ]; then
    printf 'RESULT: SKIP（能力前提全不成立，不计 PASS）\n'
    exit 3
  fi
  printf 'RESULT: PASS（仅上述 PASS 项有实测证据）\n'
  exit 0
}

CTX="${KUBECTL_CONTEXT:-}"
if [ -z "${CTX}" ]; then
  printf '[FAIL] 必须显式指定 KUBECTL_CONTEXT（禁止默认连真机）\n'
  summary
fi
KC=(kubectl --context "${CTX}")
kc() { "${KC[@]}" "$@"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SDIR="${SNAPSHOT_DIR:-${HERE}/../snapshot}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"

# 前提 0：目标集群可达（连不上是配置问题，直接 FAIL，不算能力缺失）
if ! kc get namespaces >/dev/null 2>&1; then
  fail "kubectl 无法访问 context=${CTX}"
  summary
fi
if [ ! -d "${SDIR}" ]; then
  fail "snapshot 清单目录不存在：${SDIR}"
  summary
fi
info "目标 context=${CTX} 清单目录=${SDIR}"

# 1. CRD（3 个，缺一不可）
CRDS=(volumesnapshotclasses.snapshot.storage.k8s.io
      volumesnapshotcontents.snapshot.storage.k8s.io
      volumesnapshots.snapshot.storage.k8s.io)
for f in 00-crd-volumesnapshotclasses.yaml 00-crd-volumesnapshotcontents.yaml 00-crd-volumesnapshots.yaml; do
  if [ ! -f "${SDIR}/${f}" ]; then fail "清单缺失 ${f}"; else
    kc apply -f "${SDIR}/${f}" >/dev/null 2>&1 || { fail "apply ${f} 失败"; summary; }
  fi
done
for c in "${CRDS[@]}"; do
  if kc get crd "${c}" >/dev/null 2>&1; then pass "CRD ${c} 已建立"; else fail "CRD ${c} 不存在"; fi
done
for c in "${CRDS[@]}"; do
  if kc wait --for=condition=Established "crd/${c}" --timeout="${WAIT_TIMEOUT}" >/dev/null 2>&1; then
    pass "CRD ${c} Established"
  else
    fail "CRD ${c} 未 Established"
  fi
done

# 2. snapshot-controller RBAC + Deployment
for f in 10-snapshot-controller-rbac.yaml 20-snapshot-controller.yaml; do
  kc apply -f "${SDIR}/${f}" >/dev/null 2>&1 || { fail "apply ${f} 失败"; summary; }
done
if kc -n kube-system rollout status deploy/snapshot-controller --timeout="${WAIT_TIMEOUT}" >/dev/null 2>&1; then
  pass "snapshot-controller Deployment Ready"
else
  fail "snapshot-controller 未在 ${WAIT_TIMEOUT} 内 Ready"
fi

# 3. 重渲染后带 csi-snapshotter 的 topolvm-controller
#    仅当 hlvm-system 命名空间与 CSIDriver 已就绪才有意义；否则判据前提不成立。
if ! kc get ns hlvm-system >/dev/null 2>&1; then
  skip "topolvm-controller（hlvm-system 命名空间不存在，需先部署 B 链路）"
elif ! kc get crd logicalvolumes.topolvm.io >/dev/null 2>&1; then
  skip "topolvm-controller（logicalvolumes.topolvm.io CRD 不存在，需先部署 B 链路）"
else
  kc apply -f "${SDIR}/40-csi-controller-snapshot-enabled.yaml" >/dev/null 2>&1 \
    || { fail "apply 40-csi-controller-snapshot-enabled.yaml 失败"; summary; }
  if kc -n hlvm-system get deploy topolvm-controller -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null | grep -q csi-snapshotter; then
    pass "topolvm-controller 含 csi-snapshotter sidecar（snapshot.enabled=true 产物）"
  else
    fail "topolvm-controller 未含 csi-snapshotter sidecar"
  fi
  if kc -n hlvm-system rollout status deploy/topolvm-controller --timeout="${WAIT_TIMEOUT}" >/dev/null 2>&1; then
    pass "topolvm-controller Deployment Ready（含快照 sidecar）"
  else
    fail "topolvm-controller 未在 ${WAIT_TIMEOUT} 内 Ready"
  fi
fi

# 4. VolumeSnapshotClass
kc apply -f "${SDIR}/30-volumesnapshotclass.yaml" >/dev/null 2>&1 \
  || { fail "apply 30-volumesnapshotclass.yaml 失败"; summary; }
if kc get volumesnapshotclass hlvm-b-snap -o jsonpath='{.driver}' 2>/dev/null | grep -qx 'topolvm.io'; then
  pass "VolumeSnapshotClass hlvm-b-snap 存在且 driver=topolvm.io"
else
  fail "VolumeSnapshotClass hlvm-b-snap 缺失或 driver 不匹配"
fi

# 5. 诚实边界：CRD/controller 就绪 ≠ 快照能力可用
info "注意：CRD/controller 就绪只说明控制面可受理 VolumeSnapshot；"
info "      真正 readyToUse 需要 CSI 驱动实现 CreateSnapshot（TopoLVM 仅 thin-pool 卷支持）。"
info "      隔离 kind 是否具备该能力，由 functional-test.sh 的实测判据决定，本脚本不代判。"

summary
