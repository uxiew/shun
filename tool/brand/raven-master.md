# 正式乌鸦母版

2026-10-11，内置 imagegen 两次重绘：先从 Gemini 深色原稿生成粗线条透明候选 `raven-bold-v2.png`，再移除候选的身体填充，形成正式 `raven-master.png`。原 Gemini 源图与候选均保留作历史参考。

母版为 1254×1254 RGBA 位图；乌鸦有效宽度 1155px。1024 图标中乌鸦宽约 717px，缩放比例 0.621，没有放大旧的 540px 乌鸦。仍是位图，不宣称矢量或无限清晰。

默认执行 `render_icons.py` 同时生成 Android、iOS、深浅 1024 配套图和深浅标题图标。浅色版将 RGB 明度乘以 0.58，保持 alpha、姿态、朝向和符号完全一致。首页按当前 Flutter 主题选择标题素材。旧 `light_logo.png` 是另一只乌鸦，保留原件但不作正式源图。

Android 单色图标从透明线稿的 alpha 生成，保留钥匙、眼睛、羽毛和终端符号，避免实心剪影。前景缩放为单色描边膨胀预留 4px，所有线条保持在 33dp 安全圆内。iOS 输出为 RGB，系统自行裁圆角。

## 复现

在项目根目录执行：

```sh
../.toolchain/pyenv/bin/python tool/brand/render_icons.py
../.toolchain/pyenv/bin/python tool/brand/render_icons.py --preview tool/brand/preview-dark.png
../.toolchain/pyenv/bin/python tool/brand/render_icons.py --light --preview tool/brand/preview-light.png
```

## 最终编辑提示词

内置 imagegen，输入 `raven-bold-v2.png`，`transparent_background=true`：

> Edit target: supplied right-facing raven app logo. Change ONLY the dark blue body fill: remove ALL interior dark navy/blue filled regions and make them genuinely alpha-transparent, including body, wing, head, beak inside and feet interior. Preserve the thick colorful strokes exactly, all feather contours, eye, key symbol and >_ terminal symbol. Raven must be purely bold gradient LINE ART on alpha transparent background, with see-through negative space between strokes and within the wing and head, not a solid silhouette. Keep current pose, right-facing beak, composition, violet/cyan/magenta gradients, thick crisp smooth lines. Remove stray isolated pixels and ragged edges. No background, no shadow, no glow, no border, no perch. Deliver a sharp high native resolution square PNG, preferably 2048x2048, raven spanning 85% of width. This will be recolored by Android using alpha alone, so all non-stroke interior regions MUST have zero opacity.

请求过 2048px，工具实际返回 1254px；记录和验证均以实际文件为准。
