# 自己维护的上游依赖

所有者 2026-10-04 定：依赖有 bug 或缺功能，就 fork 进这里自己改，不干等上游。每个 fork 记清上游提交、和上游差在哪、怎么同步。

## libghostty / flterm（`libghostty/`）

上游 [elias8/libghostty](https://github.com/elias8/libghostty)（MIT），起点 `609ee318`：flterm 0.0.5；里面的 libghostty 包和 `libghostty-v0.0.12` 标签逐字节相同。
目标：修 bug、补功能，和原项目（Netcatty 用的 xterm2）的终端能力看齐。

```bash
cd third_party/libghostty
flutter pub get                                       # 要联网：ptyx 的 ffigen 不在本机缓存
dart analyze packages/flterm/lib packages/libghostty/lib
../fetch-libghostty-assets.sh                         # 只有跑 flterm 渲染测试、示例程序时才要（51.5 MB）
(cd packages/flterm && flutter test)                  # 682 条
(cd packages/libghostty && dart test)                 # 412 条
```

App 里用：pubspec 写 path 依赖 `third_party/libghostty/packages/flterm` 和 `.../packages/libghostty`（R17 起主 App 这么接；spike 的用法见它的 README）。
原生库：App 不设 `hooks.user_defines` 时，构建会下载上游预编译的 `.so` 并按包内 SHA256 表核对。

### 和上游差在哪

改动处都标了 `xwshun:`，`grep -rn 'xwshun:' third_party/libghostty` 能找全。新改一处就在这里加一行。

| 提交 | 改了什么 | 为什么 |
|---|---|---|
| aad782f | 引入上游 `609ee318`，不搬示例/测试字体和示例 wasm | 那些共 51.5 MB，本仓库才 8 MB；要用时 `fetch-libghostty-assets.sh` 取回并核对 SHA256 |
| 04df082 | flterm：输入框类型 multiline → emailAddress；scanCode=0 的键按逻辑键兜底；这类键处理后让输入法重新对齐 | 不改的话 Gboard 打不了中文、微信输入法每次回到英文、软键盘退格 0 字节、删拼音漏字母（R04 问题 2、4） |
| 8caeb73 | workspace 的原生库来源 compile → prebuilt | 本机没装 Zig；暂不改原生代码 |
| 761264e | `.gitignore` 加上取回的字体、wasm | 防止 51.5 MB 被误提交 |

### 同步上游

```bash
git clone --filter=blob:none https://github.com/elias8/libghostty.git /tmp/libghostty-up
cd /tmp/libghostty-up
NEW=<上游新提交>
git diff --binary 609ee318 $NEW -- . ':!packages/flterm/example/assets/fonts' \
  ':!packages/flterm/test/fixtures/fonts' ':!*.wasm' > /tmp/libghostty-up.patch
cd -    # 回到本仓库根目录
git apply --3way --directory=third_party/libghostty /tmp/libghostty-up.patch
```

冲突会出在标了 `xwshun:` 的地方，`git apply` 返回非 0、列出合不进的文件，手工把我们的改动移植过去。
合完把本文件、`fetch-libghostty-assets.sh` 里的起点提交换成 `$NEW`，跑完上面的测试再提交。上游字体有变化时，脚本里的 SHA256 也要更新，否则它会报「对不上」。

**上游 main 的现状（2026-10-04 查，`9e40b11`）**：比起点多 105 个提交、还没发版（pubspec 仍是 flterm 0.0.5 / libghostty 0.0.12）。
有我们要的：触摸选区手柄和放大镜、可设滚动区上限、失联输入连接恢复、转发桌面通知和进度。但有两个坑：

- 输入层重构了。用上面的命令试合：177 个文件干净合入，`terminal_controller_impl.dart`（我们的输入法补丁在这里）合不进，`test/input/text_input_session_test.dart` 有冲突。
- `ghostty.version` 从 `15484b60` 换成了 `349f0260`，FFI 绑定也重新生成了，但版本号没变。这时按 0.0.12 下载的预编译库是旧源码编的，和新绑定可能对不上——**同步到 main 就得装 Zig 从源码编**。

R17 开工时先决定：在 0.0.5 上补齐，还是先同步到上游 main 再移植我们的改动。

### 要改原生代码时

装 Zig，把 `libghostty/pubspec.yaml` 的 `source: prebuilt` 改回 `compile`；Ghostty 源码版本由 `packages/libghostty/ghostty.version` 固定。
App 也要在自己的 pubspec 里设 `hooks.user_defines.libghostty.source: compile`，否则 App 构建拿到的还是上游预编译库，不是你改过的。
发布构建前删掉 `.dart_tool`：已缓存的原生库副本被改了不会被发现（R04 问题 5）。

### 待办：和 xterm2 对齐（R17、R18）

逐项对照主 App 现在的终端（`lib/presentation/terminal/xterm_terminal_view.dart`），对齐一项勾一项、写进 R17/R18 证据：

- 选区：拖动手柄选择、复制；备用屏（vim、tmux）长按出复制快照
- 鼠标：tmux 打开鼠标报告时滚动交给 tmux，手指滑动不变成方向键、点按不误发点击
- 键盘：软键盘退格（`deleteDetection`）、敏感输入走 visiblePassword、收起后点终端叫回、快捷键栏的 Ctrl/Alt/Esc
- 外观：主题色、字号、透明背景
- 和 App 其他部分的接口：画中画文字、AI 上下文（适配器的 `lineAt` / `allText`）
- R04 已知问题：dispose 后 write 段错误（问题 1）、组合字符缺重音（6）、默认资源上限过大（7）、**语音输入整段重复发送（8）**、裸 DEL 画成方格（9）

## 其他依赖

照上面的做法：bug 卡住我们时 fork 进 `third_party/<名字>/`，记起点提交、差异表、同步办法，改动标 `xwshun:`；不顺手升级版本。
现在只有 libghostty 一份。已知可能要 fork 的：

| 依赖 | 问题 | 现在怎么处理 |
|---|---|---|
| dartssh2 2.22.5 | SSH 版本行被拆包就断开 | App 里用 `SshBannerDeadlineSocket` 绕过（R06） |
| flutter_secure_storage 9.2.4 | Android 端切了存储文件名不切回来；Keystore 失效时静默换一份存储 | App 里显式写默认文件名（R14）、能识别并提示（R09）；升级到 10.x 要所有者同意 |
| xterm2 5.2.0 | 只作迁移期对照，Ghostty 成为默认后退出生产路径 | 不 fork |
