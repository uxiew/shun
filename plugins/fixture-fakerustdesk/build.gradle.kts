// 「假 RustDesk」测试 App（X07）：扮演 RustDesk 接收 rustdesk:// 链接，把收到的东西原样记进日志。
// 只用来测本 App 发了什么、发给了谁；它不是 RustDesk，和它走通不代表真实 RustDesk 能连上任何电脑。
//
// 变体参数：
//   -PfakeRdAppId=<包名>          默认 com.carriez.flutter_hbb（冒充官方包名：宿主会发现证书不是发行渠道的）
//   -PfakeRdVersion=1.4.9 -PfakeRdVersionCode=2067
//   -PsignWith=author|impostor    见 ../signing.gradle.kts；换一把密钥就是「同包名换签」
//   -PfakeRdHostOnly=true         intent-filter 限定 host=connect（真实 RustDesk 只写 scheme）。
//                                 用来确认这种 App 宿主也看得见、说得出包名
plugins {
    id("com.android.application")
}
apply(from = "../signing.gradle.kts")

val appId = (findProperty("fakeRdAppId") as String?) ?: "com.carriez.flutter_hbb"
val fakeVersion = (findProperty("fakeRdVersion") as String?) ?: "1.4.9"
val fakeVersionCode = ((findProperty("fakeRdVersionCode") as String?) ?: "2067").toInt()
val hostOnly = (findProperty("fakeRdHostOnly") as String?) == "true"

@Suppress("UNCHECKED_CAST")
val signing = extra["shunSigning"] as List<String>

android {
    namespace = "example.shun.fixture.fakerustdesk"
    compileSdk = 36

    defaultConfig {
        applicationId = appId
        minSdk = 24
        targetSdk = 36
        versionCode = fakeVersionCode
        versionName = fakeVersion
        manifestPlaceholders["schemeOnlyEnabled"] = (!hostOnly).toString()
        manifestPlaceholders["hostOnlyEnabled"] = hostOnly.toString()
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
