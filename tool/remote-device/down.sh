#!/bin/bash
# 拆掉 up.sh 建的隧道和假 SDK，并删掉经包装脚本建过的 adb 转发、反向转发。
# 那台电脑上的 adb 服务不停（那边可能还有人在用）。
host=${1:?用法：./down.sh <ssh 主机>}
state=/tmp/xwshun-remote-device
if [ -s "$state/forwards" ] && ssh -S "$state/ssh.ctl" -O check "$host" 2>/dev/null; then
  for p in $(sort -u "$state/forwards"); do
    ADB_SERVER_SOCKET=tcp:127.0.0.1:$(cat "$state/adb-port") \
      "$(cat "$state/real-adb")" forward --remove "tcp:$p" 2>/dev/null || true
  done
fi
if [ -s "$state/reverses" ]; then
  for p in $(sort -u "$state/reverses"); do
    ADB_SERVER_SOCKET=tcp:127.0.0.1:$(cat "$state/adb-port") \
      "$(cat "$state/real-adb")" reverse --remove "$p" 2>/dev/null || true
  done
fi
ssh -S "$state/ssh.ctl" -O exit "$host" 2>/dev/null || true
rm -rf "$state"
echo "已拆。开着的终端里还有 source 进去的变量，关掉那个终端或重新 source ../.toolchain/env.sh。"
