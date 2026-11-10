# -*- coding: utf-8 -*-
"""调时确认页（armed）一次性预览：25:00 暂停态 + 新按钮 −5分/开始/+5分。"""
from PIL import Image

A = "render/assets"
W, H = 1448, 1072
img = Image.new("L", (W, H), 255)

img.paste(Image.open(f"{A}/pomo_ui/card_black.png"), (289, 140))
img.paste(Image.open(f"{A}/pomo_ui/card_white.png"), (289 + 380 + 110, 140))
img.paste(Image.open(f"{A}/pomo_ui/axle.png"), (289 + 380 + (110 - 48) // 2, 140 + 156))

DW = 160
mx = 289 + (380 - 2 * DW) // 2
sx = 289 + 380 + 110 + (380 - 2 * DW) // 2
for i, c in enumerate("25"):
    img.paste(Image.open(f"{A}/v2_digits/huge_w/{c}.png"), (mx + i * DW, 140 + 62))
for i, c in enumerate("00"):
    img.paste(Image.open(f"{A}/v2_digits/huge_k/{c}.png"), (sx + i * DW, 140 + 62))

img.paste(Image.open(f"{A}/pomo_ui/round_4_1.png"), (56, 100 - 44))
img.paste(Image.open(f"{A}/pomo_ui/run_false.png"), (W - 56 - 367, 96 - 34))

BX, BY, BW, GAP = 304, 952, 240, 60
img.paste(Image.open(f"{A}/pomo_ui/btn_minus.png"), (BX, BY))
img.paste(Image.open(f"{A}/pomo_ui/btn_start.png"), (BX + BW + GAP, BY))
img.paste(Image.open(f"{A}/pomo_ui/btn_plus.png"), (BX + 2 * (BW + GAP), BY))

img.crop((40, 40, W - 40, 1072)).save("render/pomo_armed_preview.png")
print("saved render/pomo_armed_preview.png")
