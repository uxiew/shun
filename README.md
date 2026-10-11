# shun

Android 上的 SSH 终端 + SFTP + 服务器管理。GPL-3.0-or-later。

开发中，还没有安装包。进度看 [plan/v3/STATUS.md](plan/v3/STATUS.md)。

## 常用命令

```bash
source ../.toolchain/env.sh               # 每个新终端先执行；漏了 flutter test 会全卡在 loading
flutter pub get
flutter analyze && dart format --set-exit-if-changed lib test integration_test
flutter test -j 4                         # 没起 Docker 测试环境时，真实 SSH 用例自动跳过
tool/fixture-environment/up.sh            # 起真实 SSH/代理/跳板环境，用完 down.sh
flutter run -d <设备ID>                    # 设备 ID 用 flutter devices 查
tool/build-release.sh                     # 发布用的包：终端原生库从核对过的源码重编，只打 arm64
```

手机接在另一台电脑上：`tool/remote-device/`。模拟器、装真机、清磁盘：[docs/shun/README.md](docs/shun/README.md)。

## 文档

| 想做什么 | 看这里 |
|---|---|
| 用 App | [docs/user/README.md](docs/user/README.md) |
| 在本机跑、测、装、清理；仓库里各目录是什么 | [docs/shun/README.md](docs/shun/README.md) |
| 接着开发：规矩 → 进度 → 任务 | [AGENTS.md](AGENTS.md) → [plan/v3/STATUS.md](plan/v3/STATUS.md) → `plan/v3/tasks.json` |
| 自己维护的依赖（libghostty / flterm） | [third_party/README.md](third_party/README.md) |
| 写插件 | [docs/plugin-authors/README.md](docs/plugin-authors/README.md) |
| 测试插件、Mosh 插件怎么编 | [plugins/README.md](plugins/README.md) |
| 原项目留下的开发文档 | [docs/README.md](docs/README.md) |
| 换 App 图标 | `tool/brand/render_icons.py` 开头 |

## 规矩

- 所有者说推之前不 push、不发布。remote 只有 `origin` = `uxiew/shun`。
- applicationId 是 `top.xdwa.shun`，别改：换了值手机就当成另一个 App，装上后旧 App 的数据不会跟过来。为什么不能用上游的值见 [AGENTS.md](AGENTS.md)。
- 没测就写没测：没有真机或授权的用例记 NOT_RUN / BLOCKED，模拟器结果标明是模拟器。

## 致谢

shun 是在 [Netcatty Mobile](https://github.com/kmh1145/Netcatty-mobile)（作者 kmh1145）v1.4.7 的基础上改出来的，
云同步的格式和桌面版 [Netcatty](https://github.com/binaricat/Netcatty) 保持兼容。谢谢两个项目把代码以 GPL 开源，
没有它们就没有这个 App。原作者的版权和修改声明见 [NOTICE.md](NOTICE.md)。
