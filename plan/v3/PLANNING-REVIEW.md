# 规划层自检（不是独立App审计）

本轮读取上一版总册；保留网络/终端/安全测试，覆盖旧技术栈与后续门禁。新插件需求已进入核心依赖，R30无法跳过X13。数量来自结构化JSON而非手填已完成。

核对重点：Netcatty是Flutter xterm2不是WebView；Mosh README与Manifest不同；UU raw与旧搜索缓存全屏回调不同；目录凭据不入网；SOCKS复用服务不复用同一目标SSH连接；Mosh需要独立UDP；外部远控不承诺继承SSH route；独立APK不自动豁免GPL/AGPL；SDK和运行时分开。

自动结构检查与schema正/负例记录在PLAN-CHECK.json。该结果不构建应用、不运行网络、不安装APK，不证明插件安全。所有142项App验收仍NOT_RUN，独立审查仍需真实执行者。

补充核对：Conduit的Mosh为dart_mosh，不应误写native。X08增加Dart/native运行时选择及互操作要求；插件独立安装契约不变。源码与声明未替代Android实测。
