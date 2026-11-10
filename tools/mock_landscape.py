# -*- coding: utf-8 -*-
"""横屏(1448x1072)版式精确预览 —— 左照片 + 右信息栏"""
from PIL import Image, ImageDraw, ImageFont, ImageOps
import os

W, H = 1448, 1072
PHOTO_W = 1010          # 照片区宽度，右侧 438 为信息栏
FONT = os.path.join(os.path.dirname(__file__), "..", "render", "fonts", "msyh.ttc")
ASSETS = os.path.join(os.path.dirname(__file__), "..", "render", "assets")

photo = Image.open(os.path.join(os.path.dirname(__file__), "..",
                                "C:/Users/Administrator/AppData/Local/Temp/newphoto/out/cat_umbrella.png"))

img = Image.new("L", (W, H), 255)
draw = ImageDraw.Draw(img)


def f(size):
    return ImageFont.truetype(FONT, size)


def text(x, y, s, size, fill=0, anchor="la"):
    draw.text((x, y), s, font=f(size), fill=fill, anchor=anchor)


def hline(x0, x1, y):
    draw.line((x0, y, x1, y), fill=200, width=2)


# ---- 照片：等比铺满照片区、居中裁切 ----
pw, ph = photo.size
scale = max(PHOTO_W / pw, H / ph)
nw, nh = round(pw * scale), round(ph * scale)
photo2 = photo.resize((nw, nh), Image.LANCZOS).convert("L")
sx = (nw - PHOTO_W) // 2
sy = (nh - H) // 2
img.paste(photo2.crop((sx, sy, sx + PHOTO_W, sy + H)), (0, 0))

# ---- 右栏 ----
PX = PHOTO_W + 30                       # 内容起始 x
RW = W - PHOTO_W                        # 438
text(PX, 34, "11月8日", 46)
text(PX, 96, "星期日", 30, 140)
text(PX - 8, 134, "21:31", 112)
hline(PX, W - 34, 292)

# 天气
icon = Image.open(os.path.join(ASSETS, "icons", "big", "cloud.png")).convert("L")
img.paste(icon.resize((92, 92), Image.LANCZOS), (PX, 316))
text(PX + 108, 330, "13°", 74)
text(PX + 262, 352, "阴", 32, 120)
text(PX, 446, "10°–17° · 湿度 61%", 28, 90)
hline(PX, W - 34, 496)

# 月历（cal PNG 自带"2026年11月"标题，不要重复画）
cal = Image.open(os.path.join(ASSETS, "cal", "2026-11.png")).convert("L")
CX, CY, CW = PX - 8, 564, 412               # 480x292 → 412x251
k = CW / 480.0
cal = cal.resize((CW, round(292 * k)), Image.LANCZOS)
img.paste(cal, (CX, CY))
# 今天=8日：周一起始网格，第 1 行第 6 列。用 CAL_* 常量按缩放比换算
col_x = (480 / 7.0) * 6.5 * k
row_y = (56 + 34 + 2 + 1 * 32 + 1) * k
bw, bh = (480 / 7.0 - 8) * k, 30 * k
draw.rectangle((CX + col_x - bw / 2, CY + row_y, CX + col_x + bw / 2, CY + row_y + bh), fill=0)
text(CX + col_x, CY + row_y + bh / 2, "8", 20, 255, anchor="mm")

# 底部信息
text(PX, 860, "电量 26%", 28, 90)
text(PX, 916, "更新 21:31", 28, 90)
text(PX, 972, "日出 06:48 · 日落 17:06", 26, 140)

img.save(os.path.join(os.path.dirname(__file__), "landscape_mock.png"))
print("saved", img.size)
