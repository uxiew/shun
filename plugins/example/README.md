# Hello 终端：shun 插件样例

给 shun（Android 上的终端 App）提供一个最小的终端会话的插件 App。它是**样例**：照着它做你自己的插件。
从零开始的完整步骤（装工具、生成密钥、取宿主证书、构建、安装、批准、验证、出错怎么查）在
[docs/plugin-authors/README.md](../../docs/plugin-authors/README.md)，这里只列文件。

起自己的插件用脚本，一步复制、改名、生成密钥、填宿主证书、自查、构建（不改仓库）：

```bash
tools/new-plugin.sh com.alice.notes com.alice.notes "Alice 的笔记终端" --host-apk <宿主.apk> --build
```

原样编样例本身（先照作者文档第 2 步备好 `signing.properties`，不然 `preBuild` 就停下说缺签名配置）：

```bash
./gradlew assembleRelease -PshunHostSha256=<宿主证书 SHA-256>   # 产物 app/build/outputs/apk/release/app-release.apk
./gradlew :app:testDebugUnitTest                                   # 会话逻辑（HelloShell）的 JVM 单测，不用装宿主
```

| 文件 | 是什么 |
|---|---|
| `settings.gradle.kts` | 独立工程；唯一的依赖 `provider-sdk` 默认在 `../provider-sdk` |
| `app/build.gradle.kts` | 包名、版本、宿主证书、你的签名 |
| `app/src/main/AndroidManifest.xml` | 插件服务（action + 描述符）、设置页、`<queries>` |
| `app/src/main/res/raw/shun_plugin.json` | 描述符：宿主批准前只看它 |
| `app/src/main/java/.../HelloProviderService.java` | AIDL 服务：认人、握手协商版本、开关会话 |
| `app/src/main/java/.../HelloSession.java` | 一个会话的接线：从 FD 读输入、交给 HelloShell、把它的输出写回 FD |
| `app/src/main/java/.../HelloShell.java` | 会话逻辑本身，纯 Java（字节进、字节出），`app/src/test` 里有它的 JVM 单测 |
| `app/src/main/java/.../SettingsActivity.java` | 插件自己的设置页（可选；不要就删它和清单里那个 `<activity>`） |
| `signing.properties.example` | 签名配置模板，复制成 `signing.properties` 填上你的密钥（用脚本的话它替你写好） |
| `tools/new-plugin.sh` | 从样例起一个新插件工程（在仓库外） |
| `tools/check-descriptor.sh` | 构建前自查描述符（要 Dart SDK，不在仓库里写任何文件） |

会话里能输入的命令：`help`、`size`（终端大小）、`color`（ANSI 颜色）、`info`（版本、句柄、代次）、`exit`（插件这边结束会话）。

它和仓库里别的插件不是一回事：`plugins/fixture-*` 是只用于测试的（有的故意做坏），`plugins/mosh` 是真实的 Mosh 插件。
区别见作者文档 README 的「仓库里这几类「插件」不是一回事」。

许可：Apache-2.0（同目录 `LICENSE`）。照着它做的插件可以按你自己选的许可发布，前提和例外见 [docs/plugin-authors/licensing.md](../../docs/plugin-authors/licensing.md)。
