# 自己维护的上游依赖

所有者 2026-10-04 定：依赖有 bug 或缺功能，就 fork 进这里自己改，不干等上游。每个 fork 记清上游提交、和上游差在哪、怎么同步。

## libghostty / flterm（`libghostty/`）

上游 [elias8/libghostty](https://github.com/elias8/libghostty)（MIT），起点 `9e40b11`：2026-10-04 的 main，还没发版，包里的版本号仍是 flterm 0.0.5 / libghostty 0.0.12。
Ghostty 源码固定在 `packages/libghostty/ghostty.version`（`349f0260`），源码包的 SHA256 在旁边的 `ghostty.sha256`。
目标：修 bug、补功能，和原项目（Netcatty 用的 xterm2）的终端能力看齐。

```bash
source ../.toolchain/env.sh                           # 带上 Zig 0.16，见下一节
cd third_party/libghostty
flutter pub get
dart analyze packages/flterm/lib packages/libghostty/lib
../fetch-libghostty-assets.sh                         # 只有跑 flterm 测试、示例程序时才要（51.6 MB）
(cd packages/flterm && flutter test)                  # 1157 条（10-07，R20 后）
(cd packages/libghostty && dart test)                 # 514 条（R20 后）；第一次要下 Ghostty 源码再用 Zig 编，约 1 分钟
```

`dart analyze` 在 Flutter 3.44 下报 3 条 `discarded_futures`：上游 CI 用最新 stable，不报，不影响编译。

主 App 已经这样接上（R17，见根目录 `pubspec.yaml`）：flterm 写 path 依赖；libghostty 用 `dependency_overrides` 指到 fork（flterm 声明的是 pub 上的 `^0.0.12`，不 override 会拉旧版）；`hooks.user_defines.libghostty.source` 设 `compile`。App 里只有 `lib/infrastructure/terminal/ghostty_terminal_adapter.dart` 和 `lib/presentation/terminal/ghostty_terminal_view.dart` 认识 flterm（分层测试管着）。

### 原生库：从源码编，要 Zig 0.16

上游 main 换了 Ghostty 源码、重新生成了 FFI 绑定，版本号却没变。不设 `source: compile` 时构建按版本号下载 0.0.12 的预编译库，那是旧源码编的，新绑定调它会在创建终端时报 `Invalid value provided. (operation: ghostty_terminal_new, code: -2)`。

- 装：`brew install zig@0.16`。别用 brew 默认的 `zig`（现在是 0.17）：Ghostty 的构建脚本要求大、小版本号都对上，不对会在编译时报 "Your Zig version … does not meet the required build version of v0.16.0"（报错文字取自 Ghostty 源码 `src/build/zig.zig`，没拿 0.17 实跑过）。
- `../.toolchain/env.sh` 把 `../.toolchain/bin/zig` 放在 PATH 最前。它是个包装：指向 zig@0.16；去掉代理变量（Zig 经本机代理取依赖报 "400 Bad Request"，直连正常）；缓存放 `../.toolchain/zig-cache`（构建钩子会过滤环境变量，不在包装里设，缓存会落到 `~/.cache/zig`）。
- 没装 Xcode、只有 Command Line Tools 也能编：fork 让钩子不打 xcframework（67e2b70）。
- 第一次编要下 Ghostty 源码包（39 MB，按 `ghostty.sha256` 核对）和 Zig 依赖。实测 macOS 约 1 分钟；spike 的 Android arm64 release 包整个构建 60 秒。

撞墙时：

- **换了依赖来源（pub ↔ fork、预编译 ↔ 源码）后报上面的 code -2**：构建钩子沿用了 `.dart_tool/hooks_runner` 里旧的原生库（spike 撞上时，旧库的 sha256 和 0.0.12 预编译版一模一样）。删掉 `.dart_tool/hooks_runner` 再构建。
- **"Ghostty source SHA256 mismatch"**：下来的源码包和 `ghostty.sha256` 对不上。换了 `ghostty.version` 没换 hash 就会这样；如果没换，可能是 GitHub 改了打包方式，先 `git archive` 同一提交对比内容，确认没被篡改再更新 hash。
- **已缓存的原生库被改了不会被发现**（R04 问题 5）：钩子只在下载、编译时核对，翻一个字节普通构建照常成功。发布用 `tool/build-release.sh`，它丢掉缓存、从核对过的源码重编，再查每个 `.so` 的 16 KiB 对齐。

### 和上游差在哪

改动处都标了 `xwshun:`，`grep -rn 'xwshun:' third_party/libghostty` 能找全。新改一处就在这里加一行。

| 提交 | 改了什么 | 为什么 |
|---|---|---|
| aad782f、4a7ed9c | 引入上游（起初 `609ee318`，10-04 同步到 `9e40b11`），不搬示例/测试字体和示例 wasm | 那些共 51.6 MB，本仓库才 8 MB；要用时 `fetch-libghostty-assets.sh` 取回并核对 SHA256 |
| 761264e | `.gitignore` 加上取回的字体、wasm | 防止 51.6 MB 被误提交 |
| 67e2b70 | libghostty 钩子：源码编译时不打 xcframework | 只装 Command Line Tools 时构建报 "xcframework ghostty-vt failure" |
| 6018a4a | libghostty 钩子：Ghostty 源码包按 `ghostty.sha256` 核对再编 | 上游下来就编、不核对；预编译那条路有 SHA256 表，改走源码不能丢这道校验 |
| 1dda0c8 | flterm：输入框类型 multiline → emailAddress；scanCode=0 的键按逻辑键兜底；这类键处理后让输入法重新对齐 | 不改的话 Gboard 打不了中文、微信输入法每次回到英文、软键盘退格 0 字节、删拼音漏字母（R04 问题 2、4） |
| 2c41ed9 | flterm：已有焦点时点终端也叫回键盘 | 按返回收起键盘后点终端叫不回来（R04 问题 3）；上游 main 也有这个问题 |
| c3a8b40 | flterm：TerminalController 加 `tailRows(count)`，读最近几行带折行标记 | App 的画中画和 AI 上下文只看最近几百行；公开接口拿不到 Terminal，逐格读滚动区每次都要从头遍历分页 |
| 8711b1a | flterm：输入法提交后编辑区留着已发的字，输入法改写时按差异补发（先退格再发新尾巴）；输入从别的路发出（sendText/sendKey/paste、硬件键）时清空编辑区 | 上游提交即清空，微信输入法语音把同一句话整段重复发 9 次（R04 问题 8，TER02）。上游 8 条测试的编辑不带哨兵，改成真实形状 |
| 0de868c | flterm：TerminalView 加 `secureTextInput`，敏感输入时输入框改成可见密码 | App 设置里的「安全键盘」在 Ghostty 下没效果（输入框类型写死） |
| b63c843 | flterm：组字中收到空的编辑列表当组字结束；清空编辑区后、平台跟上前，oldText 对不上的编辑只按增量处理；软键盘回车键参与回车去重 | Flutter Android 的 delta 模式里 finishComposingText 不记编辑（只删 span），组字区的字拖到下一次改文字才提交；回车键后紧跟的提交按输入法旧编辑区算，整行被重发（8711b1a 引入的回退） |
| 4ba1019 | flterm：`TerminalGestureSettings.touchMouseClicks`，为 false 时远端开着鼠标报告也不把手指点按、长按发成鼠标点击（滑动照样发滚轮） | 上游在 tmux mouse on、htop 里把点按发成点击（tmux 换窗格）、长按选不了字（R19，TER07）。默认 true 不改上游行为，App 传 false |
| 54b7369 | flterm：`LinkSettings.onLongPress`，手指长按开始选字时报出手指下的链接（没有就是 null，不看激活修饰键、不需要 `onActivate`）；长按松开时还什么都没选上，就把整个链接选上 | 所有者 10-07 定点一下终端只叫键盘、链接从选字菜单打开。App 不给 `onActivate` 后，flterm 外面就不知道手指下是不是链接了（检测在内部）。默认 null，上游行为不变 |
| c474751 | flterm：`InputEncoder` 在传统键盘编码下把 Ctrl+I、Ctrl+M、Ctrl+[ 编成 Tab、回车、ESC（Alt 按着加 ESC 前缀）；远端开了 kitty 键盘协议时照上游。上游测试「virtual ctrl to punctuation commit」的期望跟着改 | 上游照 fixterms 编成 CSI u，bash、vim 不认；Android 硬件键盘的按键事件不带字符，连 CSI u 都不发，实测 Ctrl+I/M 什么都没有（R19）。所有者 10-07 定和 xterm2 一样 |
| 39a7ba8 | libghostty：`Terminal.write` 写入前去掉裸 DEL（0x7F） | Ghostty 把普通状态下的 0x7F 当可打印字存进格子，屏幕上一个方格、后面的字右移一格（R04 问题 9）；VT100、xterm、tmux、xterm2 都忽略它。Ghostty 源码是下载来编的，没法在 Zig 里改，只能在 Dart 层去掉。OSC/APC 内容里夹的 DEL 也会被去掉（R20 的对比测试 `test/terminal_vt_corpus_test.dart` 的 bare-del 素材管着） |
| （R20，见 git log） | flterm：控制器一建好就按 `TerminalTheme.dark()` 设好前景、背景、调色板，视图挂上后照常换成视图的主题 | 上游等视图挂上才把颜色交给 Ghostty，之前远端问前景/背景/光标色（OSC 10/11/12）一律不回，后台标签里一开始就问背景色的程序只能等到超时（R20 对比测试发现） |

0.0.5 时期的 04df082（输入法补丁）、8caeb73（改用预编译库）已被同步覆盖，补丁移进了 1dda0c8。

### 同步上游

上游会大改目录（这次 `widgets/` 拆成了 `controller/`、`input/`、`view/`），补丁常常对不上路径。办法是：先存下我们的改动，用上游原样覆盖、单独提交，再把改动放回去。

```bash
LAST=4a7ed9c          # 上次「同步到上游」的提交；它之后 third_party/libghostty 里的改动都是我们的
NEW=<上游新提交>
git diff $LAST HEAD -- third_party/libghostty > /tmp/xwshun-ours.patch
git clone -q --filter=blob:none https://github.com/elias8/libghostty.git /tmp/libghostty-up
rm -rf /tmp/libghostty-tree && mkdir /tmp/libghostty-tree
git -C /tmp/libghostty-up archive $NEW | tar -x -C /tmp/libghostty-tree
rm -rf /tmp/libghostty-tree/packages/flterm/example/assets/fonts /tmp/libghostty-tree/packages/flterm/test/fixtures/fonts \
  /tmp/libghostty-tree/packages/flterm/example/assets/*.wasm
rsync -a --delete --exclude .gitignore /tmp/libghostty-tree/ third_party/libghostty/
git add -A third_party/libghostty && git commit -m "fork：libghostty 同步到上游 main $NEW"
git apply --3way /tmp/xwshun-ours.patch     # 返回非 0 会列出合不进的文件，照 xwshun: 注释手工移植
```

合完还要：

- 上游 `.gitignore` 变了就手工合（上面 rsync 跳过了它，因为我们加了几行）。
- `ghostty.version` 变了就重算 hash：`curl -fsSL https://github.com/ghostty-org/ghostty/archive/$(cat third_party/libghostty/packages/libghostty/ghostty.version).tar.gz | shasum -a 256`，写进 `ghostty.sha256`。
- `fetch-libghostty-assets.sh` 里的提交和 SHA256 换成新的（上游字体变了脚本会报「对不上」）。
- 本文件的起点、`LAST`、差异表更新；跑完上面的测试，再在 Android 上用 spike 验一遍（`spikes/terminal_spike/README.md`）。

### 待办：和 xterm2 对齐（R17、R18）

逐项对照主 App 现在的终端（`lib/presentation/terminal/xterm_terminal_view.dart`），对齐一项勾一项、写进 R17/R18 证据：

- [x] 外观：主题色（16 色和 xterm2 共用）、字号、透明背景（R17）
- [x] 和 App 其他部分的接口：画中画文字、AI 上下文（适配器的 `recentLines` / `allText`，R17）
- [x] 选区：长按后拖动、双击选词、手柄、右上角「复制」；全屏程序里「复制」弹整屏文字，自动折行接回去（R17 模拟器上走过）
- [x] 快捷键栏的一次性 Ctrl/Alt/Shift：交给 flterm 的虚拟修饰键，软键盘下一个键用掉后快捷键栏复位（R17 模拟器上 Ctrl+L 走过）
- [x] 快捷键栏的方向键、Home/End 改走 `sendKey`，跟随应用光标模式（R18）
- [x] 敏感输入走 visiblePassword：fork 加了 `secureTextInput`（R18，0de868c）
- [x] 软键盘退格（xterm2 的 `deleteDetection`）：真机微信输入法删字、删拼音对，模拟器回放输入法空编辑区退格对（R18）；Gboard 的退格 R18 没单独测
- [x] 鼠标：tmux 打开鼠标报告时滑动发滚轮交给 tmux；全屏程序没开鼠标报告时滑动不变成方向键（App 把 1007 关了）；点按、长按不发点击（4ba1019）（R19）
- [x] 链接：认 OSC 8 和文字里的 http/https 网址，只把 http/https 交给浏览器、先弹确认框；不认文件路径（R19，App 侧的 LinkSettings）。
  10-07 起点一下只叫键盘，长按落在链接上（或选中的字整段是网址）时选字菜单里多「打开链接」（fork 54b7369 加了 `onLongPress`）
- [x] 粘贴：Ctrl+V 等粘贴快捷键换成 App 的意图、先预览，不再由 flterm 直接粘进终端（R19，App 侧传 `shortcuts`，fork 没改）
- [x] 硬件键盘 Ctrl+K、Ctrl+A 发给服务器，清滚动区、全选挪到 Ctrl+Shift+K、Ctrl+Shift+A（所有者 10-07 定）：改在 App 侧，fork 没改——
  App 传给 flterm 的 `shortcuts` 用同一个 const 快捷键对象盖掉它的 Android 默认（见 `lib/presentation/terminal/terminal_view.dart`
  的 `terminalKeyShortcuts`）。同步上游后 flterm 的默认键位变了要回来对一下：`test/terminal_hardware_keys_test.dart` 会挂。
- [x] 有选区时 Ctrl+C 照样发 ^C，复制挪到 Ctrl+Shift+C（R20 前所有者定，和 xterm2 一样）：同上，改在 App 侧的 `terminalKeyShortcuts`。
- [x] Ctrl+I、Ctrl+M、Ctrl+[ 发 Tab、回车、ESC（R20 前所有者定，fork c474751）。原因：Ghostty 照 fixterms 把这三个编成 CSI u，
  Android 硬件键盘的按键事件又不带字符（widget 测试里模拟的事件带，所以测试里是 CSI u、设备上什么都没有）
- R04 已知问题：
  - 已解决：收起后叫不回键盘（3，fork 修）；dispose 后 write 段错误（1，上游改成抛 StateError，适配器仍要挡住迟到的数据）
  - 还在：组合字符缺重音（6，10-04 模拟器截图；R20 核对过终端模型里重音在，宽度、光标位置和 tmux、xterm2 一样，只是没画出来）
  - R20 已解决：裸 DEL 画成方格（9，39a7ba8）
  - R20 和 tmux 对比时看到、没修的上游问题：ANSI 模式的 DECRQM（`CSI 4 $ p`）不回话——`stream.zig` 的 `'p'` 分支只认
    两个中间字节，一个 `$` 的走进「未实现」，私有模式（`CSI ? n $ p`）正常。要修得改 Ghostty 的 Zig 源码，现在没有打补丁的路子
  - R18 已解决：语音输入整段重复发送（8，8711b1a、b63c843；10-06 真机微信输入法复测通过）
  - R17 已处理：默认资源上限过大（7）：滚动区 5000 行、字节上限 8 MiB，不收 Kitty 图像和 APC 数据
  - 新看到的：Gboard 弹着时，注入的 Esc 被输入法拿去收键盘，终端收不到（模拟器；硬件键盘的情况归 TER04）

## 其他依赖

照上面的做法：bug 卡住我们时 fork 进 `third_party/<名字>/`，记起点提交、差异表、同步办法，改动标 `xwshun:`；不顺手升级版本。
现在只有 libghostty 一份。已知可能要 fork 的：

| 依赖 | 问题 | 现在怎么处理 |
|---|---|---|
| dartssh2 2.22.5 | SSH 版本行被拆包就断开 | App 里用 `SshBannerDeadlineSocket` 绕过（R06） |
| flutter_secure_storage 9.2.4 | Android 端切了存储文件名不切回来；Keystore 失效时静默换一份存储 | App 里显式写默认文件名（R14）、能识别并提示（R09）；升级到 10.x 要所有者同意 |
| xterm2 5.2.0 | 只作迁移期对照，Ghostty 成为默认后退出生产路径 | 不 fork |
