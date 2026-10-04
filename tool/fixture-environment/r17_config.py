#!/usr/bin/env python3
"""把 .run/fixture.json 里连边缘 sshd 要用的几项转成 R17 设备测试的 --dart-define=R17_SSH 参数。

用法见 integration_test/ghostty_engine_test.dart 文件头。设备经 adb reverse 连本机的 22201 端口。
密码每次 up.sh 都重新生成，所以每次起环境后都要重新取。
"""
import json
import pathlib

run = pathlib.Path(__file__).resolve().parent / '.run' / 'fixture.json'
fixture = json.loads(run.read_text())
print(json.dumps({
    'port': fixture['sshEdge']['port'],
    'user': fixture['user'],
    'password': fixture['password'],
    'fingerprint': fixture['sshEdge']['fingerprintSha256'],
}))
