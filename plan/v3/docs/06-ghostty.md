# 06 Ghostty迁移：libghostty + flterm

## 选择与边界

使用用户指定elias8仓库的Dart/native `libghostty`和Flutter组件`flterm`；2026-10-04所有者定自己维护fork（`third_party/libghostty`），修bug、补功能、对齐原项目xterm能力，差异与同步见`third_party/README.md`。后者已有controller、view、输入与选择API，不应从零绘制每个单元格，也不默认套SagerNet Compose/PlatformView。VT核心来自Ghostty，不意味着复制了桌面Ghostty GPU渲染器，性能收益需要测量。[S16](13-sources.md#s16) [S17](13-sources.md#s17) [S19](13-sources.md#s19)

当前观察 `flterm 0.0.5` + `libghostty 0.0.12`，有Android预编译清单和SHA256检查，不能说Android尚无支持；同样不能把清单当成用户手机已稳定运行。锁定pub包、Git依赖SHA、Ghostty源pin、asset hash及SDK，禁止浮动main。2026-10-04起fork固定在上游main的`9e40b11`（未发版，不跟随更新），Ghostty源固定`349f0260`、源码包按SHA256核对，用Zig 0.16从源码编原生库；同步上游要按`third_party/README.md`手动做。[S17](13-sources.md#s17) [S18](13-sources.md#s18) [S20](13-sources.md#s20) [S21](13-sources.md#s21)

## 逐步替换

A. 固定原xterm2绿色基线，先修原始字节切分问题。
B. Session与terminal类型解耦，只保留raw input/output、尺寸、输入动作、dispose和能力查询接口。
C. 离线fixture接入flterm，验证Android动态库、CJK/IME和full screen。
D. 同一SSH路由、同一字节素材对比两引擎；移植键盘、选择、theme、tmux手势，逐项确认。
E. Ghostty通过后作为默认并清除生产路径中旧xterm2依赖。测试对比支架可保留在工具目录；不长期在安装包捆绑两个完整引擎。

若Ghostty有阻断缺陷，只可交付明确标记的xterm2中间dogfood构建并记录缺口；**不能把仅有回退当成完成用户要求的替换**。改变最终引擎需所有者明确重新决策。活跃会话不盲目热切引擎；重建终端后安全重附着，不重放按键。

## API适配必须从源码核对

读取时controller的核心为 `write(Uint8List)`、`onOutput(Uint8List)`、`onResize(cols, rows)`。Key/Text/Paste各有不同语义；不要凭README简写写错callback签名。一次controller只能绑定一个view，write期间回调同步且禁止重入；dispose后不能再用。[S19](13-sources.md#s19)

双向：SSH字节原样进入write；onOutput包含用户输入与终端协议回应，发送到当前代次的SSH输入，不循环喂回write。先安装回调再feed；旧代次回调忽略且释放资源。网络chunk不是字符边界。旧xterm2适配需要持续UTF-8 decoder；Ghostty路径不先转String。

flterm的paste可能清洗控制字符、在非bracketed模式转换换行；这不构成“不会执行”的保证。产品层仍先预览多行/控制字符并区分粘贴与回车。不要将sendText用于所有按键或把方向键当普通文本。

## 必须验收的能力

中文composing/commit只发送一次；Gboard或用户实际中文输入法；软硬键盘、Ctrl/Alt/Esc/Tab、修饰键复位；CJK/emoji/组合字符、光标宽度、alternate screen、scrollback、bracketed paste、鼠标报告、主题与字号、resize和多标签。

使用同一合成VT分别整块、逐字节、随机切分输入，比较grid/cursor/回应与截图。实际CLI包括tmux、vim/less/htop，用户授权后才测试Claude Code/Codex。不能用静态截图或录制输出代替真实键盘/PTY操作。

TERM初始保持已验证的xterm-256color兼容范围；不自动更改服务器terminfo。能力不足明确关闭扩展；Kitty图像等扩展设置资源上限，不默认开启远端触发的本地通知、剪贴板读取、URL打开或文件访问。

## Android/native与资源

16KiB必须检查所有最终.so的ELF与打包对齐，并在相应设备/模拟器运行，不只看主native库。NDK/构建链与预编译清单独立记录；缺目标制品时源码编译或明确不分发该ABI，不跳过hash验证。App运行时不从网上下载可执行终端库。[S20](13-sources.md#s20) [S21](13-sources.md#s21) [S32](13-sources.md#s32)

初始设计预算：4活动连接、每会话5000行或等价受控字节预算；待渲染buffer 4MiB高水位；native库自己也有内存，Dart heap不足以衡量。用5MiB合成VT、100次创建销毁、50次键盘变化测基线；超限背压或显式终止，不丢VT数据后伪装正常。计量方法在R04冻结，不能不断放宽阈值让测试绿。

UI显示实际引擎与错误。native crash可能终止整个进程，不能承诺同进程catch并无缝回退。次启动可提供安全入口，但不自动连生产主机或重跑命令。
