#!/usr/bin/env bash
# Dedicated, disposable Android test app data only. Start fixture + AVD first.
set -euo pipefail
cd "$(dirname "$0")/.."
source ../.toolchain/env.sh
SERIAL=emulator-5580
PKG=top.xdwa.shun
ADB=(adb -s "$SERIAL")
[[ "$("${ADB[@]}" emu avd name | tr -d '\r' | head -1)" == shun-a35-4k ]] || { echo 'Expected dedicated shun-a35-4k'; exit 1; }
OUT=${R40_OUT:-../.toolchain/artifacts/r40-simulator-$(git rev-parse --short HEAD)}
mkdir -p "$OUT"
python3 - <<'PY'
import json,pathlib
root=pathlib.Path('tool/fixture-environment/.run')
cfg=json.loads((root/'fixture.json').read_text())
path=root/'r40-defines.json'
path.write_text(json.dumps({'R40_CONFIG':json.dumps(cfg)}))
path.chmod(0o600)
PY
test_pid=''
cleanup() {
  if [[ -n "$test_pid" ]] && kill -0 "$test_pid" 2>/dev/null; then
    kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
  fi
  for port in 22201 21080 21081 21082; do "${ADB[@]}" reverse --remove "tcp:$port" >/dev/null 2>&1 || true; done
  rm -f tool/fixture-environment/.run/r40-defines.json
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for port in 22201 21080 21081; do "${ADB[@]}" reverse "tcp:$port" "tcp:$port" >/dev/null; done
"${ADB[@]}" reverse tcp:21082 tcp:21080 >/dev/null
"${ADB[@]}" shell pm clear "$PKG" >/dev/null 2>&1 || true
for phase in seed cold; do
  "${ADB[@]}" shell am force-stop "$PKG"
  LOG="$OUT/$phase.log"
  flutter test --no-pub --no-uninstall integration_test/r40_route_editor_test.dart -d "$SERIAL" \
    --dart-define-from-file=tool/fixture-environment/.run/r40-defines.json > "$LOG" 2>&1 &
  test_pid=$!
  captured=' '
  while kill -0 "$test_pid" 2>/dev/null; do
    for shot in chain-three proxy-manager catalog-chain delete-impact missing-proxy english-manager; do
      if [[ "$captured" != *" $shot "* ]] && grep -q "R40 SHOT=$shot" "$LOG"; then
        captured="$captured$shot "
        "${ADB[@]}" exec-out screencap -p > "$OUT/$shot.png"
        "${ADB[@]}" shell "run-as $PKG sh -c 'mkdir -p files/r40 && touch files/r40/$shot'"
      fi
    done
    sleep 0.5
  done
  result=0
  wait "$test_pid" || result=$?
  test_pid=''
  grep -E 'R40 |\[E\]|Expected|Actual|Exception|All tests|Some tests' "$LOG" || true
  [[ "$result" == 0 ]] || { echo "Failed: $LOG"; exit "$result"; }
  grep -q "R40 DONE=$phase" "$LOG"
  python3 tool/fixture-environment/r40_check_secrets.py | tee "$OUT/$phase-secrets.txt"
  "${ADB[@]}" shell am force-stop "$PKG"
done
python3 - "$OUT" <<'PY'
import pathlib,re,sys
out=pathlib.Path(sys.argv[1])
pids=[re.search(r'R40 DONE=\w+ pid=(\d+)', (out/f'{phase}.log').read_text()).group(1) for phase in ['seed','cold']]
assert pids[0] != pids[1], 'Expected distinct processes'
print('R40 separate processes: '+ ' -> '.join(pids))
PY
echo "R40 Android evidence: $OUT"
