// Echo 测试插件：只用来验证发现、签名与双向鉴权（X02），以后给 X03 做字节流/故障注入。
// 它不是 Mosh，也不是任何产品功能；成功连上它不代表任何真实 provider 可用。
//
// 变体参数：
//   -PhostSha256=<宿主签名证书 SHA-256>   必填，插件只接受这张证书签的宿主来调它
//   -PsignWith=author|impostor|androidDebug  见 ../signing.gradle.kts
//   -PechoAppId=<包名>                     默认 example.xwshun.fixture.echo
//   -PpluginId=<pluginId>                  默认 example.fixture_echo
//   -PleakTo=<包名>                        握手后把宿主回调 Binder 转交给这个包（只为测宿主逐事务鉴权）
plugins {
    id("com.android.application")
}
apply(from = "../signing.gradle.kts")

val hostSha256 = (findProperty("hostSha256") as String?)?.lowercase()?.replace(":", "")
    ?: throw GradleException("缺 -PhostSha256：插件必须知道信任哪张宿主证书")
val appId = (findProperty("echoAppId") as String?) ?: "example.xwshun.fixture.echo"
val pluginId = (findProperty("pluginId") as String?) ?: "example.fixture_echo"
val leakTo = (findProperty("leakTo") as String?) ?: ""
@Suppress("UNCHECKED_CAST")
val signing = extra["xwshunSigning"] as List<String>

// 描述符里的包名必须等于实际安装包（宿主会核对），所以随变体生成，而不是手写一份固定 JSON。
val generatedRes = layout.buildDirectory.dir("generated/xwshun-res/$appId").get().asFile
generatedRes.resolve("raw").mkdirs()
generatedRes.resolve("raw/xwshun_plugin.json").writeText(
    """
    {
      "schemaVersion": 1,
      "pluginId": "$pluginId",
      "displayName": "Echo fixture (test only)",
      "version": "0.1.0",
      "apiMajor": 1,
      "apiMinor": 0,
      "deployment": "android-service",
      "capabilities": ["terminal-session"],
      "supportedRoutes": ["system-default"],
      "platforms": ["android"],
      "permissions": ["own-session-input-output"],
      "packageName": "$appId",
      "serviceClass": "example.xwshun.fixture.echo.EchoProviderService",
      "license": "GPL-3.0-or-later"
    }
    """.trimIndent(),
)

android {
    namespace = "example.xwshun.fixture.echo"
    compileSdk = 36

    defaultConfig {
        applicationId = appId
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        resValue("string", "xwshun_trusted_host_package", "top.xdwa.xwshun")
        resValue("string", "xwshun_trusted_host_sha256", hostSha256)
        resValue("string", "xwshun_fixture_leak_host_binder_to", leakTo)
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
