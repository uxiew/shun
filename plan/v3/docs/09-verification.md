# 09 验证矩阵与可交付门禁

共 **160个用例**：原61项适配Flutter，加38项二开测试，再加43项插件/远控/Mosh/SDK用例；2026-10-10 又加了6项日用界面和安全用例（UX05–UX09、SEC13，来自 [docs/20](20-reference-apps.md)）。2026-10-11 新增3项参考应用衍生验收（UX10–UX12），并细化尚未执行的 UX07、UX09。同日按所有者新增需求加入 AI CLI 的 AIC01–AIC09（9 项）；AIC01/AIC02 于 10-12 完成本机隔离验证。结果列只写真实执行过的。

## 证据要求

每条记录源SHA、APK hash、SDK/依赖pin、设备/API/ABI/页大小、输入法、外部proxy/VPN版本、测试命令或人工动作。UNIT/INTEGRATION/DEVICE/USER_DEVICE区分，不用桌面模拟替代真实Android。

无直连要用可直连陷阱服务的计数零证明；DNS用目标resolver注入+socket端点观测；没有异常不等于没有泄露。多跳分别记录认证前的trust结果，最终SFTP等也要查路线。用户输入/startup副作用用受控fixture计数；不要求数学意义exactly-once，只要求客户端不重放。

终端同VT整块/逐字节/随机分包，比较状态与回应；截图只作辅助。UI显示Ghostty不能替代native实际加载证据；库支持列表不是ABI/16KiB运行证据。所有最终硬项对应同一候选，版本变化重跑受影响项。

## 初始性能预算（设计目标，尚未测量）

4活动会话、每会话受控scrollback；5MiB VT压力、100次开关、50次键盘变化、20次网络切换。R04冻结设备与测量方法，观察Dart+native完整资源，不只Dart heap。本地已提交输入→SSH写入p95目标50ms，远端网络回显另计。超限背压或明确失败，不能丢VT字节保持假正常。

## 核心用例

| ID | 操作 | 通过条件 | 结果 |
|---|---|---|---|
| NET01 | 通过无认证/用户名密码两类模拟 SOCKS 连接 fixture SSH；协商分片传输。 | 真实 SSH 可建立；认证严格按配置，无字段串位、重复读写或提前截断。 | PASS |
| NET02 | 目标名仅模拟代理端能解析；把 App 目标 resolver 注入为调用即失败，并记录所有 socket 端点。 | 目标 resolver 调用零次；SOCKS 请求携带目标域名；socket 只连接代理。 | PASS |
| NET03 | 让目标具备可直连条件，但让代理拒绝、停服、超时或返回错误。 | 目标直连监听计数为零；App 明确失败；不存在成功“回退”。 | PASS |
| NET04 | IPv4、IPv6、域名、IDN、过长域名、含 NUL/控制字符、错误端口及 zone-id。 | 合法目标正确编码；非法输入在拨号前拒绝；不猜测域名、不损坏地址。 | PASS |
| NET05 | 输入错误代理口令；代理选择非允许认证方法或主动降级为无认证。 | 按用户要求的认证策略协商；要求密码时无无认证降级；secret不进日志。 | PASS |
| NET06 | 服务端逐字节发送、提前 EOF、错误 VER/RSV/ATYP、长度伪造或重复响应。 | 正确处理部分读取；错误有界退出，没有线程/内存泄漏或无限等待。 | PASS |
| NET07 | 分别在 TCP connect、SOCKS 协商、SSH 握手时挂起并触发取消/期限。 | 对应阶段超时；socket 关闭；取消完成后没有迟到成功回调。 | PASS |
| NET08 | 模拟 SOCKS REP 的拒绝、网络/主机不可达、命令不支持等结果。 | 错误分类准确，不能把 host unreachable 一律称为 DNS 失败。 | PASS |
| NET09 | 快速连接→取消→再连，同时注入旧连接的晚到事件。 | generation 隔离；旧事件不能覆盖新状态或复活已停止连接。 | PASS |
| NET10 | 两个主机同时通过不同代理账号连接；编辑其中一个配置。 | 凭据、routeSnapshot 和目标互不污染；运行连接不会换代理或身份。 | PASS |
| NET11 | 在用户输入/多行发送中间断网；记录 fixture 接收到的字节，再恢复连接。 | 新连接不自动收到旧输入、命令、Enter 或粘贴；不确定的旧发送标结果未知。 | PASS |
| NET12 | 真实手机保持已有 VPN，启动 TailSocks 非 VPN 模式，连接/停止/重启代理。 | 本 App 不弹 VPN 授权、不替换当前 VPN；可连接或如实解释具体兼容限制；代理失败无直连。 | NOT_RUN |
| SEC01 | 固定信任目标 A，经正常/替换的本地 SOCKS 端连接；检查 known_hosts key。 | 信任身份是逻辑目标及端口，不是 127.0.0.1 或代理端口；未确认时不用户认证。 | PASS |
| SEC02 | 相同主机地址换一把 fixture host key。 | 硬阻断，不以普通重试忽略；没有发出 SSH 用户认证数据。 | PASS |
| SEC03 | 代理把连接转向不同 SSH 主机，或伪造本地 SOCKS 服务。 | 已信任主机的身份不匹配会被检测；首次信任仍要求用户核对，不自动信任 Tailnet。 | PASS |
| SEC04 | 修改主机域名/端口/用户、创建 alias、删除或复用身份。 | 不把代理身份、目标身份、Unix 用户混为一谈；alias 只能显式建立。 | PASS |
| SEC05 | 搜索 App 私有数据库/偏好、备份/恢复产物、测试日志与临时导入文件。 | 没有秘密明文；备份排除生效；实际验证范围写明，不能只检查代码配置。 | PASS |
| SEC06 | 加密私钥正确/错误口令，密文篡改，Keystore key 失效，删除后重读。 | 正确成功；其他失败关闭；无明文降级、无伪恢复、无可解密残留。 | PASS |
| SEC07 | 设备锁定/应用锁定、身份 lease 到期、进程重启时尝试新认证。 | 按策略需解锁；不为后台恢复永久缓存秘密；已建立连接策略有明确 UI。 | PASS |
| SEC08 | 远端输出 OSC 52、恶意 OSC 标题/目录/URL、控制字符、超长序列。 | 不读/静默写剪贴板，不执行本地操作，不自动打开恶意 scheme；内存有界。 | PASS |
| SEC09 | 对终端适配层注入伪造sessionId、失效generation、重复view绑定、超长控制序列及恶意native effect回调。 | 终端没有secret或dial权限；不越权读写文件/剪贴板；旧代次不发送；FFI对象不会释放后使用。 | PASS |
| SEC10 | 粘贴多行、控制字符与引号到不同目标模式；随后切标签/断网。 | 先预览风险，目标绑定正确；默认不追加 Enter；不宣称 bracketed paste 对所有程序阻止执行。 | PASS |
| SEC11 | tmux 名称、路径和配置含分号、引号、换行、Tab、格式表达式及超长输出。 | 无 shell/tmux 注入；解析有界；查询不会意外创建目标或运行命令。 | PASS |
| SEC12 | 导出诊断、触发认证失败与崩溃；检查日志/通知/Intent/截图模板。 | 无代理密码、私钥、按键和完整终端原文；导出前可预览；没有自动上传。 | NOT_RUN |
| SEC13 | 在密码、私钥、代理口令页面截屏、录屏、看最近任务；在这些框里用输入法打字；回到终端页截屏。 | 敏感页面截不到，终端页能截；密码框不进输入法个人词库；终端输入行为不变。 | NOT_RUN |
| TER01 | 将同一 UTF-8/CJK/ANSI 数据按不同字节边界随机分包给内核。 | 结果与完整输入一致；不存在按包转 String 的替换符/字符损坏。 | PASS |
| TER02 | 中文输入法拼音候选、撤销 composing、混排、删除、语音输入到普通编辑区。 | 只有确定提交进入终端，中文不重复不丢失；不得自动申请 App 麦克风权限。 | PASS |
| TER03 | 测试 alternate screen、光标定位、清屏、样式切换及退出全屏。 | 主/备用缓冲状态正确；退出后内容/光标正常，没有覆盖旧屏错误。 | PASS |
| TER04 | 软键盘、硬件键盘各测 Ctrl-C/Ctrl-D/Alt/Esc/Tab/方向键及修饰键复位。 | 一次物理操作生成一次正确输入；切标签或后台无粘滞 Ctrl/Alt。 | PASS |
| TER05 | 中文候选栏、软键盘显示隐藏、横竖屏、分屏、大字体、硬件键盘。 | 光标不被遮挡，触控可达，布局/焦点保持；不将输入送往错误标签。 | PASS |
| TER06 | 快速尺寸变更，记录 SSH window-change；恢复后使用全屏程序。 | 没有 0 行/0 列、过期尺寸和 resize 风暴；最终尺寸与真实可见区域一致。 | PASS |
| TER07 | 普通 shell、大量历史、全屏鼠标模式、tmux copy-mode 下分别滚动。 | 手势语义正确，选择不会误发按键；历史只按既定上限裁剪。 | PASS |
| TER08 | 选择跨 CJK/emoji/组合字符的文本，复制并点击与拖动链接。 | 复制内容正确；拖动不打开链接；不把相邻无关内容静默合并。 | PASS |
| TER09 | 多行编辑默认粘贴、显式发送回车、bracketed paste 开/关、网络中断。 | 行为符合文案；不自动重发，不因编辑 Enter 直接运行远端命令。 | PASS |
| TER10 | 输入大于高水位的流式数据，故意让渲染消费变慢。 | 背压或明确终止；不能任意丢 VT 字节继续假正常，不发生无界队列。 | PASS |
| TER11 | 固定 VT 工作负载、多个标签、100 次创建/销毁，测完整进程树资源。 | 无 crash/ANR、持续泄漏或无法回收；达到已冻结性能预算，未达需解释/修复。 | PASS |
| TER12 | 强制候选引擎初始化失败、模拟回退或下次启动安全模式。 | requested/effective/failureReason真实；不热换不兼容状态；仅旧引擎可用不能宣布Ghostty替换完成。 | PASS |
| TER13 | 用户授权后运行实际远端 Claude Code/Codex 或其当前使用 CLI，记录版本与环境。 | 可操作提示/选择/中断/流式输出；说明已测版本与消耗，未授权则 NOT_RUN。 | BLOCKED |
| TMX01 | 测试有/无 tmux、不同实际版本、非默认 socket、异常输出和超时。 | 能力结果准确；普通 SSH 可用；无自动安装和查询副作用。 | PASS |
| TMX02 | 列表有同名显示、恶意名称、空列表、大量会话以及 server 不存在。 | 以稳定 ID 和真实作用域解析，输出限制生效；不意外启动 server。 | PASS |
| TMX03 | 从两个客户端附着既有目标，再显式创建一个新目标。 | 不会踢掉其他客户端；新建需明确动作；不自动执行 agent。 | PASS |
| TMX04 | 断线后目标被删除；重连前另建同名目标。 | 显示旧目标缺失，不按同名静默附着或重建。 | PASS |
| TMX05 | 重启 tmux server、重复 ID、切 Unix 用户/主机/socket 后恢复。 | 不把重用 ID 当同一任务；身份不足时请用户选择。 | PASS |
| TMX06 | 多个本地标签与外部客户端共用 tmux，分别切窗口/缩放/分屏。 | 只控制明确绑定的 client/pane；不靠最近客户端猜测。 | PASS |
| TMX07 | 自定义 prefix、mouse 关闭、copy-mode；执行手机快捷操作。 | 尊重已知配置，修改作用域明确；不修改 tmux.conf 或全局配置。 | PASS |
| TMX08 | 关闭标签、断开 SSH、tmux detach、停止整个 App。 | 不发送 kill-session/Ctrl-C；界面不承诺无 tmux shell 中的进程存活。 | PASS |
| LIFE01 | 按目标 API 检查实际 FGS 类型/权限、前后台启动与通知限制。 | 用户触发且类型合法；禁止伪报媒体/短信；发布审核状态真实。 | PASS |
| LIFE02 | 通知停止、系统停止服务、App force-stop，再触发网络事件。 | 不复活、不重新认证、不重放；用户重新打开后才提供恢复入口。 | PASS |
| LIFE03 | 活动连接下 Wi-Fi↔蜂窝切换 20 次；包含存活和真正断开两种流。 | 不因通知无条件断开；失效流按策略恢复；不直连、不无限重试。 | PASS |
| LIFE04 | 锁屏、进入省电、TailSocks 被停止/重启、远端 SSH 重启。 | 区分代理/SSH/目标缺失；恢复验证身份；tmux 恢复不重放。 | PASS |
| LIFE05 | Activity 重建与进程死亡后恢复标签，同时让旧回调迟到。 | 状态不假 Active；仅恢复配置/目标；旧 generation 不能覆盖新状态。 | PASS |
| LIFE06 | 100 次连接/取消/断开/引擎销毁，检查 fd、线程、协程和 native 内存。 | 无逐轮增长；每次 close 幂等，失败路径同样释放。 | FAIL |
| LIFE07 | 真实设备 30 分钟前台 + 30 分钟锁屏，记录环境；关闭省电豁免与启用时分别记录。 | 状态真实、无重复操作；不能以需要豁免的结果宣称默认配置无限保活。 | PASS |
| UX01 | 首次新建主机/代理/身份、修改引用、密码失败、缺少配置。 | SSH 目标与代理端口/凭据清晰；关键错误可纠正；没有空白失败页。 | PASS |
| UX02 | TalkBack、48dp 目标、对比度、横屏分屏、软硬键盘。 | 关键操作可识别/可达；不只用颜色传达危险或断线。 | NOT_RUN |
| UX03 | 粘贴/发送/取消、切换目标、关闭标签与断开 SSH。 | 文案与真实副作用一致；危险动作不是默认动作。 | PASS |
| UX04 | 从常见错误进入诊断与帮助，再查看实际引擎/代理路线。 | 信息对应真实阶段；支持清单无未实现功能；不能声称观察到了不可见外部链路。 | NOT_RUN |
| UX05 | 新建 SSH、Mosh、Telnet、RustDesk、UU、插件各一条；迁移挂着 RustDesk ID、UU 绑定及有效待回调的旧 SSH 主机；删除源 SSH 后杀进程，由回调冷启动并确认，再重启核验设备关联。 | 每种类型只出现它用得上的项；RustDesk/UU 不要求 SSH 字段；迁移不改变绑定 ID、pending 归属及截止时间，回调只消费一次且确认前不替换绑定；删除源 SSH 后显式目录关联保留；秘密不进保险库或明文存储；未知类型原样保留。 | PASS |
| UX06 | 在编辑器和批量导入里分别配直连、经代理、1–3 台跳板、代理加跳板；多台主机复用同一个代理；加一台自带代理或自带跳板的跳板机。 | 链的顺序和实际连接一致；代理改一处全部生效；跳板机自带路线给出明确选择、不隐式套用；两处入口结果相同。 | PASS |
| UX07 | 新建和编辑主机时弹出键盘、改了不保存就离开、填 Mosh 覆盖项、测试连接通过后再改路线。 分别选择普通 shell 与指定 tmux 会话，检查其与 SSH/Mosh 的独立说明。 | 操作栏始终点得到；没保存离开有确认；验证状态如实；覆盖项实际生效，没填时显示「自动」。 连接方式不冒充持久性，缺 tmux 时如实说明且不创建会话。 | PASS |
| UX08 | tmux 标签和普通标签分别在 SSH 与 Mosh 之间切换；代理主机、插件没装时打开菜单；设为默认；Mosh 标签断开后重新连接；服务器缺 mosh-server。 | tmux 会话不变、不重发输入；普通标签另开、不关原 shell；不可用项写原因；重新连接是新会话；只给安装命令，不代装。 | NOT_RUN |
| UX09 | 在两目录来源放入同名/同 IP 设备，覆盖控制面已连接、未连接、未知、缓存过期和未导入；切来源、刷新、移除来源，打开主机菜单。 | 来源隔离、状态带时间，与真实 SSH 状态分开；切来源不换活动会话的路线/身份，刷新不覆盖用户字段；未导入走导入，菜单只列可用动作。 | NOT_RUN |
| REL01 | 从干净环境按锁定依赖构建；审查所有新文件来源和最终 SBOM。 | 可重复构建，许可明确，无秘密、动态依赖或未授权复制。 | NOT_RUN |
| REL02 | 以实际Flutter release与Android缩减后的产物重跑SSH、Vault、flterm native初始化和输入。 | Dart AOT、native打包与平台service均正常；无调试接口、secret日志或被裁剪必要能力。 | NOT_RUN |
| REL03 | 实际 native 产物检查 ABI/16 KiB，最低 API 与目标稳定 API 设备测试。 | 只声明已测支持矩阵；若无 native 仍检查传递依赖，有依据才 N/A。 | PASS |
| REL04 | 将每项证据关联相同 commit/构建哈希/设备；核对文档与实际功能。 | NOT_RUN 不冒充 PASS；用户原 LobiShell 成功不计入本 App；生产账号/额度需授权。 | NOT_RUN |
| REL05 | 独立审查者复现关键负向测试并对照代码、日志和状态清单。 | 无未关闭硬门禁问题；风险接受不能豁免无直连/host key/无重放等核心合同。 | NOT_RUN |
| BAS01 | 固定fork SHA与lock后运行原项目测试、构建旧引擎APK。 | 建立可复现基线；上游失败如实分类，不虚增本fork通过数。 | PASS |
| BAS02 | 冷启动、deep link、后台恢复与设置打开时监测AI、同步和管理初始化。 | 未经用户开启的AI/同步/云上传网络请求为零；不执行管理命令。 | PASS |
| BAS03 | 在同机保留原App，安装fork并导入副本、升级schema。 | 不同applicationId/签名，不覆盖原数据；迁移可回滚，无未知字段暗丢。 | BLOCKED |
| BAS04 | 检查最终构建来源、GPL/Apache/第三方NOTICE与改动声明。 | 分发形态有明确许可结论；不把Conduit自身许可覆盖全部二进制。 | NOT_RUN |
| RTE01 | 导入同时包含target代理、跳板自身代理、旧hostChain的矛盾配置。 | 显示明确规范化路线或拒绝；不静默选一套或递归应用跳板route。 | PASS |
| RTE02 | 设代理host空、port<=0/>65535、profile缺失、未知代理type。 | dial计数零或只到合法代理；没有目标直连或HTTP类型默认猜测。 | PASS |
| RTE03 | 连接中修改host、身份、跳板顺序或proxy引用。 | 活动RoutePlan不可变；修改只影响新attempt。 | PASS |
| RTE04 | 从终端/SFTP/监控/转发/测试入口连接同一主机。 | 物理拨号与目标身份均遵循选定route；没有独立Direct旁路。 | PASS |
| RTE05 | 保留系统VPN选择Direct及SOCKS两种模式。 | Direct也遵守系统VPN；不使用protect或绑定底层非VPN网络。 | NOT_RUN |
| SOX01 | 外部SOCKS已运行；连续连接两个不同SSH目标后关闭本App。 | 两条独立CONNECT；不重新启动/停止外部隧道；不把一条已连流用于第二目标。 | PASS |
| SOX02 | SOCKS成功响应和SSH banner粘包，并随机切分协商。 | 完整余留字节交给SSH且仅一次；无丢包/重复读取。 | PASS |
| SOX03 | 代理接收TCP后无限慢速半包，在多个协商点取消。 | 总协商deadline有效；立即关闭正在握手socket，无迟到资源泄漏。 | PASS |
| SOX04 | 添加带密码的远程SOCKS，通过受信测试网抓取协商。 | UI明确原生SOCKS密码不加密；不把最终SSH加密误标为代理口令加密。 | PASS |
| JMP01 | 分别通过1、2、3跳建立最终SSH，关闭/重连，检查fixture。 | 逐跳forwarding与目标正确；不在跳板执行ssh命令或复制私钥。 | PASS |
| JMP02 | 分别替换每一跳及最终主机的host key，记录认证事件。 | 对应跳准确阻断，在该跳信任确认前不发送用户认证。 | PASS |
| JMP03 | 缺失跳板、非SSH、循环、超上限、重复目标、非法端点。 | 拨号前拒绝；没有最终目标Direct探测。 | PASS |
| JMP04 | SOCKS入口+跳板高级模式中拒绝第一跳、第二跳或最终转发。 | 标明失败阶段和hop；不忽略入口proxy，不旁路。 | PASS |
| TSC01 | 模拟OAuth与目录HTTP请求记录method、path、scope、redirect。 | 只用设备读取及token端点；请求devices:core:read；跨origin不转发secret。 | PASS |
| TSC02 | token过期、撤销、401、403、429以及无secret的短期导入模式。 | 受控刷新/暂停，不无限重试；保留缓存与主机，提示重新授权。 | PASS |
| TSC03 | 目录字段缺失、未知设备OS、缺IP、错误类型、超大JSON与设备名控制字符。 | 容错或有界拒绝；unknown不显示为online/SSH-ready；不崩溃或执行内容。 | PASS |
| TSC04 | 设备改名/换IP、同名不同id、旧id删除后同名重建。 | 按来源+id区分；用户route/username/trust不被覆盖；新主机不继承信任。 | PASS |
| TSC05 | 完整/不完整快照、模拟分页、网络中断与合法空目录。 | 仅按确认schema分页；不因错误或空列表删除主机；显示缓存时间与不完整。 | PASS |
| TSC06 | 目录可见但路由拒绝、端口关闭、设备离线/状态未知。 | 分别呈现目录/网络/SSH状态；导入不被标成连接成功。 | PASS |
| TSC07 | 相同100.x主机分别用普通OpenSSH和显式Tailscale SSH策略fixture。 | 不自动选择none；外部认证不提供key/password；源节点身份解释正确。 | PASS |
| TSC08 | 外部auth check批准、拒绝、超时、取消、未知或恶意URL。 | 先host trust，用户确认后外部浏览器；不自动访问，不以返回App当授权成功。 | PASS |
| TSC09 | 本地db、诊断、备份、同步、clipboard和错误对象搜索目录secret。 | secret只在受控存储/内存和官方请求；导出无secret；token不送SSH/代理。 | PASS |
| TSC10 | 两目录来源使用别名tailnet和同名主机、删除凭据再刷新。 | 来源隔离；未知canonical不误合并；删凭据不会误删手动编辑主机。 | PASS |
| GST01 | 锁定包/native hash构建，篡改缓存库、缺ABI制品，再用16KiB设备运行。 | hash错误阻断；不动态跳过校验；只声明实测ABI/页面大小。 | PASS |
| GST02 | 切标签/旋转/预览重复附着controller，销毁时触发迟到回调。 | 单view所有权，不double free/use-after-free，UI重建不新建SSH。 | PASS |
| GST03 | 输入终端查询、onOutput回调和快速resize，再注入重入尝试。 | 协议回应保序不循环；不重入write；代次关闭后不发送。 | PASS |
| GST04 | 多行paste、普通sendText、按键编码和OSC effect各自测试。 | 语义分离；不把paste清洗宣传为阻止执行；危险effect不默认允许。 | PASS |
| GST05 | 移除生产xterm2引用后构建，强制Ghostty初始化错误。 | 支持列表真实；无静默伪回退；完整READY必须使用已验Ghostty目标。 | PASS |
| REG01 | 终端正常时打开既有SFTP/转发/监控，然后关闭目标client。 | 借用者同代次失效，不重建Direct；释放顺序正确。 | NOT_RUN |
| REG02 | 配置有副作用计数的startup/managedAction；网络断开触发恢复与测试入口。 | 只有明确Fresh操作执行一次；Restore/Probe执行计数零。 | PASS |
| REG03 | 含假秘密的HostProfile.toString、异常、原有JSON导出、同步往返。 | 默认文本脱敏；secret不意外外流；受管字段和未知字段不被破坏。 | PASS |
| REG04 | 断线保存旧画面/草稿，再打开新shell或重附着tmux。 | 旧屏显示为历史；不重放旧VT产生协议回应，不重发草稿，状态不假Active。 | PASS |
| SUP01 | 清空依赖缓存，从记录的pin和asset hash重建debug/release。 | 源码、构建链和制品可追溯；main移动不会自动改变本fork依赖。 | NOT_RUN |
| SUP02 | 变更base_repository/引擎flag并检查所有状态、文档、manifest。 | 基座和实际引擎一致，跨基座结果不可复用为PASS；无旧任务误勾。 | NOT_RUN |

## 门禁

G0基线与关键风险；G1连接路线；G2目录及外部认证支持；G3 Ghostty实际替换；G4恢复与继承功能；G5完整候选。用户之前的LobiShell成功、参考repo的测试徽章、另一个commit的录屏都不能补齐本fork证据。

任何代理失败转直连、host key绕过、secret外泄、重连重复操作、核心中文/TUI错误、native释放错误、失效SFTP偷偷重拨，均阻断放行。Ghostty没完成可以报告部分可用的网络构建，但不能宣布本次全部需求完成。

## V3 插件、Mosh、远控和SDK用例

这些是本次新增验收设计，不是已经执行的测试。mock/Echo不能替代真实Mosh或外部App观测。

|ID|操作/故障|通过条件|结果|
|---|---|---|---|
|PLG01|同ID/大小写/保留ID/超长描述符与恶意schema。|冲突或非法输入拒绝，不遮蔽内置provider，不执行schema中的代码。|PASS|
|PLG02|安装API major不匹配、minor新增及缺失能力的provider。|握手先协商，未支持能力不可调用，版本错误不冒充成功。|PASS|
|PLG03|Android包可见性受限环境发现插件和外部App。|仅针对action/package查询，无QUERY_ALL_PACKAGES；安装不可见有具体诊断。|PASS|
|PLG04|同包名候选但不同签名、伪装官方pluginId以及伪造Intent extras。|对实际安装证书和组件核验，未授权不能获得会话或秘密。|PASS|
|PLG05|以未授权UID逐个调用所有AIDL敏感方法，包括拿到已有Binder后。|在真实事务逐次校验UID/证书/授权，不只验证onBind或调用者自报包名。|PASS|
|PLG06|跨UID/跨plugin复用session handle，发送旧generation回调。|所有者及代次绑定，不泄露数据、不关闭别人的会话。|PASS|
|PLG07|FD逐字节/随机分片/慢消费/超过高水位，混合resize与状态事件。|字节保序、流和控制分离、队列有界，不用大型Base64/Binder数据代替正确流。|PASS|
|PLG08|open/resize中取消、重复close、取消后迟到成功。|关闭幂等，无迟到复活，FD/native对象均有清理结果。|PASS|
|PLG09|强杀Mosh插件进程，同时另有SSH/SFTP活动。|仅相关插件会话中断，宿主存活，其他连接不被终止。|PASS|
|PLG10|宿主进程被杀，插件仍有native会话和打开FD。|death recipient/EOF策略清理，未执行命令不被重放；无法确认停止需如实记录。|PASS|
|PLG11|插件更新、卸载、替换签名后回到正在打开的页面。|缓存能力失效、重新核验；不自动重新授权或执行旧操作。|PASS|
|PLG12|运行中撤销授权，提供方拒绝close或继续发事件。|宿主停止新调用/释放秘密、关闭自有FD；其他provider不受影响，停止未确认不伪报成功。|PASS|
|PLG13|检查release APK及运行时网络/文件行为。|native随提供方APK打包；无下载Dart/Dex/.so到宿主执行，无sharedUserId。|PASS|
|PLG14|用测试秘密贯穿bootstrap、IPC、崩溃、导出、备份。|仅有本session临时材料进入Mosh；无SSH私钥/代理口令/Tailscale token整库授权或明文日志。|PASS|
|PLG15|安装独立作者签名插件，拒绝信任后再显式批准；切到release。|不要求共享签名私钥；未批准不可用，release不接受万能debug信任。|PASS|
|PLG16|前后台切换、关闭通知、系统停止、强制停止宿主和插件。|服务所有权与用户停止有效；无假媒体保活、无限自启或不断线承诺。|NOT_RUN|
|MOS01|安装真实Mosh运行时APK，将native输出接入flterm。|通过真实Mosh协议生成可操作画面，不以Echo provider冒充。|PASS|
|MOS02|首次/改变SSH主机指纹、认证失败、缺mosh-server。|用户认证前核验主机；失败不发临时key，不自动安装或sudo。|PASS|
|MOS03|隔离主机上Direct完成bootstrap与UDP会话，并记录两个阶段。|终端输入/resize有效；明确SSH和UDP不同数据路径。|PASS|
|MOS04|用户选择SOCKS、TailSocks、ProxyJump及组合路线后启动Mosh。|在bootstrap前拒绝unsupported，远端启动计数和绕路UDP拨号计数都为零。|PASS|
|MOS05|中文IME、硬件按键、旋转、随机分片VT穿过插件FD。|一次提交一次宿主写入，无双重编码，最终行列正确；不把协议内部行为说成exactly-once。|PASS|
|MOS06|活动UDP会话Wi-Fi/蜂窝切换、临时离线后回来。|存活runtime按协议恢复；宿主不重新bootstrap、不重放输入，失败状态真实。|NOT_RUN|
|MOS07|运行时初始化失败/退出/崩溃/用户关闭，再尝试恢复（Dart与native各按选定方案）。|无自动重启远端server/同名tmux或重发命令，资源清理且有重新连接入口。|NOT_RUN|
|MOS08|bootstrap恶意输出、超长内容、非法端口/注入、locale异常。|限界解析并失败关闭，临时key不入命令行日志/持久化，未支持locale明确报告。|PASS|
|UUR01|UU未安装、版本不足、合法scheme但错误签名、非Windows/macOS目标。|拒绝或明确引导，不能把Linux入口假称可用。|PASS|
|UUR02|绑定回调包含特殊字符ID、正确/错误nonce、重复参数和超长值。|严格一次解码与关联，用户确认后保存opaque引用；不解密/猜测内部ID。|PASS|
|UUR03|window_type=0全屏发起后没有任何回调，用户返回主App。|仅显示已交给UU，不等待承诺不存在的回调，不自动标Active/失败重试。|BLOCKED|
|UUR04|window_type=1分别回调success/failure、PiP不可用。|显示提供方报告状态，失败不自动切全屏后伪报成功，无持续在线假定。|BLOCKED|
|UUR05|用户确认提示延迟、timeout、superseded、取消和未知reason。|请求串行，结果未确认可终止本地等待；迟到事件不覆盖新请求、不自动再次远控。|BLOCKED|
|UUR06|伪造/重复/无pending/已过期callback、scheme劫持模拟。|nonce/state校验及固定回调路径有效；说明无法用scheme证明发送者，敏感绑定需用户确认。|PASS|
|UUR07|UU换账号或绑定失效，与同设备SSH/Tailscale/RustDesk并存。|只标UU引用失效并引导重绑，不删其他provider，不索取UU登录秘密。|BLOCKED|
|UUR08|设备的SSH要求SOCKS，同时点击UU远控且要求所有流量同路由。|明确provider-managed；无法保证同路由则拒绝/等待用户显式选择，不偷偷把SSH路由当已套用。|PASS|
|RDX01|RustDesk未安装、scheme被别的App注册、自建签名版本。|验证实际包/签名及明确用户信任，不交给任意匹配scheme的App。|PASS|
|RDX02|构造正常peer ID、含恶意scheme/路径/控制字符、带password/config修改的输入。|仅构造允许连接动作，不传密码，不调用敏感设置URI，不拼接任意外部参数。|PASS|
|RDX03|外部Activity成功启动、返回、取消但没有会话回调。|只显示已发起，绝不假称connected或远端已终止。|PASS|
|RDX04|要求使用SSH SOCKS/ProxyJump的严格远控路线。|external provider不冒充可接管网络，未支持则拒绝；独立策略由用户明确选择。|PASS|
|RDX05|目标ID失效、自建relay未配置、外部App升级改变协议。|不自动切服务器/身份/协议，记录安装版本和支持矩阵，普通SSH不受影响。|PASS|
|SDK01|新作者只根据SDK/契约/示例构建独立签名测试APK。|无需私有宿主源码或宿主签名私钥；能走授权、协商、流与关闭流程。|PASS|
|SDK02|核查SDK、native插件、fork及分发来源/许可材料。|接口与实现许可区分，保留原版权；不声称独立APK自动规避GPL/AGPL。|PASS|
|SDK03|验证schema示例与缺字段/任意exec/任意Intent恶意描述符。|结构验证有负例，运行期仍做独立签名和权限校验；计划schema测试不算App测试。|PASS|
|SDK04|打开插件声明的复杂设置页，再禁用/卸载该插件。|用户触发且目标显式，设置所有权清楚；无下载UI代码或强制宿主管理所有设置。|PASS|
|DEV01|多个provider返回相同名称或IP但不同ID，用户显式关联两个引用。|只有用户关联形成DeviceRecord；provider身份、认证、网络策略互不复制。|PASS|
|DEV02|移除一个目录来源或插件，设备还有SSH/UU/RustDesk引用。|仅断开选定关联，不级联删除其他凭据/会话；缺provider的配置可保留修复。|PASS|

完整READY额外要求GX0–GX3；可以报告CORE_READY但不得省略插件缺口。所有观察必须对应主App与各插件的实际构建和签名。

## 2026-10-11 参考应用衍生验收

以下是本项目新要求，尚未执行；参考应用的宣称不算 PASS。R51–R54 的 P6 专用用例在范围启用时另增，不作为当前主线已支持能力。

| ID | 操作 | 通过条件 | 结果 |
|---|---|---|---|
| UX10 | 同一主机经 Direct/SOCKS/Jump 连接，构造失败、取消、重连与无采样；检查本地诊断、导出脱敏、清除、数量/时间上限和秘密诱饵。 | 阶段/失败跳与真实事件一致，握手耗时不称 ping，未知不造值；无额外拨号/轮询/上传，事件无输入输出和凭据，清除及保留上限有效。 | NOT_RUN |
| UX11 | 选择普通 shell / 已有 tmux 目标，断线恢复、SSH/Mosh 切换、同名重建、换 tmux server/socket，检查旧画面与关标签行为。 | 主机/远端目标/恢复阶段清楚；按完整目标识别，同名不自动附着；历史不称存活，不重喂旧 VT、不重发输入/startup、不暗建或杀远端会话。 | NOT_RUN |
| UX12 | 从主机文件入口在 Direct/SOCKS/Jump 下浏览、预览超限文件、上传/下载；中途取消、改变连接代次、断线及覆盖结果未知。 | 只借用同目标/代次的已验证 client；预览资源有界，取消与中断明确；不另起 Direct，不自动覆盖/重传，不自动上传剪贴板内容。 | NOT_RUN |

## AI CLI 发现、启动与继续会话（R55–R57）

全部为 P4 主线验收，进入 G4 和 R30 同候选回归。fixture 与真实工具证据分开；AIC01/AIC02 于 2026-10-12 完成本机隔离验证，结果和设备/账号限制见 [R55 证据](../evidence/R55.md)。R56/R57 的受控实现和部分测试见 [启动证据](../evidence/R56.md)、[继续证据](../evidence/R57.md)；AIC03/04/05/07/08 已按本机隔离 + Android 模拟器范围通过，设备和实现限制见 [故障矩阵证据](../evidence/R56-R57-fault-matrix.md)。模块整理后的同候选真实 SSH 与模拟器回归见 [后续证据](../evidence/R56-R57-modularity-regression.md)。AIC06 仅参数派发/失效 ID 不降级的适配边界通过，真实原生对话仍 NOT_RUN。AIC09 需要对应账号/额度授权，不能用 R20/TER13 的未登录 UI 测试替代。

| ID | 操作 | 通过条件 | 结果 |
|---|---|---|---|
| AIC01 | 选定主机检测 claude/codex/gemini/opencode：PATH 与常见安装路径、非交互 PATH 差异、alias/function、多个安装、用户补充路径和未知工具。 | 结果绑定当前用户/主机与扫描范围，列出路径和可确认版本；缺失称此范围未发现，未知版本不猜能力；保留手动工具入口，不声称遍历所有容器/用户/未来工具。 | PASS |
| AIC02 | 经 Direct/SOCKS/Jump 探测；构造未知指纹、取消、超时、超限输出、恶意路径、包装脚本和失效 generation；监测命令、拨号及写入计数。 | 只用已验证目标 client 和冻结 RoutePlan，失败无 Direct；独立只读通道且有界，不向活动终端送字，不 source rc、不登录/安装/升级/读凭据/调用模型，未知副作用探测跳过。 | PASS |
| AIC03 | 在含空格、中文、引号、换行/控制字符及命令替换字符的路径/参数下启动，测试目录缺失、权限不足、工具变更及当前标签处于 AI/vim。 | 工具、目录和参数按受支持远端 shell 规则分离与转义，非法值拒绝；目录失败不回退到 home；仅用户选定新终端或专属 tmux 启动，不向其他活动程序注入 cd/命令，不降低 CLI 权限策略。 | PASS |
| AIC04 | 双击新建；在 tmux 创建、工具启动、结果确认各边界断网/取消/超时，再恢复网络；记录请求 ID、generation 与远端进程计数。 | 同一动作不重复启动，旧回调无效；发送后结果不明显示未知且先核查请求归属，不自动重发、新建或杀 tmux，不重放提示词；不能把客户端请求 ID 当远端 exactly-once 证明。 | PASS |
| AIC05 | 分别从活标签、断开 SSH、同名 tmux 重建、server/socket 更换、多窗口/窗格、窗格内程序已退出返回；同时设置不同主机/用户/项目/worktree。 | 活标签先核对工作项/连接代次/运行关联再聚焦，tmux 核验完整身份加 window/pane 与运行关联后返回；终端存活不等于原 AI 存活，只能确认终端时标未知，CLI 已退出则转显式原生继续；模糊目标要求重选，不新建、不抢其他窗格、不发送输入；失败不覆盖最后成功记录。 | PASS |
| AIC06 | 原进程退出后，以固定版本 Claude/Codex 的已绑定原生 ID 继续；另造同目录更新对话、另一 worktree、失效/缺失 ID、配置身份更换与不支持版本。 | 回到原工具/用户/目录和同一对话，指定 ID 失效不改用 --last/--continue 或新建；无可靠 ID 提供历史选择器。Gemini/OpenCode/自定义仅声明实测模式，列表提示词不留存。 | NOT_RUN |
| AIC07 | 后台、断网、锁屏、杀 App 后冷启动；迁移旧恢复记录，切换身份/删除主机/清除最近记录；检查加密存储、通知、日志、导出和备份。 | 进程冷启动只恢复卡片，点击继续才按策略验证/附着或原生继续；存活进程内运输层恢复仍按 R22/R23 且不重跑 CLI。遵守解锁和凭据租期，缓存标待检查；旧记录缺字段可修复，秘密/对话/草稿不落库或外泄，清除入口不杀远端任务。 | PASS |
| AIC08 | 输入模拟 AI 状态标题：合法、伪造、残缺、超长、版本不匹配；等待状态过期、断线、切标签及后台没有新事件。 | 状态带来源与新鲜度，仅作提示；未知/过期不称完成或仍运行，不自动批准、执行、切目录或选择恢复 ID；迟到事件不污染别的工作项。 | PASS |
| AIC09 | 在授权的测试主机上冻结 CLI/OS/tmux/候选版本，实跑 Claude/Codex 新建、留在 tmux 后返回、进程结束后按 ID 继续同段测试对话；其他工具逐模式登记。 | 记录同一主机/项目/对话身份和真实结果，受控对话可继续且不重复发送；欢迎页或 fixture 不能替代登录后的证据。未授权账号/额度或缺环境时对应模式保持未测，不宣称完整支持。 | NOT_RUN |
