// 「流氓」测试 App（X02 的负向用例）：
//   - ProbeActivity：伪造 Intent extras 冒充宿主去绑定 echo 插件，逐个调用它的 AIDL 方法；
//   - RogueProviderService：声明插件 action，描述符冒用内置 ID builtin.ssh；
//     同时接收 echo（leakTo 变体）转交来的宿主回调 Binder，用它调宿主。
// 默认用 impostor 密钥签。
plugins {
    id("com.android.application")
}
if (!project.hasProperty("signWith")) extra["signWith"] = "impostor"
apply(from = "../signing.gradle.kts")

@Suppress("UNCHECKED_CAST")
val signing = extra["shunSigning"] as List<String>

android {
    namespace = "example.shun.fixture.rogue"
    compileSdk = 36

    defaultConfig {
        applicationId = "example.shun.fixture.rogue"
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

dependencies {
    implementation(project(":provider-sdk"))
}
