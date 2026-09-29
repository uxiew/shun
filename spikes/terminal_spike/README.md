# terminal_spike（R04 一次性验证工程）

验证 libghostty 0.0.12 + flterm 0.0.5 能不能在 Android 上当终端用。和主 App 完全独立，
验证结束后整个目录可以删掉；结论写在 `plan/v3/evidence/R04.md`。

```bash
source /Users/fodelf/xdw/xwshun/.toolchain/env.sh
cd spikes/terminal_spike
flutter test                    # 本机（macOS）直接加载 Ghostty 原生库跑字节级测试
flutter build apk --release     # 三个 ABI，构建时从 GitHub Release 下载 native 库并校验 SHA256
```

App 本身是一个"回环终端"：没有 SSH，键盘/输入法发出的字节原样回显，底部列出最近发出的原始字节
（十六进制）。上真机时用它核对：中文输入法只在确认后发一次、方向键是转义序列、Ctrl/Alt 编码正确。

## 撞墙时

- **App 退出页面或 SSH 断开后整个 App 闪退**：flterm 0.0.5 在 `dispose()` 之后再 `write()`
  会段错误，不会抛异常。所有写入都要经 `GuardedWriter`，并在 dispose 之前 `close()`。
  复现：`XWSHUN_RUN_KNOWN_FAILS=1 flutter test --plain-name 已知问题`。
- **在 onOutput 回调里直接 write**：DA 等协议回应是在 write 内同步回调的，直接写回就是重入，
  库不支持。用 `GuardedWriter` 排队。协议回应应发往远端，不要喂回终端。
- **改了 `.dart_tool/hooks_runner/shared/libghostty/build/*/lib/libghostty.so`，构建照样成功**：
  是的，hook 只在下载时校验 hash，已缓存的副本不会再校验。发布构建必须先删 `.dart_tool`
  再构建（会重新下载并校验），或加打包前校验（R17 要做）。
- **APK 里的 libghostty.so 的 sha256 和 hash 表对不上**：正常，打包时 AGP 会做
  `llvm-strip --strip-unneeded`。拿下载缓存里的原文件 strip 一次再比，应该一致。
