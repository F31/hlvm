#!/usr/bin/env bash
# 由仓库内的可观测性「源文件」生成可被真机直接 apply 的部署配置清单。
#
# 设计判据（与 config/observability/gen-prometheus-rules.sh 同一套纪律）：
#   - 源文件是单一事实源，**绝不**把告警路由/仪表盘内容手抄进部署清单——
#     手抄必然在某次改路由时漏改部署副本，而 Alertmanager 路由写错的表现是
#     「告警变少了」，与「一切正常」不可区分（ADR-006 §20 反复治的同一类病）。
#   - 本脚本把源文件「原样 + 必要改写」塞进 Secret/ConfigMap，跑完即可 apply；
#     源文件改动后必须重跑本脚本（CI 不自动跑，靠人；与 gen-prometheus-rules.sh 同口径）。
#
# 生成产物：
#   1) config/alertmanager/alertmanager-config.yaml
#        Secret hlvm-alertmanager-config（键 alertmanager.yaml = 源 alertmanager.yaml 原样）。
#   2) config/grafana/grafana-config.yaml
#        ConfigMap hlvm-grafana-config：datasource 供应（uid=hlvm-prometheus）+ 仪表盘供应
#        + 两张仪表盘 JSON（数据源引用统一对齐到 uid=hlvm-prometheus，解决 §20 表里
#        drift 用 ${datasource} 变量、overview 用 ${DS_PROMETHEUS} 变量、两者不统一、
#        且 overview 的 DS_PROMETHEUS 变量根本没在 templating 里声明的问题——否则
#        provisioned 仪表盘面板会静默 No data）。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AM_SRC="$ROOT/control-plane/config/alertmanager/alertmanager.yaml"
AM_OUT="$ROOT/control-plane/config/alertmanager/alertmanager-config.yaml"
DASH_SRC_DIR="$ROOT/control-plane/config/grafana/dashboards"
GRAFANA_OUT="$ROOT/control-plane/config/grafana/grafana-config.yaml"
# provisioned 数据源 uid：与 Prometheus Service 同名，便于人读；Grafana 面板/变量都对齐它。
DS_UID="hlvm-prometheus"
DS_URL="http://hlvm-prometheus.hlvm-system.svc:9090"

python3 - "$AM_SRC" "$AM_OUT" "$DASH_SRC_DIR" "$GRAFANA_OUT" "$DS_UID" "$DS_URL" <<'PY'
import sys, os, json, yaml

am_src, am_out, dash_src_dir, grafana_out, ds_uid, ds_url = sys.argv[1:7]

# 多行字符串（告警配置 / 仪表盘 JSON / 供应文件）用 YAML 字面块 `|` 输出，
# 否则 PyYAML 会把换行进双引号转义成一整行，diff 不可读且与本仓库其余清单风格不一致。
class LiteralDumper(yaml.SafeDumper):
    pass

def _str_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)

LiteralDumper.add_representer(str, _str_representer)

def dump(obj):
    return yaml.dump(obj, Dumper=LiteralDumper, sort_keys=False,
                     default_flow_style=False, allow_unicode=True)

# ---- 1) Alertmanager Secret（源文件原样塞入，零改写）-----------------------------
with open(am_src, encoding="utf-8") as fh:
    am_body = fh.read()
am_secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": "hlvm-alertmanager-config",
        "namespace": "hlvm-system",
        "labels": {
            "app.kubernetes.io/name": "hlvm",
            "app.kubernetes.io/component": "alertmanager",
        },
    },
    "type": "Opaque",
    # stringData 让 k8s 在 apply 时把明文转 base64，仓库里看到的是可读的 alertmanager.yaml。
    "stringData": {"alertmanager.yaml": am_body},
}
with open(am_out, "w", encoding="utf-8", newline="\r\n") as fh:
    fh.write(dump(am_secret))
print("wrote", am_out)

# ---- 2) Grafana 配置 ConfigMap ---------------------------------------------------
def load_dash(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)

def rewrite_drift(d):
    """drift 看板：面板 datasource 是 {type:prometheus, uid:${datasource}}，
    统一改成固定 uid；并删掉那个不再被引用的 datasource 模板变量（否则面板上会
    多一个永远空的「数据源」下拉框）。"""
    def walk(panels):
        for p in panels:
            ds = p.get("datasource")
            if isinstance(ds, dict) and ds.get("uid") == "${datasource}":
                ds["uid"] = ds_uid
            walk(p.get("panels") or [])
    walk(d.get("panels") or [])
    tmpl = d.get("templating") or {}
    lst = tmpl.get("list") or []
    d["templating"]["list"] = [v for v in lst if v.get("name") != "datasource"]
    return d

def rewrite_overview(d):
    """overview 看板：面板与 node 变量的 datasource 都是字符串 "${DS_PROMETHEUS}"，
    而 DS_PROMETHEUS 在 templating 里根本没声明 ⇒ provisioned 后会 No data。
    统一改成对象形式 {type:prometheus, uid:hlvm-prometheus}。"""
    raw = json.dumps(d, ensure_ascii=False)
    raw = raw.replace(
        '"datasource": "${DS_PROMETHEUS}"',
        '"datasource": {"type": "prometheus", "uid": "%s"}' % ds_uid,
    )
    return json.loads(raw)

drift = rewrite_drift(load_dash(os.path.join(dash_src_dir, "hlvm-storage-drift.json")))
overview = rewrite_overview(load_dash(os.path.join(dash_src_dir, "hlvm-overview.json")))

datasource_provider = {
    "apiVersion": 1,
    "datasources": [
        {
            "name": "hlvm-prometheus",
            "uid": ds_uid,
            "type": "prometheus",
            "access": "proxy",
            "url": ds_url,
            "isDefault": True,
            "editable": False,
        }
    ],
}
dashboard_provider = {
    "apiVersion": 1,
    "providers": [
        {
            "name": "hlvm",
            "type": "file",
            "disableDeletion": False,
            "editable": True,
            "options": {
                "path": "/var/lib/grafana/dashboards",
                "foldersFromFilesStructure": False,
            },
        }
    ],
}

grafana_cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {
        "name": "hlvm-grafana-config",
        "namespace": "hlvm-system",
        "labels": {
            "app.kubernetes.io/name": "hlvm",
            "app.kubernetes.io/component": "grafana",
        },
    },
    "data": {
        # 注意 key 即挂载文件名；datasource 与 dashboard 供应文件放在 provisioning 对应子目录。
        "datasource-prometheus.yaml": dump(datasource_provider),
        "dashboard-provider.yaml": dump(dashboard_provider),
        "hlvm-storage-drift.json": json.dumps(drift, ensure_ascii=False, indent=2),
        "hlvm-overview.json": json.dumps(overview, ensure_ascii=False, indent=2),
    },
}
with open(grafana_out, "w", encoding="utf-8", newline="\r\n") as fh:
    fh.write(dump(grafana_cm))
print("wrote", grafana_out, "keys:", list(grafana_cm["data"].keys()))
PY
