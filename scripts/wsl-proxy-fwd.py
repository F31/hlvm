#!/usr/bin/env python3
"""WSL 代理转发器。

背景：Windows 宿主代理（如 Clash）在 WSL 内可通过 127.0.0.1:7890 访问，但 kind 节点容器内
的 127.0.0.1 是节点自身，无法直连宿主回环。本脚本在 WSL host 上监听 0.0.0.0:17890，
把流量转发到可用的上游代理（默认 127.0.0.1:7890）。kind 节点即可通过 docker0 网关
（通常是 172.17.0.1:17890）走代理。

用法：
    python3 scripts/wsl-proxy-fwd.py [--listen 0.0.0.0:17890] [--upstream 127.0.0.1:7890]

验证：
    docker exec <node> curl -x http://172.17.0.1:17890 -o /dev/null -w '%{http_code}\n' https://quay.io/v2/
    # 期望 401（可达）

说明：这是原始 TCP 转发（支持 HTTP CONNECT 隧道）；并发下载的上限取决于上游代理本身。
"""

import argparse
import socket
import threading


def parse_addr(value: str):
    host, _, port = value.rpartition(":")
    if not host or not port:
        raise argparse.ArgumentTypeError(f"地址格式应为 host:port，实际为 {value!r}")
    return host, int(port)


def pump(src: socket.socket, dst: socket.socket) -> None:
    """单向搬运；读到 EOF 时仅关闭对端写方向（半关闭），避免截断另一方向。"""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def handle(conn: socket.socket, upstream_addr) -> None:
    try:
        upstream = socket.create_connection(upstream_addr, timeout=10)
    except Exception:
        try:
            conn.close()
        except Exception:
            pass
        return

    t1 = threading.Thread(target=pump, args=(conn, upstream), daemon=True)
    t2 = threading.Thread(target=pump, args=(upstream, conn), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

    for s in (conn, upstream):
        try:
            s.close()
        except Exception:
            pass


def main() -> None:
    ap = argparse.ArgumentParser(description="WSL 代理 TCP 转发器")
    ap.add_argument("--listen", type=parse_addr, default=("0.0.0.0", 17890))
    ap.add_argument("--upstream", type=parse_addr, default=("127.0.0.1", 7890))
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(args.listen)
    srv.listen(256)
    print(
        "forwarder listening on %s:%d -> %s:%d" % (args.listen + args.upstream),
        flush=True,
    )
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, args.upstream), daemon=True).start()


if __name__ == "__main__":
    main()
