// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

// provider-sdk 还被宿主工程和 plugins/ 的测试工程引用。它的编译产物放进本工程自己的 build/，
// 几个工程先后或同时构建时不会互相覆盖对方的中间文件。
project(":provider-sdk") {
    layout.buildDirectory.set(rootProject.layout.buildDirectory.dir("provider-sdk"))
}
