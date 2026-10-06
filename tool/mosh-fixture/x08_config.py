#!/usr/bin/env python3
"""把 .run/fixture.json 转成设备测试的 --dart-define 参数（一行 JSON）。
X08（X08_MOSH，integration_test/mosh_runtime_test.dart）和 X09（X09_MOSH，integration_test/mosh_session_test.dart）共用。

udpHost 是模拟器眼里「这台 Mac」的数字地址：默认 10.0.2.2（模拟器网络里的本机回环别名）。
X09 的 App 直接用它连 SSH（sshHost），UDP 跟着 SSH 实际连上的 IP 走，所以两者是同一个地址。
用法：python3 tool/mosh-fixture/x08_config.py [udpHost]
"""
import json
import pathlib
import sys

run = pathlib.Path(__file__).resolve().parent / '.run' / 'fixture.json'
f = json.loads(run.read_text())
host = sys.argv[1] if len(sys.argv) > 1 else '10.0.2.2'
print(json.dumps({
    'user': f['user'],
    'password': f['password'],
    'sshPort': f['sshPort'],
    'fingerprint': f['fingerprintSha256'],
    'udpPorts': f['udpPorts'],
    'udpHost': host,
    'sshHost': host,
    'nomoshPort': f.get('nomoshPort'),
    'nomoshFingerprint': f.get('nomoshFingerprintSha256'),
}, separators=(',', ':')))
