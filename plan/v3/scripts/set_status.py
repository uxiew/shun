#!/usr/bin/env python3
"""改 tasks.json / verification-cases.json 里的状态，保持原 JSON 格式（indent=2、不转义中文）。

手工用 json.dump 改很容易把缩进写错，整份文件变成几千行 diff，没法审查。

用法：
  set_status.py task R00 IN_PROGRESS [--evidence evidence/R00.md] [--commit <sha>]
  set_status.py case NET03 PASS --evidence evidence/R03.md
  set_status.py meta implementation_started true

结果只写真实执行过的；PASS 必须带 --evidence，DONE 必须同时带 --evidence 和 --commit，
否则直接报错退出（validate_plan.py 也会拦 DONE 无证据）。
"""
from pathlib import Path
import json, sys

ROOT = Path(__file__).resolve().parents[1]
TASK_STATES = {'NOT_STARTED', 'IN_PROGRESS', 'DONE', 'BLOCKED', 'DEFERRED'}
CASE_STATES = {'NOT_RUN', 'PASS', 'FAIL', 'BLOCKED', 'N/A'}


def dump(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def opt(args, name):
    if name in args:
        i = args.index(name)
        return args[i + 1]
    return None


def main(argv):
    kind, key, value, rest = argv[0], argv[1], argv[2], argv[3:]
    evidence, commit = opt(rest, '--evidence'), opt(rest, '--commit')
    if kind == 'meta':
        p = ROOT / 'tasks.json'
        d = json.loads(p.read_text(encoding='utf-8'))
        d[key] = json.loads(value) if value in ('true', 'false') else value
        dump(p, d)
        return
    if kind == 'task':
        p, field, states, listkey = ROOT / 'tasks.json', 'status', TASK_STATES, 'tasks'
    elif kind == 'case':
        p, field, states, listkey = ROOT / 'verification-cases.json', 'result', CASE_STATES, 'cases'
    else:
        sys.exit('kind 只能是 task / case / meta')
    if value not in states:
        sys.exit(f'{value} 不在允许状态 {sorted(states)}')
    if value == 'PASS' and not evidence:
        sys.exit('PASS 必须带 --evidence')
    if value == 'DONE' and not (evidence and commit):
        sys.exit('DONE 必须带 --evidence 和 --commit')
    d = json.loads(p.read_text(encoding='utf-8'))
    hit = [x for x in d[listkey] if x['id'] == key]
    if not hit:
        sys.exit(f'找不到 {key}')
    x = hit[0]
    x[field] = value
    if evidence and evidence not in x['evidence']:
        x['evidence'].append(evidence)
    if commit:
        x['commit'] = commit
    dump(p, d)


if __name__ == '__main__':
    main(sys.argv[1:])
