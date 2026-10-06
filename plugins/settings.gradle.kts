// 测试插件工程（X02）。和宿主是两个独立的 Gradle 构建，只共享 provider-sdk 这一个目录。
// 用法见 plugins/README.md；密钥在仓库外 ../../.toolchain/plugin-keys/，不进 git。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    // 与宿主 android/settings.gradle.kts 保持同一版本，Gradle 缓存可以共用。
    id("com.android.application") version "9.0.1" apply false
    id("com.android.library") version "9.0.1" apply false
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "xwshun-plugin-fixtures"
include(":provider-sdk", ":fixture-echo", ":fixture-rogue", ":fixture-fakeuu", ":fixture-fakerustdesk", ":fixture-fakebrowser", ":fixture-replayime")
