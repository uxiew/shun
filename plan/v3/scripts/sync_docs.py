#!/usr/bin/env python3
"""把 tasks.json / verification-cases.json 的状态同步到 docs/08、docs/09 的表格里。

状态只在 JSON 里改（用 set_status.py），然后跑这个脚本。别手改 markdown 里的状态列：
两处各改各的，迟早对不上，读者不知道信哪个。
"""
from pathlib import Path
import json, re

ROOT = Path(__file__).resolve().parents[1]
tasks = {t['id']: t for t in json.loads((ROOT / 'tasks.json').read_text())['tasks']}
cases = {c['id']: c for c in json.loads((ROOT / 'verification-cases.json').read_text())['cases']}

doc8 = ROOT / 'docs/08-implementation-tasks.md'
text = doc8.read_text()
current = None
out = []
for line in text.splitlines(keepends=True):
    m = re.match(r'^## ([RX]\d{2}) ', line)
    if m:
        current = m.group(1)
    elif current and line.startswith('阶段：'):
        line = re.sub(r'状态：[A-Z_]+', '状态：' + tasks[current]['status'], line, count=1)
    out.append(line)
doc8.write_text(''.join(out))

doc9 = ROOT / 'docs/09-verification.md'
out = []
for line in doc9.read_text().splitlines(keepends=True):
    m = re.match(r'^\|\s*([A-Z]{3}\d{2})\s*\|', line)
    if m and m.group(1) in cases:
        cells = line.rstrip('\n').split('|')
        # 最后一个非空单元格是结果列
        idx = max(i for i, c in enumerate(cells) if c.strip())
        pad = ' ' if cells[idx].startswith(' ') else ''
        cells[idx] = f'{pad}{cases[m.group(1)]["result"]}{pad}'
        line = '|'.join(cells) + '\n'
    out.append(line)
doc9.write_text(''.join(out))
print('synced')
