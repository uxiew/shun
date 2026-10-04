#!/bin/bash
# 补回引入 fork 时去掉的字体和示例 wasm（共 51.5 MB，见 third_party/README.md）。
# 只有跑 flterm 自己的字体/渲染测试、或跑它的示例程序时才需要；App 构建用不到。
# 从上游固定提交下载，逐个核对 SHA256，对不上就删掉并报错。
set -euo pipefail
commit=609ee318345230b915fcfb43859202eb08f8422e
root=$(cd "$(dirname "$0")/libghostty" && pwd)
base=https://raw.githubusercontent.com/elias8/libghostty/$commit
while read -r sum path; do
  dest=$root/$path
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -c1-64)" = "$sum" ]; then
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  curl -fsSL --retry 3 -o "$dest" "$base/$path"
  if [ "$(shasum -a 256 "$dest" | cut -c1-64)" != "$sum" ]; then
    rm -f "$dest"
    echo "SHA256 对不上：$path" >&2
    exit 1
  fi
  echo "已取回 $path"
done <<'LIST'
ece02baa478a98f3b6ea0c276c1a9207c6bbdcbde04b8010542f2b0671432438 packages/flterm/example/assets/fonts/JetBrainsMono-Bold.ttf
a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f packages/flterm/example/assets/fonts/JetBrainsMono-Regular.ttf
de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551 packages/flterm/example/assets/fonts/NotoEmoji-Regular.ttf
c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f packages/flterm/example/assets/fonts/NotoSansJP-Regular.ttf
ece02baa478a98f3b6ea0c276c1a9207c6bbdcbde04b8010542f2b0671432438 packages/flterm/test/fixtures/fonts/JetBrainsMono-Bold.ttf
a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f packages/flterm/test/fixtures/fonts/JetBrainsMono-Regular.ttf
7fb39738ab18f10612d6f4595e2e8e47a0afdf34738460442d99cd0c344a4d90 packages/flterm/test/fixtures/fonts/NotoColorEmoji-Regular.ttf
bd6f162fbbd1e9662f5554bd2b4dfe655745145ad201a8e717c8789c8589f4d6 packages/flterm/test/fixtures/fonts/NotoColorEmoji-WindowsSubset.ttf
de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551 packages/flterm/test/fixtures/fonts/NotoEmoji-Regular.ttf
c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f packages/flterm/test/fixtures/fonts/NotoSansJP-Regular.ttf
e7914d8a17a62a597d298fc574f6c95aaad0471bbcf9cf99da55b4897aa1933a packages/flterm/example/assets/libghostty-wasm32-freestanding.wasm
LIST
