# shun 的文档

这里只放 shun 自己写的文档。先按下表找到要看的那一份，别从头读。

| 你是谁 / 想干什么 | 看这份 |
|---|---|
| 用 App：加服务器、连接、终端、tmux、文件、同步…… | [user/README.md](user/README.md) |
| 用 Mosh：装插件、在服务器上装 mosh-server、切换、不用了怎么卸载清理 | [user/mosh.md](user/mosh.md) |
| 在本机搭环境、跑测试、开模拟器、装真机、清磁盘；仓库里各目录是什么 | [dev/README.md](dev/README.md) |
| 改代码前弄清楚：分层、一次连接的数据怎么走、改一处会牵连什么 | [dev/architecture.md](dev/architecture.md) |
| 动密码、私钥、同步、插件信任、远端执行这类代码前要知道的规矩；提交前检查 | [dev/security.md](dev/security.md) |
| R39 真机验收怎么做 | [dev/r39-device-acceptance.md](dev/r39-device-acceptance.md) |
| 写插件：契约、能力、兼容、签名、许可、排错 | [plugin-authors/README.md](plugin-authors/README.md) |
| 为什么这么定：基座选择、Mosh 运行时选择 | [decisions/](decisions/) |

不在 `docs/` 里的：项目规矩在 [../AGENTS.md](../AGENTS.md)，进度和任务在 [../plan/v3/STATUS.md](../plan/v3/STATUS.md)，
每个任务的验证记录在 `../plan/v3/evidence/`，代码来源和许可在 [../NOTICE.md](../NOTICE.md)。

## 改文档的规矩

- **一件事只写一处。** 别的文档要提到就链接过去。同一段说明抄两份，迟早一份改了另一份没改，读者不知道信哪个。
- 用户看得到的行为改了，在同一个提交里改使用手册；Mosh 的改 `user/mosh.md`，其余改 `user/README.md`。
- 验证过程、测了什么没测什么，写进 `plan/v3/evidence/`，不写进这里。
- 不写真实的账号、IP、Token、私钥、主机指纹、签名文件。示例用 `box.example.com`、`ops` 这类占位。
- Netcatty 的旧文档和截图 2026-10-17 已经删了，不要搬回来，也不要照着改写：那些写的是上游当时的代码和发布流程，
  和现在的 shun 对不上。要写就照现在的代码写。
