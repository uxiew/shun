"""在接手机的那台电脑上开一个 TCP 转发，让手机经自己的 Wi-Fi 连到本机的测试环境。

  python3 -u tcp-relay.py <监听 IP> <监听端口> <只放行的手机 IP> <转发到 127.0.0.1 的端口> <最长秒数>

只接手机那一个 IP，别的来源一连上就关。标准输入关掉（启动它的 ssh 断了）或到了最长秒数就退出，
不会留在那台电脑上一直开着口子。转发到的 127.0.0.1 端口一般是 adb reverse 时 ssh -R 接回本机的那个。
每个连接打一行 accepted/refused/closed，方便和测试日志对时间。
"""
import asyncio
import os
import sys
import threading
import time

listen_ip, listen_port, allow_ip, target_port, max_seconds = sys.argv[1:6]


def log(*parts):
    print(time.strftime('%H:%M:%S'), 'relay', *parts, flush=True)


def exit_when_stdin_closes():
    sys.stdin.read()
    log('stdin closed, exit')
    os._exit(0)


async def pipe(reader, writer):
    # 一头读完只关另一头的写（半关闭）。直接 close 的话，对方先发完、还在等回包的连接会被掐掉。
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
    except OSError:
        writer.close()


async def handle(reader, writer):
    peer = writer.get_extra_info('peername')
    if peer[0] != allow_ip:
        log('refused', peer)
        writer.close()
        return
    log('accepted', peer)
    try:
        target_reader, target_writer = await asyncio.open_connection(
            '127.0.0.1', int(target_port))
    except OSError as error:
        log('target unreachable', error)
        writer.close()
        return
    await asyncio.gather(pipe(reader, target_writer), pipe(target_reader, writer))
    target_writer.close()
    writer.close()
    log('closed', peer)


async def main():
    server = await asyncio.start_server(handle, listen_ip, int(listen_port))
    log('listening', listen_ip, listen_port, 'allow', allow_ip, '->', target_port)
    async with server:
        await asyncio.wait_for(server.serve_forever(), timeout=int(max_seconds))


threading.Thread(target=exit_when_stdin_closes, daemon=True).start()
try:
    asyncio.run(main())
except asyncio.TimeoutError:
    log('max seconds reached, exit')
