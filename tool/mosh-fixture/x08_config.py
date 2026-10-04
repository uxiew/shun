#!/usr/bin/env python3
"""把 .run/fixture.json 转成 X08 设备测试的 --dart-define=X08_MOSH 参数（一行 JSON）。

udpHost 是模拟器眼里「这台 Mac」的数字地址：默认 10.0.2.2（模拟器网络里的本机回环别名）。
用法：python3 tool/mosh-fixture/x08_config.py [udpHost]
"""
import json
import pathlib
import sys

run = pathlib.Path(__file__).resolve().parent / '.run' / 'fixture.json'
f = json.loads(run.read_text())
print(json.dumps({
    'user': f['user'],
    'password': f['password'],
    'sshPort': f['sshPort'],
    'fingerprint': f['fingerprintSha256'],
    'udpPorts': f['udpPorts'],
    'udpHost': sys.argv[1] if len(sys.argv) > 1 else '10.0.2.2',
}, separators=(',', ':')))
