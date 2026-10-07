# 18 插件作者SDK与实施交接

## 最小作者交付

一个可独立编译的示例Android provider APK、一份薄AIDL契约和Dart adapter说明、manifest描述符schema、错误/状态语义、兼容和签名测试。SDK只含本产品新写的接口与样例；不得把GPL/AGPL实现代码复制进标注宽松许可的SDK。正式SDK许可由所有者确认；建议与具体运行时许可证分离管理。

## 作者需要遵守的语义

`TerminalSessionProvider`拥有本次终端session，接口为typed open/resize/close；输入输出走FD。`DeviceCatalogProvider`只返回来源明确的设备；`RemoteDesktopProvider`明确是external launch或embedded surface。不得创建一个带任意shell/文件/Intent能力的万能plugin API。

描述符使用`contracts/plugin-manifest.schema.json`；示例值均是占位，不是已签名包。SDK兼容矩阵记录host API major/minor、插件版本、Android API/ABI及实际签名来源。不可用能力返回unsupported，不能伪装为空列表/成功或绕过指定route。

签名流程：插件验证真实宿主caller UID及证书，宿主验证安装包证书与用户授权；独立作者无需共享宿主签名私钥。发行签名变化需要明确更新信任，不可把debug包签名自动用于正式发行。每次session使用不透明owner handle和generation，避免被别的caller/旧实例接管。

## 合规与分发

APK通过用户明确安装，Play渠道用其受支持分发路径；侧载渠道独立给源码、hash、证书和更新说明，不自动下载安装、不申请无关安装权限。native必须随提供方APK打包，不能下载运行代码到宿主；不能照用低targetSdk或假FGS规避平台要求。[S49](13-sources.md#s49) [S50](13-sources.md#s50) [S54](13-sources.md#s54)

## 必需样例与测试

- Echo provider仅在debug fixture包，用于字节分片/resize/取消/崩溃测试；产品不把它当Mosh实现。
- 最小真实Mosh provider验证完整bootstrap、UDP、VT输出和生命周期。
- 同pluginId但不同证书的伪装包，API major不符包，拒绝关闭包和低速流包。
- 未授权caller不得读取描述符以外敏感数据，更不得获得session；每个敏感方法独立授权。
- provider被杀、更新、卸载、宿主被杀时资源有界，秘密不进入日志/备份，撤销不伤害其他SSH会话。

## 调试方法

按pluginId/sessionId/generation关联双方脱敏事件，不记录原始Mosh key、SSH凭据、UU ID或完整屏幕。终端材料用合成VT fixture；每个bug保留输入分片/状态序列和版本，不用生产终端记录做自动回归。

Android实机需记录主App与插件APK SHA-256、signer SHA-256、API/ABI/页面大小、FGS行为与外部App版本。没有真机就标NOT_RUN，Echo成功不等于Mosh成功，UU Intent启动成功不等于远控成功。

## 首批插件模型提示词

```text
读取AGENTS、docs/15、docs/16、docs/17、docs/18和tasks.json。
执行X00–X03中依赖满足的部分，先做最小registry与独立测试APK/IPC；
不要实现插件商城、Dart热加载、外部native下载或任意exec。
主App沿用Flutter/Netcatty，Kotlin限Android桥和服务，不迁回Compose/SSHJ。
逐次Binder事务校验UID+签名+owner+generation；流走FD，有背压、取消、death。
记录哪些是mock、哪些是APK真实运行；不领取缺授权的生产连接。
同步任务、测试和证据，提交可回滚小变更。
```

## 已落地的接口（X02–X04 实现，X12 写成作者文档）

契约代码只有一份：`plugins/provider-sdk/`（纯 Java + AIDL，可直接作为 Android 库引用）。X02（发现与双向认人）、X03（会话字节流）、
X04（设置页与更新）落地的接口细节，现在统一写在给插件作者的文档里，这里不再重复，免得两处对不上：

- 从零做插件、装上、批准、验证：`docs/plugin-authors/README.md`
- 清单、描述符字段、AIDL 方法、字节流与状态、上限与背压、报错映射：`docs/plugin-authors/contract.md`
- 版本协商、更新时宿主怎么判、签名、Android 范围、测过什么：`docs/plugin-authors/compatibility.md`
- 许可：`docs/plugin-authors/licensing.md`
- 样例：`plugins/example`；测试插件的用法：`plugins/README.md`
