# plugin_api

插件契约 v1 的类型和判定规则（X00）。只有纯 Dart 逻辑，没有 IPC、没有 Android 代码。

```bash
source /Users/fodelf/xdw/xwshun/.toolchain/env.sh
cd packages/plugin_api && dart pub get && dart test
```

规则说明见 `plan/v3/docs/15-plugin-architecture.md` §9，这里不重复。

测试会读 `plan/v3/contracts/examples/` 下的描述符文件，所以要在本目录下运行（相对路径 `../../plan/v3/...`）。
在别的目录跑会报 `PathNotFoundException`，看着像测试坏了，其实是工作目录不对。

**这些测试证明的是"规则写对了"**，不证明任何插件 APK、Binder 事务或外部 App 的真实行为——那些在 X01–X10 用设备验证。
