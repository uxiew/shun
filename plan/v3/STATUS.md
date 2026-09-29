# 当前状态 V3

日期：2026-09-29。计划修订完成，App未实施。

- 研究：上游README、Manifest、关键源码及官方协议静态阅读；不是完整源码审计/可重建checkout。
- 推荐：Netcatty-mobile fork；GPL条件需遵守，Conduit为明确替代。
- 主线：46项NOT_STARTED；后续：7项DEFERRED；共53项。
- App验收：142项全部NOT_RUN；G0–G5与GX0–GX3全部NOT_RUN。
- 文档与schema示例检查：仅PLAN-CHECK.json的PLANNING_FILES_ONLY范围。
- 没有构建APK、安装插件、连接用户设备、修改现有repo、做Git提交或部署/发布。
- 目标repo/应用名称/applicationId/签名/实际SDK及设备授权未指定；原始来源HEAD尚未冻结。

## 下一批

R00–R04与X00；其后按tasks.json依赖推进。插件不是空接口后置：X01–X03最小独立测试APK，X08–X10真实Mosh；UU/RustDesk外部adapter在X06/X07。R38内嵌RustDesk不是本轮首版必须实现。

## 尚待真实确认

基座锁定SHA与原构建、用户Android/IME/VPN/TailSocks版本、授权SSH/UDP主机、UU>=4.42.0及Windows/macOS目标、RustDesk版本/服务器、主App及插件签名信任、native ABI/16KiB、FGS/分发审查。

只能将真执行结果写入evidence。用户LobiShell成功属于参考应用事实，不转移为新App通过；既有进度如后续出现先读真实repo，不以本包初始状态覆盖。
