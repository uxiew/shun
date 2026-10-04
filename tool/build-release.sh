#!/usr/bin/env bash
# 发布用的 APK（GST01）：Ghostty 原生库从核对过的源码重编，打完包逐个核对 .so。
#
#   source ../.toolchain/env.sh && tool/build-release.sh
#
# 平时的 flutter build 会沿用 .dart_tool 里缓存的原生库，缓存被改了不会被发现（R04 问题 5）。
# 这里先丢掉构建钩子的缓存和 Zig 的全局缓存，让 Ghostty 源码包按 ghostty.sha256、Zig 依赖按
# build.zig.zon 里的 hash 重新下载核对，再从头编。只打 arm64：只有它在设备上测过（REL03）。
#
# 撞墙时：
# - 报「GHOSTTY_SRC」或「ghostty/ 目录」：这两样会让钩子用本地源码、跳过 hash 核对，发布前去掉。
# - 报某个 .so 的 LOAD 段不是 16 KiB 对齐：16 KiB 页的手机（Android 15 起的新机）上加载会失败，不能发。
# - 第一次要联网下载 Ghostty 源码（39 MB）和 Zig 依赖，Zig 走不了本机代理，见 ../.toolchain/bin/zig。
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(cd ../.toolchain && pwd)
command -v zig >/dev/null || { echo "找不到 zig：先 source ../.toolchain/env.sh" >&2; exit 1; }
[[ -z "${GHOSTTY_SRC:-}" ]] || { echo "设了 GHOSTTY_SRC：钩子会用这份本地源码、跳过 hash 核对" >&2; exit 1; }
[[ ! -e third_party/libghostty/ghostty ]] || {
  echo "third_party/libghostty/ghostty/ 目录存在：钩子会用它、跳过 hash 核对" >&2; exit 1; }

ndk=$(ls -d "$ANDROID_HOME"/ndk/* | sort | tail -1)
bin=$(ls -d "$ndk"/toolchains/llvm/prebuilt/*/bin | head -1)

# Zig 全局缓存挪开，结束（包括失败）时放回；这次构建用一份空缓存，用完删掉。
if [[ -d "$T/zig-cache" ]]; then
  mv "$T/zig-cache" "$T/zig-cache.before-release"
  trap 'rm -rf "$T/zig-cache"; mv "$T/zig-cache.before-release" "$T/zig-cache"' EXIT
else
  trap 'rm -rf "$T/zig-cache"' EXIT
fi
rm -rf .dart_tool/hooks_runner build/app/intermediates
flutter build apk --release --target-platform android-arm64

apk=build/app/outputs/flutter-apk/app-release.apk
out=$(mktemp -d)
unzip -q -o "$apk" 'lib/*' -d "$out"
fail=0
for so in "$out"/lib/*/*.so; do
  # 每个 LOAD 段的对齐都要 >= 0x4000（16 KiB）。
  aligns=$("$bin/llvm-readelf" -lW "$so" | awk '$1=="LOAD"{print $NF}')
  for a in $aligns; do
    if (( a < 0x4000 )); then echo "FAIL 对齐 $a < 16 KiB：${so#"$out"/}" >&2; fail=1; fi
  done
  echo "$(shasum -a 256 "$so" | cut -c1-64)  ${so#"$out"/}"
done

# APK 里的 libghostty.so 就是这次编出来的那份（打包时 AGP 会 strip，对比 strip 后的）。
built=$(find .dart_tool/hooks_runner/shared/libghostty/build -path '*/lib/libghostty-vt.so.*.*' -type f | head -1)
"$bin/llvm-strip" --strip-unneeded -o "$out/built.so" "$built"
if ! cmp -s "$out/built.so" "$out/lib/arm64-v8a/libghostty.so"; then
  echo "FAIL APK 里的 libghostty.so 不是这次从源码编出来的那份" >&2; fail=1
fi
rm -rf "$out"
(( fail == 0 )) || exit 1
echo "OK $apk"
