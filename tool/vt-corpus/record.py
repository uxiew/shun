#!/usr/bin/env python3
"""R20：给终端引擎对比测试（test/terminal_vt_corpus_test.dart）录 tmux 裁判和真实程序的原始输出。

做两件事，结果写进 test/fixtures/vt/：
1. 合成素材（synthetic_cases.txt 的每一段）原样写进一个 80x24 的 tmux 窗格，记下 tmux 自己的屏幕、光标、
   是否备用屏、光标是否显示、它回给程序的字节 → tmux_oracle.json 的 synthetic。
2. 真实程序（vim、less、htop、tmux 客户端、bash 行编辑）跑在 80x24 的 tmux 窗格里，pipe-pane 录下程序写进窗格的
   原始字节（recorded/<名字>.bin），每到一个检查点记下当时录了多少字节和 tmux 的屏幕 → tmux_oracle.json 的 recorded。

测试把同一份字节喂给 Ghostty（和对照的 xterm2），在同一位置和 tmux 的屏幕比。tmux 是独立的第三个终端实现，
用来判断两个引擎不一致时谁对。

只用测试环境的镜像（shun-fixture:alpine3.22，tool/fixture-environment/up.sh 构建）起一个一次性容器，
不连、不动正在跑的测试环境；容器里没有任何凭据。跑完删容器。

    python3 tool/vt-corpus/record.py              # 全部重录
    python3 tool/vt-corpus/record.py --only synthetic
    python3 tool/vt-corpus/record.py --only vim-cjk
"""

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
VT_DIR = ROOT / 'test' / 'fixtures' / 'vt'
CASES = VT_DIR / 'synthetic_cases.txt'
ORACLE = VT_DIR / 'tmux_oracle.json'
RECORDED = VT_DIR / 'recorded'
IMAGE = 'shun-fixture:alpine3.22'
CONTAINER = 'shun-vtcorpus-rec'
COLS, ROWS = 80, 24

ORACLE_CONF = f"""
set -g default-terminal "xterm-256color"
set -g status off
set -g default-size {COLS}x{ROWS}
set -s escape-time 0
set -g history-limit 2000
"""

# 被录的那个 tmux 客户端（tmux-client 场景）自己的配置：状态栏写死、不自动改窗口名、不定时刷新，
# 免得录的时候状态栏随时间变。
INNER_CONF = """
set -g default-terminal "xterm-256color"
set -g status-left "[in] "
set -g status-right "R20"
set -g status-interval 0
set -g automatic-rename off
set -s escape-time 0
set -g history-limit 2000
set-environment -g PS1 '$ '
"""

# 录 vim 场景时屏幕上显示的文件。里面的“欢迎使用 xwshun”是改名前录下的，和 test/fixtures/vt/ 里的录像逐字节对应：
# 只改这里不重录，对比测试会报屏幕不一致；要改就照 README 重录全部素材。
DEMO_PY = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""演示文件：终端引擎对比（R20）。"""

import sys


def 问候(名字: str) -> str:
    # 中文注释：返回一句问候
    return f"你好，{名字}！欢迎使用 xwshun 🙂"


CONFIG = {
\t"主机": "example.internal",
\t"端口": 22,
\t"说明": "这一行故意写得很长很长很长，超过八十列，用来看编辑器怎样折行显示中文和 ASCII 混排的内容 abc def ghi",
}

if __name__ == "__main__":
    print(问候(sys.argv[1] if len(sys.argv) > 1 else "世界"))
'''

NOTES_MD = '''# 笔记：中文标题

- 第一项：中文内容
- 第二项：English mixed 中文
- 第三项：emoji 👍 和全角符号（）【】

> 引用：终端里的中文要对齐。
'''


def long_txt() -> str:
    lines = []
    for i in range(1, 201):
        if i % 7 == 0:
            lines.append(f'第{i:03d}行 \x1b[32m绿色\x1b[0m \x1b[1;31m粗红\x1b[0m 普通 ascii text')
        elif i % 5 == 0:
            lines.append(f'第{i:03d}行 这是一行超过八十列的长内容，用来看 less 怎样折行：'
                         f'中文中文中文中文中文 abcdefghijklmnopqrstuvwxyz 0123456789 结尾')
        else:
            lines.append(f'第{i:03d}行 中文内容 the quick brown fox {i * 37 % 101}')
    return '\n'.join(lines) + '\n'


ZWJ = chr(0x200D)
FAMILY = f'👨{ZWJ}👩{ZWJ}👧'

# 每个场景：窗格里跑的命令、步骤。步骤是 (动作, 参数)：
#   keys：tmux send-keys 的键名列表；text：原样打进去的字（send-keys -l）；wait：秒；cp：检查点名字。
SCENARIOS = {
    'vim-cjk': {
        'command': "vim -N -u NONE -i NONE -c 'syntax on' "
                   "-c 'set encoding=utf-8 number hlsearch laststatus=2 ruler mouse=a' /work/demo.py",
        'steps': [
            ('wait', 1.5), ('cp', 'open'),
            ('text', ':vsplit /work/notes.md'), ('keys', ['Enter']), ('cp', 'vsplit'),
            ('text', '/中文'), ('keys', ['Enter']), ('cp', 'search'),
            ('keys', ['G']), ('cp', 'end'),
            ('keys', ['o']), ('text', '新增一行：测试 emoji 🙂 ok'), ('keys', ['Escape']), ('cp', 'insert'),
            ('keys', ['C-w', 'l']), ('keys', ['5', 'j']), ('cp', 'other-window'),
            ('text', ':qa!'), ('keys', ['Enter']), ('cp', 'quit'),
        ],
    },
    'less-cjk': {
        'command': 'less -R /work/long.txt',
        'steps': [
            ('wait', 1.0), ('cp', 'open'),
            ('keys', ['Space']), ('cp', 'page2'),
            ('text', '/第150行'), ('keys', ['Enter']), ('cp', 'search'),
            ('keys', ['G']), ('cp', 'end'),
            ('keys', ['q']), ('cp', 'quit'),
        ],
    },
    'htop': {
        'command': 'htop -d 100',
        'steps': [
            ('wait', 3.0), ('cp', 'open'),
            ('keys', ['t']), ('cp', 'tree'),
            ('keys', ['F2']), ('cp', 'setup'),
            ('keys', ['Escape']), ('wait', 0.5),
            ('keys', ['q']), ('cp', 'quit'),
        ],
    },
    'tmux-client': {
        'command': 'tmux -u -L inner -f /work/inner.conf new-session -s in',
        'steps': [
            ('wait', 1.5), ('cp', 'open'),
            ('keys', ['C-b', '%']), ('cp', 'split-h'),
            ('text', "printf '中文测试 %s\\n' 一 二 三"), ('keys', ['Enter']), ('cp', 'printf'),
            ('keys', ['C-b', '"']), ('cp', 'split-v'),
            ('text', 'seq 1 40'), ('keys', ['Enter']), ('cp', 'seq'),
            ('keys', ['C-b', '[']), ('keys', ['PPage']), ('cp', 'copy-mode'),
            ('keys', ['q']), ('keys', ['C-b', 'z']), ('cp', 'zoom'),
            ('keys', ['C-b', 'z']), ('wait', 0.5),
            ('exec', 'tmux -L inner kill-server'), ('cp', 'exit'),
        ],
    },
    'bash-readline': {
        'command': "env PS1='$ ' bash --norc --noprofile -i",
        'steps': [
            ('wait', 1.0), ('cp', 'prompt'),
            ('text', 'echo 中文输入abc'), ('cp', 'typed'),
            ('keys', ['Left', 'Left', 'Left', 'Left']), ('text', 'X'), ('cp', 'edit-cjk'),
            ('keys', ['C-u']), ('text', f'echo A{FAMILY}B'), ('keys', ['Left', 'Left']), ('text', 'Y'),
            ('cp', 'edit-zwj'),
            ('keys', ['C-u']),
            ('text', 'echo 一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十end'),
            ('cp', 'wrap-typed'),
            ('keys', ['Enter']), ('cp', 'wrap-run'),
            ('text', 'exit'), ('keys', ['Enter']), ('cp', 'exit'),
        ],
    },
}


def decode_escapes(text: str) -> bytes:
    """synthetic_cases.txt 的转义规则，和 test/support/vt_corpus.dart 的 decodeVtEscapes 一致。"""
    out = bytearray()
    i = 0
    simple = {'e': 0x1B, 'r': 0x0D, 'n': 0x0A, 't': 0x09, 'b': 0x08, 'a': 0x07, '\\': 0x5C}
    while i < len(text):
        ch = text[i]
        if ch != '\\':
            out += ch.encode('utf-8')
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
        elif nxt == 'x' and text[i + 2] == '{':
            end = text.index('}', i)
            out += chr(int(text[i + 3:end], 16)).encode('utf-8')
            i = end + 1
        elif nxt == 'x':
            out.append(int(text[i + 2:i + 4], 16))
            i += 4
        else:
            raise ValueError(f'不认识的转义 \\{nxt}（第 {i} 个字）')
    return bytes(out)


def parse_cases(path: pathlib.Path):
    cases = []
    current = None
    for line in path.read_text('utf-8').split('\n'):
        if line.startswith('=== '):
            name, _, desc = line[4:].partition('|')
            current = {'name': name.strip(), 'description': desc.strip(), 'text': ''}
            cases.append(current)
        elif line.startswith('#') or current is None:
            continue
        else:
            current['text'] += line
    for case in cases:
        case['bytes'] = decode_escapes(case.pop('text'))
    return cases


def docker(*args, input=None, check=True) -> bytes:
    result = subprocess.run(['docker', *args], input=input, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f'docker {" ".join(args)} 失败：{result.stderr.decode(errors="replace")}')
    return result.stdout


def run(cmd: str, input=None, check=True) -> bytes:
    return docker('exec', '-i', CONTAINER, 'sh', '-c', cmd, input=input, check=check)


def put(path: str, data: bytes):
    run(f'mkdir -p "$(dirname {path})" && cat > {path}', input=data)


def tmux(*args, server='oracle') -> str:
    conf = '/work/oracle.conf' if server == 'oracle' else '/work/inner.conf'
    out = docker('exec', CONTAINER, 'tmux', '-u', '-L', server, '-f', conf, *args)
    return out.decode('utf-8', errors='replace')


def size(path='/work/rec.bin') -> int:
    out = run(f'stat -c %s {path} 2>/dev/null || echo 0').decode().strip()
    return int(out or 0)


def wait_quiet(min_wait=0.6, stable=0.6, timeout=15.0):
    """等程序画完：录下的字节数在 stable 秒内不再变。"""
    time.sleep(min_wait)
    start = time.time()
    last, since = size(), time.time()
    while time.time() - start < timeout:
        time.sleep(0.15)
        now = size()
        if now != last:
            last, since = now, time.time()
        elif time.time() - since >= stable:
            return now
    raise RuntimeError('程序一直在输出，等不到安静下来')


def screen(target: str) -> dict:
    plain = tmux('capture-pane', '-p', '-t', target)
    styled = tmux('capture-pane', '-p', '-e', '-t', target)
    info = tmux('display', '-p', '-t', target,
                '#{cursor_x} #{cursor_y} #{alternate_on} #{cursor_flag} #{pane_width} #{pane_height}').split()
    rows = plain[:-1].split('\n') if plain.endswith('\n') else plain.split('\n')
    if len(rows) != ROWS or info[4:] != [str(COLS), str(ROWS)]:
        raise RuntimeError(f'窗格尺寸不对：{info}，{len(rows)} 行')
    styled_rows = styled[:-1].split('\n') if styled.endswith('\n') else styled.split('\n')
    return {
        'rows': [r.rstrip(' ') for r in rows],
        'styled': styled_rows,
        'cursor': [int(info[1]), int(info[0])],
        'alt': info[2] == '1',
        'cursorVisible': info[3] == '1',
    }


def record_synthetic(cases) -> dict:
    result = {}
    for case in cases:
        put('/work/case.bin', case['bytes'])
        run('rm -f /work/replies.bin')
        # 窗格里先 stty raw -echo：不把 \n 改成 \r\n（素材里的字节原样到 tmux），tmux 回给程序的字节不回显到屏幕上。
        # stderr 丢掉：timeout 杀掉 cat 时 busybox sh 会往窗格里打一句 Terminated。
        tmux('new-session', '-d', '-s', 'c', '-x', str(COLS), '-y', str(ROWS),
             'exec 2>/dev/null; stty raw -echo; head -c1 >/dev/null; cat /work/case.bin; '
             'timeout 2 cat > /work/replies.bin; exec sleep 100000')
        time.sleep(0.3)
        tmux('send-keys', '-t', 'c', 'x')
        time.sleep(2.6)
        snap = screen('c')
        snap['replies'] = run('cat /work/replies.bin 2>/dev/null || true').hex()
        snap['sha256'] = hashlib.sha256(case['bytes']).hexdigest()
        tmux('kill-session', '-t', 'c')
        result[case['name']] = snap
        print(f'  synthetic {case["name"]}: cursor={snap["cursor"]} alt={snap["alt"]}', flush=True)
    return result


def record_scenario(name: str, spec: dict) -> dict:
    run('rm -f /work/rec.bin')
    tmux('new-session', '-d', '-s', 'r', '-x', str(COLS), '-y', str(ROWS),
         f'stty raw -echo; head -c1 >/dev/null; stty sane; {spec["command"]}; exec sleep 100000')
    tmux('pipe-pane', '-t', 'r', 'cat > /work/rec.bin')
    time.sleep(0.3)
    tmux('send-keys', '-t', 'r', 'x')
    checkpoints = []
    try:
        for action, arg in spec['steps']:
            if action == 'keys':
                for key in arg:
                    tmux('send-keys', '-t', 'r', key)
                    time.sleep(0.05)
            elif action == 'text':
                tmux('send-keys', '-t', 'r', '-l', arg)
            elif action == 'wait':
                time.sleep(arg)
            elif action == 'exec':
                run(arg, check=False)
            elif action == 'cp':
                for attempt in range(6):
                    offset = wait_quiet()
                    snap = screen('r')
                    if size() == offset:
                        break
                else:
                    raise RuntimeError(f'{name}/{arg}：截屏时程序还在输出')
                snap['label'] = arg
                snap['offset'] = offset
                checkpoints.append(snap)
                print(f'  {name} {arg}: offset={offset} cursor={snap["cursor"]} alt={snap["alt"]}', flush=True)
    finally:
        tmux('kill-session', '-t', 'r')
    time.sleep(0.3)
    data = run('cat /work/rec.bin')
    if len(data) < checkpoints[-1]['offset']:
        raise RuntimeError(f'{name}：录下的文件比检查点短')
    RECORDED.mkdir(parents=True, exist_ok=True)
    (RECORDED / f'{name}.bin').write_bytes(data)
    return {
        'file': f'recorded/{name}.bin',
        'sha256': hashlib.sha256(data).hexdigest(),
        'bytes': len(data),
        'command': spec['command'],
        'checkpoints': checkpoints,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--only', help='synthetic 或某个场景名')
    args = parser.parse_args()

    cases = parse_cases(CASES)
    oracle = json.loads(ORACLE.read_text('utf-8')) if ORACLE.exists() else {}
    docker('rm', '-f', CONTAINER, check=False)
    docker('run', '-d', '--rm', '--name', CONTAINER, '--hostname', 'vtcorpus',
           '-e', 'LANG=C.UTF-8', '-e', 'LC_ALL=C.UTF-8', '--entrypoint', 'sleep', IMAGE, '1800')
    try:
        put('/work/oracle.conf', ORACLE_CONF.encode())
        put('/work/inner.conf', INNER_CONF.encode())
        put('/work/demo.py', DEMO_PY.encode())
        put('/work/notes.md', NOTES_MD.encode())
        put('/work/long.txt', long_txt().encode())
        oracle['tmux'] = docker('exec', CONTAINER, 'tmux', '-V').decode().strip()
        oracle['image'] = IMAGE
        oracle['programs'] = run(
            "vim --version | head -1; less --version | head -1; htop --version; bash --version | head -1"
        ).decode().strip().split('\n')
        oracle['size'] = [COLS, ROWS]
        if args.only in (None, 'synthetic'):
            oracle['synthetic'] = record_synthetic(cases)
        oracle.setdefault('recorded', {})
        for name, spec in SCENARIOS.items():
            if args.only in (None, name):
                oracle['recorded'][name] = record_scenario(name, spec)
        oracle['recordedAt'] = time.strftime('%Y-%m-%d')
    finally:
        docker('rm', '-f', CONTAINER, check=False)
    ORACLE.write_text(json.dumps(oracle, ensure_ascii=False, indent=1, sort_keys=True) + '\n', 'utf-8')
    print(f'写好了 {ORACLE.relative_to(ROOT)}')


if __name__ == '__main__':
    sys.exit(main())
