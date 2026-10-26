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
# - 每次都要联网：Ghostty 源码（39 MB）由钩子里的 Dart 从 github.com 下；Zig 依赖由 Zig 自己下，大多在
#   deps.files.ghostty.org，aro 在 github.com。这台 Mac 直连 github.com 时好时坏，报
#   `HttpException: Operation timed out, uri = https://github.com/ghostty-org/...`；Zig 又走不了本机代理
#   （`invalid HTTP response: HttpConnectionClosing`），而钩子会把 http(s)_proxy 原样传给它调的 zig。
#   所以设上代理，再在 PATH 最前放一个写死真实路径、只给 Zig 去掉代理的包装器（10-26 这样编过）：
#     w=$(mktemp -d); printf '#!/bin/sh\nexec env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY "%s" "$@"\n' "$(mise which zig)" > $w/zig; chmod +x $w/zig
#     PATH=$w:$PATH http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 tool/build-release.sh
#   ../.toolchain/bin/zig 那个包装器按 SHUN_ZIG_EXECUTABLE 找 Zig，钩子不传这个变量，在这里用不了。
#   换的只是下载走哪条路，源码包仍按 ghostty.sha256、Zig 依赖仍按 hash 核对。
# - `pub get` 报 525 和 `Failed to update packages`：shell 里的 PUB_HOSTED_URL 镜像坏了，锁文件写的是 pub.dev，
#   `unset PUB_HOSTED_URL` 再跑。FLUTTER_STORAGE_BASE_URL 别跟着换：Gradle 按它找缓存的引擎包，换了就重下。
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
