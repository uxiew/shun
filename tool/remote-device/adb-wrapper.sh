#!/bin/bash
# 由 up.sh 填好三个 @…@ 后复制进假 SDK 的 platform-tools/adb，不要直接运行。
#
# adb 服务在接手机的那台电脑上，所以 `adb forward` 的监听口也开在那边。
# flutter test 建好转发会立刻去连本机 127.0.0.1:<端口>，本机没人监听就 Connection refused；
# 慢一点的 flutter drive 则是一直等、不报错。所以这里在把端口交回调用方之前，
# 先经同一条 SSH 主连接在本机开同一个端口。其他 adb 命令原样交给真的 adb。
REAL=@REAL@
CTL=@CTL@
HOST=@HOST@
STATE=@STATE@

fwd=0
for a in "$@"; do
  case $a in
    forward) fwd=1 ;;
    --list | --remove | --remove-all) fwd=0 ;;
  esac
done
[ $fwd = 1 ] || exec "$REAL" "$@"

out=$("$REAL" "$@")
rc=$?
if [ $rc -ne 0 ]; then
  [ -n "$out" ] && printf '%s\n' "$out"
  exit $rc
fi
args=("$@")
spec=${args[$# - 2]} # forward 的本机一侧，形如 tcp:0 或 tcp:8080
port=${spec#tcp:}
# tcp:0 由 adb 服务挑端口，挑中的端口打在输出里
[ "$port" = 0 ] && port=$(printf '%s' "$out" | tr -dc 0-9)
ssh -S "$CTL" -O forward -L "$port:127.0.0.1:$port" "$HOST" 2>/dev/null || true
# flutter test 结束时不删自己建的转发，记下来由 down.sh 删，免得在那台电脑上越积越多
echo "$port" >>"$STATE/forwards"
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
