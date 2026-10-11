// 「假 UU 远程」测试 App（X06）：扮演 UU 远程接收 uuremote:// 请求，按设定的模式回各种回调。
// 只用来测本 App 怎么发请求、怎么认回调；它不是 UU 远程，和它走通不代表真实 UU 能用。
//
// 变体参数：
//   -PfakeUuAppId=<包名>           默认 com.netease.uuremote（冒充官方包名：宿主会发现证书不是官方的）
//   -PfakeUuVersion=4.42.0 -PfakeUuVersionCode=44200
//   -PsignWith=author|impostor     见 ../signing.gradle.kts；换一把密钥就是「同包名换签」
//   -PfakeUuHijack=true            另外声明宿主的回调地址 shun-uuremote://callback（扮演抢回调的 App，见 HijackActivity）
plugins {
    id("com.android.application")
}
apply(from = "../signing.gradle.kts")

val appId = (findProperty("fakeUuAppId") as String?) ?: "com.netease.uuremote"
val fakeVersion = (findProperty("fakeUuVersion") as String?) ?: "4.42.0"
val fakeVersionCode = ((findProperty("fakeUuVersionCode") as String?) ?: "44200").toInt()
val hijack = (findProperty("fakeUuHijack") as String?) == "true"

@Suppress("UNCHECKED_CAST")
val signing = extra["shunSigning"] as List<String>

android {
    namespace = "example.shun.fixture.fakeuu"
    compileSdk = 36

    defaultConfig {
        applicationId = appId
        minSdk = 24
        targetSdk = 36
        versionCode = fakeVersionCode
        versionName = fakeVersion
        manifestPlaceholders["hijackEnabled"] = hijack.toString()
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
