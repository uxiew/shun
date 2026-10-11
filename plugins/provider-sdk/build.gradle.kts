// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

// 宿主与插件共用的薄契约：AIDL + 认人的两个工具类。纯 Java，不带 Kotlin，也不依赖 Flutter，
// 插件作者可以直接引用。宿主工程（android/）和测试插件工程（plugins/）都把这个目录当子模块引入。
plugins {
    id("com.android.library")
}

android {
    namespace = "top.xdwa.shun.plugin.v1"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    buildFeatures {
        // AGP 8 起 AIDL 默认关闭，不开会找不到 IShunProvider 等生成类。
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // 只为 ProviderSessions 的纯 JVM 单测；4.12 是本机 Gradle 缓存里已有的版本，不用联网。
    testImplementation("junit:junit:4.12")
}
