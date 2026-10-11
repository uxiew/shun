// Echo 测试插件：只用来验证发现、签名与双向鉴权（X02），以后给 X03 做字节流/故障注入。
// 它不是 Mosh，也不是任何产品功能；成功连上它不代表任何真实 provider 可用。
//
// 变体参数：
//   -PhostSha256=<宿主签名证书 SHA-256>   必填，插件只接受这张证书签的宿主来调它
//   -PsignWith=author|impostor|androidDebug  见 ../signing.gradle.kts
//   -PechoAppId=<包名>                     默认 example.shun.fixture.echo
//   -PpluginId=<pluginId>                  默认 example.fixture_echo
//   -PleakTo=<包名>                        握手后把宿主回调 Binder 转交给这个包（只为测宿主逐事务鉴权）
//   -Pbehavior=normal|slowopen|stubborn|misbehave|major2|badhandshake   X03/X12 故障注入，见 EchoProviderService
//   -PdescriptorVersion=0.1.0 -PversionCode=1               X04 模拟插件更新（版本号要递增才能覆盖安装）
//   -PextraCapability=<能力名>                               X04 更新后多申请一项能力，宿主应要求重新批准
//   -PapiMajor=1                                             X04 描述符声明的 API major，改成 2 宿主应判不兼容
plugins {
    id("com.android.application")
}
apply(from = "../signing.gradle.kts")

val hostSha256 = (findProperty("hostSha256") as String?)?.lowercase()?.replace(":", "")
    ?: throw GradleException("缺 -PhostSha256：插件必须知道信任哪张宿主证书")
val appId = (findProperty("echoAppId") as String?) ?: "example.shun.fixture.echo"
val pluginId = (findProperty("pluginId") as String?) ?: "example.fixture_echo"
val leakTo = (findProperty("leakTo") as String?) ?: ""
val behavior = (findProperty("behavior") as String?) ?: "normal"
val descriptorVersion = (findProperty("descriptorVersion") as String?) ?: "0.1.0"
val fixtureVersionCode = ((findProperty("versionCode") as String?) ?: "1").toInt()
val extraCapability = (findProperty("extraCapability") as String?) ?: ""
val apiMajor = ((findProperty("apiMajor") as String?) ?: "1").toInt()
val capabilities = listOf("terminal-session") + listOfNotNull(extraCapability.ifBlank { null })
val permissions = listOf("own-session-input-output") +
    if (extraCapability == "remote-desktop-external") listOf("user-initiated-external-launch") else emptyList()
fun jsonList(items: List<String>) = items.joinToString(", ") { "\"$it\"" }
if (behavior !in setOf("normal", "slowopen", "stubborn", "misbehave", "major2", "badhandshake")) {
    throw GradleException("behavior 只能是 normal/slowopen/stubborn/misbehave/major2/badhandshake")
}
@Suppress("UNCHECKED_CAST")
val signing = extra["shunSigning"] as List<String>

// 描述符里的包名必须等于实际安装包（宿主会核对），所以随变体生成，而不是手写一份固定 JSON。
val generatedRes = layout.buildDirectory.dir("generated/shun-res/$appId").get().asFile
generatedRes.resolve("raw").mkdirs()
generatedRes.resolve("raw/shun_plugin.json").writeText(
    """
    {
      "schemaVersion": 1,
      "pluginId": "$pluginId",
      "displayName": "Echo fixture (test only)",
      "version": "$descriptorVersion",
      "apiMajor": $apiMajor,
      "apiMinor": 0,
      "deployment": "android-service",
      "capabilities": [${jsonList(capabilities)}],
      "supportedRoutes": ["system-default"],
      "platforms": ["android"],
      "permissions": [${jsonList(permissions)}],
      "packageName": "$appId",
      "serviceClass": "example.shun.fixture.echo.EchoProviderService",
      "license": "GPL-3.0-or-later"
    }
    """.trimIndent(),
)

android {
    namespace = "example.shun.fixture.echo"
    compileSdk = 36

    defaultConfig {
        applicationId = appId
        minSdk = 24
        targetSdk = 36
        versionCode = fixtureVersionCode
        versionName = descriptorVersion
        resValue("string", "shun_trusted_host_package", "top.xdwa.shun")
        resValue("string", "shun_trusted_host_sha256", hostSha256)
        resValue("string", "shun_fixture_leak_host_binder_to", leakTo)
        resValue("string", "shun_fixture_behavior", behavior)
    }

    signingConfigs {
        create("fixture") {
            storeFile = file(signing[0])
            storePassword = signing[1]
            keyAlias = signing[2]
            keyPassword = signing[3]
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // 测试 APK：可 debug 才能 run-as 看进程的 fd 表（X03 核对 FD 是否清理）。
            isDebuggable = true
            signingConfig = signingConfigs.getByName("fixture")
        }
    }

    buildFeatures {
        // AGP 9 默认关闭；不开会报 "defaultConfig contains custom resource values, but the feature is disabled"。
        resValues = true
    }

    sourceSets.getByName("main").res.srcDir(generatedRes)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":provider-sdk"))
}
