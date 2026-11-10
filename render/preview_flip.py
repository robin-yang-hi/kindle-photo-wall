# -*- coding: utf-8 -*-
"""翻牌混合帧本地预览：旧 24:17 → 新 23:05 的中间画面。
左卡分钟 24→23 两位都变（混合帧画 23 上半 + 24 下半），右卡 17→05 同理。
检查：折线与卡面装饰缝(y=376)对齐、翻板边线可见、数字无错位。"""
from PIL import Image

A = "render/assets"
W, H = 1448, 1072
img = Image.new("L", (W, H), 255)

card_bk = Image.open(f"{A}/pomo_ui/card_black.png")
card_wt = Image.open(f"{A}/pomo_ui/card_white.png")
axle = Image.open(f"{A}/pomo_ui/axle.png")
CARD_X0, CARD_Y, CARD_W, CARD_GAP = 289, 140, 380, 110
DW, CTOP, FLIP = 160, 62, 174

img.paste(card_bk, (CARD_X0, CARD_Y))
img.paste(card_wt, (CARD_X0 + CARD_W + CARD_GAP, CARD_Y))
img.paste(axle, (CARD_X0 + CARD_W + (CARD_GAP - 48) // 2, CARD_Y + 156))


def mix(x, old, new, style):
    for i in range(2):
        o, n = old[i], new[i]
        if o != n:
            t = Image.open(f"{A}/v2_digits/{style}/{n}_t.png")
            b = Image.open(f"{A}/v2_digits/{style}/{o}_b.png")
            img.paste(t, (x, CARD_Y + CTOP))
            img.paste(b, (x, CARD_Y + CTOP + FLIP))
        else:
            img.paste(Image.open(f"{A}/v2_digits/{style}/{n}.png"), (x, CARD_Y + CTOP))
        x += DW


mx = CARD_X0 + (CARD_W - 2 * DW) // 2
sx = CARD_X0 + CARD_W + CARD_GAP + (CARD_W - 2 * DW) // 2
mix(mx, "24", "23", "huge_w")
mix(sx, "17", "05", "huge_k")

img.crop((CARD_X0 - 20, CARD_Y - 20, CARD_X0 + 2 * CARD_W + CARD_GAP + 20, 640)).save("render/pomo_flip_preview.png")
print("saved render/pomo_flip_preview.png")
