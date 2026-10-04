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
    namespace = "app.netcatty.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 本 fork 的安装身份，所有者 2026-09-29 指定。改回上游的 app.netcatty.mobile
        // 会覆盖手机上的原版 Netcatty 及其数据。上面的 namespace 只是 Kotlin 代码包名，
        // 不影响安装身份，保持上游值以减少与上游合并时的冲突。
        applicationId = "top.xdwa.xwshun"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
}
