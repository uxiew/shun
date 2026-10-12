# R56/R57 模块整理与用户手册补充

日期：2026-10-12。基线 `f9d004d`，代码提交 `8bbb460`。按所有者对模块化、可维护性、解耦和鲁棒性的要求，聚焦上一批 AI CLI 改动；不扩大到其他功能重写，不改变 R56/R57 或验收用例状态。

## 模块与约束

- `domain/host_identity.dart` 集中临时标签的来源主机身份；`domain/ai_cli_identity.dart` 集中发现设置和最近工作的隔离规则。身份模块不依赖 Flutter、SSH、应用生命周期或存储。首页、工具面板和返回判定直接引用同一规则；`connection_lifecycle.dart` 重新导出原身份入口，保留已有调用方兼容。
- `infrastructure/storage/ai_cli_preferences.dart` 仅保留设置读写，不再定义身份规则或反向依赖应用生命周期。键的序列化保持一致，不迁移、不清除已有最近工作。测试固定无环境配置时的历史格式，以及临时标签归属、环境顺序/重复键的有效值、用户/主机/项目分隔等已有行为。
- `infrastructure/ssh/ai_cli_launch_handshake.dart` 独立管理等待、已确认、失败三个状态。通过原始字节输入、一次确认回调、输出回调和完成 Future 暴露接口；不持有 SSH 客户端、终端对象、凭据或存储。SSH 模块继续负责 15 秒期限、取消、绑定及资源释放；普通 PTY 和 tmux 不通过该握手解析。
- 修复确认前输出的长度漏洞：原逻辑先找 marker，有 marker 时不检查前缀大小。现统一限制 marker 结束位置不超过 8192 字节；允许 marker 后同包的大量 CLI 输出。失败会清空暂存并丢弃迟到字节，不能再切到成功。125/126 只有确认前才算 wrapper 拒绝；确认后的工具退出不重新归类。

## 文档

`docs/user/README.md` 第 20 节补上首次使用四步、五种返回/继续入口的差异、常见故障与下一步、最近记录不是对话备份；修复旧章节锚点。`docs/shun/README.md` 记录模块职责、兼容约束及定向测试入口。用户手册不暴露握手协议实现细节。

## 验证

- `flutter analyze --no-pub`：无问题。
- 定向测试：**54 通过、0 失败**。其中新增握手 10 项、身份兼容 2 项；遍历完整二进制/UTF-8 输入的所有两包切分位置，另测逐字节分包、超限有/无 marker、同包大输出、确认前退出、失败后的迟到字节；复跑启动参数、最近存储、界面、controller 代次及终端分层检查。
- 全量 `flutter test --no-pub -j 4 --exclude-tags ai-cli-ssh-fixture --reporter expanded`：**1114 通过、101 跳过、0 失败**。本次未启动 SSH/tmux/Mosh 环境，其用例跳过，另含 Windows 专用与耗时基准；不与前轮环境齐备时的通过数直接比较。
- 本轮尝试启动隔离 SSH fixture，但 Docker socket 不存在（OrbStack 当前未运行），未连接到 Docker daemon、未创建容器。已删除启动脚本生成的临时凭据目录；没有启动系统 Docker 应用、使用真实主机或安装设备包。因此本轮真实 SSH/模拟器复验未执行，不复用前轮通过数冒充当前候选实测。前轮完整故障矩阵见 [已有证据](R56-R57-fault-matrix.md)。
- 磁盘满曾阻止新测试文件写入及 Flutter 静态检查；只清理本项目可重新生成的 `build/app` 与 `.dart_tool/flutter_build`（约 2.4 GiB），保留源码、SDK、AVD 和历史证据后重试成功。

日志保存在仓库外 `../.toolchain/artifacts/ai-cli-modularity-f9d004d/`。本轮不改变 AIC06/AIC09 未测和 R56/R57 IN_PROGRESS 的事实。
