# 14 插件社区研判与接入边界

## 结论

使用轻量能力接口统一产品入口，但不强求统一执行方式。借鉴LobiShell的独立协议APK、OpenPGP的跨进程接口和Termux的授权经验；不整体照搬任一项目。用户所说的“moshi”按移动终端协议Mosh规划，不是Moshi JSON库。

| 参考 | 核查到的事实 | 本方案吸收 / 不照搬 |
|---|---|---|
| LobiShell Mosh插件 | README说bound service，当前Manifest却声明MoshBinaryProvider，代码为二进制交付路径 | 借鉴可选安装；不能照README假设已有可直接兼容的会话AIDL [S36–S38] |
| LobiShell RustDesk插件 | 独立APK，AIDL会话服务，接口含Surface；声明AGPL | 可借鉴会话/画面分离，未来有选择地复用；先审协议、签名、全局状态和许可 [S39–S41] |
| OpenPGP API | 应用绑定外部提供方，FD传数据，返回成功/错误/需交互 | 借鉴小SDK、流与控制分离；不引入PGP功能 [S46] |
| Termux:API | 独立附加App，同签名是其授权前提 | 借鉴安装/兼容管理；不把same-signature和任意第三方同时承诺 [S47] |
| Flutter deferred components | Android模块仍一起构建为完整AAB并上传 | 是分发优化，不是第三方运行期插件市场 [S48] |
| UU官方协议 | 设备绑定/远控跨App调用，不是嵌入SDK | 实现薄适配器即可，无须给它再造一层APK [S42–S43] |

来源：[S36](13-sources.md#s36) [S37](13-sources.md#s37) [S38](13-sources.md#s38) [S39](13-sources.md#s39) [S40](13-sources.md#s40) [S41](13-sources.md#s41) [S46](13-sources.md#s46) [S47](13-sources.md#s47) [S48](13-sources.md#s48)。这里只是静态研究，不代表这些App经过本轮实测。

## 不能照抄的结论

LobiShell README对闭源宿主/独立GPL或AGPL插件的许可解释，是作者的设计说明，不是本产品的法律结论。进程分离、AIDL或独立安装本身，不自动证明两个程序不构成组合。接口耦合、分发与改动需要单独审查。Netcatty本身的GPL条件同样不会因为插件化消失。[S56](13-sources.md#s56)

RustDesk插件实际读取路径以Binder UID映射包名决定允许调用；本设计额外固定证书/授权关系和session所有者。并非声称现有插件已被利用，而是不把名称白名单等同于完整的签名信任。[S41](13-sources.md#s41)

## 不采用运行期任意Dart/Dex/.so热装

普通Flutter pub插件是构建期依赖；deferred components需整体AAB。外部代码载入宿主进程仍共享宿主权限。远程可执行代码分发还涉及Play政策，签名和哈希不能代替这些限制。因此native功能用随APK打包的运行时及跨应用接口，主App不下载后执行插件二进制。[S48](13-sources.md#s48) [S49](13-sources.md#s49) [S50](13-sources.md#s50)

## 研究置信度

已读公开README、Manifest和上述关键源码；没有检查完整提交树或构建插件。UU搜索缓存曾返回“全屏也回调”的旧说明，本轮raw是“全屏不回调”；以后以冻结的官方协议及实测版本为准，不混用两版。所有package/certificate/SDK方法需实施时复核。

## 额外复用机会：Conduit的dart_mosh

Conduit不是依靠原生Mosh客户端完成全部Mosh路径：其当前依赖为dart_mosh。X08必须记录Dart组件与官方native运行时的比较，优先验证可少写代码的路径，不把独立APK等同于必须C++。部署与协议实现分开，仍不在运行时向宿主装入Dart代码。[S59](13-sources.md#s59) [S60](13-sources.md#s60)
