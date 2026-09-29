# 00 修订结论与旧计划替代关系

版本：3.0 / 2026-09-29。本包是规划修订，不是App版本3.0。V3同时替代09-28原方案及本轮未交付的V2草稿。新增插件机制为主线，不是将全部扩展留到未来。

## 决策

以 **Netcatty-mobile为优先二开基座**，保持Flutter + 现有Riverpod + dartssh2；目标终端使用 **elias8/libghostty仓库中的libghostty + flterm**。Conduit为明确的替代方案，不同时维护两个产品分支。前提是接受Netcatty的GPL-3.0-or-later；正式分发路线未定时先个人隔离实验，不能将未确认许可视为默认闭源授权。[S02](13-sources.md#s02) [S34](13-sources.md#s34)

上一版 `android-terminal-implementation-handbook-2026-09-28.md` 的Kotlin/Compose、SSHJ、三个Gradle模块、WebView+xterm.js、从零建设主机/密钥/SSH层，全部被本包替代。原 `T00–T41` 不再作为活动任务；对应转移在 `legacy-task-map.json`。不得把新任务Rxx写成已完成旧任务，也不得同时照两套提示词实施。

| 上一版 | 本版决定 | 原因 |
|---|---|---|
| 独立从零写Android应用 | 在指定新仓库fork Netcatty | 复用已存在移动终端、SFTP、代理、跳板和安全存储的路径 |
| Kotlin/Compose + SSHJ | Flutter + Riverpod + dartssh2 | 用户新增了明确的Flutter二开方向 |
| 原生Android Ghostty与WebView二选一 | Flutter `flterm` + `libghostty`为目标，旧xterm2为迁移基线 | 不引入第二套UI栈；替换需实测，不是一行改依赖 |
| 首版不做跳板与发现 | ProxyJump、外部SOCKS、Tailscale设备目录进入主线 | 本次明确需求 |
| SOCKS默认只支持回环 | 回环和显式远端SOCKS均支持 | 外部已有动态转发/远程代理是用户指定场景 |
| SFTP等从零后置 | 已有能力保留且回归，不无端删掉重写 | 二开不等于重做整套产品 |
| 无Tailscale节点代码 | 仍不嵌入节点；新增只读设备目录 | 设备发现不负责网络连通 |

## 继续有效的硬约束

不启动VpnService、不替换现有VPN；无效代理/失败不直连；每跳和最终host key独立校验；秘密与终端内容默认不上云；重连不重放；tmux恢复不自动新建/杀进程；无设备不伪造验收；不消耗真实模型额度做默认测试。

## 三层分离

`设备目录：选择谁` → `连接路由：如何到达` → `SSH认证：以谁登录`。

“从Tailscale列表点击SSH”是产品入口，不是第四种网络协议。不因导入了一台设备而强制它使用官方Tailscale VPN，也不因100.x地址而跳过SSH认证或主机指纹。

## 完成边界

本轮完成的是源码线索审阅和计划文件；未修改任何用户仓库，未克隆完整源码、构建、签名或真机执行。旧计划中的成功记录为LobiShell用户实测，不是本项目测试。

## 插件需求引起的追加修订

采用同一能力注册表，支持随包内置模块、独立Android服务APK、外部App适配器。Tailscale目录为内置provider；SSH/SOCKS/ProxyJump是受控内置连接能力；Mosh为首个真实外置运行时插件；UU/RustDesk首版实现外部App联动。RustDesk内嵌画面单列后续门禁。

R00–R31延续并修订；新增X00–X13必须完成才算完整范围。R34仅保留Mosh代理UDP扩展，Mosh本身不再整个后置。插件主契约见docs/15，交付分层见docs/19；不要照V2旧数量或旧门禁宣布完成。
