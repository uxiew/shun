#!/usr/bin/env bash
# 打印测试环境此刻的计数（一行 JSON），X09 的证据用：前后各跑一次，看差值。
#   moshServerStarts  装了 mosh 的那台上，mosh-server 一共被启动过几次（记账脚本记的）
#   moshServerRunning 此刻还在跑的 mosh-server 有几个（按脱离出来、父进程是 1 的那个数；
#                     每个还没被客户端连过的 mosh-server 另有一个等着起 shell 的子进程，不重复算）
#   installAttempts   两台上 sudo / apk / apt-get 之类一共被调过几次（应当永远是 0）
#   sshLogins         两台 sshd 日志里登录成功（Accepted）的次数，按 mosh / nomosh 分开
set -euo pipefail
cd "$(dirname "$0")"

run_in() { docker compose exec -T "$1" sh -c "$2" | tr -d ' \r'; }
lines() { run_in "$1" "cat $2 2>/dev/null | wc -l"; }
logins() { docker compose logs --no-log-prefix "$1" 2>/dev/null | grep -cE 'Accepted [a-z-]+ for ' || true; }

printf '{"moshServerStarts":%s,"moshServerRunning":%s,"installAttempts":%s,"sshLogins":{"mosh":%s,"nomosh":%s}}\n' \
  "$(lines mosh /var/log/shun/mosh-server-starts.log)" \
  "$(run_in mosh "ps -o ppid,comm | awk '\$1 == 1 && \$2 == \"mosh-server\"' | wc -l")" \
  "$(( $(lines mosh /var/log/shun/install-attempts.log) + $(lines nomosh /var/log/shun/install-attempts.log) ))" \
  "$(logins mosh)" "$(logins nomosh)"
