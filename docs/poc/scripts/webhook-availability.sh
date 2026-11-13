#!/usr/bin/env bash
# webhook-availability.sh —— webhook 可用性预演判据（设计 §4 / add-poc-decision-gate §5.4）
#
# 验证：全部 hlvm webhook 副本宕机时，**非平台 PVC 的 API 创建不被阻塞**（分级 FailurePolicy=Ignore）。
#
# 判据修正（原脚本三处不成立，见 ADR-006 §23.5 / D3）：
#   1) `<非 hlvm 的 StorageClass>` 是占位符，YAML 直接 apply 会失败；改为自动发现 / 可显式指定，
#      没有非平台 SC 时退化成 storageClassName: "" 的静态 PVC；
#   2) 原判据 `wait --for=bound` 验的是 provisioner 能否供给，与 webhook FailurePolicy 无关，
#      且 WaitForFirstConsumer 下无 consumer Pod 时必然超时 ⇒ 假红。改为「apply 成功 + 对象存在」，
#      这才是准入链路的判据；
#   3) 原脚本没有确认 webhook 真的全部宕机、失败时也不会恢复副本。现补「endpoints 清空 +
#      readyReplicas=0」硬断言，并用 EXIT trap 兜底恢复原副本数。
#
# 静态断言是必要补充：非平台 PVC 本就不匹配 matchConditions，仅靠动态判据发现不了
# failurePolicy 被改成 Fail。两类断言都做，变异校验才有鉴别力。
#
# 判据纪律：能力前提不成立 → SKIP 不计 PASS；每条断言显式计数；末尾 SUMMARY 汇总行；
# rc：0=有 PASS 且无 FAIL；1=存在 FAIL；3=全部 SKIP。结果回填 ../poc-report.md §5.4。
#
# 用法：
#   bash webhook-availability.sh
#   KUBECTL_CONTEXT=kind-hlvm-m15-20261113 bash webhook-availability.sh
#
# 变量（全部可选）：
#   WEBHOOK_NS / WEBHOOK_DEPLOY / WEBHOOK_SVC    默认 hlvm-system / hlvm-storage-webhook ×2
#   VWC / MWC                默认 hlvm-storage-webhook-validating / -mutating
#   NONPLATFORM_SC          显式指定非平台 SC；缺省自动发现
#   PLATFORM_SC_PREFIXES    默认 "topolvm- hlvm-"（清单 matchConditions 实际只认 topolvm-）
#   POC_NS / DOWN_TIMEOUT / UP_TIMEOUT / KEEP_NS
#   KUBECONFIG_FILE / KUBECTL_CONTEXT
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
    printf 'RESULT: SKIP（能力前提全不成立，本轮未覆盖 §5.4，不计 PASS）\n'
    exit 3
  fi
  printf 'RESULT: PASS（仅上述 PASS 项有实测证据；SKIP 项仍需补齐）\n'
  exit 0
}

WEBHOOK_NS="${WEBHOOK_NS:-hlvm-system}"
WEBHOOK_DEPLOY="${WEBHOOK_DEPLOY:-hlvm-storage-webhook}"
WEBHOOK_SVC="${WEBHOOK_SVC:-hlvm-storage-webhook}"
VWC="${VWC:-hlvm-storage-webhook-validating}"
MWC="${MWC:-hlvm-storage-webhook-mutating}"
SUFFIX="$$"
NS="${POC_NS:-poc-webhook-${SUFFIX}}"
PLATFORM_SC_PREFIXES="${PLATFORM_SC_PREFIXES:-topolvm- hlvm-}"
DOWN_TIMEOUT="${DOWN_TIMEOUT:-60s}"
UP_TIMEOUT="${UP_TIMEOUT:-120s}"
KEEP_NS="${KEEP_NS:-0}"
PVC_BASE="poc-nonplatform-base-${SUFFIX}"
PVC_DOWN="poc-nonplatform-down-${SUFFIX}"
ORIG_REPLICAS=""
SCALED_DOWN=0
CLEANUP_NS=""

cleanup() {
  # 兜底恢复：即使中途 FAIL / 被中断，也不把 webhook 留在 0 副本
  if [ "${SCALED_DOWN}" = "1" ] && [ -n "${ORIG_REPLICAS}" ]; then
    kc -n "${WEBHOOK_NS}" scale "deploy/${WEBHOOK_DEPLOY}" --replicas="${ORIG_REPLICAS}" >/dev/null 2>&1 || true
  fi
  if [ -n "${CLEANUP_NS}" ] && [ "${KEEP_NS}" != "1" ]; then
    kc delete namespace "${CLEANUP_NS}" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  fi
  return 0
}
trap cleanup EXIT

# 用 printf 拼 YAML，避免占位符与 heredoc 变量展开纠缠
mk_pvc() {
  local name="$1" sc="$2" sc_line
  if [ -n "${sc}" ]; then
    sc_line="  storageClassName: ${sc}"
  else
    sc_line='  storageClassName: ""'
  fi
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: PersistentVolumeClaim' \
    'metadata:' \
    "  name: ${name}" \
    '  labels: {app: poc-webhook-availability}' \
    'spec:' \
    '  accessModes: [ReadWriteOnce]' \
    "${sc_line}" \
    '  resources: { requests: { storage: 1Gi } }' \
    | kc -n "${NS}" apply -f - >/dev/null 2>&1
}

if ! kc get namespaces >/dev/null 2>&1; then
  fail "kubectl 无法访问目标集群（检查 KUBECONFIG_FILE / KUBECTL_CONTEXT）"
  summary
fi
if ! kc -n "${WEBHOOK_NS}" get "deploy/${WEBHOOK_DEPLOY}" >/dev/null 2>&1; then
  skip "5.4 目标集群未部署 ${WEBHOOK_NS}/deploy/${WEBHOOK_DEPLOY}"
  summary
fi

# 5.4-A 静态断言：分级 FailurePolicy（容量类 Ignore，安全类 Fail，见 config/webhook/manifests.yaml）
PVC_FP="$(kc get validatingwebhookconfiguration "${VWC}" \
  -o jsonpath='{.webhooks[?(@.name=="validate-pvc.hlvm.storage.example.io")].failurePolicy}' 2>/dev/null || true)"
if [ -z "${PVC_FP}" ]; then
  skip "5.4 validate-pvc failurePolicy 静态断言（VWC ${VWC} 或该 webhook 不存在）"
elif [ "${PVC_FP}" = "Ignore" ]; then
  pass "5.4 validate-pvc failurePolicy=Ignore（容量类 Fail-safe 放行）"
else
  fail "5.4 validate-pvc failurePolicy=${PVC_FP}，期望 Ignore（分级策略被破坏）"
fi
POD_FP="$(kc get mutatingwebhookconfiguration "${MWC}" \
  -o jsonpath='{.webhooks[?(@.name=="mutate-pod.hlvm.storage.example.io")].failurePolicy}' 2>/dev/null || true)"
if [ -z "${POD_FP}" ]; then
  skip "5.4 mutate-pod failurePolicy 静态断言（MWC ${MWC} 或该 webhook 不存在）"
elif [ "${POD_FP}" = "Ignore" ]; then
  pass "5.4 mutate-pod failurePolicy=Ignore（Pod 注入 Fail-safe 放行）"
else
  fail "5.4 mutate-pod failurePolicy=${POD_FP}，期望 Ignore（分级策略被破坏）"
fi

# 选择非平台 SC；真机只有 hlvm-b 时无非平台 SC ⇒ 用无 SC 的静态 PVC（只验 API 准入）
NONPLATFORM_SC="${NONPLATFORM_SC:-}"
if [ -z "${NONPLATFORM_SC}" ]; then
  sc_list="$(kc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  while IFS= read -r name; do
    if [ -z "${name}" ]; then continue; fi
    excluded=0
    for pfx in ${PLATFORM_SC_PREFIXES}; do
      case "${name}" in "${pfx}"*) excluded=1 ;; esac
    done
    if [ "${excluded}" = "1" ]; then continue; fi
    NONPLATFORM_SC="${name}"
    break
  done <<< "${sc_list}"
fi
if [ -n "${NONPLATFORM_SC}" ]; then
  info "非平台 SC=${NONPLATFORM_SC}；判据是 API 准入是否阻塞，不等 PVC Bound"
else
  info "集群无可用的非平台 SC（平台前缀 ${PLATFORM_SC_PREFIXES}），改用 storageClassName: \"\" 的静态 PVC"
  info "注意：config/webhook/manifests.yaml 的 matchConditions 只认 topolvm- 前缀，真机 SC hlvm-b 不匹配该准入规则；"
  info "代码侧 IsPlatformStorageClass 却按 provisioner=topolvm.io 判定，两处口径不一致（ADR-006 §23.8 已登记，未修）"
fi

ORIG_REPLICAS="$(kc -n "${WEBHOOK_NS}" get "deploy/${WEBHOOK_DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
if [ -z "${ORIG_REPLICAS}" ]; then
  ORIG_REPLICAS="$(kc -n "${WEBHOOK_NS}" get "deploy/${WEBHOOK_DEPLOY}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
fi
if [ -z "${ORIG_REPLICAS}" ] || [ "${ORIG_REPLICAS}" = "0" ]; then
  skip "5.4 原 webhook 副本数为 0 或不可读（${ORIG_REPLICAS:-空}），无法做宕机预演与恢复"
  summary
fi
info "webhook 原副本数=${ORIG_REPLICAS}"

kc create namespace "${NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null 2>&1 || { fail "测试 namespace ${NS} 创建失败"; summary; }
CLEANUP_NS="${NS}"

# 5.4-B 基线：webhook 在线时非平台 PVC 可创建
if mk_pvc "${PVC_BASE}" "${NONPLATFORM_SC}" && kc -n "${NS}" get "pvc/${PVC_BASE}" >/dev/null 2>&1; then
  pass "5.4 基线：webhook 在线时非平台 PVC 的 API 创建成功"
else
  fail "5.4 基线：webhook 在线时非平台 PVC 创建失败（前提不成立，后续结论无效）"
fi

# 5.4-C 模拟全部副本宕机，并硬断言确实宕机（防止「根本没停」的假绿）
if ! kc -n "${WEBHOOK_NS}" scale "deploy/${WEBHOOK_DEPLOY}" --replicas=0 >/dev/null 2>&1; then
  fail "5.4 scale --replicas=0 失败"
  summary
fi
SCALED_DOWN=1
DOWN_OK=0
for _i in $(seq 1 30); do
  ep="$(kc -n "${WEBHOOK_NS}" get endpoints "${WEBHOOK_SVC}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  ready="$(kc -n "${WEBHOOK_NS}" get "deploy/${WEBHOOK_DEPLOY}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [ -z "${ep}" ] && { [ -z "${ready}" ] || [ "${ready}" = "0" ]; }; then
    DOWN_OK=1
    break
  fi
  sleep 2
done
if [ "${DOWN_OK}" = "1" ]; then
  pass "5.4 webhook 全部副本确已宕机（endpoints 清空 + readyReplicas=0）"
else
  fail "5.4 webhook 未在 ${DOWN_TIMEOUT} 内全部宕机，动态判据无效"
fi

# 5.4-D 核心判据：全宕机时非平台 PVC 的 API 创建不得被阻塞
if [ "${DOWN_OK}" != "1" ]; then
  skip "5.4 全宕机时非平台 PVC 创建（前置「确已宕机」未成立）"
elif mk_pvc "${PVC_DOWN}" "${NONPLATFORM_SC}" && kc -n "${NS}" get "pvc/${PVC_DOWN}" >/dev/null 2>&1; then
  pass "5.4 全 webhook 宕机时非平台 PVC 创建未被阻塞（分级 FailurePolicy 成立）"
else
  fail "5.4 全 webhook 宕机时非平台 PVC 创建被阻塞，需检查 FailurePolicy 配置"
fi

# 5.4-E 恢复并确认（trap 另有兜底，保证异常路径也不会留 0 副本）
if kc -n "${WEBHOOK_NS}" scale "deploy/${WEBHOOK_DEPLOY}" --replicas="${ORIG_REPLICAS}" >/dev/null 2>&1 && \
   kc -n "${WEBHOOK_NS}" wait --for=condition=Available "deploy/${WEBHOOK_DEPLOY}" --timeout="${UP_TIMEOUT}" >/dev/null 2>&1; then
  SCALED_DOWN=0
  pass "5.4 webhook 恢复至 ${ORIG_REPLICAS} 副本且 Available"
else
  fail "5.4 webhook 未在 ${UP_TIMEOUT} 内恢复（trap 会再尝试一次 scale）"
fi

info "结果只回填 poc-report.md §5.4；本脚本验证 API 准入链路，不验证 PVC 供给与数据面"
summary
