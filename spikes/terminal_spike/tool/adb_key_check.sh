#!/usr/bin/env bash
# 用 adb 往 spike 注入真实按键事件（走 Android 输入管线，不是 Dart 里直接调 sendKey），
# 读 logcat 里的 SPIKE_SENT，逐项比对终端发出的字节。
#
# 用法：
#   1. 装好并打开 spike：adb install -r build/app/outputs/flutter-apk/app-release.apk
#                         adb shell am start -n top.xdwa.xwshun.terminal_spike/.MainActivity
#   2. tool/adb_key_check.sh [设备ID]     # 只有一台设备时可以不写
#
# 输出每个按键一行 PASS/FAIL，最后一行汇总；有 FAIL 时退出码 1。
# 期望值按 xterm 默认模式（普通光标模式、Backspace 发 0x7f）。远端程序切到"应用光标模式"
# 之后方向键会变成 ESC O A——那是正确行为，但这个脚本只测回环页的默认模式。
#
# 撞墙时：
# - 全部 FAIL 且"实际"为空：终端没拿到焦点。脚本会先点一下屏幕上部，如果你的设备
#   屏幕比例特殊，手动点一下终端区域再跑。
# - 用 zsh 直接把命令存进变量再执行会报 "command not found"（zsh 不拆分变量），所以这里是 bash。
# - 方向键/退格等全部 0 字节：装的是没有 android_key_fallback 的旧包。adb 注入的键 scanCode=0，
#   flterm 0.0.5 按物理键查表认不出来。
# - 最后一段 Ctrl/Alt 组合报 FAIL 不代表终端有问题，只统计不计入退出码：用 `input keycombination`
#   注入时，Flutter 收到的顺序是 Ctrl 按下→Ctrl 抬起→C 按下→C 抬起（SPIKE_KEY 日志），
#   C 到达时 Ctrl 已不算按住。真实硬件键盘的组合键要用带扫描码的方式另测（见 plan/v3/evidence/R04.md）。
set -euo pipefail

dev=${1:-${ANDROID_SERIAL:-}}
a() { adb ${dev:+-s "$dev"} "$@"; }

size=$(a shell wm size | awk -F'[ x]' '/Physical/{print $3" "$4}')
read -r w h <<<"$size"
a shell input tap $((w / 2)) $((h * 3 / 10))
sleep 1

# 取一次操作之后所有 SPIKE_SENT 的十六进制，多次发送用 " | " 隔开。
sent_after() {
  a logcat -c
  a shell "$@"
  sleep 0.6
  a logcat -d -s flutter |
    sed -n 's/.*SPIKE_SENT [0-9]*B  \([0-9a-f ]*\)  「.*/\1/p' |
    paste -sd'|' - | sed 's/|/ | /g'
}

pass=0 fail=0
check() {
  local name=$1 expect=$2
  shift 2
  local got
  got=$(sent_after "$@")
  if [[ "$got" == "$expect" ]]; then
    printf 'PASS  %-10s %s\n' "$name" "$got"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-10s 期望 [%s] 实际 [%s]\n' "$name" "$expect" "$got"
    fail=$((fail + 1))
  fi
}

# Android KeyEvent 键码：19 上 22 右 111 Esc 61 Tab 67 退格 66 回车 92 PageUp 122 Home 131 F1
# 113 左 Ctrl，57 左 Alt，31 C，32 D，29 A，52 X
check 文字abc   '61 | 62 | 63'  input text abc
check 上        '1b 5b 41'      input keyevent 19
check 右        '1b 5b 43'      input keyevent 22
check Esc       '1b'            input keyevent 111
check Tab       '09'            input keyevent 61
check 退格      '7f'            input keyevent 67
check 回车      '0d'            input keyevent 66
check PageUp    '1b 5b 35 7e'   input keyevent 92
check Home      '1b 5b 48'      input keyevent 122
check F1        '1b 4f 50'      input keyevent 131

echo "合计 PASS $pass / FAIL $fail"
main_fail=$fail

# 以下只统计、不计入退出码：adb keycombination 的注入顺序问题，见文件头"撞墙时"。
echo "-- 组合键（adb 注入限制，仅参考）"
check Ctrl+C    '03'            input keycombination 113 31
check Ctrl+D    '04'            input keycombination 113 32
check Ctrl+A    '01'            input keycombination 113 29
check Alt+X     '1b 78'         input keycombination 57 52
[[ $main_fail -eq 0 ]]
