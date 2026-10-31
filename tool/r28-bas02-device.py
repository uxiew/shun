#!/usr/bin/env python3
"""BAS02（R28）、SYN03（R61）：AI、检查更新关着、云同步没配置时，正式包在冷启动、打开设置、后台再回来、收到 deep link 时
有没有往手机外面发任何东西。

怎么跑（模拟器要带 -tcpdump 启动、拿好锁、装好正式包 top.xdwa.shun，见 plan/v3/evidence/R28.md）：

  python3 tool/r28-bas02-device.py <输出目录> measure   # 被测的那些动作
  python3 tool/r28-bas02-device.py <输出目录> control   # 对照：用户自己点「测试连接」，要先起 tool/fixture-environment
  python3 tool/r28-bas02-device.py <输出目录> sync      # SYN03：在云端备份页配好 S3（电脑上的假服务器），点「立即备份」，只该连填的地址
  python3 tool/r28-bas02-device.py <输出目录> pcap <pcap 文件>   # 都跑完后按时间窗整理抓包

三路互相独立的观察，前两路按 App 的 uid：
  1. 内核按 uid 记的流量：`dumpsys netstats --poll` 后读 `detail`（DNS 也记在发起的 App 名下，见 R01）。回环不计。
  2. 每 0.3 秒读一次 /proc/net/{tcp,tcp6,udp,udp6}，记下这个 uid 的套接字连着哪。
  3. 模拟器自己的 -tcpdump（整台模拟器的流量）：分不出 uid，系统的 Google 服务也在发，
     只用来按时间窗列出 DNS 查询和 TLS 里的域名，看有没有 App 这些功能会去的地方。
对照那一段三路都必须看得到这个 App 的流量，不然「测量段零流量」可能只是测量本身坏了。
只读写这个模拟器和输出目录，不碰真机。
"""
import json
import re
import struct
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SERIAL = 'emulator-5580'
PKG = 'top.xdwa.shun'
ACTIVITY = f'{PKG}/.MainActivity'
# App 里继承来、关着的功能会去的地方（R28.md 表 1），抓包里出现就要查。
WATCH = ['openai', 'anthropic', 'github', 'tailscale', 'googleapis.com/v1beta',
         'generativelanguage', 'openrouter', 'deepseek', 'netcatty', 'amazonaws', 'webdav']


def adb(*args, check=False, timeout=60):
    return subprocess.run(['adb', '-s', SERIAL, *args], capture_output=True, text=True,
                          errors='replace', timeout=timeout, check=check).stdout


def uid_of():
    found = re.search(rf'package:{re.escape(PKG)} uid:(\d+)',
                      adb('shell', 'cmd', 'package', 'list', 'packages', '-U', PKG))
    if not found:
        sys.exit(f'{PKG} 没装')
    return found.group(1)


def force_poll():
    """让系统现在就把内核计数读进 netstats。

    API 30 上 shell 跑 `dumpsys netstats --poll` 会报 `Requires ... NETWORK_STACK`，什么也不做；
    这时 detail 里只有系统自己（默认 30 分钟一次）读的旧数，刚发的流量是 0——R28 第一遍就这样误读成「零流量」。
    网络一变系统会自己读一次，所以被拒时关开一次移动数据（这台模拟器默认网络是蜂窝）。
    只在测量窗口两头做，窗口里不动网络。"""
    if 'Security exception' not in adb('shell', 'dumpsys', 'netstats', '--poll'):
        return 'dumpsys netstats --poll'
    adb('shell', 'svc', 'data', 'disable')
    time.sleep(3)
    adb('shell', 'svc', 'data', 'enable')
    time.sleep(8)
    return 'svc data disable/enable'


def netstats(uid):
    """内核记在 uid 名下的行（原样）和收发字节合计。调用前先 force_poll()。"""
    rows, total, mine = [], 0, False
    for line in adb('shell', 'dumpsys', 'netstats', 'detail').splitlines():
        head = re.search(r'\buid=(-?\d+)\b', line)
        if head:
            mine = head.group(1) == uid
            if mine:
                rows.append(line.strip())
            continue
        if mine:
            for rb, tb in re.findall(r'\brb=(\d+) rp=\d+ tb=(\d+)', line):
                total += int(rb) + int(tb)
                rows.append(line.strip())
    return rows, total


def hex_endpoint(text):
    addr, port = text.split(':')
    port = int(port, 16)
    if len(addr) == 8:
        ip = '.'.join(str(b) for b in bytes.fromhex(addr)[::-1])
    else:
        raw = b''.join(bytes.fromhex(addr[i:i + 8])[::-1] for i in range(0, 32, 8))
        ip = (('.'.join(str(b) for b in raw[12:])) if raw[:12] == b'\0' * 10 + b'\xff\xff'
              else raw.hex())
    return f'{ip}:{port}'


class Sampler(threading.Thread):
    """读 /proc/net，记下 uid 的套接字的对端（带第一次看到的时间）。对端全 0 的是监听或未连接，不记。"""

    def __init__(self, uid):
        super().__init__(daemon=True)
        self.uid, self.seen, self.stop, self.reads = uid, {}, threading.Event(), 0

    def run(self):
        while not self.stop.is_set():
            text = adb('shell', 'cat', '/proc/net/tcp', '/proc/net/tcp6', '/proc/net/udp',
                       '/proc/net/udp6')
            self.reads += 1
            for line in text.splitlines():
                cols = line.split()
                if len(cols) < 8 or cols[7] != self.uid or ':' not in cols[2]:
                    continue
                if set(cols[2].split(':')[0]) == {'0'}:
                    continue
                self.seen.setdefault(hex_endpoint(cols[2]), time.time())
            self.stop.wait(0.3)


def ui_nodes():
    adb('shell', 'uiautomator', 'dump', '/sdcard/r28-ui.xml')
    xml = adb('exec-out', 'cat', '/sdcard/r28-ui.xml')
    nodes = []
    for node in ET.fromstring(xml).iter('node'):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
        nodes.append({'label': (node.get('text') or '') + '|' + (node.get('content-desc') or ''),
                      'cls': node.get('class', ''), 'at': ((x1 + x2) // 2, (y1 + y2) // 2)})
    return nodes


def tap(label, nodes=None):
    for node in nodes or ui_nodes():
        if label in node['label']:
            adb('shell', 'input', 'tap', *map(str, node['at']))
            return node
    raise SystemExit(f'屏幕上没有「{label}」')


def shot(out, name):
    with (out / f'{name}.png').open('wb') as png:
        subprocess.run(['adb', '-s', SERIAL, 'exec-out', 'screencap', '-p'], stdout=png,
                       timeout=30)


def measure(out, log):
    log('cold-start', adb('shell', 'am', 'start', '-W', '-n', ACTIVITY))
    time.sleep(12)
    shot(out, 'cold-start')
    tap('设置\n')
    time.sleep(2)
    labels = set()
    for _ in range(12):  # 懒加载的列表：滑到底，每一项都得建出来
        labels.update(n['label'] for n in ui_nodes() if n['label'] != '|')
        adb('shell', 'input', 'swipe', '540', '1800', '540', '500', '300')
        time.sleep(1)
    labels.update(n['label'] for n in ui_nodes() if n['label'] != '|')
    (out / 'settings-labels.txt').write_text('\n'.join(sorted(labels)) + '\n')
    log('settings', f'{len(labels)} 个可见标签，见 settings-labels.txt')
    shot(out, 'settings-bottom')
    time.sleep(5)
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    log('home', 'HOME')
    time.sleep(8)
    log('resume', adb('shell', 'am', 'start', '-W', '-n', ACTIVITY))
    time.sleep(6)
    adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP')
    log('screen-off', 'KEYCODE_SLEEP')
    time.sleep(6)
    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    adb('shell', 'wm', 'dismiss-keyguard')
    log('screen-on', 'KEYCODE_WAKEUP + dismiss-keyguard')
    time.sleep(6)
    # deep link：本 App 只接 UU 回调。伪造一个，再拿 ssh:// 和显式 Intent 带数据、带 ce86d30 那个 extra 去敲。
    for name, args in [
        ('deeplink-uu-forged', ['-a', 'android.intent.action.VIEW', '-d',
                                'shun-uuremote://callback?state=r28forged&code=1&host=192.0.2.1']),
        ('deeplink-ssh', ['-a', 'android.intent.action.VIEW', '-d', 'ssh://nobody@192.0.2.1:22']),
        ('explicit-ssh-data', ['-n', ACTIVITY, '-a', 'android.intent.action.VIEW', '-d',
                               'ssh://nobody@192.0.2.1:22', '--es', 'cached_engine_id', 'r28',
                               '--es', 'route', '/r28']),
    ]:
        log(name, adb('shell', 'am', 'start', '-W', *args))
        time.sleep(6)
    shot(out, 'after-deeplinks')
    log('pid-after-deeplinks', adb('shell', 'pidof', PKG).strip() or '（没在跑）')
    adb('shell', 'am', 'force-stop', PKG)
    time.sleep(2)
    log('cold-start-2', adb('shell', 'am', 'start', '-W', '-n', ACTIVITY))
    time.sleep(12)


def control(out, log):
    """对照：同一个包，用户新建 SSH 连接、点「测试连接」去 10.0.2.2:22201（电脑上的测试环境）。
    不接受指纹、不填密码：只要有包发出去。虚拟 Wi-Fi 下连 10.0.2.2 的 TCP 建得上、收不到数据
    （docs/dev/README.md 第 3 节），所以这里可能一直等到超时，不影响对照。"""
    log('control-start', adb('shell', 'am', 'start', '-W', '-n', ACTIVITY))
    time.sleep(4)
    tap('连接\n')  # 底栏第一页，10-30 前叫「保险库」
    time.sleep(1)
    tap('添加连接')
    time.sleep(2)
    tap('|SSH')
    time.sleep(2)
    fields = [n for n in ui_nodes() if n['cls'].endswith('EditText')]
    # 顺序：名称、主机名 / IP、用户名、端口（host_editor.dart、connection_endpoint_fields）
    for node, text in zip(fields[:4], ['r28control', '10.0.2.2', 'nobody', '22201']):
        adb('shell', 'input', 'tap', *map(str, node['at']))
        time.sleep(0.5)
        if text == '22201':
            adb('shell', 'input', 'keyevent', 'KEYCODE_MOVE_END', 'KEYCODE_DEL', 'KEYCODE_DEL')
        adb('shell', 'input', 'text', text)
        time.sleep(0.5)
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')  # 收键盘
    time.sleep(1)
    tap('测试连接')
    log('control-probe', 'tapped 测试连接')
    for _ in range(25):
        time.sleep(1)
        nodes = ui_nodes()
        if any('确认服务器指纹' in n['label'] for n in nodes):
            shot(out, 'control-hostkey')
            tap('拒绝', nodes)
            log('control-hostkey', '弹了指纹框，点了拒绝')
            break
    time.sleep(3)
    shot(out, 'control-end')


SYNC_PORT = 22411


class _FakeS3(BaseHTTPRequestHandler):
    """电脑上的假 S3：GET、PUT 语义对就行，不验签名。只记方法和路径，请求头里有签名。"""
    files = {}
    requests = []

    def log_message(self, *args):
        pass

    def _answer(self, code, body=b''):
        self.send_response(code)
        self.send_header('ETag', f'"{len(body)}"')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def do_GET(self):
        _FakeS3.requests.append(f'GET {self.path}')
        body = _FakeS3.files.get(self.path.split('?')[0])
        self._answer(404) if body is None else self._answer(200, body)

    do_HEAD = do_GET

    def do_PUT(self):
        _FakeS3.requests.append(f'PUT {self.path}')
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        _FakeS3.files[self.path.split('?')[0]] = body
        self._answer(200)


def fill_next_empty(text):
    """填这一屏最上面的空输入框。Flutter 的输入框在无障碍树里没有标签，只能按顺序填。"""
    for _ in range(8):
        empty = [n for n in ui_nodes()
                 if n['cls'].endswith('EditText') and n['label'] == '|' and n['at'][1] < 1900]
        if empty:
            adb('shell', 'input', 'tap', *map(str, empty[0]['at']))
            time.sleep(0.5)
            adb('shell', 'input', 'text', text)
            time.sleep(0.5)
            # 键盘没起来时按返回会退到后台，所以先看一眼。
            if 'mInputShown=true' in adb('shell', 'dumpsys', 'input_method'):
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
                time.sleep(0.5)
            return
        adb('shell', 'input', 'swipe', '540', '1500', '540', '1000', '300')
        time.sleep(1)
    raise SystemExit(f'找不到空输入框来填 {text[:8]}')


def scroll_to(label):
    for _ in range(20):
        nodes = ui_nodes()
        if any(label in n['label'] and n['at'][1] < 1950 for n in nodes):
            return nodes
        adb('shell', 'input', 'swipe', '540', '1500', '540', '1000', '300')
        time.sleep(1)
    raise SystemExit(f'滑不到「{label}」')


def sync(out, log):
    """SYN03 后半段。S3 走 http（「允许不安全连接」），经 adb reverse 到电脑：模拟器里凭空起不了 https 假服务器。
    在用户这条路上走一遍真的云端备份页。"""
    server = ThreadingHTTPServer(('127.0.0.1', SYNC_PORT), _FakeS3)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    adb('reverse', f'tcp:{SYNC_PORT}', f'tcp:{SYNC_PORT}')
    try:
        adb('shell', 'am', 'force-stop', PKG)
        log('sync-start', adb('shell', 'am', 'start', '-W', '-n', ACTIVITY))
        time.sleep(6)
        tap('设置\n')
        time.sleep(2)
        tap('云端备份', scroll_to('云端备份'))
        time.sleep(2)
        tap('|S3', scroll_to('|S3'))
        time.sleep(1)
        adb('shell', 'input', 'swipe', '540', '1500', '540', '1000', '300')
        time.sleep(1)
        # Region 自带 us-east-1，不是空的，所以不在这个列表里；多填一个后面全错位，prefix 的值会跑进主密码框。
        for text in [f'http://127.0.0.1:{SYNC_PORT}', 'r61bucket', 'R61ACCESS', 'R61SECRET',
                     'R61TOKEN', 'shun']:
            fill_next_empty(text)
        # 带竖线才是开关本身；不带的话先匹配到旁边的「说明」按钮，弹窗会挡住后面的输入框。
        tap('|允许不安全连接', scroll_to('|允许不安全连接'))
        time.sleep(1)
        fill_next_empty('r61-master-password')
        log('sync-filled', '填好 S3 和主密码')
        tap('立即备份', scroll_to('立即备份'))
        log('sync-tapped', '点了立即备份')
        for _ in range(60):
            time.sleep(1)
            if any(r.startswith('PUT') for r in _FakeS3.requests):
                break
        time.sleep(4)
        log('sync-server', ' ; '.join(_FakeS3.requests) or '服务器没收到请求')
        stored = b''.join(_FakeS3.files.values())
        log('sync-stored', f'{len(stored)} bytes, secret-in-body={b"R61SECRET" in stored}, '
                           f'master-in-body={b"r61-master-password" in stored}')
        if not any(r.startswith('PUT') for r in _FakeS3.requests):
            raise SystemExit('服务器没收到 PUT：没同步上去')
        # 从云端恢复：真解密、弹确认框。这里点取消，写本机那段单测管；要看的是全程不往云端写。
        puts = sum(r.startswith('PUT') for r in _FakeS3.requests)
        tap('从云端恢复', scroll_to('从云端恢复'))
        log('restore-tapped', '点了从云端恢复')
        for _ in range(30):
            time.sleep(1)
            nodes = ui_nodes()
            if any('恢复备份' in n['label'] for n in nodes):
                break
        else:
            raise SystemExit('没等到恢复确认框')
        log('restore-dialog', ' ; '.join(n['label'] for n in nodes if n['label'] != '|'))
        tap('取消', nodes)
        time.sleep(2)
        if sum(r.startswith('PUT') for r in _FakeS3.requests) != puts:
            raise SystemExit('恢复往云端写了东西')
        log('restore-server', ' ; '.join(_FakeS3.requests))
    finally:
        server.shutdown()
        adb('reverse', '--remove', f'tcp:{SYNC_PORT}')


def pcap(out, path):
    """按时间窗列出抓包里的 DNS 查询、TLS SNI、去 10.0.2.2 的 TCP。Ethernet，IPv4 和 IPv6 都看。

    模拟器写的时间戳比宿主机慢一个时区（JST 下整 9 小时，把本地时间当 UTC 写了），
    不校正的话按宿主机时间划的窗口里一个包都没有。按「文件最后写入时间 − 最后一个包」取整到 15 分钟来校。"""
    windows = json.loads((out / 'windows.json').read_text())
    data = Path(path).read_bytes()
    magic = struct.unpack('<I', data[:4])[0]
    endian = '<' if magic in (0xa1b2c3d4, 0xa1b23c4d) else '>'
    nano = magic in (0xa1b23c4d, 0x4d3cb2a1)
    link = struct.unpack(endian + 'I', data[20:24])[0]
    events, off, last = [], 24, 0.0
    while off + 16 <= len(data):
        sec, frac, cap, _ = struct.unpack(endian + 'IIII', data[off:off + 16])
        pkt = data[off + 16:off + 16 + cap]
        off += 16 + cap
        t = last = sec + frac / (1e9 if nano else 1e6)
        kind = pkt[12:14] if link == 1 else b''
        ip = pkt[14:]
        if kind == b'\x08\x00' and len(ip) >= 20 and ip[0] >> 4 == 4:
            proto, body = ip[9], ip[(ip[0] & 15) * 4:]
            dst = '.'.join(map(str, ip[16:20]))
        elif kind == b'\x86\xdd' and len(ip) >= 40:
            proto, body = ip[6], ip[40:]  # 不展开扩展头：TCP/UDP 直接跟在后面的才看
            dst = ip[24:40].hex()
        else:
            continue
        if proto == 17 and len(body) >= 8 and struct.unpack('>H', body[2:4])[0] == 53:
            q, i = [], 20
            while i < len(body) and body[i]:
                q.append(body[i + 1:i + 1 + body[i]].decode('ascii', 'replace'))
                i += 1 + body[i]
            events.append((t, 'dns', '.'.join(q)))
        elif proto == 6 and len(body) >= 20:
            dport = struct.unpack('>H', body[2:4])[0]
            payload = body[(body[12] >> 4) * 4:]
            if dst == '10.0.2.2' and body[13] & 0x02:
                events.append((t, 'syn', f'{dst}:{dport}'))
            if payload[:1] == b'\x16' and b'\x00\x00' in payload[:200]:
                for m in re.finditer(rb'\x00\x00(.{2})\x00(.{2})([a-z0-9.-]{4,253})', payload, re.S):
                    events.append((t, 'sni', m.group(3).decode()))
                    break
    shift = round((Path(path).stat().st_mtime - last) / 900) * 900
    print(f'抓包时间校正 {shift:+d} 秒')
    report = {'_shiftSeconds': shift}
    for name, (start, end) in windows.items():
        hits = sorted({f'{kind} {what}' for t, kind, what in events
                       if start <= t + shift <= end})
        report[name] = {'events': hits,
                        'watched': [h for h in hits if any(w in h for w in WATCH)]}
    (out / 'pcap-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    for name, value in report.items():
        if name.startswith('_'):
            continue
        print(f'{name}: {len(value["events"])} 种事件，命中关注名单 {value["watched"]}')
        for hit in value['events']:
            print('   ', hit)


def main():
    out, phase = Path(sys.argv[1]), sys.argv[2]
    out.mkdir(parents=True, exist_ok=True)
    if phase == 'pcap':
        return pcap(out, sys.argv[3])
    uid = uid_of()
    poll = force_poll()
    rows_before, before = netstats(uid)
    sampler = Sampler(uid)
    sampler.start()
    lines = []

    def log(step, text):
        line = f'{time.time():.3f} {step}: {" ".join(text.split())}'
        lines.append(line)
        print(line, flush=True)

    start = time.time()
    try:
        {'measure': measure, 'control': control, 'sync': sync}[phase](out, log)
        time.sleep(3)
    finally:
        sampler.stop.set()
        sampler.join()
    end = time.time()
    force_poll()
    rows_after, after = netstats(uid)
    windows_path = out / 'windows.json'
    windows = json.loads(windows_path.read_text()) if windows_path.exists() else {}
    windows[phase] = [start, end]
    windows_path.write_text(json.dumps(windows))
    result = {
        'uid': uid, 'phase': phase, 'window': [start, end], 'netstatsPoll': poll,
        'netstatsBytes': {'before': before, 'after': after, 'delta': after - before},
        'netstatsRowsAfter': rows_after,
        'procNetReads': sampler.reads,
        'remoteEndpoints': {k: round(v - start, 1) for k, v in sorted(sampler.seen.items())},
        'steps': lines,
    }
    (out / f'{phase}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({k: result[k] for k in ['uid', 'netstatsBytes', 'procNetReads',
                                              'remoteEndpoints']}, ensure_ascii=False))
    print('netstats rows after:', *rows_after, sep='\n  ')


if __name__ == '__main__':
    main()
