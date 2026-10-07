#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 xwfe
#
# 从样例起一个新插件工程（在仓库外），一步做完 docs/plugin-authors/README.md 第 1–4 步：
# 复制样例和契约库、改包名/类名/pluginId/显示名、生成你自己的签名密钥并写好签名配置、
# 从宿主安装包读出宿主证书填进去、跑一遍描述符自查；加 --build 再编出 APK。
#
#   plugins/example/tools/new-plugin.sh <包名> <pluginId> <显示名> --host-apk <宿主.apk> [选项]
#   plugins/example/tools/new-plugin.sh com.alice.notes com.alice.notes "Alice 的笔记终端" --host-apk ~/Downloads/xwshun.apk --build
#
# 选项：
#   --host-apk <apk>        宿主安装包，用 apksigner 读它的签名证书（推荐，不会抄错）
#   --host-sha256 <hex>     或者直接给宿主证书 SHA-256（宿主「设置 → 插件（实验）」最底下抄的）；两个都给就都信任
#   --dir <目录>            新工程放哪，默认 ~/xwshun-plugins/<包名最后一段>，必须还不存在
#   --keystore <文件>       新密钥库放哪，默认 ~/xwshun-plugin-keys/<包名最后一段>.jks，必须还不存在
#   --license <SPDX>        描述符里的 license，默认 Apache-2.0（样例的许可）；你的插件用别的许可就改
#   --build                 生成完顺手 ./gradlew assembleRelease，并打印 APK 路径和你的证书 SHA-256
#
# 要：bash、perl、JDK 17 的 keytool（PATH 上或 JAVA_HOME 里）；--host-apk 和 --build 还要 Android SDK（ANDROID_HOME）；
# 自查要 dart（没有就跳过）。不改仓库里的任何文件。
set -euo pipefail

die() { echo "出错：$*" >&2; exit 1; }
say() { echo "== $*"; }

here="$(cd "$(dirname "$0")" && pwd)"
example="$(cd "$here/.." && pwd)"
sdk="$(cd "$example/../provider-sdk" 2>/dev/null && pwd)" || die "找不到 provider-sdk：这个脚本要在 xwshun 仓库的 plugins/example/tools/ 下运行"
api="$(cd "$example/../../packages/plugin_api" 2>/dev/null && pwd)" || die "找不到 packages/plugin_api"

[[ $# -ge 3 ]] || { sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
pkg=$1 plugin_id=$2 name=$3
shift 3
host_apk="" host_sha="" dest="" keystore="" license="Apache-2.0" build=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-apk) host_apk=$2; shift 2 ;;
    --host-sha256) host_sha=$2; shift 2 ;;
    --dir) dest=$2; shift 2 ;;
    --keystore) keystore=$2; shift 2 ;;
    --license) license=$2; shift 2 ;;
    --build) build=1; shift ;;
    *) die "不认识的参数：$1" ;;
  esac
done

# ---- 检查参数：规则和宿主一样，现在报错比装上去才发现省事 ----
ident='^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'
[[ $pkg =~ $ident ]] || die "包名「${pkg}」不行：小写字母开头，只用小写字母、数字、下划线，至少两段用点隔开，比如 com.alice.notes"
[[ $plugin_id =~ $ident && ${#plugin_id} -le 128 ]] || die "pluginId「${plugin_id}」不行：规则同包名，最长 128 字符"
case "$plugin_id" in
  builtin.*) die "pluginId 不能用 builtin. 开头：那是宿主自带插件保留的" ;;
  xwshun.mosh) die "xwshun.mosh 是 Mosh 插件的 ID，宿主只认它那张证书，你的插件会被拒" ;;
esac
[[ -n $name && ${#name} -le 80 ]] || die "显示名要 1–80 个字符"
printf '%s' "$name" | LC_ALL=C grep -q '[[:cntrl:]]' && die "显示名里不能有控制字符"
case "$name" in
  *[\"\\\<\>\&]*) die "显示名里别用 \" \\ < > &：它会原样写进 Java 字符串、XML 和 JSON" ;;
esac
[[ ${#license} -le 100 ]] || die "license 最长 100 字符"
[[ -n $host_apk || -n $host_sha ]] || die "要告诉插件信任哪个宿主：--host-apk <宿主.apk>（推荐），或 --host-sha256 <64 位十六进制>"

seg=${pkg##*.}
dest=${dest:-$HOME/xwshun-plugins/$seg}
keystore=${keystore:-$HOME/xwshun-plugin-keys/$seg.jks}
[[ ! -e $dest ]] || die "$dest 已经存在，换一个 --dir，免得覆盖你的东西"
[[ ! -e $keystore ]] || die "$keystore 已经存在：换一个 --keystore。脚本只新建密钥，不碰已有的（丢了密钥就没法给插件发新版本）"

keytool=$(command -v keytool || true)
[[ -z $keytool && -n ${JAVA_HOME:-} && -x $JAVA_HOME/bin/keytool ]] && keytool=$JAVA_HOME/bin/keytool
[[ -n $keytool ]] || die "找不到 keytool：装 JDK 17，把它的 bin 放进 PATH 或设 JAVA_HOME"
command -v perl >/dev/null || die "要 perl（macOS、Linux 一般都自带）"

apksigner() {
  local tools="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/build-tools"
  [[ -d $tools ]] || die "找不到 Android SDK 的 build-tools：设 ANDROID_HOME"
  local found
  found=$(ls -d "$tools"/*/apksigner 2>/dev/null | sort -V | tail -1)
  [[ -n $found ]] || die "build-tools 里没有 apksigner"
  "$found" "$@"
}

# ---- 宿主证书 ----
hosts=()
if [[ -n $host_apk ]]; then
  [[ -f $host_apk ]] || die "宿主安装包不存在：$host_apk"
  read_sha=$(apksigner verify --print-certs "$host_apk" | awk -F': ' '/certificate SHA-256 digest/{print $2}')
  [[ $(printf '%s\n' "$read_sha" | wc -l) -eq 1 && -n $read_sha ]] || die "从 $host_apk 读出的证书不是正好一张：$read_sha"
  hosts+=("$read_sha")
  say "宿主证书（从 $host_apk 读出）：$read_sha"
fi
if [[ -n $host_sha ]]; then
  host_sha=$(printf '%s' "$host_sha" | tr 'A-F' 'a-f' | tr -d ':')
  [[ $host_sha =~ ^[0-9a-f]{64}$ ]] || die "--host-sha256 要 64 位十六进制（冒号可有可无）"
  hosts+=("$host_sha")
fi
host_list=$(printf '%s\n' "${hosts[@]}" | sort -u | paste -sd, -)

# ---- 复制样例和契约库 ----
say "复制样例到 $dest"
mkdir -p "$dest"
(cd "$example" && tar cf - --exclude ./build --exclude ./.gradle --exclude ./app/build --exclude ./tools \
  --exclude ./signing.properties --exclude ./local.properties --exclude ./README.md --exclude ./LICENSE .) \
  | (cd "$dest" && tar xf -)
mkdir -p "$dest/provider-sdk" "$dest/tools/plugin_api" "$dest/LICENSES"
(cd "$sdk" && tar cf - --exclude ./build .) | (cd "$dest/provider-sdk" && tar xf -)
(cd "$api" && tar cf - lib bin LICENSE) | (cd "$dest/tools/plugin_api" && tar xf -)
cp "$here/check-descriptor.sh" "$dest/tools/"
cp "$example/LICENSE" "$dest/LICENSES/Apache-2.0.txt"

# ---- 改包名、类名、pluginId、显示名 ----
pkg_path=${pkg//.//}
for src in main test; do
  from="$dest/app/src/$src/java/example/xwshun/hello"
  [[ -d $from ]] || continue
  mkdir -p "$dest/app/src/$src/java/$pkg_path"
  mv "$from"/* "$dest/app/src/$src/java/$pkg_path/"
  rm -rf "$dest/app/src/$src/java/example"
done
for java in "$dest"/app/src/*/java/"$pkg_path"/*.java; do
  base=$(basename "$java")
  case "$base" in
    HelloProviderService.java) mv "$java" "$(dirname "$java")/ProviderService.java" ;;
    HelloSession.java) mv "$java" "$(dirname "$java")/TerminalSession.java" ;;
    HelloShell.java) mv "$java" "$(dirname "$java")/TerminalShell.java" ;;
    HelloShellTest.java) mv "$java" "$(dirname "$java")/TerminalShellTest.java" ;;
  esac
done
tag="Xw$(printf '%s' "$seg" | perl -pe 's/(^|_)(.)/\U$2/g')"
tag=${tag:0:23}
prompt="$seg> "
export PKG="$pkg" PLUGIN_ID="$plugin_id" NAME="$name" TAG="$tag" PROMPT="$prompt" LICENSE_ID="$license"
find "$dest/app" "$dest/settings.gradle.kts" "$dest/build.gradle.kts" -type f \
  \( -name '*.java' -o -name '*.kts' -o -name '*.xml' -o -name '*.json' \) -print0 | xargs -0 perl -pi -e '
    s/example\.xwshun\.hello/$ENV{PKG}/g;
    s/example\.hello_terminal/$ENV{PLUGIN_ID}/g;
    s/HelloProviderService/ProviderService/g;
    s/HelloSession/TerminalSession/g;
    s/HelloShellTest/TerminalShellTest/g;
    s/HelloShell/TerminalShell/g;
    s/"XwshunHello"/"$ENV{TAG}"/g;
    s/"hello> "/"$ENV{PROMPT}"/g;
    s/Hello 终端（xwshun 插件样例）/$ENV{NAME}/g;
    s/Hello 终端（样例）/$ENV{NAME}/g;
    s/Hello 终端/$ENV{NAME}/g;
    s/"license": "Apache-2.0"/"license": "$ENV{LICENSE_ID}"/g;
  '

# ---- 你自己的签名密钥 ----
say "生成签名密钥 $keystore"
mkdir -p "$(dirname "$keystore")"
password=$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')
# JDK 9 起 keytool 默认建 PKCS12 密钥库：密钥口令和密钥库口令只能是同一个（另给的会被忽略并警告），所以两处写同一个。
"$keytool" -genkeypair -keystore "$keystore" -storetype PKCS12 -alias plugin -keyalg RSA -keysize 3072 -validity 10000 \
  -dname "CN=$seg plugin author" -storepass "$password" -keypass "$password" >/dev/null 2>&1 \
  || die "keytool 生成密钥失败"
chmod 600 "$keystore"
author_sha=$("$keytool" -list -v -keystore "$keystore" -storepass "$password" -alias plugin 2>/dev/null \
  | awk '/SHA256:/{print $2}' | tr -d ':' | tr 'A-F' 'a-f')
umask 077
cat > "$dest/signing.properties" <<EOF
# new-plugin.sh 生成。密码在这里，别提交进 git（.gitignore 已忽略这个文件），也别丢：丢了就没法给插件发新版本。
storeFile=$keystore
storePassword=$password
keyAlias=plugin
keyPassword=$password
EOF
umask 022
{
  echo "xwshunHostSha256=$host_list"
  echo "xwshunSdkDir=provider-sdk"
} >> "$dest/gradle.properties"

cat > "$dest/NOTICE.md" <<EOF
# NOTICE

本工程由 xwshun 插件样例（plugins/example，Apache-2.0，Copyright 2026 xwfe）用 new-plugin.sh 生成。

- \`provider-sdk/\`：xwshun 插件契约库，Apache-2.0，全文见 \`provider-sdk/LICENSE\`。
- \`tools/plugin_api/\`：xwshun 的描述符判定代码（只给 \`tools/check-descriptor.sh\` 用，不编进 APK），Apache-2.0。
- \`app/\` 和构建脚本：从样例改来，Apache-2.0 全文见 \`LICENSES/Apache-2.0.txt\`。保留文件头的原版权行；你自己新写的代码按你选的许可。
EOF

cat > "$dest/README.md" <<EOF
# $name

xwshun 终端插件。包名 \`$pkg\`，pluginId \`$plugin_id\`。由 xwshun 的 \`plugins/example/tools/new-plugin.sh\` 生成。

\`\`\`bash
./gradlew assembleRelease                      # 产物 app/build/outputs/apk/release/app-release.apk
./gradlew :app:testDebugUnitTest               # 会话逻辑（TerminalShell）的 JVM 单测，不用装宿主
tools/check-descriptor.sh app/src/main/res/raw/xwshun_plugin.json --package $pkg --service $pkg.ProviderService
adb install -r app/build/outputs/apk/release/app-release.apk
\`\`\`

- 签名：\`signing.properties\`（密码在里面，别提交）指向 \`$keystore\`。你的证书 SHA-256：\`$author_sha\`，用户批准时拿它核对。
- 信任的宿主证书：\`gradle.properties\` 的 \`xwshunHostSha256\`。
- 会话逻辑在 \`TerminalShell.java\`（纯 Java），接线在 \`TerminalSession.java\`、\`ProviderService.java\`。
- 怎么装、批准、验证、出错怎么查：xwshun 仓库的 \`docs/plugin-authors/\`。
EOF

say "改好的工程：$dest"
echo "   包名 $pkg / pluginId $plugin_id / 显示名 $name / license $license"
echo "   信任的宿主证书：$host_list"
echo "   你的证书 SHA-256：${author_sha}（密钥库 ${keystore}，口令在 $dest/signing.properties）"

# ---- 自查描述符 ----
if command -v dart >/dev/null 2>&1; then
  say "自查描述符"
  "$dest/tools/check-descriptor.sh" "$dest/app/src/main/res/raw/xwshun_plugin.json" \
    --package "$pkg" --service "$pkg.ProviderService" || die "描述符自查没过，上面写了原因"
else
  say "没有 dart，跳过描述符自查（可选的一步，宿主装上插件后会报同样的话）"
fi

if [[ $build -eq 1 ]]; then
  say "构建（第一次要下载 Gradle 和 Android Gradle Plugin）"
  (cd "$dest" && ./gradlew -q assembleRelease) || die "构建失败，看上面 Gradle 的报错；常见原因见 docs/plugin-authors/troubleshooting.md「构建时」"
  apk="$dest/app/build/outputs/apk/release/app-release.apk"
  built_sha=$(apksigner verify --print-certs "$apk" | awk -F': ' '/certificate SHA-256 digest/{print $2}')
  [[ $built_sha == "$author_sha" ]] || die "APK 的签名证书 $built_sha 不是刚生成的那把 $author_sha"
  say "APK：${apk}（签名证书 ${built_sha}）"
  echo "   下一步：adb install -r \"$apk\"，再到宿主「设置 → 插件（实验）」核对证书、批准，用「会话测试」验证。"
else
  echo "   下一步：cd \"$dest\" && ./gradlew assembleRelease，再 adb install，见 docs/plugin-authors/README.md 第 5 步起。"
fi
