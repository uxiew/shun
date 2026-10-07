# plugin_api

插件契约 v1 的类型和判定规则（X00）。只有纯 Dart 逻辑，没有 IPC、没有 Android 代码。宿主 App 用它判定插件能不能用；
插件作者用它在构建前自查描述符（X12）。

许可：Apache-2.0（同目录 `LICENSE`）。宿主（GPL-3.0-or-later）把它作为依赖编进去，见根目录 `NOTICE.md`。

```bash
source /Users/fodelf/xdw/xwshun/.toolchain/env.sh
cd packages/plugin_api && dart pub get && dart test
```

## 给插件作者：构建前自查描述符

```bash
plugins/example/tools/check-descriptor.sh <你的 xwshun_plugin.json> --package <你的 applicationId> --service <服务类全名>
```

只要 Dart SDK（Flutter 自带的也行）。脚本临时生成一份包配置直接跑 `bin/check_descriptor.dart`，不在这个目录里 `pub get`、不写任何文件。
用 `new-plugin.sh` 起的工程里有一份自己的 `tools/check-descriptor.sh`（带着这个包的拷贝），离开仓库也能用。

通过退出 0，不通过退出 1。报出来的话和宿主「设置 → 插件（实验）」里显示的一致，因为是同一套判定代码。
它查不了证书和用户批准：那些要装到设备上才知道。可选的一步，不跑也能做插件，见 `docs/plugin-authors/README.md`。

## 规则和测试

规则说明见 `docs/plugin-authors/contract.md`，这里不重复。

测试会读 `plan/v3/contracts/examples/` 下的描述符文件和 `plugins/example` 的描述符，所以要在本目录下运行（相对路径 `../../...`）。
在别的目录跑会报 `PathNotFoundException`，看着像测试坏了，其实是工作目录不对。

**这些测试证明的是"规则写对了"**，不证明任何插件 APK、Binder 事务或外部 App 的真实行为——那些在 X01–X10 用设备验证。
