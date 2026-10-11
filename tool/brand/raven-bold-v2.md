# 粗线条候选 v2

2026-10-11，使用内置 imagegen 从 Gemini 深色原稿重绘，保存为 `raven-bold-v2.png`。这是候选素材，正式平台图标尚未替换。

提示词要点：保持朝右乌鸦、钥匙、翅膀上的 `>_`、两只脚和渐变配色；线条约加粗到原稿的 1.8 倍；去掉外框、网格、水印和光晕；透明背景，按 48px 图标的辨识度设计。

输出为 1254×1254 RGBA 位图，并非矢量。新稿包含深蓝色身体填充，因此单色主题图标会呈现剪影，不能视为原线稿的等价替换。正式采用前仍需决定是否接受这一变化，或继续生成无填充版本。

深浅预览使用同一源图，只改变背景：

```sh
../.toolchain/pyenv/bin/python tool/brand/render_icons.py --source tool/brand/raven-bold-v2.png --preview /tmp/raven-dark.png
../.toolchain/pyenv/bin/python tool/brand/render_icons.py --source tool/brand/raven-bold-v2.png --light --preview /tmp/raven-light.png
```

已生成并目视检查深浅预览中的大图、48px、圆形遮罩及标题图标；`git diff --check` 通过。未做桌面真机验证。
