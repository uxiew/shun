# 终端引擎对比素材（R20）

`test/terminal_vt_corpus_test.dart` 把同一份字节喂给 Ghostty（App 的终端引擎）和旧引擎 xterm2，再和 tmux 自己的屏幕比。
这里的脚本负责录素材和 tmux 裁判，结果提交在 `test/fixtures/vt/`，平时跑测试不需要它，也不需要 Docker。

```bash
flutter test test/terminal_vt_corpus_test.dart               # 约 3 秒；对比报告写到 build/vt_corpus_report.md
VT_BENCH=1 flutter test test/terminal_vt_corpus_test.dart    # 顺带量两个引擎吃 5 MiB 的耗时（只是参考）

python3 tool/vt-corpus/record.py                    # 全部重录（约 3 分钟）
python3 tool/vt-corpus/record.py --only synthetic   # 只重录合成素材的裁判（改了 synthetic_cases.txt 之后）
python3 tool/vt-corpus/record.py --only vim-cjk     # 只重录一个真实程序
```

## 什么时候要重录

- 改了 `test/fixtures/vt/synthetic_cases.txt`：测试按每段的 SHA256 核对裁判，对不上会报「改过，裁判是旧的」。
- 想加一个真实程序：在 `record.py` 的 `SCENARIOS` 里加一项（命令 + 按键步骤 + 检查点），重录。

重录之后先看 `build/vt_corpus_report.md`，再决定测试里钉住的差异（`ghosttyVsTmux`）要不要跟着改。
htop 的进程列表、内存数字每次都不一样，重录 htop 后它的检查点内容会变，这是正常的。

## 怎么录的

- 起一个一次性容器（`shun-vtcorpus-rec`），镜像是测试环境的 `shun-fixture:alpine3.22`（`tool/fixture-environment/up.sh` 会构建）。
  不连、不动正在跑的测试环境，容器里没有任何凭据，跑完删掉。没有这个镜像时先 `up.sh` 一次再 `down.sh`。
- 裁判是容器里的 tmux 3.5a：窗格固定 80x24、`default-terminal xterm-256color`、关掉状态栏。
- 合成素材：窗格里 `stty raw -echo` 后 `cat` 原样写进去（不让终端驱动把 `\n` 改成 `\r\n`，tmux 回给程序的字节也不回显），
  记下 `capture-pane -p`（文字）、`capture-pane -p -e`（带样式）、光标、是否备用屏、光标是否显示、tmux 回的字节。
- 真实程序：`pipe-pane` 录程序写进窗格的原始字节；每到一个检查点，等录下的字节数 0.6 秒不变，再截 tmux 的屏幕，
  截完字节数还变了就重来。记下的偏移就是「喂到这里为止，屏幕应该是这样」。

## 撞墙时

- **合成素材的屏幕上多了一行 `Terminated`**：busybox 的 `timeout` 杀掉 `cat` 时 sh 往窗格里打的。脚本已经把窗格的 stderr 丢掉。
- **tmux 的样式看起来不对（vim 的 `~` 行没颜色）**：`capture-pane -e` 只在样式变化时写 SGR，跨行接着上一行的样式，
  必须整屏当一条流来拆（`parseStyledRows`），不能每行从默认样式开始。
- **Ghostty 的空格看起来带了背景色**：Ghostty 的 VT 格式化输出给从没写过的格子补空格时不切回默认样式，
  所以样式只比字、不比空格（背景色擦除这类「空格上的样式」比不出来）。
- **想在 `\x{...}` 之外写码点**：别写 `\u`。工具链会把 `\u` 转义提前解码，组合字符、零宽连接符就看不见了。
