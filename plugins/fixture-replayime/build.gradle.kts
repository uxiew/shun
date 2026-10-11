// 「回放输入法」测试 App（R18）：一个只认 adb 广播的输入法，按真实输入法的调用顺序操作输入连接
// （setComposingText / finishComposingText / setComposingRegion / commitText / deleteSurroundingText），
// 用来在模拟器上复现微信输入法语音那种「结束组字又圈回去改」的序列。它不识别语音、不联网，
// 走通只说明本 App 对这些调用的处理对，不代表真的微信输入法、Gboard 就没问题。
plugins {
    id("com.android.application")
}
apply(from = "../signing.gradle.kts")

@Suppress("UNCHECKED_CAST")
val signing = extra["shunSigning"] as List<String>

android {
    namespace = "example.shun.fixture.replayime"
    compileSdk = 36

    defaultConfig {
        applicationId = "example.shun.fixture.replayime"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
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

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
