#!/usr/bin/env bash
# 由仓库内的 PrometheusRule 源文件（config/prometheus/*.yaml）生成
# 可被裸 Prometheus `rule_files` 直接加载的 ConfigMap 清单。
#
# 关键约束：config/prometheus/*.yaml 是 monitoring.coreos.com/v1 PrometheusRule
# CRD 格式（带 apiVersion/kind/metadata/spec 包装），裸 Prometheus 的 rule_files
# 加载器只认顶层的 `groups:` 文档，直接挂会报
#   "field apiVersion not found in type rulefmt.RuleGroups"
# 并导致 Prometheus 启动失败（CrashLoop）。本脚本抽出 spec.groups 重写为裸规则，
# 输出 hlvm-prometheus-rules ConfigMap（4 个 key 各为一个 .yaml 规则文件）。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR="$SCRIPT_DIR/../prometheus"
OUT="$SCRIPT_DIR/prometheus-rules.yaml"
python3 - "$SRC_DIR" "$OUT" <<'PY'
import sys, os, yaml
src_dir, out = sys.argv[1], sys.argv[2]
files = ["alert-rules.yaml","alert-rules-drift.yaml","alert-rules-backup.yaml","recording-rules.yaml"]
data = {}
for f in files:
    p = os.path.join(src_dir, f)
    if not os.path.exists(p):
        raise SystemExit("missing rule source: " + p)
    doc = yaml.safe_load(open(p))
    groups = (doc.get("spec") or {}).get("groups", [])
    if not groups:
        raise SystemExit("no spec.groups in " + f)
    data[f] = yaml.safe_dump({"groups": groups}, sort_keys=False, default_flow_style=False)
cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {
        "name": "hlvm-prometheus-rules",
        "namespace": "hlvm-system",
        "labels": {"app.kubernetes.io/name": "hlvm", "app.kubernetes.io/component": "prometheus"},
    },
    "data": data,
}
open(out, "w").write(yaml.safe_dump(cm, sort_keys=False))
print("wrote", out, "keys:", list(data.keys()))
PY
