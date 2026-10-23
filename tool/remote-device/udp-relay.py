"""在接手机的那台电脑上开一组 UDP 转发，让手机经自己的 Wi-Fi 连到本机测试环境里的 mosh-server。

  python3 -u udp-relay.py <监听 IP> <起始端口> <结束端口> <只放行的手机 IP> <最长秒数>

监听 IP 上的每个端口原样转发到 127.0.0.1 的同一端口：mosh-server 告诉客户端「连 6010x」，客户端按 SSH 连上的地址发过来，
不用改端口就能用。手机每换一个源端口（mosh 长时间收不到回应会换端口），就另开一个到 127.0.0.1 的 socket，
服务器看到的是一个新来源、按 mosh 协议跟过去，和家用路由器的 NAT 一样。别的来源的包直接丢，只计数。
标准输入关掉（启动它的脚本退了）或到了最长秒数就退出，不会一直开着口子。

有过来源以后每分钟打一行收发包数，没流量的分钟也打（记 0），锁屏拔线时手机还发不发包就看这几行。
"""
import os
import selectors
import socket
import sys
import threading
import time

listen_ip, first, last, allow_ip, max_seconds = sys.argv[1:6]


def log(*parts):
    print(time.strftime('%H:%M:%S'), 'udp', *parts, flush=True)


def exit_when_stdin_closes():
    sys.stdin.read()
    log('stdin closed, exit')
    os._exit(0)


selector = selectors.DefaultSelector()
listeners = {}
upstreams = {}
for port in range(int(first), int(last) + 1):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((listen_ip, port))
    sock.setblocking(False)
    listeners[port] = sock
    selector.register(sock, selectors.EVENT_READ, (port, None))
log('listening', f'{listen_ip}:{first}-{last}', 'allow', allow_ip, '-> 127.0.0.1 same port')

# 每分钟清零：手机 -> 服务器、服务器 -> 手机、被拒（别的来源）。
up = down = refused = 0
threading.Thread(target=exit_when_stdin_closes, daemon=True).start()
deadline = time.monotonic() + int(max_seconds)
next_report = time.monotonic() + 60
while True:
    now = time.monotonic()
    if now >= deadline:
        log('max seconds reached, exit')
        break
    if now >= next_report:
        if upstreams or refused:
            log(f'last minute: phone->server {up} server->phone {down} refused {refused}',
                'sources', ' '.join(f'{a[0]}:{a[1]}->{p}' for p, a in upstreams))
        up = down = refused = 0
        next_report += 60
    for key, _ in selector.select(timeout=max(0, min(next_report, deadline) - now)):
        port, phone = key.data
        try:
            data, source = key.fileobj.recvfrom(65535)
        except OSError:
            # 服务器那头的口子没人听时，上一次发包换回来的 ICMP 会在这里报 ConnectionRefused，丢掉这个包就行。
            continue
        try:
            if phone is None:
                if source[0] != allow_ip:
                    refused += 1
                    continue
                upstream = upstreams.get((port, source))
                if upstream is None:
                    upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    upstream.connect(('127.0.0.1', port))
                    upstream.setblocking(False)
                    upstreams[(port, source)] = upstream
                    selector.register(upstream, selectors.EVENT_READ, (port, source))
                    log('new source', f'{source[0]}:{source[1]}', '->', port)
                upstream.send(data)
                up += 1
            else:
                listeners[port].sendto(data, phone)
                down += 1
        except OSError as error:
            log('send failed', port, error)
