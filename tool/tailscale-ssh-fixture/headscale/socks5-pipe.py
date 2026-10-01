#!/usr/bin/env python3
"""给 ssh 当 ProxyCommand 用的 SOCKS5 客户端（带用户名密码）。selfcheck-routes.sh 用。

macOS 自带的 nc 只会 SOCKS5 无认证，ts-relay 的 dante 要口令，所以自己写一个最小的。
用法：socks5-pipe.py <代理 host> <代理 port> <目标 host> <目标 port>，口令从环境变量 SOCKS_USER / SOCKS_PASS 读，
免得出现在 ps 里。只做 CONNECT，连上后在 stdin/stdout 和代理之间原样搬字节。
"""
import os
import select
import socket
import struct
import sys


def main() -> int:
    proxy_host, proxy_port, host, port = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
    user = os.environ["SOCKS_USER"].encode()
    password = os.environ["SOCKS_PASS"].encode()
    s = socket.create_connection((proxy_host, proxy_port), timeout=15)
    s.sendall(b"\x05\x01\x02")  # 只提供用户名密码一种方法
    if s.recv(2) != b"\x05\x02":
        sys.stderr.write("socks5-pipe: 代理不接受用户名密码认证\n")
        return 1
    s.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
    if s.recv(2) != b"\x01\x00":
        sys.stderr.write("socks5-pipe: 代理拒绝了用户名密码\n")
        return 1
    try:
        addr = b"\x01" + socket.inet_aton(host)
    except OSError:
        addr = b"\x03" + bytes([len(host)]) + host.encode()
    s.sendall(b"\x05\x01\x00" + addr + struct.pack(">H", port))
    head = s.recv(4)
    if len(head) < 4 or head[1] != 0:
        sys.stderr.write(f"socks5-pipe: CONNECT 失败，状态码 {head[1] if len(head) > 1 else '?'}\n")
        return 1
    # 跳过回复里的绑定地址和端口
    rest = {1: 4, 4: 16}.get(head[3])
    if rest is None:
        rest = s.recv(1)[0]
    s.recv(rest + 2)
    s.settimeout(None)
    stdin, stdout = sys.stdin.fileno(), sys.stdout.fileno()
    readers = [s, stdin]
    while True:
        ready, _, _ = select.select(readers, [], [])
        if s in ready:
            data = s.recv(65536)
            if not data:
                return 0
            os.write(stdout, data)
        if stdin in ready:
            data = os.read(stdin, 65536)
            if not data:
                s.shutdown(socket.SHUT_WR)
                readers.remove(stdin)
                continue
            s.sendall(data)


if __name__ == "__main__":
    sys.exit(main())
