#!/usr/bin/env bash
# 给已经 up 的 ai-cli 容器接上假模型接口（mock-model.mjs），让真的 Claude Code、Codex 不登录也能对话。AIC06 用。
# 用法：./up.sh && ./mock-model.sh。想回到未登录的样子（R20 的 TER13）就重新 ./up.sh，容器是新建的。
#
# 两个工具的配置只写进容器里 fixture 用户的家目录：
#   Claude：~/.claude/settings.json 把 ANTHROPIC_BASE_URL 指到假接口，apiKeyHelper 给一个假密钥；
#           ~/.claude.json 标记走完引导、信任测试目录（不然每次先弹选主题、信任目录）。
#   Codex： ~/.codex/config.toml 用自定义 provider 指到假接口，信任测试目录。
# 信任要写到每个项目目录本身（AIC06 用 ~/aic/repo、~/aic/repo-wt、~/aic/codex）：Claude Code 2.1.314 不从父目录
# ~/aic 继承，只信任 ~/aic 时在 repo 里一启动就停在「Accessing workspace … Yes, I trust this folder」。
# 不配这些，工具一启动就停在登录页，测试等不到提示符。
#
# 另外装两样东西（要联网，第一次约 30 秒）：git（测「另一个 worktree」）、Claude Code 1.0.0 装在 ~/old-claude
# （测「不支持的版本」：它还没有 --session-id，会报 unknown option）。
set -euo pipefail
cd "$(dirname "$0")"
NAME=shun-ai-cli

docker ps --format '{{.Names}}' | grep -qx "$NAME" || { echo "先 ./up.sh" >&2; exit 1; }
docker cp mock-model.mjs "$NAME:/opt/mock-model.mjs"
docker exec "$NAME" sh -c 'command -v git >/dev/null || {
  apt-get update -qq && apt-get install -y -qq --no-install-recommends git >/dev/null && rm -rf /var/lib/apt/lists/*; }'
docker exec -u fixture "$NAME" bash -lc '[ -x ~/old-claude/node_modules/.bin/claude ] ||
  npm install --prefix ~/old-claude --no-fund --no-audit @anthropic-ai/claude-code@1.0.0 >/dev/null'
docker exec -u fixture "$NAME" bash -lc '
set -euo pipefail
mkdir -p ~/.claude ~/.codex ~/aic ~/mock-model
: > ~/mock-model/requests.jsonl
cat > ~/.claude/settings.json <<EOF
{
  "env": { "ANTHROPIC_BASE_URL": "http://127.0.0.1:18080" },
  "apiKeyHelper": "printf mock-key-not-a-secret"
}
EOF
node -e "
const fs = require(\"fs\"), p = process.env.HOME + \"/.claude.json\";
const c = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p)) : {};
c.hasCompletedOnboarding = true;
c.theme = \"dark\";
// 2.1.314 前三次启动弹「Try the new fullscreen renderer?」选择框，会吞掉测试打的第一句；选 Not now 也只是计数加一。
c.fullscreenUpsellSeenCount = 3;
c.projects = c.projects || {};
// allowedTools：同一个目录也要给 Claude Code 1.0.0 用。它不检查就遍历这个字段，而 2.1.314 写项目条目时不带它：
// 缺了的话 1.0.0 一启动就崩成「B.allowedTools is not iterable」，测不到它对「会话 ID 不存在」的真实反应。
for (const d of [\"aic\", \"aic/repo\", \"aic/repo-wt\", \"aic/codex\"]) {
  c.projects[process.env.HOME + \"/\" + d] = { hasTrustDialogAccepted: true, allowedTools: [] };
}
fs.writeFileSync(p, JSON.stringify(c, null, 2));
"
cat > ~/.codex/config.toml <<EOF
model = "mock-model"
model_provider = "mock"
check_for_update_on_startup = false

# Codex 0.166 退出界面后还留着后台 app-server，启动参数带 --analytics-default-enabled；关掉，测试不往外发统计。
[analytics]
enabled = false

[model_providers.mock]
name = "Mock"
base_url = "http://127.0.0.1:18080/v1"
wire_api = "responses"

[projects."$HOME/aic"]
trust_level = "trusted"

[projects."$HOME/aic/repo"]
trust_level = "trusted"

[projects."$HOME/aic/repo-wt"]
trust_level = "trusted"

[projects."$HOME/aic/codex"]
trust_level = "trusted"
EOF
'
# 旧的假接口还在跑就先杀掉，端口只有一个。写成 mj[s]：直接写文件名的话，pkill 会连执行它的这个 sh 一起杀（退出 143）。
docker exec "$NAME" sh -c 'pkill -f "node /opt/mock-model.mj[s]" || :'
docker exec -d -u fixture "$NAME" bash -lc 'exec node /opt/mock-model.mjs >> ~/mock-model/server.log 2>&1'
for _ in $(seq 20); do
  docker exec -u fixture "$NAME" node -e "fetch('http://127.0.0.1:18080/ping').then(()=>process.exit(0),()=>process.exit(1))" && break
  sleep 0.5
done
docker exec -u fixture "$NAME" node -e "fetch('http://127.0.0.1:18080/ping').then(()=>process.exit(0),()=>process.exit(1))" \
  || { echo '假模型接口没起来' >&2; docker exec -u fixture "$NAME" cat /home/fixture/mock-model/server.log >&2; exit 1; }
# 探活那一条也记进了日志，清掉，测试从空日志开始数。
docker exec -u fixture "$NAME" sh -c ': > ~/mock-model/requests.jsonl'
echo '假模型接口已在容器里 127.0.0.1:18080 上；Claude Code、Codex 已指向它'
