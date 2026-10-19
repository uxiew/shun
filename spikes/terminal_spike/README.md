# terminal_spike（R04 验证工程，现在用来在 Android 上验 fork）

R04 用它验证 libghostty + flterm 能不能在 Android 上当终端用，结论在 `plan/v3/evidence/R04.md`。
现在依赖的是自己维护的 fork（`third_party/libghostty`，上游 main + 我们的补丁）；
R04 当时测的是 pub 上的 flterm 0.0.5 / libghostty 0.0.12，用 pub 版的最后一版在提交 `f82c00a`。
和主 App 完全独立，R17 把 Ghostty 接进主 App 以后整个目录可以删掉。

```bash
source ../.toolchain/env.sh   # 带上 Zig 0.16，原生库要从源码编
cd spikes/terminal_spike
flutter test                                          # 本机（macOS）加载原生库跑字节级测试
flutter build apk --release --target-platform android-arm64   # 项目模拟器和 Pixel 都是 arm64
```

App 本身是一个"回环终端"：没有 SSH，键盘/输入法发出的字节原样回显，底部列出最近发出的原始字节
（十六进制）。上真机时用它核对：中文输入法只在确认后发一次、方向键是转义序列、Ctrl/Alt 编码正确。

## 在模拟器/设备上核对按键和输入法

每次发出的字节都会打到 logcat（`SPIKE_SENT` 前缀），每个到达 Flutter 的按键也会打一行（`SPIKE_KEY`，
带物理键、逻辑键）。屏幕底部只留最近 8 条，逐次核对看 logcat：

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n top.xdwa.shun.terminal_spike/.MainActivity
tool/adb_key_check.sh emulator-5580     # adb 注入方向键/退格/F1 等，逐项 PASS/FAIL
adb logcat -s flutter | grep SPIKE_     # 手点软键盘时边点边看
```

R04 发现的软键盘退格 0 字节、打不了中文、收起后叫不回键盘，都已经修在 fork 的 flterm 里。
`lib/android_key_fallback.dart` 是 0.0.5 时期的适配层，留着兜 fork 没收的 Ctrl/Alt+数字，原因写在文件头。

## 撞墙时

- **dispose 之后再 `write()`**：0.0.5 会段错误、整个 App 闪退；上游 main 起改成抛
  `StateError: TerminalController is disposed.`，不崩了，但 SSH 迟到的数据照样会抛。
  所有写入都要经 `GuardedWriter`，并在 dispose 之前 `close()`。
- **换了依赖来源以后，测试报 `Invalid value provided. (operation: ghostty_terminal_new, code: -2)`**：
  构建钩子沿用了 `.dart_tool/hooks_runner` 里旧的原生库（这次 pub 预编译 0.0.12 → fork 源码编译时撞上的，
  旧库 sha256 和 0.0.12 预编译版一模一样），新的 FFI 绑定调旧库。删 `.dart_tool/hooks_runner` 再跑。
- **在 onOutput 回调里直接 write**：DA 等协议回应是在 write 内同步回调的，直接写回就是重入，
  库不支持。用 `GuardedWriter` 排队。协议回应应发往远端，不要喂回终端。
- **改了 `.dart_tool/hooks_runner/shared/libghostty/build/*/lib/libghostty.so`，构建照样成功**：
  是的，hook 只在下载或编译时校验，已缓存的副本不会再校验。发布构建必须先删 `.dart_tool`
  再构建（会重新下载源码、核对 SHA256、编译），或加打包前校验（R17 要做）。
- **换了依赖的 path（pubspec 或 pubspec_overrides.yaml），APK 却和上次一模一样**：Gradle 按
  `build/app/intermediates/flutter/release/flutter_build.d` 里记的旧文件判断"没变"，整个 Dart
  编译被跳过，连 `.dart_tool/flutter_build` 都不生成。只删 `.dart_tool/flutter_build` 没用，
  要删 `build/app/intermediates/flutter`。核对办法：`unzip` 出 `libapp.so` 用 `strings` 搜你改的字符串。
- **APK 里的 libghostty.so 和编出来的对不上**：正常，打包时 AGP 会做 `llvm-strip --strip-unneeded`
  （10 MB → 1.9 MB）。拿 `.dart_tool/hooks_runner/shared/libghostty/build/*/lib/libghostty-vt.so.0.1.0`
  用 NDK 的 `llvm-strip --strip-unneeded` 处理一次再比，应该一致。
