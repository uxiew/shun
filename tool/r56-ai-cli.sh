#!/usr/bin/env bash
# Account-free R56/R57 Android matrix. Only the dedicated shun emulator and
# locally generated tmux fixture are accepted. Two runs use separate processes
# but preserve the real encrypted recent-work store for the cold-start check.
set -euo pipefail
cd "$(dirname "$0")/.."
source ../.toolchain/env.sh
SERIAL=emulator-5580
PKG=top.xdwa.shun
ADB=(adb -s "$SERIAL")
[[ "$("${ADB[@]}" emu avd name | tr -d '\r' | head -1)" == shun-a35-4k ]] || { echo 'Expected dedicated shun-a35-4k'; exit 1; }
OUT=../.toolchain/artifacts/r56-$(git rev-parse --short HEAD)
mkdir -p "$OUT"
python3 - <<'PY'
import json,pathlib
root=pathlib.Path('tool/tmux-fixture/.run')
cfg=json.loads((root/'fixture.json').read_text())
path=root/'r56-defines.json'
path.write_text(json.dumps({'R56_CONFIG':json.dumps(cfg)}))
path.chmod(0o600)
PY
"${ADB[@]}" reverse tcp:22314 tcp:22314 >/dev/null
"${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
"${ADB[@]}" shell input keyevent 82
"${ADB[@]}" shell pm clear "$PKG" >/dev/null 2>&1 || true
grant_pid=''
cleanup() {
  [[ -z "$grant_pid" ]] || kill "$grant_pid" 2>/dev/null || true
  "${ADB[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  "${ADB[@]}" shell input keyevent 82 >/dev/null 2>&1 || true
}
trap cleanup EXIT
for phase in seed cold; do
  LOG="$OUT/$phase.log"
  "${ADB[@]}" shell am force-stop "$PKG" >/dev/null
  (for _ in $(seq 1 600); do
    "${ADB[@]}" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null && break
    sleep 0.5
  done) >/dev/null 2>&1 & grant_pid=$!
  flutter test --no-pub --no-uninstall integration_test/r56_ai_cli_test.dart -d "$SERIAL" \
    --dart-define-from-file=tool/tmux-fixture/.run/r56-defines.json > "$LOG" 2>&1 &
  test_pid=$!
  acted=0
  killed=0
  while kill -0 "$test_pid" 2>/dev/null; do
    if [[ "$acted" == 0 ]] && grep -q 'R56 ACTION=background-lock' "$LOG"; then
      acted=1
      "${ADB[@]}" exec-out screencap -p > "$OUT/before-lock.png"
      "${ADB[@]}" shell input keyevent KEYCODE_HOME
      sleep 2
      "${ADB[@]}" shell input keyevent KEYCODE_SLEEP
      sleep 3
      "${ADB[@]}" shell dumpsys power > "$OUT/locked-power.txt"
      "${ADB[@]}" shell dumpsys notification --noredact > "$OUT/locked-notifications.txt"
      "${ADB[@]}" shell input keyevent KEYCODE_WAKEUP
      "${ADB[@]}" shell input keyevent 82
      "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
      "${ADB[@]}" shell "run-as $PKG sh -c 'mkdir -p files/r56 && touch files/r56/background-lock'"
    fi
    if [[ "$phase" == seed && "$killed" == 0 ]] && grep -q 'R56 KILL_READY=seed' "$LOG"; then
      killed=1
      seed_pid=$("${ADB[@]}" shell pidof "$PKG" | tr -d '\r')
      [[ -n "$seed_pid" ]] || { echo 'Seed App was already gone before force-stop'; exit 1; }
      "${ADB[@]}" exec-out screencap -p > "$OUT/seed-live.png"
      "${ADB[@]}" shell am force-stop "$PKG"
      [[ -z "$("${ADB[@]}" shell pidof "$PKG" | tr -d '\r')" ]] || { echo 'App survived force-stop'; exit 1; }
      echo "R56 HOST_KILL=seed pid=$seed_pid (before test teardown)" | tee "$OUT/force-stop.txt"
    fi
    sleep 0.5
  done
  status=0
  wait "$test_pid" || status=$?
  kill "$grant_pid" 2>/dev/null || true
  grant_pid=''
  grep -E 'R56 |\[E\]|Expected|Actual|Exception|All tests|Some tests' "$LOG" || true
  if [[ "$phase" == seed ]]; then
    [[ "$killed" == 1 ]] && grep -q 'R56 KILL_READY=seed' "$LOG" || { echo "Seed failed before controlled kill: $LOG"; exit 1; }
    echo 'R56 seed assertions passed; test transport intentionally lost by force-stop'
  else
    [[ "$status" == 0 ]] || { echo "Log: $LOG"; exit "$status"; }
    grep -q 'R56 DONE=cold' "$LOG" || { echo "Missing cold evidence: $LOG"; exit 1; }
  fi
  "${ADB[@]}" exec-out screencap -p > "$OUT/$phase.png"
  "${ADB[@]}" shell "run-as $PKG sh -c 'find shared_prefs files -maxdepth 2 -type f'" > "$OUT/$phase-private-files.txt"
done
echo "R56 Android evidence: $OUT"
