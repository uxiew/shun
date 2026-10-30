#!/usr/bin/env bash
# AIC06 设备测试（integration_test/aic06_real_cli_test.dart）：真的 Claude Code / Codex + 容器里的假模型接口。
# 每次都重建 ai-cli 容器再接假接口：Codex 的历史列表要从空的开始数，上一轮留下的对话会让「默认选中哪段」对不上。
# 只认本项目的模拟器（emulator-5580），先拿锁、开好模拟器，见 docs/dev/README.md 第 3、7 节。
# 日志、截图、假接口的请求记录、两个工具的会话文件清单都在 ../.toolchain/artifacts/aic06-<提交>/。
set -euo pipefail
cd "$(dirname "$0")/.."
source ../.toolchain/env.sh
export PATH="$HOME/.orbstack/bin:$PATH"
SERIAL=emulator-5580
PKG=top.xdwa.shun.debug
ADB=(adb -s "$SERIAL")
case "$("${ADB[@]}" emu avd name | tr -d '\r' | head -1)" in
  shun-r39-a30|shun-a35-4k) ;;
  *) echo 'Expected a dedicated shun emulator (shun-r39-a30 or shun-a35-4k)'; exit 1 ;;
esac
OUT=../.toolchain/artifacts/aic06-$(git rev-parse --short HEAD)
mkdir -p "$OUT"
(cd tool/ai-cli-fixture && ./up.sh >/dev/null && ./mock-model.sh)
python3 - <<'PY'
import json, pathlib
root = pathlib.Path('tool/ai-cli-fixture/.run')
fixture = json.loads((root / 'fixture.json').read_text())
cfg = {k: fixture[k] for k in ('port', 'user', 'password', 'fingerprint')}
path = root / 'aic06-defines.json'
path.write_text(json.dumps({'AIC06_CONFIG': json.dumps(cfg)}))
path.chmod(0o600)
PY
cp tool/ai-cli-fixture/.run/hostkeys/versions.txt "$OUT/versions.txt"
"${ADB[@]}" reverse tcp:22401 tcp:22401 >/dev/null
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
"${ADB[@]}" shell input keyevent 82
"${ADB[@]}" shell pm clear "$PKG" >/dev/null 2>&1 || true
grant_pid=''
cleanup() {
  [[ -z "$grant_pid" ]] || kill "$grant_pid" 2>/dev/null || true
  "${ADB[@]}" reverse --remove tcp:22401 >/dev/null 2>&1 || true
}
trap cleanup EXIT
# 通知权限要在装完包之后才能授，包是 flutter test 自己装的，所以在后台轮询着授。
(for _ in $(seq 1 600); do
  "${ADB[@]}" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null && break
  sleep 0.5
done) >/dev/null 2>&1 & grant_pid=$!
LOG="$OUT/test.log"
flutter test --no-pub integration_test/aic06_real_cli_test.dart -d "$SERIAL" \
  --dart-define-from-file=tool/ai-cli-fixture/.run/aic06-defines.json > "$LOG" 2>&1 &
TEST=$!
SEEN=0
while kill -0 "$TEST" 2>/dev/null; do
  COUNT=$(grep -c 'AIC06 SHOT=' "$LOG" || true)
  while (( SEEN < COUNT )); do
    SEEN=$((SEEN + 1))
    NAME=$(grep 'AIC06 SHOT=' "$LOG" | sed -n "${SEEN}p" | sed 's/.*AIC06 SHOT=//' | tr -d '\r')
    "${ADB[@]}" exec-out screencap -p > "$OUT/$NAME.png" || true
  done
  sleep 0.5
done
wait "$TEST" && STATUS=0 || STATUS=$?
# 假接口的请求记录和会话文件清单留作证据：里面只有会话 ID、口令和条数，没有提示词全文和密钥。
docker exec -u fixture shun-ai-cli cat /home/fixture/mock-model/requests.jsonl > "$OUT/mock-requests.jsonl" || true
docker exec -u fixture shun-ai-cli sh -c 'find ~/.claude/projects ~/.codex/sessions -name "*.jsonl" | sort' > "$OUT/session-files.txt" || true
grep -E 'AIC06 |\[E\]|Expected|Actual|Which|Timed out|All tests|Some tests|skipped' "$LOG" | grep -v 'AIC06 SHOT=' || true
echo "日志和截图在 ${OUT}。容器还开着，用完 (cd tool/ai-cli-fixture && ./down.sh)"
exit "$STATUS"
