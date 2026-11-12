#!/usr/bin/env bash
# promtool 规则校验：用真实 PromQL 引擎解析 + 求值告警/记录规则。
#
# 解决的问题（ADR-006 §17.7 登记的诚实边界）：
#   仓库里原先只有「规则清单」和「指标名静态守卫」（TestAlertRulesReferenceKnownMetrics）。
#   静态守卫只能证明**被引用的指标存在**，证明不了：
#     1) 表达式能被 PromQL 解析（括号/聚合/区间写法）；
#     2) `for:` 时长与判据语义真的会在预期时刻触发（尤其 Stalled 用 `time() - ts`
#        而不是「滞后秒数」这种反假绿改写，只有引擎求值才能验证）；
#     3) 健康态不会误报（时间戳随抓取推进时 age≈0）。
#
# 用法（WSL 内、仓库根）：
#   scripts/prometheus-rules-check.sh
#   PROM_IMAGE=docker.m.daocloud.io/prom/prometheus:v3.1.0 scripts/prometheus-rules-check.sh
#
# 环境变量：
#   PROM_IMAGE      提供 promtool 的镜像，默认 prom/prometheus:v3.1.0
#   PROMTOOL        本机 promtool 路径；存在则直接使用，跳过 docker
#   KEEP_WORK=1     保留临时目录便于排查
#
# 判据：exit 0 + 无 FAIL: + 收尾汇总行。缺 docker/promtool 一律 SKIP，绝不计 PASS。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_DIR="$ROOT/control-plane/config/prometheus"
TESTS_DIR="$RULES_DIR/tests"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v3.1.0}"
PROMTOOL="${PROMTOOL:-}"

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf '  [pass] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  [skip] %s\n' "$*"; }

on_err() {
  local rc=$?
  printf '  FAIL: 第 %s 行命令失败（rc=%s）：%s\n' "${BASH_LINENO[0]:-?}" "$rc" "${BASH_COMMAND:-?}"
  FAIL=$((FAIL + 1))
}
trap on_err ERR

WORK="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_WORK:-0}" = "1" ]; then
    printf '  [info] 保留临时目录：%s\n' "$WORK"
  else
    rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---- promtool 可用性 ---------------------------------------------------------
prom_run() {
  if [ -n "$PROMTOOL" ] && [ -x "$PROMTOOL" ]; then
    ( cd "$WORK" && "$PROMTOOL" "$@" ) || return $?
  elif command -v promtool >/dev/null 2>&1; then
    ( cd "$WORK" && promtool "$@" ) || return $?
  elif command -v docker >/dev/null 2>&1; then
    # 镜像默认以 nobody 运行，而 mktemp 目录是 0700 ⇒ 显式带上宿主 uid/gid，
    # 否则 promtool 读到的是 "permission denied"（看起来像规则文件坏了）。
    docker run --rm --entrypoint /bin/promtool \
      --user "$(id -u):$(id -g)" \
      -v "$WORK:/work" -w /work "$PROM_IMAGE" "$@" || return $?
  else
    return 127
  fi
}

printf '== promtool 规则校验（%s）\n' "$RULES_DIR"
if ! prom_run --version >/dev/null 2>&1; then
  # 真机脚本里「能力缺失即 SKIP」是对的（环境本身没有该能力）；但 CI 里 SKIP 等于
  # 门禁开洞：yml 里写着有这个 job、日志一片绿，规则其实一条都没求值过。
  if [ -n "${CI:-}" ] || [ "${REQUIRE_PROMTOOL:-0}" = "1" ]; then
    fail "CI/强制模式下必须真的跑 promtool，但本机既无 promtool 也无可用镜像（$PROM_IMAGE）"
    printf 'SUMMARY PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
    exit 1
  fi
  skip "无 promtool 也无 docker（或镜像不可用 $PROM_IMAGE），本轮不覆盖规则求值"
  printf 'SUMMARY PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
fi
PROM_VER="$(prom_run --version 2>/dev/null | head -1 || true)"
printf '  [info] %s\n' "${PROM_VER:-promtool 版本未知}"

# ---- 1. PrometheusRule CRD → 纯规则文件 --------------------------------------
# CRD 的 spec.groups 整体缩进 2 空格；promtool 只认顶层 groups:。逐文件去缩进，
# 并显式拒绝「groups 之后还有其它顶层键」的文件（那种文件去缩进后必然非法）。
shopt -s nullglob
RULE_FILES=("$RULES_DIR"/*.yaml)
shopt -u nullglob
if [ "${#RULE_FILES[@]}" -eq 0 ]; then
  fail "在 $RULES_DIR 下没找到任何规则文件"
fi

EXTRACTED=()
for f in "${RULE_FILES[@]}"; do
  base="$(basename "$f")"
  out="$WORK/$base"
  awk '
    { sub(/\r$/, "") }
    /^  groups:[[:space:]]*$/ { ingroups = 1 }
    ingroups == 1 { sub(/^  /, ""); print }
  ' "$f" >"$out"
  if [ ! -s "$out" ]; then
    fail "$base 没有可提取的 spec.groups（结构变了？）"
    continue
  fi
  if [ "$(head -1 "$out" | tr -d '\r')" != "groups:" ]; then
    fail "$base 提取结果首行不是 groups:（实际：$(head -1 "$out" | tr -d '\r')）"
    continue
  fi
  EXTRACTED+=("$base")
  pass "$base 提取成功（$(grep -c '^\s*- \(alert\|record\):' "$out" || true) 条规则）"
done

# ---- 2. promtool check rules（全部规则文件，含未写单测的） -------------------
printf '== check rules\n'
for base in "${EXTRACTED[@]:-}"; do
  [ -n "$base" ] || continue
  : >"$WORK/check.log"
  if prom_run check rules "$base" >>"$WORK/check.log" 2>&1; then
    pass "check rules $base"
  else
    fail "check rules $base"
    sed 's/^/      /' "$WORK/check.log" | tail -20
  fi
done

# ---- 3. promtool test rules（真实求值） -------------------------------------
printf '== test rules\n'
shopt -s nullglob
TEST_FILES=("$TESTS_DIR"/*.yml "$TESTS_DIR"/*.yaml)
shopt -u nullglob
if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  fail "在 $TESTS_DIR 下没有任何求值用例"
else
  # 规则文件与用例放在同一目录，用例内 rule_files 用相对文件名引用。
  for f in "${TEST_FILES[@]}"; do
    cp "$f" "$WORK/"
  done
  for f in "${TEST_FILES[@]}"; do
    base="$(basename "$f")"
    if prom_run test rules "$base" >>"$WORK/test-$base.log" 2>&1; then
      pass "test rules $base"
    else
      fail "test rules $base"
      sed 's/^/      /' "$WORK/test-$base.log" | tail -40
    fi
  done
fi

# ---- 4. 覆盖守卫：每条告警都必须有用例 --------------------------------------
# 新加告警却没写求值用例 = 规则永远不会在测试里被触发过，属最容易回归的静默缺口。
# 默认对**全部** alert-rules*.yaml 生效（recording 文件没有 alert，不参与）；
# COVERAGE_FILE 可指定单个文件名，COVERAGE_GLOB 可改写匹配模式（排查用）。
COVERAGE_FILE="${COVERAGE_FILE:-}"
COVERAGE_GLOB="${COVERAGE_GLOB:-alert-rules*.yaml}"
if [ -n "$COVERAGE_FILE" ]; then
  COVERAGE_FILES=("$COVERAGE_FILE")
else
  shopt -s nullglob
  COVERAGE_FILES=()
  for f in "$RULES_DIR"/$COVERAGE_GLOB; do
    COVERAGE_FILES+=("$(basename "$f")")
  done
  shopt -u nullglob
fi
printf '== 覆盖守卫（%s 个规则文件）\n' "${#COVERAGE_FILES[@]}"
TOTAL_ALERTS=0
for cf in "${COVERAGE_FILES[@]:-}"; do
  [ -n "$cf" ] || continue
  if [ ! -f "$RULES_DIR/$cf" ]; then
    skip "$cf 不存在，跳过"
    continue
  fi
  # 去 CR：仓库在 Windows 上 autocrlf=true，工作区里的 *.yaml 是 CRLF；awk 打印出来
  # 的告警名会带尾随 \r，grep 的 `Foo\b` 永远匹配不到（表现为「告警没有用例」假红）。
  ALERTS="$(awk '{ sub(/\r$/, "") } /^ *- alert:/ { gsub(/^ *- alert:[[:space:]]*/, ""); print }' "$RULES_DIR/$cf" || true)"
  if [ -z "${ALERTS}" ]; then
    continue
  fi
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    TOTAL_ALERTS=$((TOTAL_ALERTS + 1))
    if grep -rqs "alertname:[[:space:]]*$a\b" "$TESTS_DIR"; then
      pass "用例覆盖 $a"
    else
      fail "告警 $a 没有 promtool 求值用例（$TESTS_DIR）"
    fi
  done <<<"$ALERTS"
done
if [ "$TOTAL_ALERTS" -eq 0 ]; then
  fail "覆盖守卫没有扫到任何告警（规则文件结构或 glob 变了）"
else
  printf '  [info] 共校验 %s 条告警的用例覆盖\n' "$TOTAL_ALERTS"
fi

printf 'SUMMARY PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
