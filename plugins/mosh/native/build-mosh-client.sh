#!/usr/bin/env bash
# 从核对过 SHA256 的源码交叉编译官方 mosh-client（1.4.0）给 Android arm64，产物放进插件 APK 的 jniLibs。
#
# 为什么是可执行文件而不是 JNI 库：mosh-client 是个完整程序（main、exit()、全局单例、信号、要求 stdin 是 tty），
# 放进插件进程的线程里跑，一个会话 exit() 会带走整个插件进程和别的会话。所以每个会话一个子进程，
# 由插件用 PTY 拉起。Android 10 起不许 exec App 可写目录里的文件（docs/13 S54），可执行文件只能随 APK
# 装进 nativeLibraryDir（只读、系统安装时解出），所以名字必须是 lib*.so，APK 里要 extractNativeLibs。
#
# 用法：source ../../../../.toolchain/env.sh 后直接跑。从零约 2 分钟（10 核，不算下载 60 MB 源码）。
# 可以重复跑，已编好的阶段跳过；编译目录可以删（腾磁盘），装好的库和本机工具在 prefix-*/、host/ 里。
#   FORCE=1 ./build-mosh-client.sh     全部重编
# 产物：../build-native/jniLibs/arm64-v8a/libmoshclient.so（不进 git）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(cd "$HERE/../../../.." && pwd)/.toolchain/mosh-build"   # 仓库外：源码包、编译目录
OUT="$HERE/../build-native/jniLibs/arm64-v8a"
NDK="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}"
API=24                                     # 和主 App、插件的 minSdk 一致
ABI=arm64-v8a
TRIPLE=aarch64-linux-android
TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
CMAKE_BIN="$ANDROID_HOME/cmake/3.22.1/bin"
JOBS="${JOBS:-8}"
PREFIX="$W/prefix-$ABI"
HOST="$W/host"
mkdir -p "$W/src" "$W/build" "$PREFIX" "$HOST" "$OUT"
[[ -d "$TC" ]] || { echo "找不到 NDK：$NDK" >&2; exit 1; }
[[ "${FORCE:-0}" == 1 ]] && rm -rf "$W/build" "$PREFIX" "$HOST" && mkdir -p "$W/build" "$PREFIX" "$HOST"

# ---- 源码：固定版本 + SHA256。对不上就停，不退回别的来源。----
fetch() { # 文件名 URL sha256
  local f="$W/src/$1"
  if [[ ! -f "$f" ]]; then
    curl -fsSL --max-time 600 -o "$f.part" "$2"
    mv "$f.part" "$f"
  fi
  local got; got=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [[ "$got" == "$3" ]] || { echo "$1 的 SHA256 对不上：$got（应为 $3）" >&2; exit 1; }
}
# mosh：SHA256 与 mosh.org 签名发布公告一致（https://mosh.org/mosh-1.4.0-released.html）
fetch mosh-1.4.0.tar.gz https://github.com/mobile-shell/mosh/releases/download/mosh-1.4.0/mosh-1.4.0.tar.gz \
  872e4b134e5df29c8933dff12350785054d2fd2839b5ae6b5587b14db1465ddd
# protobuf 21.12：最后一个不依赖 abseil 的版本；mosh 的 .proto 都是 LITE_RUNTIME
fetch protobuf-cpp-3.21.12.tar.gz https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-3.21.12.tar.gz \
  4eab9b524aa5913c6fffb20b2a8abf5ef7f95a80bc0701f3a6dbb4c607f73460
# OpenSSL 3.5 LTS：只要 libcrypto 的 AES/OCB；SHA256 与官方发行页的 .sha256 一致
fetch openssl-3.5.4.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.4/openssl-3.5.4.tar.gz \
  967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99
# ncurses 6.5：mosh 只用 terminfo 查终端能力；把 xterm-256color 编进库里（fallback），设备上不需要 terminfo 文件
fetch ncurses-6.5.tar.gz https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz \
  136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6

unpack() { [[ -d "$W/build/$1" ]] || tar xzf "$W/src/$2" -C "$W/build"; }
unpack mosh-1.4.0 mosh-1.4.0.tar.gz

export PATH="$CMAKE_BIN:$TC/bin:$PATH"
CC_A="$TC/bin/$TRIPLE$API-clang"
CXX_A="$TC/bin/$TRIPLE$API-clang++"
# 16 KiB 页：所有段按 0x4000 对齐（Android 15+ 的 16 KiB 设备上，4 KiB 对齐的 ELF 加载失败）
LD16="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

# ---- 1. protobuf：本机 protoc（生成 mosh 的 .pb.cc）+ Android 静态库 ----
if [[ ! -x "$HOST/bin/protoc" || ! -f "$PREFIX/lib/libprotobuf.a" ]]; then
  unpack protobuf-3.21.12 protobuf-cpp-3.21.12.tar.gz
fi
if [[ ! -x "$HOST/bin/protoc" ]]; then
  cmake -S "$W/build/protobuf-3.21.12" -B "$W/build/pb-host" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$HOST" >/dev/null
  ninja -C "$W/build/pb-host" -j "$JOBS" protoc >/dev/null
  mkdir -p "$HOST/bin" && cp "$W/build/pb-host/protoc" "$HOST/bin/protoc"
fi
if [[ ! -f "$PREFIX/lib/libprotobuf.a" ]]; then
  cmake -S "$W/build/protobuf-3.21.12" -B "$W/build/pb-$ABI" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=$ABI -DANDROID_PLATFORM=$API \
    -DANDROID_STL=c++_static -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
  ninja -C "$W/build/pb-$ABI" -j "$JOBS" install >/dev/null
fi
echo "protobuf：$("$HOST/bin/protoc" --version)，$(ls "$PREFIX"/lib/libprotobuf*.a | xargs -n1 basename | tr '\n' ' ')"

# ---- 2. OpenSSL：只编 libcrypto 静态库 ----
if [[ ! -f "$PREFIX/lib/libcrypto.a" ]]; then
  unpack openssl-3.5.4 openssl-3.5.4.tar.gz
  (
    cd "$W/build/openssl-3.5.4"
    export ANDROID_NDK_ROOT="$NDK"
    ./Configure android-arm64 -D__ANDROID_API__=$API no-shared no-tests no-apps no-docs no-engine no-dso \
      no-ssl no-tls no-dtls --prefix="$PREFIX" --libdir=lib "$LD16" >/dev/null
    make -j "$JOBS" build_libs >/dev/null
    make install_dev >/dev/null
  )
fi
echo "openssl：$(grep -m1 OPENSSL_VERSION_TEXT "$PREFIX/include/openssl/opensslv.h" | sed 's/.*"\(.*\)".*/\1/')"

# ---- 3. ncurses：先编本机 tic/infocmp 和 terminfo（生成 fallback 要用），再编 Android 静态库 ----
# 窄字符、不扩展数值：ncurses 6.5 的 infocmp -E 生成 fallback 时数值数组固定写 short，而开了宽字符（默认）就开了
# ext-colors，库里的数值是 int，编出来 pairs 变 0、数组按 int 读成乱数（编译只给警告）。mosh 只用 setupterm/tigetstr/tigetflag，
# 用不到宽字符 curses。本机和 Android 两边必须同一套选项，否则 terminfo 里的数值超过 short 范围。
NC_ABI="--disable-widec --disable-ext-colors --disable-ext-mouse"
unpack ncurses-6.5 ncurses-6.5.tar.gz
if [[ ! -x "$HOST/bin/tic" ]]; then
  rm -rf "$W/build/nc-host" && cp -R "$W/build/ncurses-6.5" "$W/build/nc-host"
  (
    cd "$W/build/nc-host"
    ./configure --prefix="$HOST" --without-shared --without-debug --without-ada --without-cxx --without-cxx-binding \
      --without-manpages --without-tests --disable-db-install $NC_ABI >/dev/null
    make -j "$JOBS" -C include >/dev/null && make -j "$JOBS" -C ncurses >/dev/null && make -j "$JOBS" -C progs >/dev/null
    mkdir -p "$HOST/bin" && cp progs/tic progs/infocmp "$HOST/bin/"
  )
fi
# 只编要用的几条：xterm-256color（宿主的 flterm/Ghostty 按 xterm 兼容）
if [[ ! -d "$HOST/terminfo" ]]; then
  mkdir -p "$HOST/terminfo"
  "$HOST/bin/tic" -x -e xterm-256color,xterm,vt100 -o "$HOST/terminfo" "$W/build/ncurses-6.5/misc/terminfo.src"
fi
if [[ ! -f "$PREFIX/lib/libncurses.a" ]]; then
  rm -rf "$W/build/nc-$ABI" && cp -R "$W/build/ncurses-6.5" "$W/build/nc-$ABI"
  (
    cd "$W/build/nc-$ABI"
    export TERMINFO="$HOST/terminfo"
    CC="$CC_A" AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" CFLAGS="-O2 -fPIE" LDFLAGS="$LD16" \
    ./configure --host=$TRIPLE --build="$(uname -m)-apple-darwin" --with-build-cc=/usr/bin/clang --prefix="$PREFIX" \
      --without-shared --with-normal --without-debug --without-ada --without-cxx --without-cxx-binding \
      --without-progs --without-tests --without-manpages --disable-database --disable-db-install --disable-home-terminfo \
      --with-fallbacks=xterm-256color --with-tic-path="$HOST/bin/tic" --with-infocmp-path="$HOST/bin/infocmp" $NC_ABI >/dev/null
    make -j "$JOBS" -C include >/dev/null && make -j "$JOBS" -C ncurses >/dev/null
    make -C include install >/dev/null && make -C ncurses install >/dev/null
  )
fi
# 编译目录被清掉（腾磁盘）时跳过这两项检查：库是上次检查通过后才装进 prefix 的。
if [[ -d "$W/build/nc-$ABI" ]]; then
grep -q xterm_256color "$W/build/nc-$ABI/ncurses/fallback.c" || { echo "ncurses 没把 xterm-256color 编进 fallback" >&2; exit 1; }
grep -q "static short xterm_256color_number_data" "$W/build/nc-$ABI/ncurses/fallback.c" \
  && grep -q "short \*Numbers" "$W/build/nc-$ABI/include/term.h" && ! grep -q "int \*Numbers" "$W/build/nc-$ABI/include/term.h" \
  || { echo "ncurses fallback 的数值类型和库不一致（见上面 NC_ABI 的说明）" >&2; exit 1; }
fi
echo "ncurses：$(ls "$PREFIX"/lib/libncurses*.a | xargs -n1 basename | tr '\n' ' ')，fallback xterm-256color"

# ---- 4. mosh-client ----
# 没有 pkg-config：PKG_CHECK_MODULES 看到 *_CFLAGS/*_LIBS 已设就直接用。全部静态链接，只依赖 Android 系统库
# （libc、libm、libz、libdl；protobuf 在 Android 上把内部日志写进 logcat，要 liblog）。
# OCB 用 OpenSSL 自己的 EVP_aes_128_ocb（不用 mosh 内置 OCB + 已弃用的 AES_encrypt）。
if [[ ! -x "$W/build/mosh-$ABI/src/frontend/mosh-client" ]]; then
  rm -rf "$W/build/mosh-$ABI" && cp -R "$W/build/mosh-1.4.0" "$W/build/mosh-$ABI"
  (
    cd "$W/build/mosh-$ABI"
    # 我们对 mosh 源码的全部改动都在 patches/ 里（GPL：改动随源码提供），逐个打上，打不上就停。
    for p in "$HERE"/patches/*.patch; do patch -p1 --forward --quiet < "$p"; done
    CC="$CC_A" CXX="$CXX_A" AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" \
    CPPFLAGS="-I$PREFIX/include" CXXFLAGS="-O2 -g0" LDFLAGS="-L$PREFIX/lib $LD16" \
    PROTOC="$HOST/bin/protoc" \
    protobuf_CFLAGS="-I$PREFIX/include" protobuf_LIBS="$PREFIX/lib/libprotobuf-lite.a" LIBS="-llog" \
    OpenSSL_CFLAGS="-I$PREFIX/include" OpenSSL_LIBS="-L$PREFIX/lib" \
    TINFO_CFLAGS="-I$PREFIX/include/ncurses" TINFO_LIBS="$PREFIX/lib/libncurses.a" \
    ./configure --host=$TRIPLE --prefix=/nonexistent --enable-client --disable-server --disable-examples \
      --disable-completion --with-crypto-library=openssl-with-openssl-ocb --enable-static-libstdc++ --enable-static-protobuf \
      --enable-static-crypto >"$W/build/mosh-$ABI.configure.log"
    make -j "$JOBS" >/dev/null
  )
fi
BIN="$W/build/mosh-$ABI/src/frontend/mosh-client"
cp "$BIN" "$OUT/libmoshclient.so"
"$TC/bin/llvm-strip" --strip-unneeded "$OUT/libmoshclient.so"

# 许可证原文随 APK 一起分发（assets/licenses/），对应的源码和我们的补丁在本仓库 plugins/mosh/native/。
LIC="$HERE/../build-native/assets/licenses"
mkdir -p "$LIC"
tar xzf "$W/src/mosh-1.4.0.tar.gz" -O mosh-1.4.0/COPYING > "$LIC/mosh-COPYING.txt"
tar xzf "$W/src/protobuf-cpp-3.21.12.tar.gz" -O protobuf-3.21.12/LICENSE > "$LIC/protobuf-LICENSE.txt"
tar xzf "$W/src/openssl-3.5.4.tar.gz" -O openssl-3.5.4/LICENSE.txt > "$LIC/openssl-LICENSE.txt"
tar xzf "$W/src/ncurses-6.5.tar.gz" -O ncurses-6.5/COPYING > "$LIC/ncurses-COPYING.txt"
cp "$HERE/../LICENSES.md" "$LIC/README.md"

# ---- 5. 核对：ABI、16 KiB 对齐、动态依赖只有系统库 ----
RE="$TC/bin/llvm-readelf"
# 先存进变量再查：grep -q 提前关管道，pipefail 下会把 readelf 的 SIGPIPE 当成失败。
HDR=$("$RE" -h "$OUT/libmoshclient.so")
[[ "$HDR" == *AArch64* ]] || { echo "不是 arm64" >&2; exit 1; }
ALIGNS=$("$RE" -lW "$OUT/libmoshclient.so" | awk '$1=="LOAD"{print $NF}' | sort -u)
if [[ "$ALIGNS" != "0x4000" ]]; then
  echo "有 LOAD 段不是 16 KiB 对齐" >&2; "$RE" -lW "$OUT/libmoshclient.so" >&2; exit 1
fi
NEEDED=$("$RE" -dW "$OUT/libmoshclient.so" | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}' | sort | tr '\n' ' ')
for lib in $NEEDED; do
  case "$lib" in libc.so|libm.so|libdl.so|libz.so|liblog.so) ;; *) echo "意外的动态依赖：$lib" >&2; exit 1;; esac
done
echo "mosh-client：$(shasum -a 256 "$OUT/libmoshclient.so" | cut -c1-16)…  $(du -h "$OUT/libmoshclient.so" | cut -f1)  依赖：$NEEDED"
