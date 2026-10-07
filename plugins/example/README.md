# Hello 终端：xwshun 插件样例

给 xwshun（Android 上的终端 App）提供一个最小的终端会话的插件 App。它是**样例**：照着它做你自己的插件。
从零开始的完整步骤（装工具、生成密钥、取宿主证书、构建、安装、批准、验证、出错怎么查）在
[docs/plugin-authors/README.md](../../docs/plugin-authors/README.md)，这里只列文件。

```bash
./gradlew assembleRelease -PxwshunHostSha256=<宿主证书 SHA-256>   # 产物 app/build/outputs/apk/release/app-release.apk
```

| 文件 | 是什么 |
|---|---|
| `settings.gradle.kts` | 独立工程；唯一的依赖 `provider-sdk` 默认在 `../provider-sdk` |
| `app/build.gradle.kts` | 包名、版本、宿主证书、你的签名 |
| `app/src/main/AndroidManifest.xml` | 插件服务（action + 描述符）、设置页、`<queries>` |
| `app/src/main/res/raw/xwshun_plugin.json` | 描述符：宿主批准前只看它 |
| `app/src/main/java/.../HelloProviderService.java` | AIDL 服务：认人、握手协商版本、开关会话 |
| `app/src/main/java/.../HelloSession.java` | 一个会话：从 FD 读输入、往 FD 写终端输出 |
| `app/src/main/java/.../SettingsActivity.java` | 插件自己的设置页（可选） |
| `signing.properties.example` | 签名配置模板，复制成 `signing.properties` 填上你的密钥 |

会话里能输入的命令：`help`、`size`（终端大小）、`color`（ANSI 颜色）、`info`（版本、句柄、代次）、`exit`（插件这边结束会话）。

它和仓库里别的插件不是一回事：`plugins/fixture-*` 是只用于测试的（有的故意做坏），`plugins/mosh` 是真实的 Mosh 插件。
区别见作者文档的「这几类插件有什么不同」。
