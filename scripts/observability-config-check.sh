#!/usr/bin/env bash
# Alertmanager 配置 + Grafana 仪表盘的**真实校验**（ADR-006 §20）。
#
# 解决的问题：规则文件只决定「什么时候算告警」，决定不了「谁会收到、噪声会不会盖住
# 真故障」。而这两类配置写错时的行为都是**静默的**：
#   - Alertmanager：抑制规则的 alertname 拼错 ⇒ 该条抑制永不生效（不报错）；路由
#     matcher 的 severity 写错 ⇒ 告警落到默认接收器，值班人什么都收不到；
#   - Grafana：面板 expr 写错 ⇒ 面板显示 "No data"，看起来像「没有异常」。
# 两者都与「一切正常」不可区分，与本 ADR 反复要治的是同一种病。
#
# 分工：
#   - 本脚本：用**外部验证器**证明「配置能被真实解析」——
#     amtool check-config（Alertmanager 官方校验）/ promtool check rules（PromQL 语法）。
#   - control-plane/internal/metrics/alertmanager_config_test.go：不需要 docker，
#     守只有我们自己知道的语义（抑制规则引用的告警必须存在、每条 severity 必须有路由等）。
#
# 用法（WSL 内、仓库根）：
#   scripts/observability-config-check.sh
#   AM_IMAGE=docker.m.daocloud.io/prom/alertmanager:v0.28.1 \
#     PROM_IMAGE=docker.m.daocloud.io/prom/prometheus:v3.1.0 scripts/observability-config-check.sh
#
# 环境变量：
#   AMTOOL / AM_IMAGE    amtool 路径 / 提供 amtool 的镜像（默认 prom/alertmanager:v0.28.1）
#   PROMTOOL / PROM_IMAGE  promtool 路径 / 提供 promtool 的镜像（默认 prom/prometheus:v3.1.0）
#   KEEP_WORK=1          保留临时目录便于排查
#
# 判据：exit 0 + 无 FAIL: + 收尾汇总行。缺工具一律 SKIP，绝不计 PASS；**CI 里禁止 SKIP**。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AM_DIR="$ROOT/control-plane/config/alertmanager"
AM_FILE="$AM_DIR/alertmanager.yaml"
DASH_DIR="$ROOT/control-plane/config/grafana/dashboards"
AMTOOL="${AMTOOL:-}"
AM_IMAGE="${AM_IMAGE:-prom/alertmanager:v0.28.1}"
PROMTOOL="${PROMTOOL:-}"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v3.1.0}"

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

# CI 里 SKIP 等于门禁开洞：yml 里写着有这个 job、日志一片绿，配置其实一次都没校验。
ci_strict() { [ -n "${CI:-}" ] || [ "${REQUIRE_TOOLS:-0}" = "1" ]; }

summary() {
  printf 'SUMMARY PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
  if [ "$FAIL" -gt 0 ]; then exit 1; fi
  exit 0
}

# ---- 0. 工具解析 -------------------------------------------------------------
am_run() {
  if [ -n "$AMTOOL" ] && [ -x "$AMTOOL" ]; then
    ( cd "$WORK" && "$AMTOOL" "$@" ) || return $?
  elif command -v amtool >/dev/null 2>&1; then
    ( cd "$WORK" && amtool "$@" ) || return $?
  elif command -v docker >/dev/null 2>&1; then
    # 与 promtool 同一套约定：只挂 $WORK、带宿主 uid/gid。
    # 这样本地二进制与容器两种跑法共用**同一个相对路径**（alertmanager.yaml），
    # 不必为 runner 分叉参数（分叉过的参数一定会有一条路径长期没人跑）。
    docker run --rm --entrypoint /bin/amtool \
      --user "$(id -u):$(id -g)" \
      -v "$WORK:/work" -w /work "$AM_IMAGE" "$@" || return $?
  else
    return 127
  fi
}

prom_run() {
  if [ -n "$PROMTOOL" ] && [ -x "$PROMTOOL" ]; then
    ( cd "$WORK" && "$PROMTOOL" "$@" ) || return $?
  elif command -v promtool >/dev/null 2>&1; then
    ( cd "$WORK" && promtool "$@" ) || return $?
  elif command -v docker >/dev/null 2>&1; then
    # 镜像以 nobody 运行，而 mktemp 目录是 0700 ⇒ 显式带宿主 uid/gid，
    # 否则读到的是 permission denied（看起来像文件损坏）。
    docker run --rm --entrypoint /bin/promtool \
      --user "$(id -u):$(id -g)" \
      -v "$WORK:/work" -w /work "$PROM_IMAGE" "$@" || return $?
  else
    return 127
  fi
}

# ---- 1. Alertmanager：amtool check-config -----------------------------------
printf '== amtool check-config（%s）\n' "$AM_FILE"
if [ ! -f "$AM_FILE" ]; then
  fail "缺少 Alertmanager 配置 $AM_FILE"
else
  cp "$AM_FILE" "$WORK/alertmanager.yaml"
  if am_run --version >/dev/null 2>&1; then
    printf '  [info] %s\n' "$(am_run --version 2>/dev/null | head -1 || true)"
    if am_run check-config alertmanager.yaml >"$WORK/am.log" 2>&1; then
      pass "check-config 通过（$(grep -cE '^ - ' "$WORK/am.log" || true) 项结构摘要）"
      sed 's/^/      /' "$WORK/am.log" | tail -8
    else
      fail "check-config 失败"
      sed 's/^/      /' "$WORK/am.log" | tail -30
    fi
  elif ci_strict; then
    fail "CI/强制模式下必须真的跑 amtool，但既无 amtool 也无可用镜像（$AM_IMAGE）"
  else
    skip "无 amtool 也无 docker（或镜像不可用 $AM_IMAGE），本轮不覆盖 Alertmanager 配置校验"
  fi
fi

# ---- 2. 仪表盘：结构 + PromQL 语法 ------------------------------------------
printf '== Grafana 仪表盘（%s）\n' "$DASH_DIR"
if ! command -v python3 >/dev/null 2>&1; then
  if ci_strict; then
    fail "CI/强制模式下需要 python3 解析仪表盘 JSON，但未找到"
  else
    skip "无 python3，本轮不覆盖仪表盘校验"
  fi
else
  shopt -s nullglob
  DASH_FILES=("$DASH_DIR"/*.json)
  shopt -u nullglob
  if [ "${#DASH_FILES[@]}" -eq 0 ]; then
    fail "在 $DASH_DIR 下没有任何仪表盘 JSON"
  fi

  # 2a. 结构：uid/title/panels 齐全，panel id 唯一，每个 panel 的每条 target 都有非空 expr。
  for f in "${DASH_FILES[@]:-}"; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    if python3 "$ROOT/scripts/dashboard_lint.py" "$f" >"$WORK/lint-$base.log" 2>&1; then
      pass "$base 结构合法（$(head -1 "$WORK/lint-$base.log")）"
    else
      fail "$base 结构非法"
      sed 's/^/      /' "$WORK/lint-$base.log" | head -20
    fi
  done

  # 2b. PromQL：把每条 expr 包成 recording rule 交给 promtool 解析。
  #     Grafana 内建变量先做**显式替换**（下表之外出现 `$` 一律判 FAIL）——
  #     否则一个 `$unknown` 会被 promtool 当成语法错误，报错指向 promtool 而不指向真正的
  #     笔误位置；反过来若默默放行，面板在 Grafana 里就是空图。
  if prom_run --version >/dev/null 2>&1; then
    for f in "${DASH_FILES[@]:-}"; do
      [ -n "$f" ] || continue
      base="$(basename "$f")"
      if ! python3 "$ROOT/scripts/dashboard_lint.py" --emit-rules "$f" "$WORK/probe-$base" >"$WORK/emit-$base.log" 2>&1; then
        fail "$base 表达式提取失败"
        sed 's/^/      /' "$WORK/emit-$base.log" | head -20
        continue
      fi
      if grep -q 'record: ' "$WORK/probe-$base"; then
        if prom_run check rules "probe-$base" >"$WORK/rules-$base.log" 2>&1; then
          pass "$base 全部 expr 通过 PromQL 解析（$(grep -c 'record: ' "$WORK/probe-$base" || true) 条）"
        else
          fail "$base 存在无法解析的 expr"
          sed 's/^/      /' "$WORK/rules-$base.log" | tail -30
        fi
      else
        fail "$base 没有提取到任何 expr（面板全部空？）"
      fi
    done
  elif ci_strict; then
    fail "CI/强制模式下必须真的跑 promtool，但既无 promtool 也无可用镜像（$PROM_IMAGE）"
  else
    skip "无 promtool 也无 docker（或镜像不可用 $PROM_IMAGE），本轮不覆盖面板表达式解析"
  fi
fi

summary
