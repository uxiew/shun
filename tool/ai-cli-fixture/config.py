#!/usr/bin/env python3
"""把 .run/fixture.json 转成设备测试的 --dart-define=R20_AI_CLI 参数（端口、用户、密码、指纹）。

设备经 adb reverse 连本机的 22401 端口。密码每次 up.sh 都换，起环境后要重新取。
"""
import json
import pathlib

run = pathlib.Path(__file__).resolve().parent / '.run' / 'fixture.json'
fixture = json.loads(run.read_text())
print(json.dumps({k: fixture[k] for k in ('port', 'user', 'password', 'fingerprint')}))
