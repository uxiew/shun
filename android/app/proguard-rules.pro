# yubikit 3.1.0 的几个类带 SpotBugs 注解，那个包只在它编译时用、运行时没有。
# 不写这条 release 构建直接失败：Missing class edu.umd.cs.findbugs.annotations.SuppressFBWarnings。
-dontwarn edu.umd.cs.findbugs.annotations.SuppressFBWarnings
