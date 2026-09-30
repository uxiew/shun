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
build rogue          fixture-rogue -PsignWith=impostor
# X03 故障注入：与 echo-author 同包名同密钥，覆盖安装即可切换行为。
build echo-slowopen  fixture-echo  -PsignWith=author -Pbehavior=slowopen
build echo-stubborn  fixture-echo  -PsignWith=author -Pbehavior=stubborn
build echo-misbehave fixture-echo  -PsignWith=author -Pbehavior=misbehave
build echo-major2    fixture-echo  -PsignWith=author -Pbehavior=major2
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
