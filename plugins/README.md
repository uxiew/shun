# 插件契约与测试插件

- `provider-sdk/`：宿主与插件共用的 AIDL 契约和认人工具（`CallerVerifier`、`SignerDigests`）。宿主工程和这里的测试工程引用同一份。
- `fixture-echo/`、`fixture-rogue/`：X02 的测试 APK。**只用于测试**：echo 连上不代表 Mosh 或任何真实 provider 可用。

## 构建

```bash
source ../../.toolchain/env.sh
cp ../android/local.properties .      # 首次：告诉 Gradle SDK 在哪（被 .gitignore 忽略）
./build-fixtures.sh                   # 约 1 分钟，产物在 out/
```

首次运行会在仓库外 `../../.toolchain/plugin-keys/` 生成两把测试密钥（口令都是 `xwshun-fixture`）。
删掉这个目录再构建，证书就变了，手机上已批准的插件会被判为「换签」。

| 产物 | 包名 | 签名 | 用来测 |
|---|---|---|---|
| `echo-author.apk` | example.xwshun.fixture.echo | 独立作者密钥 | 批准后接入、双向鉴权（PLG15） |
| `echo-impostor.apk` | 同上 | 另一把密钥 | 同包名不同签名（PLG04）。要先卸载 author 版才装得上 |
| `echo-leaky.apk` | 同上 | 独立作者密钥 | 握手后把宿主回调 Binder 转交给 rogue（PLG05 宿主侧） |
| `echo-debugkey.apk` | example.xwshun.fixture.echo.debugkey | 本机 Android 调试证书 | release 宿主拒收调试证书（PLG15） |
| `rogue.apk` | example.xwshun.fixture.rogue | 另一把密钥 | 冒用 `builtin.ssh`、伪造 Intent extras 调插件、用转交来的 Binder 调宿主 |

插件只接受一张宿主证书：默认是本机 `~/.android/debug.keystore`（宿主 debug 包和没配正式签名的 release 包都用它）。
换台电脑构建的宿主证书不同，插件会拒绝它，报「签名证书不是信任的那张」。要指定别的宿主证书：`HOST_SHA256=<64位十六进制> ./build-fixtures.sh`。

## 负向探测

```bash
adb install -r out/rogue.apk
adb shell am start -n example.xwshun.fixture.rogue/.ProbeActivity      # 冒充宿主调 echo 的每个方法
adb logcat -d -s XwshunRogue XwshunEcho XwshunPlugins                   # 每个方法一行；出现 ACCEPTED 就是鉴权有洞
```

## 撞墙时

- **`defaultConfig contains custom resource values, but the feature is disabled`**：AGP 9 默认关了 resValue，模块里要 `buildFeatures { resValues = true }`。
- **构建 rogue 时报「缺 -PhostSha256」**：Gradle 会配置所有模块，echo 的脚本也会跑。用 `build-fixtures.sh`，它每次都传。
- **`keytool -printcert -jarfile` 什么都不打印**：APK 只有 v2 签名，keytool 读不了。用 `$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs <apk>`。
- **`adb install` 报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`**：同包名换了签名，系统不让覆盖。先 `adb uninstall example.xwshun.fixture.echo`。
