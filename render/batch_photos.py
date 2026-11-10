#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
照片批量预处理 —— 把一堆照片转成 Kindle 能直接贴图的灰度 PNG。

为什么要在电脑上做：Kindle 没有图像处理能力（没有 Python/Pillow），
所以照片的裁切、灰度、对比度、抖动全部在电脑上一次做完，设备端
只需要 fbink 贴图，零算力。

用到的处理，都是为了 e-ink 屏幕好看：
  1. EXIF 方向校正        —— 手机竖拍的照片不会横躺
  2. 中心/主体裁切        —— 填满面板，不留白边
  3. 自动对比度 + 黑点白点 —— e-ink 对比度低，必须先把层次拉开
  4. 感知亮度灰度          —— 不是简单 RGB 平均，符合人眼
  5. 轻微锐化             —— 抵消缩放和抖动带来的模糊
  6. Floyd-Steinberg 抖动  —— 把灰阶打散成点阵颗粒，还原层次

用法：
    py -3.11 batch_photos.py                          # 处理 photos/ 全部，输出 836x1072
    py -3.11 batch_photos.py --size 1072x1448         # 竖屏全幅
    py -3.11 batch_photos.py --size 1448x1072         # 横屏全幅
    py -3.11 batch_photos.py --onebit                 # 输出纯黑白（A2 快刷用）
    py -3.11 batch_photos.py --src D:/照片 --out D:/out
"""

import argparse
import shutil
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter, ImageOps

HERE = Path(__file__).resolve().parent
SUFFIX = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}


def parse_size(s):
    w, h = s.lower().replace("*", "x").split("x")
    return int(w), int(h)


def fit_cover(img, size):
    """等比缩放后中心裁切，填满目标尺寸（不拉伸、不留白）。"""
    tw, th = size
    sw, sh = img.size
    scale = max(tw / sw, th / sh)
    nw, nh = int(round(sw * scale)), int(round(sh * scale))
    img = img.resize((nw, nh), Image.LANCZOS)
    left = (nw - tw) // 2
    top = (nh - th) // 2
    return img.crop((left, top, left + tw, top + th))


def normalize(im):
    """拉开对比度：先按 0.5% 分位裁掉极端值，再线性拉伸到全范围。"""
    hist = im.histogram()
    total = sum(hist)
    if total == 0:
        return im
    lo_cut, hi_cut = total * 0.005, total * 0.995
    acc, lo, hi = 0, 0, 255
    for v, c in enumerate(hist):
        acc += c
        if acc >= lo_cut:
            lo = v
            break
    acc = 0
    for v, c in enumerate(hist):
        acc += c
        if acc >= hi_cut:
            hi = v
            break
    if hi <= lo:
        return im
    # 留一点余量，避免纯黑纯白死区
    return im.point(lambda p: max(0, min(255, int((p - lo) * 255 / (hi - lo)))))


def process(src: Path, dst_dir: Path, size, onebit: bool, contrast: float, sharp: float):
    img = Image.open(src)
    img = ImageOps.exif_transpose(img)
    if img.mode in ("RGBA", "LA", "P"):
        bg = Image.new("RGB", img.size, (255, 255, 255))
        img = img.convert("RGBA")
        bg.paste(img, mask=img.split()[-1])
        img = bg
    else:
        img = img.convert("RGB")

    img = fit_cover(img, size)

    # 感知亮度（ITU-R BT.601），比 PIL 默认的 L 更贴近人眼
    gray = img.convert("L")

    gray = normalize(gray)
    if contrast and abs(contrast - 1.0) > 1e-3:
        gray = ImageEnhance.Contrast(gray).enhance(contrast)
    if sharp > 0:
        gray = gray.filter(ImageFilter.UnsharpMask(radius=2, percent=int(sharp * 100), threshold=3))

    if onebit:
        out = gray.convert("1", dither=Image.FLOYDSTEINBERG)
        out = out.convert("L")           # FBInk 读 8bit，值仍是 0/255
    else:
        out = gray

    name = src.stem + ".png"
    out.save(dst_dir / name, "PNG", optimize=True)
    return name, out.size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(HERE / "photos"))
    ap.add_argument("--out", default=str(HERE / "photos_ready"))
    ap.add_argument("--size", default="1072x760", help="目标尺寸，竖屏机型默认 1072x760")
    ap.add_argument("--onebit", action="store_true", help="输出纯黑白抖动图（A2 快刷、无闪）")
    ap.add_argument("--contrast", type=float, default=1.12)
    ap.add_argument("--sharp", type=float, default=0.6)
    ap.add_argument("--limit", type=int, default=0, help="只处理前 N 张（调试用）")
    a = ap.parse_args()

    src_dir, out_dir = Path(a.src), Path(a.out)
    size = parse_size(a.size)
    if not src_dir.is_dir():
        raise SystemExit(f"照片目录不存在: {src_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)

    files = sorted(p for p in src_dir.iterdir() if p.suffix.lower() in SUFFIX)
    if a.limit:
        files = files[: a.limit]
    if not files:
        raise SystemExit(f"目录里没有图片: {src_dir}")

    print(f"源: {src_dir}  共 {len(files)} 张")
    print(f"目标尺寸: {size[0]}x{size[1]}  模式: {'1-bit 抖动' if a.onebit else '8-bit 灰度'}")
    print("-" * 58)

    total = 0
    for i, f in enumerate(files, 1):
        try:
            name, sz = process(f, out_dir, size, a.onebit, a.contrast, a.sharp)
            total += (out_dir / name).stat().st_size
            print(f"[{i:3}/{len(files)}] {f.name[:36]:<36} -> {name[:30]:<30} {sz[0]}x{sz[1]}")
        except Exception as e:
            print(f"[{i:3}/{len(files)}] {f.name}  失败: {type(e).__name__}: {e}")

    n = len(list(out_dir.glob("*.png")))
    print("-" * 58)
    print(f"完成：{n} 张，共 {total / 1048576:.1f} MB，平均 {total / max(n,1) / 1024:.0f} KB/张")
    print(f"输出目录: {out_dir}")


if __name__ == "__main__":
    main()
