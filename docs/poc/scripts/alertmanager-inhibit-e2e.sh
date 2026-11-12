#!/usr/bin/env bash
# alertmanager-inhibit-e2e.sh —— ADR-006 §21：在**真实 Alertmanager 实例**上验路由与抑制。
#
# 为什么需要它（§20.8 的第一条边界）：
#   `amtool check-config` 只能证明「配置能被解析」；`alertmanager_config_test.go` 只能证明
#   「引用的 alertname 存在、equal 非空、severity 都有路由」。两者都证明不了**运行时真的按
#   预期抑制**，而下面三种错法全都不报错：
#     - `equal` 里的标签在某一侧告警上不存在 ⇒ 该条抑制永不匹配（配置看着完全正常）；
#     - 路由顺序写反 ⇒ critical 被 warning 路由吃掉，降级成工单（通知变慢，没人察觉）；
#     - 抑制写得过宽 ⇒ 把「必须由人处理」的告警压掉，表现为「告警变少了」。
#   三者都与「一切正常」不可区分 —— 与本 ADR 反复要治的是同一种病。
#
# 判据（每条都成对出现正例与反例，只有正例等于没测）：
#   1. 同一 thin-pool：Critical 抑制对应 Warning（suppressed / inhibitedBy=1）；
#   2. 只差一个 equal 标签（同 node 不同 vg、同 vg 不同 node）**不得**互相抑制；
#   3. OutOfSpace 抑制同 node+vg 的 DataWarning 与 MetadataCritical（派生量）；
#   4. OutOfSpace **不得**抑制同节点的 StorageDriftDetected / DriftLVReportStalled /
#      AgentHeartbeatLost（跨子系统不压制 —— 配置文件里「刻意不加」那一段的反例）；
#   5. DiskSmartCritical 抑制同盘温度告警，**不得**抑制另一块盘（equal: [node, device]）；
#   6. 路由：critical→pager、warning→ticket、未知 severity→默认接收器且告警仍可见（不丢弃）；
#      **不断言顺序**——两条 matcher 互斥时顺序不产生行为差异（见第 6 段注释）；
#   7. 抑制是**动态计算**：解析 OutOfSpace 后 MetadataCritical 回到 active，而 DataWarning
#      仍被仍在响的 DataCritical 压着（不是一次性扣帽子，也不会挂在已解析的告警上）；
#   8. 分组：同 alertname+node、仅 device 不同 → 合成一个分组（一次通知，group_by 不含 device）。
#
# 能力缺失（无 docker / 无镜像 / 无 jq / API 起不来）一律 SKIP 并写明未覆盖，绝不计 PASS。
#
# 本脚本**不进 CI**：要拉 ~280MB 的 alertmanager 镜像，属「本地/真机验收」链路
# （与 docs/poc/scripts 下其它脚本同一纪律）。CI 侧的静态部分由
# scripts/observability-config-check.sh + observability_config_test.go 覆盖。
#
# 用法（WSL 内、仓库根）：
#   bash docs/poc/scripts/alertmanager-inhibit-e2e.sh
#   AM_IMAGE=docker.m.daocloud.io/prom/alertmanager:v0.28.1 bash docs/poc/scripts/alertmanager-inhibit-e2e.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
AM_CONFIG="${AM_CONFIG:-${REPO_ROOT}/control-plane/config/alertmanager/alertmanager.yaml}"
AM_IMAGE="${AM_IMAGE:-prom/alertmanager:v0.28.1}"
AM_PORT="${AM_PORT:-19093}"
AM_NAME="${AM_NAME:-hlvm-am-e2e-$$}"
READY_SECS="${READY_SECS:-40}"
SETTLE_SECS="${SETTLE_SECS:-20}"     # 抑制状态收敛的等待上限（每轮 1s 轮询）
GROUP_WAIT_SECS="${GROUP_WAIT_SECS:-150}" # 分组要等 group_wait(1m) 过后才会被 flush

passes=0 fails=0 skips=0
VERDICT="PASS"
STARTED=0

pass() { echo "[pass] $*"; passes=$((passes + 1)); }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
skip() { echo "[skip] $*"; skips=$((skips + 1)); }
info() { echo "       $*"; }

trap 'echo "[error] line=$LINENO cmd=${BASH_COMMAND}" >&2' ERR

cleanup_am() {
  # 只用全局变量：EXIT trap 里阶段内的 local 已出作用域。
  if [ "${STARTED}" = "1" ]; then
    docker rm -f "${AM_NAME}" >/dev/null 2>&1 || true
    STARTED=0
  fi
}

finish() {
  local rc=0
  if ((fails > 0)); then VERDICT="FAIL"; rc=1; fi
  cleanup_am
  trap - EXIT
  echo "SUMMARY PASS=${passes} FAIL=${fails} SKIP=${skips} VERDICT=${VERDICT}"
  exit "${rc}"
}
trap 'cleanup_am' EXIT

# ---------------------------- Alertmanager / API 基础 ----------------------------

api() { curl -sS --max-time 10 "http://127.0.0.1:${AM_PORT}/api/v2/$1" 2>/dev/null || true; }

# 走 docker exec 而非 docker run：省一次容器启动，也不需要 --network host。
amtool_bin() { docker exec "${AM_NAME}" /bin/amtool --alertmanager.url=http://127.0.0.1:9093 "$@"; }

am_add() {
  if amtool_bin alert add "$@" >/dev/null 2>&1; then
    return 0
  fi
  fail "amtool alert add 失败：$*"
}

# 把 k=v 列表转成 JSON 对象，供 jq 做标签全等匹配（标签值都是 ASCII 字面量，无需转义）。
want_json() {
  local out="{" sep="" kv
  for kv in "$@"; do
    out="${out}${sep}\"${kv%%=*}\":\"${kv#*=}\""
    sep=","
  done
  printf '%s}' "${out}"
}

# alert_field <state|inh|receivers> <k=v...>
# MISSING = 没有匹配的告警；QUERYFAIL = jq/接口失败（不可当成「没抑制」）。
alert_field() {
  local field="$1"
  shift
  local want
  want="$(want_json "$@")"
  api alerts | jq -r --argjson want "${want}" --arg f "${field}" '
    [ .[] | select(.labels as $l | all($want | to_entries[]; $l[.key] == .value)) ] as $m
    | if ($m | length) == 0 then "MISSING"
      else $m[0] as $a
        | if $f == "state" then ($a.status.state // "NOSTATE")
          elif $f == "inh" then (($a.status.inhibitedBy // []) | length | tostring)
          elif $f == "receivers" then (($a.receivers // []) | map(.name) | sort | join(","))
          else "BADFIELD" end
      end' 2>/dev/null || echo "QUERYFAIL"
}

# 抑制状态由通知流水线异步重算，等它收敛再断言；等不到就报实际值。
expect_state() {
  local desc="$1" want="$2" want_inh="$3"
  shift 3
  local i st inh
  for i in $(seq 1 "${SETTLE_SECS}"); do
    st="$(alert_field state "$@")"
    inh="$(alert_field inh "$@")"
    if [ "${st}" = "${want}" ] && [ "${inh}" = "${want_inh}" ]; then
      pass "${desc}（state=${st} inhibitedBy=${inh}）"
      return 0
    fi
    sleep 1
  done
  case "${st}" in
    MISSING) fail "${desc}：查不到该告警（标签 $*）—— 注入失败或标签写错" ;;
    QUERYFAIL) fail "${desc}：查询告警失败（jq/接口异常），不能当作「未抑制」" ;;
    *) fail "${desc}：期望 state=${want} inhibitedBy=${want_inh}，实际 state=${st} inhibitedBy=${inh}" ;;
  esac
}

expect_receiver() {
  local desc="$1" want="$2"
  shift 2
  local got
  got="$(alert_field receivers "$@")"
  if [ "${got}" = "${want}" ]; then
    pass "${desc}（receivers=${got}）"
  else
    fail "${desc}：期望 receivers=${want}，实际 ${got}"
  fi
}

# status.inhibitedBy 是**抑制者指纹**列表，实测只会有 0 或 1 个元素：
# Alertmanager 0.28 按规则顺序取第一个匹配的抑制源，多根因同时命中时不会累积。
# 所以「被几条规则压住」无法从数量判断，断言只能落在「抑制者是谁」上。
inhibitor_names() {
  local want
  want="$(want_json "$@")"
  api alerts | jq -r --argjson want "${want}" '
    . as $all
    | [ $all[] | select(.labels as $l | all($want | to_entries[]; $l[.key] == .value)) ] as $m
    | if ($m | length) == 0 then "MISSING"
      else ($m[0].status.inhibitedBy // []) as $fps
        | if ($fps | length) == 0 then "NONE"
          else [ $fps[] as $f | ($all[] | select(.fingerprint == $f) | .labels.alertname) ]
               | sort | join(",")
          end
      end' 2>/dev/null || echo "QUERYFAIL"
}

# expect_inhibitor <desc> <期望抑制者(csv，任一即可)> <k=v...>
expect_inhibitor() {
  local desc="$1" allowed="$2"
  shift 2
  local i got hit
  for i in $(seq 1 "${SETTLE_SECS}"); do
    got="$(inhibitor_names "$@")"
    for hit in ${allowed//,/ }; do
      if [ "${got}" = "${hit}" ]; then
        pass "${desc}（抑制者=${got}）"
        return 0
      fi
    done
    sleep 1
  done
  fail "${desc}：期望抑制者为 [${allowed}]，实际 ${got}"
}

# expect_group_alerts <desc> <alertname> <node> <期望组内告警数>
# 分组只有在 group_wait 过后才会出现在 /api/v2/alerts/groups，所以要轮询。
expect_group_alerts() {
  local desc="$1" an="$2" node="$3" want="$4"
  local i got=""
  for i in $(seq 1 "${GROUP_WAIT_SECS}"); do
    got="$(api alerts/groups | jq -r --arg an "${an}" --arg node "${node}" '
      [ .[] | select((.labels.alertname // "") == $an and (.labels.node // "") == $node) ]
      | if length == 0 then "" else (length | tostring) + ":" + ((.[0].alerts | length) | tostring) end' 2>/dev/null || true)"
    if [ "${got}" = "1:${want}" ]; then
      pass "${desc}（1 个分组，组内 ${want} 条告警）"
      return 0
    fi
    sleep 1
  done
  fail "${desc}：等了 ${GROUP_WAIT_SECS}s 仍未出现 1 组/${want} 条（实际 ${got:-<无分组>}）"
}

# ---------------------------- 前置能力检查 ----------------------------

echo "== hlvm Alertmanager 路由/抑制实测（ADR-006 §21）"
info "配置：${AM_CONFIG}"
info "镜像：${AM_IMAGE}"

if [ ! -f "${AM_CONFIG}" ]; then
  fail "找不到 Alertmanager 配置 ${AM_CONFIG}"
  finish
fi
if ! command -v docker >/dev/null 2>&1; then
  skip "无 docker，本轮不覆盖真实 Alertmanager 行为"
  finish
fi
if ! command -v jq >/dev/null 2>&1; then
  skip "无 jq（解析 /api/v2 响应），本轮不覆盖真实 Alertmanager 行为"
  finish
fi
if ! docker image inspect "${AM_IMAGE}" >/dev/null 2>&1; then
  skip "本地没有镜像 ${AM_IMAGE}（先 docker pull ${AM_IMAGE}），本轮不覆盖"
  finish
fi

docker rm -f "${AM_NAME}" >/dev/null 2>&1 || true
if docker run -d --name "${AM_NAME}" \
  -p "127.0.0.1:${AM_PORT}:9093" \
  -v "${AM_CONFIG}:/etc/alertmanager/alertmanager.yaml:ro" \
  "${AM_IMAGE}" \
  --config.file=/etc/alertmanager/alertmanager.yaml \
  --storage.path=/tmp/am \
  --cluster.listen-address= >/dev/null 2>&1; then
  STARTED=1
else
  fail "启动 Alertmanager 容器失败（${AM_IMAGE}）"
  finish
fi

READY=0
for _ in $(seq 1 "${READY_SECS}"); do
  if api status | jq -e '.versionInfo.version' >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done
if [ "${READY}" != "1" ]; then
  fail "Alertmanager ${READY_SECS}s 内未就绪"
  docker logs "${AM_NAME}" 2>&1 | tail -10 || true
  finish
fi
pass "Alertmanager 就绪（$(api status | jq -r '.versionInfo.version')），配置已加载"

# ---------------------------- 1. 同一 thin-pool：Critical 压 Warning ----------------------------
info "1. inhibit_rules[0]：同 node+vg 的 Critical 压掉对应 Warning"
am_add alertname=ThinPoolDataCritical node=n1 vg=v1 severity=critical
am_add alertname=ThinPoolDataWarning node=n1 vg=v1 severity=warning
expect_state "DataCritical 自身照常上报（不自我抑制）" active 0 alertname=ThinPoolDataCritical node=n1 vg=v1
expect_state "同 node+vg 的 DataWarning 被抑制" suppressed 1 alertname=ThinPoolDataWarning node=n1 vg=v1

# ---------------------------- 2. equal 反例：只差一个标签就不得抑制 ----------------------------
info "2. equal 反例：只差一个标签不得互相抑制"
am_add alertname=ThinPoolDataWarning node=n1 vg=v2 severity=warning
am_add alertname=ThinPoolDataWarning node=n2 vg=v1 severity=warning
expect_state "同 node 不同 vg：不抑制" active 0 alertname=ThinPoolDataWarning node=n1 vg=v2
expect_state "同 vg 不同 node：不抑制" active 0 alertname=ThinPoolDataWarning node=n2 vg=v1

# ---------------------------- 3. OutOfSpace 压同 pool 的派生量 ----------------------------
info "3. inhibit_rules[1]：OutOfSpace 压同 pool 的容量百分比告警"
am_add alertname=ThinPoolOutOfSpace node=n3 vg=v3 severity=critical
am_add alertname=ThinPoolDataWarning node=n3 vg=v3 severity=warning
am_add alertname=ThinPoolMetadataCritical node=n3 vg=v3 severity=critical
expect_state "根因 OutOfSpace 自身照常上报" active 0 alertname=ThinPoolOutOfSpace node=n3 vg=v3
expect_state "同 pool 的 DataWarning 被压" suppressed 1 alertname=ThinPoolDataWarning node=n3 vg=v3
# MetadataCritical 只能被这条规则压（规则 1 的 target 是 *Warning），所以它是规则 2 的专属判据。
expect_state "同 pool 的 MetadataCritical 被压（规则 2 专属）" suppressed 1 alertname=ThinPoolMetadataCritical node=n3 vg=v3
expect_inhibitor "MetadataCritical 的抑制者确实是 OutOfSpace（只有规则 2 覆盖它）" \
  ThinPoolOutOfSpace alertname=ThinPoolMetadataCritical node=n3 vg=v3
# DataWarning 同时被两条规则覆盖（规则 1 的 MetadataCritical 与规则 2 的 OutOfSpace），
# 而 inhibitedBy 只报一个，所以这里只能断言「抑制者来自容量族根因」这个集合。
expect_inhibitor "DataWarning 的抑制者来自容量族根因" \
  ThinPoolOutOfSpace,ThinPoolMetadataCritical alertname=ThinPoolDataWarning node=n3 vg=v3

# ---------------------------- 4. 跨子系统反例 ----------------------------
info "4. 反例：根因告警不得压掉其它子系统的告警"
am_add alertname=StorageDriftDetected node=n3 kind=missing-lv severity=warning
am_add alertname=DriftLVReportStalled node=n3 severity=warning
am_add alertname=AgentHeartbeatLost node=n3 severity=warning
expect_state "StorageDriftDetected 不被 OutOfSpace 压掉" active 0 alertname=StorageDriftDetected node=n3
expect_state "DriftLVReportStalled 不被 OutOfSpace 压掉" active 0 alertname=DriftLVReportStalled node=n3
expect_state "AgentHeartbeatLost 不被 OutOfSpace 压掉" active 0 alertname=AgentHeartbeatLost node=n3

# ---------------------------- 5. 磁盘：equal 按 device 对齐 ----------------------------
info "5. inhibit_rules[2]：SMART 判死压同盘派生信号，不跨盘"
am_add alertname=DiskSmartCritical node=n4 device=sda severity=critical
am_add alertname=DiskTemperatureWarning node=n4 device=sda severity=warning
am_add alertname=DiskLifeWarning node=n4 device=sdb severity=warning
expect_state "同盘（device=sda）温度告警被压" suppressed 1 alertname=DiskTemperatureWarning node=n4 device=sda
expect_state "另一块盘（device=sdb）不受影响" active 0 alertname=DiskLifeWarning node=n4 device=sdb

# ---------------------------- 6. 路由 ----------------------------
info "6. 路由：severity 决定接收器，未知 severity 不丢弃"
# 注意这里**故意不断言路由顺序**：本配置两条 severity 路由的 matcher 互斥
# （`severity="critical"` / `severity="warning"`），一条告警只会命中其中一条，于是
# 把 warning 路由挪到前面也不改变任何行为（§21.4 实测：该变异下本段仍全绿）。
# 顺序只在 matcher 可重叠时才起作用（例如将来有人写成 `severity=~"warning|critical"`），
# 那种情况由 Go 守卫 TestAlertmanagerRoutesCoverEverySeverity 守。
# 在这里塞一条「顺序错就红」的断言只能靠假造配置，测不出任何真东西 —— 比没有更糟。
expect_receiver "critical → pager" pager alertname=DiskSmartCritical node=n4 device=sda
expect_receiver "warning → ticket" ticket alertname=DiskLifeWarning node=n4 device=sdb
am_add alertname=UnknownSeverityProbe node=n5 severity=nonsense
expect_receiver "未知 severity → 默认接收器 blackhole（记录但不投递）" blackhole alertname=UnknownSeverityProbe node=n5
expect_state "未知 severity 的告警仍可见（不是被丢弃）" active 0 alertname=UnknownSeverityProbe node=n5

# ---------------------------- 7. 抑制是动态计算 ----------------------------
info "7. 抑制随根因消失而解除（不是一次性扣帽子）"
# 再叠一个 DataCritical：它自己也会被规则 2 压（该规则 target 明确写了 DataCritical），
# 这条配置看着多余，但正因如此「Critical 也压在 OutOfSpace 之下」是可断言的。
am_add alertname=ThinPoolDataCritical node=n3 vg=v3 severity=critical
expect_state "DataCritical 也被 OutOfSpace 压掉（规则 2 的 target 含 Critical）" suppressed 1 alertname=ThinPoolDataCritical node=n3 vg=v3
expect_inhibitor "…且抑制者确实是 OutOfSpace" ThinPoolOutOfSpace alertname=ThinPoolDataCritical node=n3 vg=v3
expect_inhibitor "DataWarning 的抑制者仍是容量族根因之一" \
  ThinPoolOutOfSpace,ThinPoolMetadataCritical,ThinPoolDataCritical alertname=ThinPoolDataWarning node=n3 vg=v3
# 用 endsAt 落在过去来解析 OutOfSpace（amtool alert add --end）。
END_AT="$(date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%SZ)"
am_add alertname=ThinPoolOutOfSpace node=n3 vg=v3 severity=critical --end="${END_AT}"
expect_state "解析 OutOfSpace 后 MetadataCritical 回到 active（只有它被这条规则压）" active 0 alertname=ThinPoolMetadataCritical node=n3 vg=v3
expect_state "DataCritical 也回到 active（抑制源自己解除）" active 0 alertname=ThinPoolDataCritical node=n3 vg=v3
# 关键：同一时刻「解除了一个、还压着另一个」——抑制是逐 target 按当前活跃根因实时算的，
# 不是一次性全局扣帽子，也不会残留在已解析的告警上。
expect_state "DataWarning 仍被压（规则 1 的 Critical 还在响）" suppressed 1 alertname=ThinPoolDataWarning node=n3 vg=v3
expect_inhibitor "…抑制者已不是 OutOfSpace（它已解析），而是规则 1 的 Critical" \
  ThinPoolDataCritical,ThinPoolMetadataCritical alertname=ThinPoolDataWarning node=n3 vg=v3

# ---------------------------- 8. 分组 ----------------------------
info "8. group_by 不含 device ⇒ 同 alertname+node 的多盘告警合成一次通知"
am_add alertname=DiskTemperatureWarning node=n9 device=sdc severity=warning
am_add alertname=DiskTemperatureWarning node=n9 device=sdd severity=warning
expect_group_alerts "同 node 两块盘的温度告警合成一个分组" DiskTemperatureWarning n9 2

finish
