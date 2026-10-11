// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

// 插件样例：一个独立的 Gradle 工程，不依赖宿主工程，也不依赖 plugins/ 下别的模块。
// 唯一的依赖是契约库 provider-sdk（AIDL + 认人工具），默认在旁边的 ../provider-sdk。
// 把样例复制到别处时，provider-sdk 一起复制、保持相对位置；或者在 gradle.properties 里写 shunSdkDir=<绝对路径>。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "9.0.1" apply false
    id("com.android.library") version "9.0.1" apply false
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "shun-plugin-example"
include(":app")

val sdkDir = file(providers.gradleProperty("shunSdkDir").getOrElse("../provider-sdk"))
if (!sdkDir.resolve("build.gradle.kts").isFile) {
    throw GradleException("找不到 provider-sdk：$sdkDir。把 provider-sdk 目录放在样例旁边，或在 gradle.properties 里写 shunSdkDir=<路径>")
}
include(":provider-sdk")
project(":provider-sdk").projectDir = sdkDir
