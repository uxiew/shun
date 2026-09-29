# 01 基座研判与静态代码发现

## 比较结论

| 候选 | 已核对的优势/事实 | 对本需求的主要增量 | 建议 |
|---|---|---|---|
| Netcatty-mobile | 已有hostChain、复用proxy profiles、SOCKS/HTTP接入；Flutter xterm2；主机、SFTP与session管理 | 边界加固、Ghostty替换、Tailscale目录 | **默认基座**，GPL接受为前置 |
| Conduit | 自身Apache-2.0，已有tmux/SFTP/FIDO/external auth；终端为conduit_vt | 当前读取SSH工厂为直接TCP路径，需补路由模型并覆盖所有独立SSH消费者；还要替换终端 | **许可或产品偏好改变时的替代** |
| NiceSSH | MIT，Flutter，简介简洁 | README仍把host-key验证、jump等列planned；不能以功能标题视为成熟实现 | 参考界面，暂不选主基座 |
| claude-carry | MIT，Flutter；附件、工具栏、远端Claude场景贴近 | 产品带自动启动/专用工作流，通用路由不是其核心 | 参考移动编辑和附件，不整体移植 |

依据：[S01](13-sources.md#s01) [S03](13-sources.md#s03) [S04](13-sources.md#s04) [S10](13-sources.md#s10) [S11](13-sources.md#s11) [S14](13-sources.md#s14) [S15](13-sources.md#s15)。不是四个App的实测排名；“默认基座”是按本需求增量作出的工程判断。

Conduit源码本身Apache，不代表本地shell附带的GPL/LGPL二进制变成Apache；不能靠换基座绕过第三方许可。Netcatty主应用GPL也不是只能免费使用：关键在修改和向他人提供时的许可义务，正式分发要单独审核。[S02](13-sources.md#s02) [S10](13-sources.md#s10) [S34](13-sources.md#s34)

## 明确纠正：xterm2不是xterm.js

Netcatty的依赖是Flutter/Dart `xterm2`；Conduit是`conduit_vt`，来源为xterm.dart。这里不是从WebView/JS切到“原生”，而是替换Dart终端引擎/视图为Ghostty VT绑定与Flutter绘制组件。不能用“去掉WebView”作为收益指标。[S03](13-sources.md#s03) [S10](13-sources.md#s10)

## 优先复验的代码发现

以下仅是本轮读取的分支代码事实或由调用关系得出的风险；先固定SHA、写失败用例，再修复。不能将其扩大成对作者整款应用的安全结论。

| ID | 位置/观察 | 本项目应做什么 |
|---|---|---|
| A01 | `ssh_service.dart::_openTransport`把无代理与代理host空/port无效放在同一直连分支 | 已选择代理而配置失效必须阻断；只有显式Direct才直连 |
| A02 | `_connectSocksProxy`有凭据时同时提供无认证和密码方法 | 定义显式认证策略；要求密码时不接受无认证选择 |
| A03 | stdout/stderr按每个网络chunk独立`utf8.decode` | 终端边界改为原始bytes；旧引擎使用持续decoder，不按块转String |
| A04 | connect发送startupCommand；reconnectDisconnected再次调用connect原host | 区分Fresh/Restore；断线恢复不得重跑startup或managed命令 |
| A05 | 跳板链只在第一跳打开物理transport，其余forwardLocal；target上的代理配置可能不是实际生效位置 | 冻结RoutePlan，只允许一个明确入口；拒绝无提示忽略配置 |
| A06 | 协商TCP有超时，cursor异步读取本身未见统一handshake deadline | 代理协商限时及取消必须关闭仍协商的socket；测慢速半包与迟到完成 |
| A07 | HostProfile.toString输出原始data，模型容纳password | 默认toString/诊断必须脱敏；不据此声称已发生日志泄露 |

来源：[S04](13-sources.md#s04) [S05](13-sources.md#s05) [S06](13-sources.md#s06)。A03/A04需网络切分及副作用计数测试确认影响；本轮未执行这些测试。

## 可复用不是可以不审查

保留主机CRUD、身份、主题、SFTP和平台service的已有实现。重点检查上游已有AI assistant、同步、系统管理、Telnet/Mosh入口：本版不新增模型API，AI和自动化入口默认不可激活、无初始化网络请求；同步默认关闭，控制面secret从所有导出/同步排除。已有高风险操作若保留，仍需单独用户确认与测试，不因fork自动获得执行授权。

## 版本冻结

本轮观察到Netcatty `1.4.7+26`、xterm2 `5.2.0`；Conduit `1.4.14+39`；flterm `0.0.5` + libghostty `0.0.12`。这些不是完整兼容矩阵，也不是仓库HEAD。`flterm`当前声明Flutter>=3.44、Dart^3.12，实施时以同时满足依赖的已验证SDK锁定，不泛升级其余依赖。[S03](13-sources.md#s03) [S12](13-sources.md#s12) [S17](13-sources.md#s17) [S18](13-sources.md#s18)
