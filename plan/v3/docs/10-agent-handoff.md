# 10 V3模型交接

## 开始前

读取AGENTS、STATUS、docs/00/01/03/04/05/06/07/15/19及tasks.json。旧Txx是退役计划，V2草稿不再作为门禁。目标repo未指定时不写入历史powell/xdo等仓库；此包可放入指定新fork，已有AGENTS/README先合并不覆盖。

## 首批提示词

```text
按Flutter移动终端V3二开计划实施，本批只做R00–R04与X00。
默认以Netcatty-mobile为基座，保留作者版权/GPL；不接受其分发条件时先记录Conduit替代ADR，
不搬运GPL代码后改贴Apache。读取当前HEAD/dirty/lock，先跑原基座测试和构建。
建立SOCKS/SSH/VT/目录fixture；修代理失效转直连、按块UTF8解码、恢复startup重放等可复验风险。
验证elias8/libghostty + flterm的Android可行性与输入，不从零写Compose/SSHJ/WebView。
完成插件能力/签名/路由/会话分型契约。外置APK采用受控IPC，非动态下载Dart/.so。
本批不一次实现全部UI或插件，不操作生产VPN/主机/密钥/账号/模型额度，不自动push/发布。
有设备才记录真机证据；无设备完成独立测试并保留NOT_RUN/BLOCKED。
同步tasks、verification、STATUS和evidence，粒度commit，结束给出门禁与下一批依赖。
```

## 插件实施入口

第二批按依赖做X01–X03（registry、独立fixture APK、签名与FD），同步R05–R10路线。
X06 UU以本次raw协议为基准，先复核已安装版本：全屏不回调，小窗才可能回调；nonce不等于签名认证。
X07 RustDesk先外部启动，不传密码URL，不擅自复制native核心。
X08–X10 Mosh必须真实runtime；不支持SOCKS CONNECT/ProxyJump的UDP，启动前拒绝，不偷直连。

## 继续提示词

```text
读取V3 STATUS、tasks.json、实际git diff及上一批evidence，只领依赖满足的最小批次。
维持单一RoutePlan、每跳host key、无代理回退、无用户输入/startup重放；Ghostty原始字节与单view所有权。
插件逐事务核验UID+签名+授权+session代次，秘密最小授予；死亡/升级/撤销不伤及其他连接。
UU/RustDesk外部启动不代表连接成功，也不继承SSH代理；Mosh缺UDP路由明确拒绝。
运行本任务test_ids并记录真实结果，mock和reference App不替代设备证据。
完整V3要X00–X13，R30全量142用例；只通过核心不得标FULL_READY。
```

## 独立审查重点

读源码而非仅实施摘要，复现：无效SOCKS无直连、每跳指纹改变、旧startup不重放、跨包UTF8；再复现未授权Binder caller、换签插件、跨session handle、插件crash不影响SSH、撤销挂死、UU callback重放/全屏误判、RustDesk密码URI拒绝、Mosh proxy route在bootstrap前拒绝。核对同候选APK哈希、签名、依赖、FGS/native/16KiB与许可证来源。

每批只报完成ID与证据、具体阻塞、下一项依赖；不重复整套规划。项目名称、applicationId、分发、正式签名及公开发布仍须所有者确认。
