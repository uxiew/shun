// Mosh 运行时插件（X08）：独立 APK、独立 UID，不设 sharedUserId。宿主经 AIDL + socketpair 用它（docs/15、16）。
//
// 运行时是官方 mosh-client 1.4.0 的 Android 交叉编译版，先跑 native/build-mosh-client.sh 生成
// build-native/jniLibs/arm64-v8a/libmoshclient.so，再构建本模块；没有它构建直接失败（不打一个缺运行时的包）。
// 只打 arm64-v8a：只有它在设备上测过（docs/shun/README.md「只声明实测 ABI」）。
//
// 参数：
//   -PhostSha256=<宿主签名证书 SHA-256>   必填，插件只接受这张证书签的宿主
//   -PsignWith=author|impostor|androidDebug  见 ../signing.gradle.kts（正式签名待所有者决定）
plugins {
    id("com.android.application")
}
apply(from = "../signing.gradle.kts")

val hostSha256 = (findProperty("hostSha256") as String?)?.lowercase()?.replace(":", "")
    ?: throw GradleException("缺 -PhostSha256：插件必须知道信任哪张宿主证书")
@Suppress("UNCHECKED_CAST")
val signing = extra["shunSigning"] as List<String>
val appId = "top.xdwa.shun.mosh"
val pluginVersion = "0.1.0"

val runtime = file("build-native/jniLibs/arm64-v8a/libmoshclient.so")
// 构建本模块时才查（配置阶段不查）：build-fixtures.sh 配置整个工程时不该因为没编 Mosh 运行时而失败。
tasks.matching { it.name == "preBuild" }.configureEach {
    doFirst { if (!runtime.isFile) throw GradleException("缺运行时 $runtime：先跑 native/build-mosh-client.sh") }
}

val generatedRes = layout.buildDirectory.dir("generated/shun-res").get().asFile
generatedRes.resolve("raw").mkdirs()
generatedRes.resolve("raw/shun_plugin.json").writeText(
    """
    {
      "schemaVersion": 1,
      "pluginId": "shun.mosh",
      "displayName": "Mosh",
      "version": "$pluginVersion",
      "apiMajor": 1,
      "apiMinor": 0,
      "deployment": "android-service",
      "capabilities": ["terminal-session"],
      "supportedRoutes": ["system-default"],
      "platforms": ["android"],
      "permissions": ["own-session-input-output", "own-session-ephemeral-secret"],
      "packageName": "$appId",
      "serviceClass": "top.xdwa.shun.mosh.MoshProviderService",
      "license": "GPL-3.0-or-later"
    }
    """.trimIndent(),
)

android {
    namespace = "top.xdwa.shun.mosh"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = appId
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = pluginVersion
        resValue("string", "shun_trusted_host_package", "top.xdwa.shun")
        resValue("string", "shun_trusted_host_sha256", hostSha256)
        ndk { abiFilters += "arm64-v8a" }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets.getByName("main") {
        jniLibs.srcDir("build-native/jniLibs")
        assets.srcDir("build-native/assets")   // 许可证原文，见 LICENSES.md
        res.srcDir(generatedRes)
    }

    packaging {
        jniLibs {
            // 运行时是可执行文件：必须由系统安装时解到 nativeLibraryDir 才能 exec（APK 里不压缩、不解出时没有文件可 exec）。
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        create("plugin") {
            storeFile = file(signing[0])
            storePassword = signing[1]
            keyAlias = signing[2]
            keyPassword = signing[3]
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // 证据阶段要 run-as 看进程 fd 和 /proc；正式发布前关掉（docs/18）。
            isDebuggable = true
            signingConfig = signingConfigs.getByName("plugin")
        }
    }

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":provider-sdk"))
}
