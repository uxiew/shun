# R56/R57 真的 Claude Code / Codex + 模拟模型：AIC06 设备证据

日期：2026-10-30。测试提交 `93a011e`（`integration_test/aic06_real_cli_test.dart`、`tool/aic06-real-cli.sh`；夹具 `344531d`、`249ae27`）。
**AIC06 按「真实 CLI + 模拟模型」的范围 PASS。AIC09 保持 NOT_RUN**（所有者的决定，见下）。App 代码这次没改。

## 所有者的决定（10-30）

不登录真实 AI 账号，改用模拟测试：容器里装的是真的 Claude Code 和 Codex，只把它们连的模型接口换成容器里的假服务。
AIC09（真实账号、真实模型）等全部任务做完后，由所有者自己实际使用、实测；R56、R57 不再等 AIC09。

## 哪些是真的、哪些是假的

- **真的**：App（ShunApp、Riverpod、Ghostty 终端、Android 加密存储），Android 11 模拟器 `shun-r39-a30`（`emulator-5580`）；
  SSH（adb reverse 22401 → 容器里的 OpenSSH，按指纹核对）；tmux 3.3a、Debian 12.15、Node 22.23.4；
  Claude Code 2.1.314、Codex CLI 0.166.0、Claude Code 1.0.0 的原版程序，以及它们自己写的会话文件、自己的历史列表。
- **假的**：模型接口。容器里 127.0.0.1:18080 跑 `tool/ai-cli-fixture/mock-model.mjs`，`mock-model.sh` 把两个工具指过去，Claude 的 API key 是假值。
  假服务的规矩：`MOCK-REMEMBER <口令>` 回 `OK <口令>`；`MOCK-RECALL <标签>` 只在工具这次发来的历史里找口令，找到回 `RECALL <标签> <口令>`，找不到回 `NONE`。
  说白了：屏幕上出现了对的口令，就说明工具真的把那段历史一起发了过来。

## 怎么判断「续上的是同一段对话」

三样互相独立的东西，不只看屏幕：

1. 假服务的回话（上面那条规矩）。
2. 工具自己报的会话 ID：Claude 每个请求带 `x-claude-code-session-id` 头；Codex 把会话 ID 放在 `prompt_cache_key` 里。假服务把它记进 `requests.jsonl`（只记 ID、口令、条数，不记提示词全文）。
3. 工具自己的会话文件：`~/.claude/projects/<目录>/<ID>.jsonl`、`~/.codex/sessions/**/rollout-*-<ID>.jsonl`。

## 场景和结果（`../.toolchain/artifacts/aic06-93a011e/`，4 分 06 秒，`All tests passed!`）

| 场景 | 做了什么 | 看到什么 |
|---|---|---|
| Claude 在 tmux 里新建 | 主机详情 → AI 工具 → Claude 2.1.314，目录 `~/aic/repo`，勾「保留在专属 tmux 会话」 | tmux 窗格进程是 `/usr/local/bin/claude --session-id 91230ab8-…`，和最近工作记下的 ID 一样；请求头里的会话 ID、会话文件名也是它 |
| 留在 tmux 里返回 | 关掉 App 这边的 SSH，从首页卡片 →「核对并返回 tmux」 | 附着回同一个窗格；远端带这个 ID 的 Claude 进程只有 1 个；`MOCK-RECALL t2` 答出口令，这次请求带 2 句用户提问 |
| 进程结束后按 ID 继续 | Claude 里 `/exit`，tmux 会话随之没了；容器里在同目录另开一段更新的对话（8860abe9）；再点「核对并返回 tmux」 | 先报目标不在了，不附着、不新建；点「按会话 ID 继续」后 App 启动的是 `--resume 91230ab8-…`，工作目录 `~/aic/repo`；`MOCK-RECALL t3` 答出口令，请求带 3 句提问；目录里还是 2 个会话文件，更新的那段一行没多（`--continue` 会选中的就是它） |
| 另一个 worktree | `~/aic/repo-wt`（同一仓库的 git worktree）新建，退出，再按 ID 继续 | 会话 68e99c66 写在 `-home-fixture-aic-repo-wt/` 下；继续后工作目录是 worktree，答出自己的口令，没串到 repo 那段 |
| ID 失效（会话文件被挪走） | 把 91230ab8 的会话文件挪走，再点「按会话 ID 继续」 | Claude 自己报「No conversation found」退出；假服务没收到任何对话请求（前后都是 6 条）；没有新会话文件；最近工作仍指着原 ID |
| 配置身份换了 | 主机加环境变量 `CLAUDE_CONFIG_DIR=/home/fixture/.claude-other` | 首页「最近 AI 工作」卡片消失；改回去又出现 |
| 不支持的版本 | 「补充目录」里的 Claude Code 1.0.0 新建，再按 ID 继续 | 新建时它报 `unknown option '--session-id'` 退出，App 没替它换成不带 ID 的启动；继续时报「No conversation found」；没有请求、没有会话文件 |
| Codex 在 tmux 里新建 | Codex 0.166，目录 `~/aic/codex`，勾 tmux | 窗格进程是 Codex 自带的原生程序、不带参数（没有 `resume`、`--last`）；会话 01a18ad4-207a-… 的 rollout 文件 1 个 |
| Codex 留在 tmux 里返回 | 关 SSH，「核对并返回 tmux」 | 同一窗格；`MOCK-RECALL t9` 答出口令，会话 ID 不变 |
| Codex 进程结束后 | `/exit`；容器里同目录另开一段更新的交互式对话（01a18ad4-8e0c-…）；点「核对并返回 tmux」→ 报不在了 →「选择 Codex 历史」 | App 启动的是 `codex resume`（不带 `--last`）；列表里两段都在，**Codex 自己默认选中更新的那段**（截图 `codex-picker.png`）；用户按 ↓ 选原来那段、回车，`MOCK-RECALL t10` 答出原口令，会话 ID 是原来的；会话文件还是 2 个 |
| 列表里的提示词不留存 | 最后读 App 写进加密存储的最近工作（解密后那份） | 4 条记录里搜不到任何口令或 `MOCK-` |

截图 7 张（`claude-new`、`claude-tmux-return`、`claude-exact-resume`、`claude-missing-id`、`codex-new`、`codex-picker`、`codex-picked`），
`mock-requests.jsonl`（21 条，其中 10 条是对话请求）、`session-files.txt`、`versions.txt` 都在同一目录。
同样的测试在 `4af82be`（`aic06-4af82be/`）、改测试前的工作区（`aic06-344531d/`）上也各全过一次，一共连续 3 次全过。

## 跑到全过之前撞的墙

都是测试或夹具的问题，App 代码没改：

1. 读最近工作读到空列表：App 在终端连上**之后**才写记录，测试一看到连上就去读。改成等记录出现（最多 20 秒）。
2. tmux 标签上 `aiLaunch` 是空的（它只附着窗格，启动参数不挂在标签上），测试拿它断言参数就崩。改从远端 `/proc/<窗格 PID>/cmdline` 读。
3. Claude 停在「Yes, I trust this folder」：夹具只信任了父目录 `~/aic`，2.1.314 不继承，要逐个目录写。它前三次启动还弹「Try the new fullscreen renderer?」，会吞掉第一句输入，夹具把计数设成 3（`249ae27`）。
4. Claude 1.0.0 崩成 `B.allowedTools is not iterable`：2.1.314 写的项目配置不带这个字段，1.0.0 不检查就遍历。夹具先写好空数组，之后 1.0.0 才给出它对「ID 不存在」的真实反应（`249ae27`）。
5. Codex 窗格进程的命令行读到空串：`/usr/local/bin/codex` 是 npm 的 node 入口，会再 exec 成包里自带的原生程序，正赶上 exec 时读不到。改成轮询。
6. 期望值多写了一个尾随空格（远端输出会 trim）。
7. `4af82be` 那轮全过了，但请求日志里有一条意外的：Claude 在回复后 37 毫秒又发了一条带工具定义的请求，同一会话 ID、多一句不进会话文件的提问。
   测试原来取「最后一条对话请求」核对提问条数，被它抢先就会偶发差 1；改成只看回答我们提问的那些（`93a011e`），「没发任何请求」照旧全数。

## 顺带看到的工具行为（不是 App 的问题）

- 同一目录先用过 Claude 2.1.314、再用 1.0.0，1.0.0 一启动就崩（上面第 4 条）。用户混用新旧版本时可能撞上；App 不替它改配置，也不降级成别的启动方式。
- Codex 0.166 退出界面后留着 `codex app-server` 后台进程（在 `~/.codex/packages/app-server-daemon/` 下），启动参数带 `--analytics-default-enabled`；夹具在 `config.toml` 里关了 analytics。测试每轮开头会停掉它，不然历史列表可能带出上一轮的状态。
- Codex 发给模型的第一条请求就带 2 条「用户」消息（一条是它自己加的环境说明），所以 Codex 的提问条数从 2 起算。
- `claude -p` 在标准输入不是终端时会等它读完；SSH exec 的标准输入一直开着，要 `</dev/null`。

## 没测的

- **真实模型和账号那一侧**：登录、登录过期、限流、额度、服务端怎么处理会话。这是 AIC09，所有者 10-30 定了最后自己实测，现在 NOT_RUN。
- 真机、iOS：只在 API 30 模拟器上。
- Gemini、OpenCode、自定义工具：容器里没装。App 对它们只提供新建和可核对的活终端 / tmux 返回（见 [R57](R57.md)），这次没有新的实测。
- tmux 只测了容器里的 3.3a；四个 tmux 版本上的目标核对在 [R56](R56.md)、[故障矩阵](R56-R57-fault-matrix.md)。
- 「ID 失效」只测了会话文件被挪走；文件损坏、没权限读没测，结果以工具自己的报错为准。
- Codex 没有拿到本次运行 ID 的可靠办法（ID 只出现在发给模型的请求和文件名里），所以 App 不按 ID 继续 Codex，只开它自己的历史列表让用户选；这里测的就是这条路。

## 复跑

见 `docs/dev/README.md` 第 2 节 AIC06 那段：先拿锁、开 `emulator-5580`，`bash tool/aic06-real-cli.sh`，约 7 分钟。

收尾：`shun-ai-cli` 容器已 `down.sh`；`emulator-5580` 已关机、锁已还；flutter test 跑完自己卸了测试包，22401 的 reverse 脚本已撤。没碰别的容器和模拟器。
