#!/bin/sh
# 假 tmux（只在 TMUX_MODE=fake 的容器里）：按 ~/.faketmux 第一行决定行为，其余照常转给真 tmux。
# 测试经 SSH 写这个文件来切换模式，不用重建容器。
mode=$(head -n 1 "$HOME/.faketmux" 2>/dev/null)
listing=no
for arg in "$@"; do
  [ "$arg" = list-sessions ] && listing=yes
done

case "$mode" in
  hang)
    # 远端 tmux 卡住：App 必须按自己的期限放弃，不能一直等。
    exec sleep 600
    ;;
  version\ *)
    if [ "${1:-}" = -V ]; then
      printf '%s\n' "${mode#version }"
      exit 0
    fi
    ;;
  binary)
    if [ "${1:-}" = -V ]; then
      # 版本行里夹控制字符和终端转义序列。
      printf 'tmux 3.5a\033]52;c;cHduZWQ=\007\033[2J\001\002\n'
      exit 0
    fi
    ;;
  fail)
    if [ "$listing" = yes ]; then
      echo 'server exited unexpectedly' >&2
      exit 1
    fi
    ;;
  huge)
    if [ "$listing" = yes ]; then
      # 约 20 MB：App 只读到上限就停，不把它整个读进内存。
      yes 'S|~|1|~|2|~|$1|~|3|~|1|~|0|~|3|~|0|~|C-b|~||~|huge' | head -c 20000000
      exit 0
    fi
    ;;
  garbage)
    if [ "$listing" = yes ]; then
      /usr/bin/tmux.real "$@"
      rc=$?
      # 真行之后混进各种坏行：字段数不对、非数字、伪造的 server、重复 ID、转义序列、超长行。
      printf 'not a tmux row at all\n'
      printf 'S|~|abc|~|def|~|$x|~|ghi|~|1|~|0|~|1|~|0|~|C-b|~||~|badnumbers\n'
      printf 'S|~|99999|~|1|~|$77|~|1|~|1|~|0|~|1|~|0|~|C-b|~||~|forged-server\n'
      printf 'S|~|1|~|2\n'
      printf '\033[2J\033]0;owned\007S|~|1|~|2|~|$5|~|3\n'
      head -c 300000 /dev/zero | tr '\0' 'x'
      printf '\n'
      exit $rc
    fi
    ;;
esac
exec /usr/bin/tmux.real "$@"
