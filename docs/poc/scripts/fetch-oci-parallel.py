#!/usr/bin/env python3
"""fetch-oci-parallel.py —— 弱网下拉 OCI 镜像：HTTP Range 分块 + 多连接并行，组装 OCI layout。

背景（ADR-006 §10.5）：真机直连 ghcr.io 时单连接被限速到 90–500 KiB/s 且抖动剧烈，
210 MiB 的镜像拉 8 分钟只到 66 MiB。ghcr 的 blob 端点支持 Range（HTTP 206），
把每层切成 2 MiB 块、8 并发抓取后按序拼装，实测吞吐提升到 ~1 MiB/s 量级。

产物是标准 OCI layout 目录（oci-layout + index.json + blobs/sha256/*），
可直接 `tar -cf img.tar oci-layout index.json blobs` 后 `ctr -n k8s.io images import`。

用法:
  python fetch-oci-parallel.py <repo> <tag> <outdir> [--chunk-mb 2] [--workers 8]
例:
  python fetch-oci-parallel.py topolvm/topolvm 0.42.0 ./oci --workers 8

注意:
  - 只取 linux/amd64 单架构（省掉 index 里其它架构的 manifest）。
  - `index.json` 的 manifests[0].size 必须等于 manifest blob 的真实字节数，
    且 annotations["io.containerd.image.name"] 决定 import 后的本地镜像名。
  - 走 HTTP(S)_PROXY 环境变量或 --proxy 指定的代理；没有代理也能跑，只是更慢。
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import subprocess
import sys

REG = "https://ghcr.io"


def curl(args):
    return subprocess.run(["curl", "-s", "--ssl-no-revoke", *args],
                          capture_output=True, text=True)


def get_token(repo, proxy):
    url = f"{REG}/token?scope=repository:{repo}:pull&service=ghcr.io"
    for extra in ([*proxy], []):
        r = curl([*extra, url])
        if r.returncode == 0 and '"token":"' in r.stdout:
            i = r.stdout.find('"token":"')
            return r.stdout[i + 9:r.stdout.find('"', i + 9)]
    raise SystemExit("无法获取 ghcr token")


def resolve_amd64_manifest(repo, tag, token, proxy):
    accepts = ("-H", "Accept: application/vnd.oci.image.index.v1+json,"
                     "application/vnd.docker.distribution.manifest.list.v2+json,"
                     "application/vnd.oci.image.manifest.v1+json")
    r = curl([*proxy, "-H", f"Authorization: Bearer {token}", *accepts,
              f"{REG}/v2/{repo}/manifests/{tag}"])
    doc = json.loads(r.stdout)
    if "manifests" in doc:
        for m in doc["manifests"]:
            p = m.get("platform", {})
            if p.get("os") == "linux" and p.get("architecture") == "amd64":
                return m["digest"]
        raise SystemExit("index 里没有 linux/amd64")
    return r.stdout  # 已经是单架构 manifest 时返回原文


def fetch_manifest(repo, digest, token, proxy, outdir):
    hexd = digest.split(":", 1)[1]
    path = os.path.join(outdir, "blobs", "sha256", hexd)
    if os.path.exists(path):
        return path
    r = curl([*proxy, "-H", f"Authorization: Bearer {token}",
              "-H", "Accept: application/vnd.oci.image.manifest.v1+json",
              "-o", path, f"{REG}/v2/{repo}/manifests/{digest}"])
    if r.returncode != 0:
        raise SystemExit(f"manifest 下载失败 {digest}")
    return path


def fetch_blob(repo, digest, token, proxy, outdir, chunk, workers):
    hexd = digest.split(":", 1)[1]
    final = os.path.join(outdir, "blobs", "sha256", hexd)
    if os.path.exists(final):
        print(f"  skip {hexd[:12]} (exists)")
        return
    url = f"{REG}/v2/{repo}/blobs/{digest}"
    head = curl([*proxy, "-H", f"Authorization: Bearer {token}", "-I", url]).stdout
    total = None
    for line in head.splitlines():
        if line.lower().startswith("content-length:"):
            total = int(line.split(":", 1)[1])
    if not total:
        # 有些 registry 不给 HEAD 长度，退回单连接
        curl([*proxy, "-H", f"Authorization: Bearer {token}", "-o", final, url])
        return
    parts = [(s, min(s + chunk - 1, total - 1)) for s in range(0, total, chunk)]
    tmpdir = os.path.join(outdir, "_chunks", hexd)
    os.makedirs(tmpdir, exist_ok=True)
    print(f"  {hexd[:12]} {total/1048576:.2f} MiB / {len(parts)} chunks / {workers} workers")

    def job(item):
        idx, (s, e) = item
        out = os.path.join(tmpdir, f"{idx:05d}")
        for _ in range(6):
            r = curl([*proxy, "-H", f"Authorization: Bearer {token}",
                      "-r", f"{s}-{e}", "-o", out, url])
            if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out) == e - s + 1:
                return
            if os.path.exists(out):
                os.remove(out)
        raise RuntimeError(f"range {s}-{e} 失败")

    with cf.ThreadPoolExecutor(max_workers=workers) as ex:
        for f in cf.as_completed([ex.submit(job, p) for p in enumerate(parts)]):
            f.result()

    with open(final + ".assembling", "wb") as fo:
        for idx in range(len(parts)):
            with open(os.path.join(tmpdir, f"{idx:05d}"), "rb") as fi:
                while True:
                    buf = fi.read(1 << 20)
                    if not buf:
                        break
                    fo.write(buf)
    os.replace(final + ".assembling", final)

    h = hashlib.sha256()
    with open(final, "rb") as fi:
        for buf in iter(lambda: fi.read(1 << 20), b""):
            h.update(buf)
    if h.hexdigest() != hexd:
        raise SystemExit(f"digest 不匹配 {digest}")
    import shutil
    shutil.rmtree(tmpdir, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("tag")
    ap.add_argument("outdir")
    ap.add_argument("--chunk-mb", type=int, default=2)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--proxy", default=os.environ.get("HTTPS_PROXY", ""))
    a = ap.parse_args()

    proxy = ["-x", a.proxy] if a.proxy else []
    os.makedirs(os.path.join(a.outdir, "blobs", "sha256"), exist_ok=True)
    token = get_token(a.repo, proxy)

    man_digest = resolve_amd64_manifest(a.repo, a.tag, token, proxy)
    man_path = fetch_manifest(a.repo, man_digest, token, proxy, a.outdir)
    manifest = json.load(open(man_path))

    print(f"manifest {man_digest}")
    fetch_blob(a.repo, manifest["config"]["digest"], token, proxy, a.outdir,
               1024 * 1024, a.workers)
    for layer in manifest["layers"]:
        fetch_blob(a.repo, layer["digest"], token, proxy, a.outdir,
                   a.chunk_mb * 1024 * 1024, a.workers)

    with open(os.path.join(a.outdir, "oci-layout"), "w") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)
    index = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [{
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": man_digest,
            "size": os.path.getsize(man_path),
            "platform": {"architecture": "amd64", "os": "linux"},
            "annotations": {
                "io.containerd.image.name": f"ghcr.io/{a.repo}:{a.tag}",
                "org.opencontainers.image.ref.name": a.tag,
            },
        }],
    }
    with open(os.path.join(a.outdir, "index.json"), "w") as f:
        json.dump(index, f, indent=2)
    print(f"\nOCI layout 就绪：{a.outdir}")
    print(f"  打包：tar -cf img.tar -C {a.outdir} oci-layout index.json blobs")
    print(f"  导入：ctr -n k8s.io images import img.tar")
    return 0


if __name__ == "__main__":
    sys.exit(main())
