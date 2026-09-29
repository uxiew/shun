# 12 上游维护、许可与范围控制

## 高效二开的方式

保留upstream remote及可追踪提交，自己的origin只在用户确定新仓库后设置。不自动push或创建公开仓库。先固定绿色基线，然后网络硬化、目录、终端、平台分别小提交；不同时全局格式化/重命名/升级依赖，让后续cherry-pick与rebase成本可控。

上游bug修复尽量独立补丁：无效代理、协商取消、增量UTF-8、重连startup等，与本产品Tailscale目录/引擎偏好分开。提交公共PR须有用户授权，临时密钥与个人设备截图不随补丁发出。

## 许可门禁

Netcatty是GPL-3.0-or-later；Conduit自身Apache-2.0，但本地shell附属组件另有许可；elias8项目声明MIT仍需核对native/字体/传递依赖。GPL的个人修改与向他人提供产物的义务不同；不能以不开源仓库就认为所有后续分发都可闭源。正式分发前核对对应源码、修改声明、NOTICE及具体商店条件，本规划不替代必要的专业许可审查。[S02](13-sources.md#s02) [S10](13-sources.md#s10) [S16](13-sources.md#s16) [S34](13-sources.md#s34)

不要复制LobiShell闭源UI资源或商标。三张用户照片用于交互理解，本包不将其打包成App资源。替换icon/app name/applicationId不删除版权归属。

## 不扩大范围

不因为基座带AI assistant就增加模型API；不因为Flutter就同期发所有平台；不因为有Mosh就重造UDP代理；不因为Tailscale有API就加全网管理/ACL编辑。清理冗余可以做，但先界定删除哪些产品入口、后台初始化和授权数据，不能破坏已选主线路由、SFTP或主机配置。

## 更新规则

依赖升级按安全/缺陷需要，不批量追最新。每次涉及dartssh2、flterm或native制品变更，重跑路由负向、每跳host key、TUI/IME、资源释放和release构建矩阵。上游README“测试通过”不是本fork的证据；测试数只作为仓库自述，不作为选型排名。

## V3多仓库来源

维护主App fork、薄插件SDK、Mosh运行时及以后RustDesk插件的来源/版本/许可台账。能向上游提交的代理、UTF8及生命周期修复保持小补丁；不要靠长期vendor整份项目解决局部接口问题。每次升级重跑route、API/signature、native及回调兼容；外部App升级也要更新实际支持矩阵。
