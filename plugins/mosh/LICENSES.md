# Mosh 插件的来源、许可与 native 台账

这份表随 APK 一起分发（`assets/licenses/README.md`），许可证原文在同一目录。
对应源码：本仓库 `plugins/mosh/`（插件代码、JNI、构建脚本、对 mosh 的补丁）+ 下表的上游源码包。按 `README.md` 能从源码重建。

## 进 APK 的 native 文件

| 文件 | 是什么 | ABI | LOAD 对齐 | 动态依赖 |
|---|---|---|---|---|
| `lib/arm64-v8a/libmoshclient.so` | 官方 mosh-client 1.4.0（可执行文件，见 README「为什么叫 .so」），静态链接下表的库 | arm64-v8a | 0x4000（16 KiB） | 只有系统库 `libc.so libdl.so liblog.so libm.so libz.so` |
| `lib/arm64-v8a/libmoshpty.so` | 本插件的 JNI：开 PTY、fork + exec、改窗口尺寸、等子进程 | arm64-v8a | 0x4000 | `liblog.so libc.so` 等系统库 |

只打 arm64-v8a：armeabi-v7a、x86_64 没有设备测过，不声明支持（REL03）。
每次构建 `native/build-mosh-client.sh` 最后都会核对 ABI、对齐和动态依赖，不对就停。

## 上游组件

| 组件 | 版本 | 源码包 SHA-256 | 来源 | 许可 | 用了什么 |
|---|---|---|---|---|---|
| mosh | 1.4.0 | `872e4b134e5df29c8933dff12350785054d2fd2839b5ae6b5587b14db1465ddd`（与 mosh.org 签名发布公告一致） | https://github.com/mobile-shell/mosh/releases/download/mosh-1.4.0/mosh-1.4.0.tar.gz | GPL-3.0-or-later，附「允许与 OpenSSL 链接」例外 | 只编客户端（`--disable-server`）；OCB 用 OpenSSL 的 `EVP_aes_128_ocb`，没用 mosh 自带的 OCB 实现 |
| Protocol Buffers | 21.12（C++ 3.21.12） | `4eab9b524aa5913c6fffb20b2a8abf5ef7f95a80bc0701f3a6dbb4c607f73460` | https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-3.21.12.tar.gz | BSD-3-Clause | 只链 `libprotobuf-lite`（mosh 的 .proto 都是 LITE_RUNTIME）；本机的 `protoc` 用同一份源码编 |
| OpenSSL | 3.5.4（LTS） | `967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99`（与官方 `.sha256` 一致） | https://github.com/openssl/openssl/releases/download/openssl-3.5.4/openssl-3.5.4.tar.gz | Apache-2.0 | 只编 `libcrypto`（关掉 TLS/SSL、engine、dso、apps） |
| ncurses | 6.5 | `136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6` | https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz | X11 风格（MIT 类） | 只用 terminfo（`setupterm`/`tigetstr`/`tigetflag`）；`xterm-256color` 编进库里（fallback），设备上不需要 terminfo 文件 |
| LLVM libc++ | NDK 28.2.13676358 自带 | — | Android NDK | Apache-2.0 WITH LLVM-exception | 静态链接（`-static-libstdc++`），APK 里不带 `libc++_shared.so` |
| zlib | 系统自带 | — | Android 系统 `libz.so` | zlib | 动态链接系统库，不打包 |

## 我们对上游的改动

只有一处，在 `native/patches/`：

- `0001-android-api24-locale-charset.patch`：Android 8.0（API 26）以前 bionic 没有 `nl_langinfo()`，mosh 用它判断终端是不是 UTF-8。
  改成和 bionic 自己的 `nl_langinfo(CODESET)` 同一个判断（`MB_CUR_MAX == 1` 才是 ASCII）。只在 API < 26 的编译目标上生效。

## 许可结论（给所有者看的，不是法律意见）

- 插件 APK 里静态链接了 GPL-3.0-or-later 的 mosh-client，所以**整个插件按 GPL-3.0-or-later 分发**，分发时要能提供对应源码
  （本仓库 + 上表源码包 + 补丁 + 构建脚本）。描述符里的 `license` 写的就是 `GPL-3.0-or-later`。
- OpenSSL 3 是 Apache-2.0，和 GPL-3.0 兼容；mosh 本身还带 OpenSSL 链接例外，两种角度都不冲突。
- **独立 APK 不会让宿主「绕开」GPL**，也不是为此而拆（docs/15、SDK02）。宿主本来就是 GPL-3.0-or-later 的 Netcatty fork。
  拆成独立 APK 是为了独立更新、独立 UID 和故障隔离。
- 正式签名、发行名称、要不要上架都等所有者定；现在是测试作者密钥签的。

## 没有的东西

- 没有网络下载后执行的代码：运行时只来自 APK 安装时系统解出的 nativeLibraryDir（只读），插件不往可写目录写可执行文件（PLG13）。
- 没有 `sharedUserId`；和宿主是两个 UID，靠 Binder 逐事务核对 UID + 证书（provider-sdk 的 `CallerVerifier`）。
- 插件只申请 `INTERNET`（mosh-client 自己收发 UDP）。
