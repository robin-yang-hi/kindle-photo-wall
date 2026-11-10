# -*- coding: utf-8 -*-
"""番茄钟新 UI 本地预览：按 layout 常量拼一帧 1448x1072"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
A = ROOT / "assets"
S = Image.new("L", (1448, 1072), 255)
d = ImageDraw.Draw(S)

CX, CY, CW, CH, GAP = 289, 140, 380, 500, 110
DZ = 260
DW = 160

# 卡片
S.paste(Image.open(A / "pomo_ui/card_black.png"), (CX, CY))
S.paste(Image.open(A / "pomo_ui/card_white.png"), (CX + CW + GAP, CY))
S.paste(Image.open(A / "pomo_ui/axle.png"), (CX + CW + (GAP - 48) // 2, CY + CH // 2 - 90))

# 数字（基线 y = 布局值；stamp 顶 = 基线 - 字号）
by = CY + 62 + DZ
for i, c in enumerate("24"):
    S.paste(Image.open(A / f"v2_digits/huge_w/{c}.png"), (CX + (CW - 2 * DW) // 2 + i * DW, by - DZ))
for i, c in enumerate("17"):
    S.paste(Image.open(A / f"v2_digits/huge_k/{c}.png"), (CX + CW + GAP + (CW - 2 * DW) // 2 + i * DW, by - DZ))

# 进度条
BY, CELLS, CWD, CHT, CG = 700, 14, 32, 44, 4
BRW = 30
bx = (1448 - (BRW + 8 + CELLS * CWD + (CELLS - 1) * CG + 8 + BRW + 20 + 2 * 30 + 44)) // 2
S.paste(Image.open(A / "pomo_ui/bracket_l.png"), (bx, BY + (CHT - 64) // 2))
bx += BRW + 8
filled = 6
for i in range(CELLS):
    nm = "cell_on" if i < filled else "cell_off"
    S.paste(Image.open(A / f"pomo_ui/{nm}.png"), (bx, BY))
    bx += CWD + CG
bx += 8 - CG
S.paste(Image.open(A / "pomo_ui/bracket_r.png"), (bx, BY + (CHT - 64) // 2))
bx += BRW + 20
fnt = ImageFont = None
from PIL import ImageFont
f44 = ImageFont.truetype("C:/Windows/Fonts/times.ttf", 44)
d.text((bx, BY + CHT), "42%", font=f44, fill=0, anchor="ls")

# 文本行 / 按钮
S.paste(Image.open(A / "pomo_ui/round_4_2.png"), (56, 100 - 44))
rt = Image.open(A / "pomo_ui/run_true.png")
S.paste(rt, (1448 - 56 - rt.width, 96 - 34))
S.paste(Image.open(A / "pomo_ui/tomato_label.png"), (330, 836 - 40))
S.paste(Image.open(A / "pomo_ui/tomato_icon.png"), (330 + 200, 836 - 44))
S.paste(Image.open(A / "pomo_ui/done_label.png"), (330, 906 - 40))
S.paste(Image.open(A / "pomo_ui/done_tail.png"), (330 + 40 * 5 + 30, 906 - 40))
for i, nm in enumerate(("btn_rest", "btn_skip", "btn_reset")):
    S.paste(Image.open(A / f"pomo_ui/{nm}.png"), (304 + i * 300, 952))

S.save(ROOT / "pomo_preview.png")
print("saved pomo_preview.png")
