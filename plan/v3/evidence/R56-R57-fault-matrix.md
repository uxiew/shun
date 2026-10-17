# R56/R57 无账号故障矩阵与 Android 模拟器证据

日期：2026-10-12。基线 `1b7d652`，本轮是在 R56/R57 初版上补测、修复，代码提交 `af17597`。R56/R57 仍 IN_PROGRESS；AIC03/04/05/07/08 按下述本机 + Android 模拟器范围记 PASS。AIC06 的参数派发边界已测，但真实原生会话连续性未测，AIC06/AIC09 仍 NOT_RUN。

## 环境与边界

- macOS arm64，仓库独立 Flutter 3.44.4 工具链；本机 Docker OpenSSH 主测试环境和 tmux 2.4、2.7、3.0a、3.5a。使用测试生成的账号、指纹、独立 socket 与无模型请求的可执行脚本，全部走真实 SSH；未连接用户主机。
- Android 15 / API 35 / arm64 / 4 KiB，专用 `shun-a35-4k`，序列号 `emulator-5580`，包名 `top.xdwa.shun`。真实 ShunApp、Riverpod、Ghostty、SSH 与 Android 加密存储；不使用真实 AI 账号。未运行真机/iOS、非 POSIX 登录 shell。
- Claude Code 2.1.292、Codex CLI 0.160.1 的隔离镜像版本沿用初版；本轮另以 `--network none`、非 root 用户运行 `claude --help`，确认无 ID 时 `--resume` 为历史选择器。未登录、调用模型或创造真实原生对话 ID。无 ID 的选择器与有 ID 但失效时的处理不同：后者不自动降级。

## 故障矩阵

| 用例 | 实际动作与观察 | 结论范围 |
|---|---|---|
| AIC03 | 本机 shell 和真实 Direct / SOCKS+Jump 检查空格、中文、引号、字面命令替换；C0/C1 控制字符逐个拒绝；不存在/不可进入目录、工具移走及执行权限取消后拒绝。执行前再次检查失败不写成功入口。另开 raw cat、真实 vim 时启动工具，原 PTY 没有收到启动文字/按键，vim 仍运行，手动 `:q!` 才退出。 | PASS；受支持 POSIX shell，本机 SSH + Android UI |
| AIC04 | 在创建前、创建后、启动前、启动后分别断 SSH、取消、触发真实有界命令超时，共 12 项；独立连接统计 session 与模拟工具执行次数，创建后/启动前保留单个空目标，启动后只运行一次；随后只读核查不改变计数。controller 另测同 ID 重复请求、超时与取消后迟到成功不能创建标签/回调。 | PASS；不自动补发或杀目标，发送后未知仍未知，不构成 exactly-once 证明 |
| AIC05 | 四版本各测死窗格、分窗格、加窗口、同名重建、重启 server、改变 socket、换 SSH 用户，28 项的 verify 与 guarded attach 均拒绝；另 4 项在收到 attach 握手后加窗格、再发确认，退出 97 且未附着。四版本正常精确附着及替换 pane PID 回归 5 项通过。活标签匹配工具/目录/用户/原运行，Android 真断 SSH 后显式返回原 tmux，计数不增。 | PASS；限定完整原目标，失配拒绝 |
| AIC06 | 模拟可执行文件收到原目录与准确 `--resume <ID>` 后主动退出 44，记录只有这一次调用，未替换成 `--last`/`--continue`/新建；缺 ID 的 Claude/Codex 走各自选择器；主机 CODEX_HOME 环境配置变化后隔离旧入口。 | 仅适配层边界通过，真实对话/删除历史/工具版本与账号身份仍 NOT_RUN |
| AIC07 | 模拟器从主机详情启动失败、普通启动及返回、专属 tmux、断 SSH、后台 HOME/息屏/唤醒、活跃连接时 force-stop，随后在另一进程显式返回；冷启动无活动标签或待连接项，计数不增。验证缩短到 2 秒的凭据租期清空路线秘密、无自动恢复/输入；切用户/删主机隐藏入口，清除本机记录不杀远端 pane。私有 XML 值无明文工具/目录/请求 ID/伪标题，保险库导出不含工作指针；通知转储无伪标题/READY/输入哨兵。单测验证旧记录缺字段、损坏包清除修复、worktree 并发写与清除顺序、20 条和总长度上限。 | PASS；模拟器 + 本机，生产 10 分钟租期的长时等待/真机未复测；备份禁用与不导出沿用既有策略，不声称执行了系统备份恢复 |
| AIC08 | 输入伪造完成/批准/恢复 ID、一般工作标题、残缺与超长标题；实际终端可以显示这些字节，但原生 ID、目标及操作决策不变。Android 经过断线、切页、后台和杀进程，首页始终标「会话状态待核对」。 | PASS；当前未实现 AI 标题状态解析，所有此类输入均不作为身份/批准/完成依据，不宣称已实现状态协议 |
| AIC09 | 未使用真实 AI 账号、真实测试对话、模型额度。 | NOT_RUN |

## 修复

1. tmux 核对增加 `pane_dead`、唯一窗口/窗格约束，并在启动和附着握手守卫重复检查，拒绝死窗格或后来出现的歧义目标。
2. 活终端返回检查原工具路径、项目、主机身份、原运行与原生 ID；异步操作后重新核对，不再依赖旧标签下标。tmux 已发出创建但本地未打开成功时保持「结果未知」。
3. 普通 SSH 启动增加有界、可跨分包的启动前确认；目录/权限二次检查退出 125/126 时确认拒绝，不产生成功标签/最近记录。确认只表示已通过 wrapper 检查、即将 exec，不证明 AI 登录或对话创建。其他发出请求后的失败保留未知。普通终端原始字节路径保留。
4. 最近记录按配置环境的规范化摘要增加隔离，不写原始环境秘密；按主机串行化写入/清除，限制序列化总长度，避免并发 worktree 丢失或清除后复活。旧数据要求绝对项目路径和完整身份；损坏时保留清除入口。
5. 项目路径不再 trim，保留有效首尾空格。模拟器发现长目录与操作按钮挤在同一行，将最近卡片改为内容在上、按钮换行；Claude 缺可靠 ID 的旧入口可显式选择工具历史。

## 执行与原始材料

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub -j 4 --exclude-tags ai-cli-ssh-fixture --reporter expanded`：**1188 通过、15 跳过、0 失败**（13 项 Mosh fixture 未启动、1 项 Windows 专用、1 项耗时基准）。第一次全量发现 TER01 的源码边界检查失败（AI 握手接入时移除了普通原始字节直连的显式结构），已恢复普通路径并全量重跑；未忽略该检查。
- 单独 `test/ai_cli_launch_ssh_fixture_test.dart`：7 过；`test/ai_cli_tmux_ssh_fixture_test.dart`：5 过；`test/ai_cli_fault_matrix_test.dart`：44 过；无失败。
- R55 回归 `test/ai_cli_ssh_fixture_test.dart`：7 过、1 跳过（本轮未启动真实安装包发现容器；不覆盖或替代原 R55 的 8 过证据）。
- `bash tool/r56-ai-cli.sh`：seed PID **7206** 所有前置断言通过，在 `R56 KILL_READY=seed` 后由宿主强制结束且确认 PID 消失，测试尚未 teardown；seed 的 `did not complete` 是该真实杀进程动作的预期结果，不记作 Flutter 测试通过。第二进程 cold PID **7482**：**1 过、0 失败**，完整显式返回/清除/身份隔离通过。两个进程内远端累计始终 **2 次启动**（一次普通、一次 tmux）。
- `locked-power.txt` 实测 `mWakefulness=Asleep`。仅测试缩短租期，不更改生产值。首轮脚本曾因 Flutter 默认卸载测试 App 而无法保留冷启动数据，改成 `--no-uninstall` 后复跑；未把该次失败当成功。另曾只在测试结束后 force-stop，已改为上述活跃连接期间杀进程并复跑，最终证据采用 PID 7206/7482。
- 仓库外材料：`../.toolchain/artifacts/r56-1b7d652/`，含 `seed.log`、`cold.log`、`force-stop.txt`、`seed-live.png`、`before-lock.png`、`locked-power.txt`、`locked-notifications.txt`、私有文件名清单及本机测试日志。设备截图用于观察，不替代进程/计数断言；测试凭据不写入本证据或普通导出。

复跑与收尾步骤见 `docs/dev/README.md`。收尾已卸载本项目模拟器测试包、删除 22314 reverse、关闭专用模拟器并释放本次锁；两套 fixture 已 down，临时凭据删除，其他模拟器/容器未操作。R56/R57 不改 DONE，G4/R30 不因此通过；下一项是获得真实测试主机/AI 账号与额度授权后的 AIC06/AIC09 连续性验证。
