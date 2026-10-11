// 两个测试 APK 共用的签名选择。-PsignWith=author|impostor|androidDebug
//
// author：独立作者自己的密钥（和宿主没有任何关系，证明「不用共享宿主私钥」）。
// impostor：另一把密钥，用来做「同包名、不同签名」的冒牌包。
// androidDebug：本机 ~/.android/debug.keystore，也就是宿主 debug 包用的那把——用来测 release 宿主拒收调试证书。
val keysDir = rootProject.file("../../.toolchain/plugin-keys")
val signWith = (findProperty("signWith") as String?) ?: "author"

extra["shunSigning"] = when (signWith) {
    "author" -> listOf(keysDir.resolve("fixture-author.jks").path, "shun-fixture", "author", "shun-fixture")
    "impostor" -> listOf(keysDir.resolve("fixture-impostor.jks").path, "shun-fixture", "impostor", "shun-fixture")
    "androidDebug" -> listOf(
        System.getProperty("user.home") + "/.android/debug.keystore",
        "android",
        "androiddebugkey",
        "android",
    )
    else -> throw GradleException("signWith 只能是 author / impostor / androidDebug")
}
