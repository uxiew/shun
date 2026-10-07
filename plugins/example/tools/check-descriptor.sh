#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 xwfe
#
# 构建前自查描述符：用宿主同一套判定代码（plugin_api），报出来的话和宿主插件页上的一字不差。要 Dart SDK（Flutter 自带的也行）。
#
#   tools/check-descriptor.sh app/src/main/res/raw/xwshun_plugin.json --package <applicationId> --service <服务类全名>
#
# 通过退出 0，不通过 1，用法不对 2。不往任何地方写文件（不在仓库里 pub get）：临时生成一份包配置，跑完就删。
# plugin_api 在哪：new-plugin.sh 生成的工程里是 tools/plugin_api；在 xwshun 仓库里直接用 packages/plugin_api。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "$here/plugin_api/lib" ]]; then
  api="$here/plugin_api"
elif [[ -d "$here/../../../packages/plugin_api/lib" ]]; then
  api="$(cd "$here/../../../packages/plugin_api" && pwd)"
else
  echo "找不到 plugin_api（应在 $here/plugin_api 或 xwshun 仓库的 packages/plugin_api）" >&2
  exit 2
fi
if ! command -v dart >/dev/null 2>&1; then
  echo "没有 dart 命令：装 Dart SDK 或 Flutter 后再跑。自查是可选的，宿主装上插件后也会报同样的话。" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
uri="file://$(printf '%s' "$api" | perl -pe 's/([^A-Za-z0-9\/._~-])/sprintf("%%%02X", ord($1))/ge')"
printf '{"configVersion":2,"packages":[{"name":"plugin_api","rootUri":"%s","packageUri":"lib/","languageVersion":"3.12"}]}\n' \
  "$uri" > "$tmp/package_config.json"
set +e
dart --packages="$tmp/package_config.json" "$api/bin/check_descriptor.dart" "$@"
code=$?
set -e
exit $code
