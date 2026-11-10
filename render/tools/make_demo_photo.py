#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成一张演示用的风景图，用来预览排版效果。真实使用请换成自己的照片。"""

import math
import random
from PIL import Image, ImageDraw, ImageFilter

W, H = 1600, 2200
random.seed(7)

img = Image.new("RGB", (W, H), (255, 255, 255))
d = ImageDraw.Draw(img)

# 天空渐变
horizon = 1460
for y in range(horizon):
    t = y / horizon
    g = int(96 + 120 * (t ** 1.5))
    b = int(86 + 128 * (t ** 1.4))
    r = int(88 + 126 * (t ** 1.6))
    d.line((0, y, W, y), fill=(r, g, b))

# 太阳光晕
glow = Image.new("L", (W, H), 0)
gd = ImageDraw.Draw(glow)
sun_x, sun_y, sun_r = 1080, 470, 92
gd.ellipse((sun_x - sun_r * 4.2, sun_y - sun_r * 4.2,
            sun_x + sun_r * 4.2, sun_y + sun_r * 4.2), fill=90)
gd.ellipse((sun_x - sun_r * 1.9, sun_y - sun_r * 1.9,
            sun_x + sun_r * 1.9, sun_y + sun_r * 1.9), fill=170)
gd.ellipse((sun_x - sun_r, sun_y - sun_r, sun_x + sun_r, sun_y + sun_r), fill=255)
glow = glow.filter(ImageFilter.GaussianBlur(70))
img.paste(Image.new("RGB", (W, H), (255, 250, 235)), (0, 0), glow)

d = ImageDraw.Draw(img)


def ridge(base_y, amp, tone, seed, sharp=True):
    rnd = random.Random(seed)
    pts = [(0, H)]
    x = 0
    step = 60
    y = base_y
    while x <= W + step:
        y = base_y + math.sin(x / 320.0 + seed) * amp * 0.6 + rnd.uniform(-amp * 0.35, amp * 0.35)
        pts.append((x, y))
        x += step
    pts += [(W, H)]
    d.polygon(pts, fill=tone)


ridge(1120, 130, (172, 176, 182), 1)
ridge(1260, 150, (140, 145, 152), 2)
ridge(1400, 120, (108, 113, 120), 3)
ridge(1560, 90, (74, 78, 84), 4)

# 前景坡地
d.polygon([(0, H), (0, 1780), (260, 1700), (620, 1760), (980, 1680), (1350, 1740),
           (W, 1700), (W, H)], fill=(38, 40, 44))

# 一棵孤树
tx, ty = 1180, 1745
d.rectangle((tx - 7, ty - 210, tx + 7, ty), fill=(28, 29, 32))
for i, (dx, dy, rw, rh) in enumerate([(0, -230, 92, 76), (-52, -190, 66, 56),
                                     (54, -196, 70, 58), (0, -168, 78, 54)]):
    d.ellipse((tx + dx - rw, ty + dy - rh, tx + dx + rw, ty + dy + rh), fill=(30, 32, 35))

# 颗粒
noise = Image.effect_noise((W, H), 26).convert("RGB")
img = Image.blend(img, noise, 0.055)

# 暗角
mask = Image.radial_gradient("L").resize((W, H))
mask = mask.filter(ImageFilter.GaussianBlur(160))
dark = Image.new("RGB", (W, H), (18, 20, 24))
img = Image.composite(dark, img, mask.point(lambda v: max(0, int((v - 90) * 0.85))))

img.save("demo-photo.jpg", quality=90)
print("demo-photo.jpg", img.size)
