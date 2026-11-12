#!/usr/bin/env python3
"""Grafana 仪表盘：结构检查 + PromQL 探针生成（ADR-006 §20）。

分工：本脚本**不做** PromQL 判断，只做「解析与提取」；表达式能否被引擎接受由
`promtool check rules` 判定（见 scripts/observability-config-check.sh）。

两个子命令：
  dashboard_lint.py <dash.json>
      结构检查：uid/title/panels、panel id 唯一、每个 panel 有 type/title、
      每条 target 有非空 expr。成功时打印一行摘要（面板数/查询数）供脚本记录。

  dashboard_lint.py --emit-rules <dash.json> <out.yaml>
      把每条 target.expr 包成 recording rule 写进 <out.yaml>，交给 promtool 解析。
      Grafana 内建变量按显式表中的字面量替换；**表外出现 `$` 直接失败**——
      否则脚本会把一个笔误（$unknown）当成 promtool 语法错误报出来，定位指向错误的地方。

为什么不用 Grafana 自己校验：仓库里没有 Grafana 实例，而面板写错的表现是
"No data"（看起来像没有异常），与「一切正常」不可区分 —— 这正是要治的失败模式。
Grafana 的内建变量替换是运行时行为，静态环境里只能按文档给的间隔边界近似。
"""

import json
import re
import sys

# Grafana 内建变量 → 校验用字面量。
# 取值按「最小可信区间」：$__rate_interval 在 scrape=15s 时最低为 4*15s=1m（Grafana 默认下限 1m），
# 这里用 5m 覆盖绝大多数面板配置；区间长度不影响 PromQL 语法解析。
BUILTIN_VARS = {
    "$__rate_interval": "5m",
    "$__interval": "5m",
    "$__range": "1h",
    "$__interval_ms": "300000",
    "$__rate_interval_ms": "300000",
}

KNOWN_PANEL_KEYS = ("id", "type", "title", "targets")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def iter_panels(panels):
    """展开 nested panels（row 里的折叠面板）。"""
    for p in panels:
        yield p
        for sub in p.get("panels") or []:
            yield sub


def lint(dash):
    problems = []
    if not isinstance(dash, dict):
        return ["顶层不是 JSON 对象"], 0, 0

    if not str(dash.get("uid") or "").strip():
        problems.append("缺少 uid（provisioning 与分享链接靠它定位）")
    if not str(dash.get("title") or "").strip():
        problems.append("缺少 title")
    panels = dash.get("panels")
    if not isinstance(panels, list) or not panels:
        return problems + ["缺少 panels 或为空"], 0, 0

    ids = {}
    n_panels = 0
    n_targets = 0
    for p in iter_panels(panels):
        n_panels += 1
        pid = p.get("id")
        ptype = str(p.get("type") or "")
        # row 是纯布局元素：没有查询也没有数据源。
        is_row = ptype == "row"
        if pid is None:
            problems.append(f"panel(type={ptype}, title={p.get('title')!r}) 缺少 id")
        else:
            ids.setdefault(pid, 0)
            ids[pid] += 1
        if not ptype:
            problems.append(f"panel(id={pid}) 缺少 type")
        if not str(p.get("title") or "").strip():
            problems.append(f"panel(id={pid}, type={ptype}) 缺少 title")
        if is_row:
            continue
        targets = p.get("targets")
        if not isinstance(targets, list) or not targets:
            problems.append(f"panel(id={pid}, {ptype}) 没有 targets")
            continue
        for ti, t in enumerate(targets):
            n_targets += 1
            expr = str(t.get("expr") or "").strip()
            if not expr:
                problems.append(f"panel(id={pid}) targets[{ti}] 没有 expr（面板会显示 No data）")

    for pid, count in ids.items():
        if count > 1:
            problems.append(f"panel id={pid} 重复 {count} 次（Grafana 会拒绝导入）")
    return problems, n_panels, n_targets


def declared_vars(dash):
    """仪表盘自己声明的模板变量名（templating.list[].name）。

    变量值在运行时由 Grafana 填入，静态环境里无从得知；替换成 `.*` 只为让 PromQL
    能被解析——**求值语义不在本脚本职责内**（语法正确不代表面板指标对）。
    """
    names = []
    tmpl = dash.get("templating") or {}
    for v in tmpl.get("list") or []:
        name = str(v.get("name") or "").strip()
        if name:
            names.append(name)
    # 长的先替换，避免 $node_name 被 $node 截断。
    return sorted(set(names), key=len, reverse=True)


def substitute(expr, names):
    """替换内建变量与已声明变量；返回 (结果, 未知变量列表)。"""
    out = expr
    for var in sorted(BUILTIN_VARS, key=len, reverse=True):
        out = out.replace(var, BUILTIN_VARS[var])
    for name in names:
        out = re.sub(r"\$\{" + re.escape(name) + r"\}", ".*", out)
        out = re.sub(r"\$" + re.escape(name) + r"(?![A-Za-z0-9_])", ".*", out)
    unknown = []
    if "$" in out:
        # 定位每个剩余的 $ 后跟的标识符，便于一次看全。
        i = 0
        while i < len(out):
            if out[i] == "$":
                j = i + 1
                while j < len(out) and (out[j].isalnum() or out[j] in "_"):
                    j += 1
                unknown.append(out[i:j])
                i = j
            else:
                i += 1
    return out, unknown


def emit_rules(dash_path, out_path):
    dash = load(dash_path)
    problems, _, _ = lint(dash)
    if problems:
        for p in problems:
            print(f"structure: {p}", file=sys.stderr)
        return 2

    lines = ["groups:", "  - name: dashboard-probes", "    rules:"]
    count = 0
    bad = []
    names = declared_vars(dash)
    for p in iter_panels(dash.get("panels") or []):
        if str(p.get("type") or "") == "row":
            continue
        for ti, t in enumerate(p.get("targets") or []):
            expr, unknown = substitute(str(t.get("expr") or "").strip(), names)
            if unknown:
                bad.append((p.get("id"), ti, sorted(set(unknown))))
                continue
            count += 1
            # recording rule 名只用于让 promtool 校验 expr；不会被真正采集。
            name = f"probe_p{str(p.get('id')).replace('-', '_')}_t{ti}"
            lines.append(f"      - record: {name}")
            # JSON 字符串与 YAML 双引号标量兼容，避免引号/转义踩坑。
            lines.append(f"        expr: {json.dumps(expr, ensure_ascii=False)}")

    if bad:
        for pid, ti, vars_ in bad:
            print(
                f"panel(id={pid}) targets[{ti}] 含未登记模板变量 {vars_}；"
                f"请先在 BUILTIN_VARS 里登记（否则无法静态校验）",
                file=sys.stderr,
            )
        return 3
    if count == 0:
        print("没有提取到任何 expr", file=sys.stderr)
        return 4

    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return 0


def main(argv):
    if len(argv) >= 4 and argv[1] == "--emit-rules":
        return emit_rules(argv[2], argv[3])
    if len(argv) == 2:
        dash = load(argv[1])
        problems, n_panels, n_targets = lint(dash)
        if problems:
            for p in problems:
                print(p, file=sys.stderr)
            return 1
        print(f"{n_panels} panels, {n_targets} queries")
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
