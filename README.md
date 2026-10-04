# xwshun

Android 上的 SSH 终端 + SFTP，基于 [Netcatty Mobile](https://github.com/kmh1145/Netcatty-mobile) v1.4.7（`495f5d31`）改造。GPL-3.0-or-later。

开发中，还没有安装包。进度看 [plan/v3/STATUS.md](plan/v3/STATUS.md)，和原版的区别看 [使用手册第 16 节](docs/user/README.md#16-和原版-netcatty-不一样的地方)。

## 常用命令

```bash
source ../.toolchain/env.sh               # 每个新终端先执行；漏了 flutter test 会全卡在 loading
flutter pub get
flutter analyze && dart format --set-exit-if-changed lib test integration_test
flutter test -j 4                         # 没起 Docker 测试环境时，真实 SSH 用例自动跳过
tool/fixture-environment/up.sh            # 起真实 SSH/代理/跳板环境，用完 down.sh
flutter run -d <设备ID>                    # 设备 ID 用 flutter devices 查
flutter build apk --release --target-platform android-arm64
```

手机接在另一台电脑上：`tool/remote-device/`。模拟器、装真机、清磁盘：[docs/xwshun/README.md](docs/xwshun/README.md)。

## 文档

| 想做什么 | 看这里 |
|---|---|
| 用 App | [docs/user/README.md](docs/user/README.md) |
| 在本机跑、测、装、清理；仓库里各目录是什么 | [docs/xwshun/README.md](docs/xwshun/README.md) |
| 接着开发：规矩 → 进度 → 任务 | [AGENTS.md](AGENTS.md) → [plan/v3/STATUS.md](plan/v3/STATUS.md) → `plan/v3/tasks.json` |
| 自己维护的依赖（libghostty / flterm） | [third_party/README.md](third_party/README.md) |
| 插件 | [plugins/README.md](plugins/README.md) |
| 上游原来的文档 | [docs/README.md](docs/README.md) |

## 规矩

- 所有者说推之前不 push、不发布。remote 只有 `origin` = `uxiew/xwshun`。
- applicationId 保持 `top.xdwa.xwshun`。改回 `app.netcatty.mobile` 会覆盖手机上的原版 Netcatty 和它的数据。
- 没测就写没测：没有真机或授权的用例记 NOT_RUN / BLOCKED，模拟器结果标明是模拟器。
