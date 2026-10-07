// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

// Hello 终端：xwshun 插件样例（X12）。给宿主提供一个最小的终端会话，演示授权、版本协商、字节流、改尺寸和关闭。
// 怎么从它做出你自己的插件，见仓库的 docs/plugin-authors/README.md。
//
// 构建参数（写在 ../gradle.properties 里，或构建时 -P 传）：
//   xwshunHostSha256=<宿主签名证书 SHA-256>   必填。插件只接受这张证书签的宿主调它；多张用逗号隔开
//   signingProperties=<路径>                   可选。签名配置文件，默认 ../signing.properties
//   minHostMinor=<数字>                        可选。插件要求的最低宿主 API minor，默认 0；演示「插件拒绝旧宿主」时改成 1
import java.util.Properties

plugins {
    id("com.android.application")
}

// 缺配置时不在这里就失败（那样连 ./gradlew tasks 都跑不了），而是记下来，构建时再报（见文件末尾）。
val problems = mutableListOf<String>()

val hostSha256 = (findProperty("xwshunHostSha256") as String?).orEmpty()
    .split(",")
    .map { it.trim().lowercase().replace(":", "") }
    .filter { it.isNotEmpty() }
if (hostSha256.isEmpty() || hostSha256.any { !Regex("^[0-9a-f]{64}$").matches(it) }) {
    problems += "xwshunHostSha256 没填或格式不对：要宿主签名证书的 SHA-256，64 位十六进制（冒号可有可无）。" +
        "怎么取见 docs/plugin-authors/README.md 第 3 步"
}

// 签名用你自己生成的密钥：不需要、也拿不到宿主的私钥。密钥库建议放在工程外面，别提交进 git。
val signingFile = rootProject.file((findProperty("signingProperties") as String?) ?: "signing.properties")
val signing = Properties()
if (signingFile.isFile) {
    signingFile.inputStream().use { signing.load(it) }
} else {
    problems += "缺签名配置 $signingFile：照 signing.properties.example 写一份。怎么生成密钥见 docs/plugin-authors/README.md 第 2 步"
}
fun signingValue(key: String): String? = signing.getProperty(key)?.trim()?.takeIf { it.isNotEmpty() }
for (key in listOf("storeFile", "storePassword", "keyAlias", "keyPassword")) {
    if (signingFile.isFile && signingValue(key) == null) problems += "$signingFile 里缺 $key"
}
// storeFile 可以写绝对路径、~/ 开头，或相对这个配置文件所在目录的路径。
val keystore = signingValue("storeFile")
    ?.let { if (it.startsWith("~/")) System.getProperty("user.home") + it.substring(1) else it }
    ?.let { path -> File(path).takeIf { it.isAbsolute } ?: signingFile.parentFile.resolve(path) }
if (keystore != null && !keystore.isFile) problems += "密钥库不存在：$keystore"

val minHostMinor = ((findProperty("minHostMinor") as String?) ?: "0").toInt()

android {
    namespace = "example.xwshun.hello"
    compileSdk = 36

    defaultConfig {
        // 改成你自己的包名；res/raw/xwshun_plugin.json 里的 packageName 要一起改，宿主会核对两者相等。
        applicationId = "example.xwshun.hello"
        minSdk = 24 // 宿主最低支持 Android 7.0（API 24）
        targetSdk = 36
        // 发新版本时 versionCode 要递增，否则系统拒绝覆盖安装（INSTALL_FAILED_VERSION_DOWNGRADE）。
        versionCode = 1
        // 和描述符里的 version 保持一致：宿主详情页两个都显示，对不上用户看得出来。
        versionName = "0.1.0"
        resValue("string", "xwshun_host_package", "top.xdwa.xwshun")
        resValue("string", "xwshun_host_sha256", hostSha256.joinToString(","))
        resValue("integer", "xwshun_min_host_minor", "$minHostMinor")
    }

    signingConfigs {
        create("author") {
            if (problems.isEmpty()) {
                storeFile = keystore
                storePassword = signingValue("storePassword")
                keyAlias = signingValue("keyAlias")
                keyPassword = signingValue("keyPassword")
            }
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("author")
        }
        // debug 包也用你的密钥签。不然它用 Android 调试证书签：正式版宿主一律拒收，换台电脑构建证书还会变。
        getByName("debug") {
            signingConfig = signingConfigs.getByName("author")
        }
    }

    buildFeatures {
        // AGP 9 默认关闭；不开会报 "defaultConfig contains custom resource values, but the feature is disabled"。
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":provider-sdk"))
    // 只给 HelloShellTest：会话逻辑在电脑上用 JVM 跑，不用装宿主（./gradlew :app:testDebugUnitTest）。
    testImplementation("junit:junit:4.12")
}

tasks.matching { it.name == "preBuild" }.configureEach {
    doFirst {
        if (problems.isNotEmpty()) throw GradleException(problems.joinToString("\n"))
    }
}
