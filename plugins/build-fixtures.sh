#!/usr/bin/env bash
# 构建 X02 的测试 APK 到 plugins/out/。首次运行会在仓库外生成两把测试密钥。
# 先 source ../.toolchain/env.sh（要用里面的 JDK 和 Gradle 缓存）。
set -euo pipefail
cd "$(dirname "$0")"

KEYS=../../.toolchain/plugin-keys
mkdir -p "$KEYS" out
for who in author impostor; do
  if [ ! -f "$KEYS/fixture-$who.jks" ]; then
    keytool -genkeypair -keystore "$KEYS/fixture-$who.jks" -storepass xwshun-fixture -keypass xwshun-fixture \
      -alias "$who" -keyalg RSA -keysize 3072 -validity 3650 \
      -dname "CN=xwshun fixture $who, O=xwshun test only" >/dev/null
  fi
done

# 插件只信这张宿主证书。宿主 debug 包和本机 release 包（没配正式签名时）都用本机调试密钥签。
HOST_SHA256=${HOST_SHA256:-$(keytool -list -v -keystore ~/.android/debug.keystore -storepass android \
  -alias androiddebugkey | awk '/SHA256:/{print $2}' | tr -d ':' | tr 'A-F' 'a-f')}

G=../android/gradlew
build() {
  local out=$1 module=$2
  shift 2
  # 每次都带上 hostSha256：Gradle 会配置所有模块，构建 rogue 时 echo 的脚本也要跑。
  "$G" -p . -q ":$module:assembleRelease" -PhostSha256="$HOST_SHA256" "$@"
  cp "$module/build/outputs/apk/release/$module-release.apk" "out/$out.apk"
  echo "out/$out.apk"
}

build echo-author    fixture-echo  -PsignWith=author
build echo-impostor  fixture-echo  -PsignWith=impostor
build echo-leaky     fixture-echo  -PsignWith=author -PleakTo=example.xwshun.fixture.rogue
build echo-debugkey  fixture-echo  -PsignWith=androidDebug \
  -PechoAppId=example.xwshun.fixture.echo.debugkey -PpluginId=example.fixture_echo_debugkey
# X12：自称 Mosh 插件的 ID（xwshun.mosh），用另一把密钥签。宿主只认 Mosh 插件那张证书，应直接「已拒绝」、不给批准。
build echo-fakemosh  fixture-echo  -PsignWith=impostor \
  -PechoAppId=example.xwshun.fixture.fakemosh -PpluginId=xwshun.mosh
build rogue          fixture-rogue -PsignWith=impostor
# X03 故障注入：与 echo-author 同包名同密钥，覆盖安装即可切换行为。
build echo-slowopen  fixture-echo  -PsignWith=author -Pbehavior=slowopen
build echo-stubborn  fixture-echo  -PsignWith=author -Pbehavior=stubborn
build echo-misbehave fixture-echo  -PsignWith=author -Pbehavior=misbehave
build echo-major2    fixture-echo  -PsignWith=author -Pbehavior=major2
# X12：握手时抛约定以外的异常（UnsupportedOperationException），宿主要如实报错、不能崩。
build echo-badhandshake fixture-echo -PsignWith=author -Pbehavior=badhandshake
# X04 模拟插件更新：同包名同密钥、版本号递增，覆盖安装即是「更新」。退回旧版要 adb install -r -d。
build echo-v2        fixture-echo  -PsignWith=author -PdescriptorVersion=0.2.0 -PversionCode=2
build echo-morecaps  fixture-echo  -PsignWith=author -PdescriptorVersion=0.3.0 -PversionCode=3 \
  -PextraCapability=remote-desktop-external
build echo-apimajor2 fixture-echo  -PsignWith=author -PdescriptorVersion=0.4.0 -PversionCode=4 -PapiMajor=2
# X06「假 UU 远程」：冒充官方包名 com.netease.uuremote（证书当然不是官方的）。同包名的变体要先卸载才能换装。
build fakeuu           fixture-fakeuu -PsignWith=author
build fakeuu-old       fixture-fakeuu -PsignWith=author -PfakeUuVersion=4.41.0 -PfakeUuVersionCode=44100
build fakeuu-resigned  fixture-fakeuu -PsignWith=impostor
build fakeuu-lookalike fixture-fakeuu -PsignWith=impostor -PfakeUuAppId=example.xwshun.fixture.fakeuu
# 抢回调的 App：和 lookalike 同包名同密钥（install -r 互相覆盖），多声明宿主的回调地址 xwshun-uuremote://callback。
build fakeuu-hijack    fixture-fakeuu -PsignWith=impostor -PfakeUuAppId=example.xwshun.fixture.fakeuu -PfakeUuHijack=true
# X07「假 RustDesk」：冒充官方包名 com.carriez.flutter_hbb（证书当然不是发行渠道的）。
# 同包名同密钥的变体 install -r 直接覆盖（versionCode 故意都一样，不用 -d）；换了密钥的要先卸载。
build fakerd            fixture-fakerustdesk -PsignWith=author
build fakerd-old        fixture-fakerustdesk -PsignWith=author -PfakeRdVersion=1.2.3
build fakerd-ungated    fixture-fakerustdesk -PsignWith=author -PfakeRdVersion=1.4.6
build fakerd-newer      fixture-fakerustdesk -PsignWith=author -PfakeRdVersion=1.6.0
build fakerd-resigned   fixture-fakerustdesk -PsignWith=impostor
# 别的包名也声明 rustdesk://：扮演「改了包名的自建客户端」，也扮演「碰巧或故意占这个 scheme 的 App」——宿主分不出这两种。
build fakerd-custom     fixture-fakerustdesk -PsignWith=impostor -PfakeRdAppId=example.xwshun.fixture.fakerustdesk
# 同上，但 intent-filter 限定 host=connect、换一把密钥：和 fakerd-custom 同包名，要先卸载才能换装（用来测「信任过的包换签」）。
build fakerd-custom-hostonly fixture-fakerustdesk -PsignWith=author -PfakeRdAppId=example.xwshun.fixture.fakerustdesk -PfakeRdHostOnly=true
# R14「假浏览器」：临时设成默认浏览器，接住 Tailscale check 链接只记日志、不联网。
build fakebrowser       fixture-fakebrowser -PsignWith=author
# R18「回放输入法」：按脚本对输入连接做真实输入法那样的调用（不是插件，只是测试 App）。用法见 plugins/README.md。
build replayime         fixture-replayime    -PsignWith=author
