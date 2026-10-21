// 「流氓」测试 App（X02 的负向用例）：
//   - ProbeActivity：伪造 Intent extras 冒充宿主去绑定 echo 插件，逐个调用它的 AIDL 方法；
//   - RogueProviderService：声明插件 action，描述符冒用内置 ID builtin.ssh；
//     同时接收 echo（leakTo 变体）转交来的宿主回调 Binder，用它调宿主。
// 默认用 impostor 密钥签。
// -PhostPackage=<宿主包名>：ProbeActivity 冒充谁，默认正式包 top.xdwa.shun。要和 echo 信任的包名一致（build-fixtures.sh 都传同一个）：
// 冒充的名字和 echo 信任的不一样时，就算插件错信了 Intent 里自报的包名也会拒绝，测不出那个洞。
plugins {
    id("com.android.application")
}
if (!project.hasProperty("signWith")) extra["signWith"] = "impostor"
apply(from = "../signing.gradle.kts")

@Suppress("UNCHECKED_CAST")
val signing = extra["shunSigning"] as List<String>
val hostPackage = (findProperty("hostPackage") as String?) ?: "top.xdwa.shun"

android {
    namespace = "example.shun.fixture.rogue"
    compileSdk = 36

    defaultConfig {
        applicationId = "example.shun.fixture.rogue"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        resValue("string", "shun_host_package", hostPackage)
        manifestPlaceholders["hostPackage"] = hostPackage
    }

    buildFeatures {
        // AGP 9 默认关闭；不开会报 "defaultConfig contains custom resource values, but the feature is disabled"。
        resValues = true
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
