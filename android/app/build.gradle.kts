plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
val releaseKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseKeystorePath,
    releaseKeystorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "top.xdwa.shun"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 安装身份，所有者 2026-10-11 定为 top.xdwa.shun（之前是 top.xdwa.xwshun）。
        // 改成上游的 app.netcatty.mobile 会覆盖手机上的原版 Netcatty 及其数据；
        // 再改成别的值，手机会当成另一个 App，旧 App 的保险库、密钥不会跟过来。
        applicationId = "top.xdwa.shun"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "shun"
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("ciRelease") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        // 调试包（flutter run、flutter test integration_test、flutter drive 装的都是它）装成 top.xdwa.shun.debug，
        // 和留在手机上用的正式包 top.xdwa.shun 并存。不加后缀的话，调试包签名对不上，flutter 会自己
        // 「Uninstalling old version...」把正式包连数据卸掉再装（flutter_tools installApp，3.47.7）。
        // 插件只信任构建时指定的宿主包名，给调试宿主用的插件要带 -PhostPackage=top.xdwa.shun.debug 编（plugins/build-fixtures.sh 默认就是，见 plugins/README.md）。
        debug {
            applicationIdSuffix = ".debug"
            manifestPlaceholders["appLabel"] = "shun 调试"
        }
        // profile（flutter run/build/drive --profile）是 Flutter 插件在这个文件之前照 debug 复制出来的，
        // 那时 debug 还没加后缀：不写这几行，它的包名就是正式包 top.xdwa.shun（10-25 编出来看过），
        // 在装着正式包的手机上跑 --profile，和上面说的一样会把正式包连数据卸掉。
        getByName("profile") {
            applicationIdSuffix = ".profile"
            manifestPlaceholders["appLabel"] = "shun profile"
        }
        release {
            // Local release builds remain installable with the debug key. CI injects
            // one persistent keystore so every downloaded artifact can update the
            // previous CI build instead of being signed by a new runner each time.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("ciRelease")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// 发布包只带 arm64-v8a：只有它在设备上测过（REL03、GST01）。不排除的话插件自带的 armeabi-v7a、
// x86_64 库会进包，32 位手机能装上却没有对应的 Flutter 引擎，一打开就崩。在 buildTypes.release 里写
// ndk.abiFilters 没用：Flutter 插件把 defaultConfig 设成了三种 ABI，两边取并集。
// 要加 ABI，先在那种设备上跑过 integration_test/ghostty_engine_test.dart。
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf("lib/armeabi-v7a/**", "lib/x86_64/**", "lib/x86/**"),
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":provider-sdk"))
    // 安全密钥（R59）：CTAP2、NFC、USB 都由它走，SecurityKeyChannel 只做桥。
    implementation("com.yubico.yubikit:android:3.1.0")
    implementation("com.yubico.yubikit:fido:3.1.0")
    testImplementation("junit:junit:4.13.2")
}
