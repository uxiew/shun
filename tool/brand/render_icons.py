"""从 Gemini 出的乌鸦图生成全部 App 图标。

用法（在仓库根目录下）：

    ../.toolchain/pyenv/bin/python tool/brand/render_icons.py                    # 覆盖写入各平台图标
    ../.toolchain/pyenv/bin/python tool/brand/render_icons.py --preview out.png  # 只出预览图，不碰仓库

缺 Pillow 会报 "No module named 'PIL'"：
    ../.toolchain/pyenv/bin/python -m pip install pillow==12.3.0 numpy==2.5.4

源图 gemini_dark_logo.png 是所有者 2026-10-10 用 Gemini 生成的深色版（原件和对话记录在仓库外
../SSH移动应用Logo设计/）。它是一张“图标效果图”：乌鸦外面画了一圈圆角边框，右下角有 Gemini 水印，
不能直接缩放当图标——系统还会再套一层圆角/圆形遮罩，桌面上会出现框中框，水印也会跟着进去。

所以这里只取乌鸦：按框内背景反推每个像素的透明度（霓虹光晕保留下来），贴到一张新画的、
和原图同色调的渐变底上。边框、网格纹理、水印都不要。换源图时，框内范围 PANEL 要重新量。

生成物（都提交进仓库，手改会在下次生成时被覆盖）：
- Android 旧版图标 mipmap-*/ic_launcher.png：只给 API 24、25 用，自带圆角和透明边。
- Android 自适应图标三层 ic_launcher_{background,foreground,monochrome}.png：API 26+ 用，
  由 mipmap-anydpi-v26/ic_launcher.xml 拼起来。画布 108dp，桌面只露出中间 72dp，乌鸦整只
  缩在直径 66dp 的安全圆里，圆形、方形遮罩都切不到。monochrome 是 Android 13 主题图标用的单色线稿。
- iOS AppIcon 全套：铺满不留圆角（系统自己切），不带透明通道（带透明通道的 1024 图上架会被拒）。
- assets/icon.png：1024 的完整图标。
- assets/brand/header_icon.png：首页标题旁的小图标，28dp 按 4 倍像素出。
"""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SOURCE = HERE / 'gemini_dark_logo.png'

# 源图里内框以内的范围（左, 上, 右, 下），往里收了几像素避开框线的光晕。
PANEL = (212, 190, 812, 832)
# 乌鸦在新图标里的宽度占比。原效果图里乌鸦占框宽 87%，尾巴几乎贴边，套上系统遮罩会被切掉。
ART_WIDTH = 0.70
# 自适应图标：乌鸦离中心最远的一点不超过 33dp（安全圆半径），画布 108dp。
SAFE_RADIUS = 33 / 108
VISIBLE = 72 / 108
# 透明度低于这个值当成背景噪点（框内那层淡网格大约 0.02~0.04）。
NOISE_FLOOR = 0.05


def load_source():
    return np.asarray(Image.open(SOURCE).convert('RGB')).astype(np.float64)


def backdrop(src):
    """估计框内背景：先粗略圈出线条，剩下的像素按 24px 分块取中位数，再平滑放大。"""
    left, top, right, bottom = PANEL
    panel = src[top:bottom, left:right]
    rough = np.median(panel, axis=1, keepdims=True)
    rough_alpha = ((panel - rough) / (255 - rough)).max(axis=2)
    lines = Image.fromarray((rough_alpha > 0.04).astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(13))
    lines = np.asarray(lines) > 0
    block = 24
    h, w = panel.shape[:2]
    gh, gw = -(-h // block), -(-w // block)
    grid = np.zeros((gh, gw, 3))
    for gy in range(gh):
        for gx in range(gw):
            cell = panel[gy * block:(gy + 1) * block, gx * block:(gx + 1) * block]
            keep = ~lines[gy * block:(gy + 1) * block, gx * block:(gx + 1) * block]
            grid[gy, gx] = np.median(cell[keep], axis=0) if keep.sum() > 20 else np.nan
    # 被乌鸦整块占满的格子没有背景样本，用同一行其他格子的值补。
    for gy in range(gh):
        row = grid[gy]
        bad = np.isnan(row[:, 0])
        if bad.any():
            row[bad] = np.nanmedian(row[~bad], axis=0) if (~bad).any() else np.nanmedian(grid.reshape(-1, 3), axis=0)
    # 分块中位数之间还有起伏，放大前在格子上抹平两遍，否则底色会出现一块块的明暗。
    for _ in range(2):
        padded = np.pad(grid, ((1, 1), (1, 1), (0, 0)), mode='edge')
        grid = (padded[:-2, 1:-1] + padded[2:, 1:-1] + padded[1:-1, :-2] + padded[1:-1, 2:] + 4 * padded[1:-1, 1:-1]) / 8
    channels = [Image.fromarray(grid[..., c].astype(np.float32), mode='F').resize((w, h), Image.BICUBIC)
                for c in range(3)]
    return np.stack([np.asarray(c) for c in channels], axis=2).astype(np.float64)


def raven_region(alpha):
    """只留乌鸦附近：框是圆角的，矩形 PANEL 的四角和上沿还会带进框线的光晕。

    做法：亮线条按 3 倍缩小、膨胀一点把相邻笔画连起来，找连通块；碰到 PANEL 边的块是框线，
    扔掉，剩下的就是乌鸦（身体、钥匙、>_、腿）。再放回原尺寸、往外扩一圈留住光晕。
    """
    step = 3
    h, w = alpha.shape
    strong = Image.fromarray((alpha > 0.25).astype(np.uint8) * 255)
    small = np.asarray(strong.resize((-(-w // step), -(-h // step)), Image.BOX)) > 0
    small = np.asarray(Image.fromarray(small.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(5))) > 0
    sh, sw = small.shape
    seen = np.zeros_like(small)
    keep = np.zeros_like(small)
    for y0, x0 in zip(*np.nonzero(small)):
        if seen[y0, x0]:
            continue
        stack, block = [(y0, x0)], []
        seen[y0, x0] = True
        while stack:
            y, x = stack.pop()
            block.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < sh and 0 <= nx < sw and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        ys, xs = zip(*block)
        if min(ys) > 2 and min(xs) > 2 and max(ys) < sh - 3 and max(xs) < sw - 3:
            keep[ys, xs] = True
    region = Image.fromarray(keep.astype(np.uint8) * 255).resize((w, h), Image.NEAREST)
    region = region.filter(ImageFilter.MaxFilter(25)).filter(ImageFilter.GaussianBlur(6))
    return np.asarray(region).astype(np.float64) / 255


def extract_raven(src):
    """返回框内乌鸦的 RGBA（光晕保留），和框内背景。"""
    left, top, right, bottom = PANEL
    panel = src[top:bottom, left:right]
    bg = backdrop(src)
    alpha = ((panel - bg) / np.maximum(255 - bg, 1)).max(axis=2).clip(0, 1)
    alpha = ((alpha - NOISE_FLOOR) / (1 - NOISE_FLOOR)).clip(0, 1) * raven_region(alpha)
    color = bg + (panel - bg) / np.maximum(alpha, 0.02)[..., None]
    rgba = np.dstack([color.clip(0, 255), alpha * 255]).round().astype(np.uint8)
    return Image.fromarray(rgba, 'RGBA'), bg


def art_box(raven):
    """乌鸦本体的外框（不算淡光晕）和本体离外框中心最远的距离。"""
    a = np.asarray(raven)[..., 3] > 40
    ys, xs = np.nonzero(a)
    box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    radius = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2).max()
    return box, (cx, cy), radius


def sky(size, visible, bg):
    """新画的底：把框内背景拉伸到可见区域；可见区外（自适应图标的出血区）沿用边缘颜色。"""
    channels = [np.asarray(Image.fromarray(bg[..., c].astype(np.float32), mode='F').resize((visible, visible), Image.BICUBIC))
                for c in range(3)]
    pad = (size - visible) // 2
    image = np.pad(np.stack(channels, axis=2), ((pad, size - visible - pad), (pad, size - visible - pad), (0, 0)), mode='edge')
    return Image.fromarray(image.clip(0, 255).round().astype(np.uint8), 'RGB')


def place(canvas_size, raven, scale, center):
    """把乌鸦按比例缩放，外框中心对准画布中心，返回透明画布。"""
    box, (cx, cy), _ = center
    w, h = raven.size
    resized = raven.convert('RGBa').resize((round(w * scale), round(h * scale)), Image.LANCZOS).convert('RGBA')
    layer = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
    layer.alpha_composite(resized, (round(canvas_size / 2 - cx * scale), round(canvas_size / 2 - cy * scale)))
    return layer


def build(raven, bg):
    geometry = art_box(raven)
    box, _, radius = geometry
    art_w = box[2] - box[0]
    big = 1536

    # iOS / assets：整张铺满。
    full = sky(big, big, bg).convert('RGBA')
    full.alpha_composite(place(big, raven, big * ART_WIDTH / art_w, geometry))

    # 自适应图标：画布 108dp，可见 72dp。乌鸦宽度按可见区算，同时不能出安全圆。
    visible = round(big * VISIBLE)
    scale = min(visible * ART_WIDTH / art_w, big * SAFE_RADIUS / radius)
    background = sky(big, visible, bg)
    foreground = place(big, raven, scale, geometry)
    a = np.asarray(foreground)[..., 3].astype(np.float64) / 255
    # 主题图标只认透明度：只留线条主体（光晕会糊成一片），再加粗一点，
    # 不然缩到 48dp 线只剩 1px，系统染色后发灰看不清。
    line = Image.fromarray((((a - 0.2) / 0.35).clip(0, 1) * 255).round().astype(np.uint8))
    line = np.asarray(line.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1)))
    mono = np.dstack([np.full(a.shape + (3,), 255), line]).astype(np.uint8)
    monochrome = Image.fromarray(mono, 'RGBA')

    # 旧版图标：自己切圆角、四周留 1/16 透明边（和原来猫图标一样）。
    inset = big // 16
    inner = full.resize((big - 2 * inset, big - 2 * inset), Image.LANCZOS)
    mask = Image.new('L', inner.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, inner.size[0] - 1, inner.size[1] - 1), radius=round(inner.size[0] * 0.22), fill=255)
    inner.putalpha(mask)
    legacy = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    legacy.alpha_composite(inner, (inset, inset))

    return {'full': full.convert('RGB'), 'legacy': legacy, 'background': background,
            'foreground': foreground, 'monochrome': monochrome}


def sized(image, px):
    if image.mode == 'RGBA':
        return image.convert('RGBa').resize((px, px), Image.LANCZOS).convert('RGBA')
    return image.resize((px, px), Image.LANCZOS)


def save(image, path):
    target = REPO / path
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target, optimize=True)
    print(path)


def write_all(icons):
    res = 'android/app/src/main/res'
    for name, scale in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
        save(sized(icons['legacy'], round(48 * scale)), f'{res}/mipmap-{name}/ic_launcher.png')
        for part in ('background', 'foreground', 'monochrome'):
            save(sized(icons[part], round(108 * scale)), f'{res}/mipmap-{name}/ic_launcher_{part}.png')
    iconset = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    contents = json.loads((REPO / iconset / 'Contents.json').read_text())
    done = set()
    for entry in contents['images']:
        name = entry.get('filename')
        if not name or name in done:
            continue
        done.add(name)
        px = round(float(entry['size'].split('x')[0]) * int(entry['scale'].rstrip('x')))
        save(sized(icons['full'], px), f'{iconset}/{name}')
    save(sized(icons['full'], 1024), 'assets/icon.png')
    save(rounded(sized(icons['full'], 112), 0.22), 'assets/brand/header_icon.png')


def rounded(image, ratio):
    out = image.convert('RGBA')
    mask = Image.new('L', out.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, out.size[0] - 1, out.size[1] - 1), radius=round(out.size[0] * ratio), fill=255)
    out.putalpha(mask)
    return out


def circle_crop(adaptive, px):
    """模拟 Pixel 桌面：背景、前景叠好，取中间 72dp，切成圆。"""
    size = adaptive.size[0]
    margin = round(size * (1 - VISIBLE) / 2)
    visible = adaptive.crop((margin, margin, size - margin, size - margin))
    out = visible.convert('RGBA').resize((px, px), Image.LANCZOS)
    mask = Image.new('L', (px, px), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, px - 1, px - 1), fill=255)
    out.putalpha(mask)
    return out


def preview(icons, out):
    sheet = Image.new('RGB', (860, 600), (236, 236, 241))
    sheet.paste(rounded(sized(icons['full'], 420), 0.22), (30, 30), rounded(sized(icons['full'], 420), 0.22))
    adaptive = icons['background'].convert('RGBA')
    adaptive.alpha_composite(icons['foreground'])
    themed = Image.new('RGBA', adaptive.size, (214, 227, 255, 255))
    tint = Image.new('RGBA', adaptive.size, (27, 58, 115, 255))
    themed.paste(tint, (0, 0), icons['monochrome'])
    for img, xy, px in [(adaptive, (480, 30), 180), (themed, (480, 240), 180), (adaptive, (690, 96), 48)]:
        c = circle_crop(img, px)
        sheet.paste(c, xy, c)
    small = rounded(sized(icons['full'], 48), 0.22)
    sheet.paste(small, (690, 186), small)
    legacy = sized(icons['legacy'], 96)
    sheet.paste(legacy, (666, 270), legacy)
    # 首页标题区按 1:1 摆（标题图标 28dp，这里按 2 倍像素放 56px）。
    draw = ImageDraw.Draw(sheet)
    draw.rounded_rectangle((30, 480, 440, 570), radius=14, fill=(14, 20, 36))
    draw.rounded_rectangle((460, 480, 830, 570), radius=14, fill=(255, 255, 255))
    header = Image.open(REPO / 'assets/brand/header_icon.png') if (REPO / 'assets/brand/header_icon.png').exists() else rounded(sized(icons['full'], 112), 0.22)
    h56 = header.resize((56, 56), Image.LANCZOS)
    sheet.paste(h56, (50, 497), h56)
    sheet.paste(h56, (480, 497), h56)
    sheet.save(out)
    print(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--preview')
    args = parser.parse_args()
    raven, bg = extract_raven(load_source())
    icons = build(raven, bg)
    if args.preview:
        preview(icons, args.preview)
    else:
        write_all(icons)


if __name__ == '__main__':
    main()
