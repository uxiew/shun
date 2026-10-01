// 「假浏览器」测试 App（R14）：临时设成默认浏览器，接住本 App 交出去的 Tailscale check 链接，
// 只把收到的链接记进日志、显示在屏幕上，从不联网——模拟器上测「点了才交给浏览器」时，
// 不让真 Chrome 拿着假 token 去访问 login.tailscale.com。它不是浏览器，和它走通不代表真实 check 能通过。
plugins {
    id("com.android.application")
}
apply(from = "../signing.gradle.kts")

@Suppress("UNCHECKED_CAST")
val signing = extra["xwshunSigning"] as List<String>

android {
    namespace = "example.xwshun.fixture.fakebrowser"
    compileSdk = 36

    defaultConfig {
        applicationId = "example.xwshun.fixture.fakebrowser"
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
