#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
番茄钟 · flip-clock 风格专注页素材（按用户 mockup 设计）。

产出（render/assets/ 下）：
  pomo_ui/card_black.png / card_white.png   翻牌卡片（380x500，含铰链/顶钮/底层）
  pomo_ui/axle.png                          两卡之间的转轴圆点
  pomo_ui/cell_on.png / cell_off.png        进度条格子（32x44）
  pomo_ui/bracket_l.png / bracket_r.png     进度条方括号
  pomo_ui/round_<den>_<n>.png               「第 n / den 轮 · FOCUS MODE」（den=2..8）
  pomo_ui/run_true.png / run_false.png      右上角状态行
  pomo_ui/tomato_label.png / tomato_icon.png / done_label.png / done_tail.png
  pomo_ui/btn_rest.png / btn_go.png / btn_exit.png / btn_reset.png   黑底白字胶囊按钮（休息/继续同热区动态换图）
  pomo_ui/btn_minus.png / btn_start.png / btn_plus.png              调时态按钮（−5分 / 开始 / +5分）
  v2_digits/huge_w/*.png                    翻牌白字（黑底，供黑卡）
  v2_digits/huge_k/*.png                    翻牌黑字（白底，供白卡）

设计约定：所有 PNG 不带 alpha（fbink 整块贴图），
  黑卡上的字模底色=黑(0)、白卡上的字模底色=白(255)，与卡片底色无缝衔接。
可独立运行：py -3.11 render/make_pomo_ui.py   （make_v2.py 全量再生时也会调用）
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "assets"

INK, BG = 0, 255
SANS_B = "C:/Windows/Fonts/msyhbd.ttc"      # 粗黑体：标题/按钮/标签
SANS = "C:/Windows/Fonts/msyh.ttc"

# ---------- 几何常量（设备像素，与 mockup 对应）----------
W, H = 1448, 1072
CARD_W, CARD_H, CARD_GAP = 380, 500, 110
CARD_X0 = (W - 2 * CARD_W - CARD_GAP) // 2          # 289
CARD_Y = 140
DIGIT_SIZE = 260                                     # 翻牌数字字号
BAR_Y = 700                                          # 进度条顶
BAR_CELLS, CELL_W, CELL_H, CELL_GAP = 14, 32, 44, 4
BR_W, BR_H = 30, 64
TOMATO_X, TOMATO_Y = 330, 836                        # TOMATO 行左缘 / 基线
DONE_Y = 906                                         # 今日完成行基线
BTN_Y, BTN_H, BTN_W, BTN_GAP = 952, 100, 240, 60
BTN_X0 = (W - 3 * BTN_W - 2 * BTN_GAP) // 2          # 304
ROUND_X, ROUND_Y = 56, 100                           # 左上角轮次行
RUN_Y = 96                                           # 右上角状态行基线


def fnt(path, size):
    return ImageFont.truetype(path, size)


def text_img(text, size, fill=INK, bg=BG, font_path=SANS_B, pad=2):
    """整行文字烤成 PNG，返回 (img, width)。宽度=实际文本宽+2*pad。"""
    f = fnt(font_path, size)
    w = int(round(f.getlength(text))) + pad * 2
    img = Image.new("L", (w, int(size * 1.35)), bg)
    ImageDraw.Draw(img).text((pad, size), text, font=f, fill=fill, anchor="ls")
    return img, w


def rrect(d, box, r, **kw):
    d.rounded_rectangle(box, radius=r, **kw)


# ---------------------------------------------------------------- 翻牌卡片
def make_cards():
    d0 = OUT / "pomo_ui"
    d0.mkdir(parents=True, exist_ok=True)

    # ---- 黑卡：实心圆角 + 底层堆叠 + 两侧铰链 + 顶钮 ----
    img = Image.new("L", (CARD_W, CARD_H), BG)
    d = ImageDraw.Draw(img)
    face = (10, 0, CARD_W - 10, 462)
    rrect(d, (face[0] + 8, face[1] + 14, face[2] + 4, face[3] + 20), 26, fill=70)   # 底层堆叠
    rrect(d, face, 26, fill=20)                                                     # 卡面
    rrect(d, (0, 208, 36, 280), 10, fill=30, outline=BG, width=4)                   # 左铰链
    rrect(d, (CARD_W - 36, 208, CARD_W, 280), 10, fill=30, outline=BG, width=4)     # 右铰链
    rrect(d, (CARD_W // 2 - 22, 6, CARD_W // 2 + 22, 44), 12, fill=40, outline=BG, width=4)  # 顶钮
    d.line((face[0] + 8, 236, face[2] - 8, 236), fill=45, width=3)                  # 翻转缝
    img.save(d0 / "card_black.png", "PNG", optimize=True)

    # ---- 白卡：白底黑框 + 深灰铰链 + 顶钮 ----
    img = Image.new("L", (CARD_W, CARD_H), BG)
    d = ImageDraw.Draw(img)
    face = (10, 0, CARD_W - 10, 462)
    rrect(d, (face[0] + 8, face[1] + 14, face[2] + 4, face[3] + 20), 26, fill=225)  # 底层堆叠
    rrect(d, face, 26, fill=BG, outline=INK, width=6)                               # 卡面
    rrect(d, (0, 208, 36, 280), 10, fill=60, outline=INK, width=4)                  # 左铰链
    rrect(d, (CARD_W - 36, 208, CARD_W, 280), 10, fill=60, outline=INK, width=4)    # 右铰链
    rrect(d, (CARD_W // 2 - 22, 6, CARD_W // 2 + 22, 44), 12, fill=BG, outline=INK, width=5)  # 顶钮
    d.line((face[0] + 10, 236, face[2] - 10, 236), fill=150, width=3)               # 翻转缝
    # 底部小 logo：番茄简笔（浅灰，不与数字区冲突——数字画布只盖到 y=400）
    _lx, _ly, _s = CARD_W // 2 - 22, 406, 2
    d.ellipse((_lx + 2, _ly + 12, _lx + 42, _ly + 46), outline=170, width=3)        # 果身
    d.polygon([(_lx + 22, _ly + 2), (_lx + 29, _ly + 12), (_lx + 22, _ly + 17), (_lx + 15, _ly + 12)], fill=170)  # 蒂叶
    d.arc((_lx + 10, _ly + 18, _lx + 28, _ly + 38), 120, 220, fill=170, width=3)    # 高光
    img.save(d0 / "card_white.png", "PNG", optimize=True)

    # ---- 转轴圆点（两卡之间）----
    img = Image.new("L", (48, 150), BG)
    d = ImageDraw.Draw(img)
    for cy in (38, 112):
        d.ellipse((7, cy - 17, 41, cy + 17), outline=INK, width=6)
    img.save(d0 / "axle.png", "PNG", optimize=True)


# ---------------------------------------------------------------- 翻牌数字
# 翻牌动画的折线 = 卡面翻转缝（SEAM_Y）在数字画布里的投影：
#   数字画布贴在卡内 y=CARD_DY 处 → 画布内分割线 = SEAM_Y - CARD_DY = 174
SEAM_Y = 236
FLIP_TOP = SEAM_Y - int(DIGIT_SIZE * 0.24)      # 174


def make_card_digits():
    """白字（黑底）供黑卡、黑字（白底）供白卡；无衬线粗体贴近 mockup。

    每个数字额外产出两个半字（翻牌动画用）：
      c_t.png  上半（画布 0..FLIP_TOP）
      c_b.png  下半（画布 FLIP_TOP..ch），顶上 3px 翻板边缘线 —— 混合帧里
               「新上半 + 旧下半」时，这条线就是翻板落下的视觉锚点。
    """
    f = fnt(SANS_B, DIGIT_SIZE)
    dw = max(1, int(round(f.getlength("0"))))
    ch = int(DIGIT_SIZE * 1.30)
    for name, fill, bg, edge in (("huge_w", BG, INK, 90), ("huge_k", INK, BG, 110)):
        d0 = OUT / "v2_digits" / name
        d0.mkdir(parents=True, exist_ok=True)
        for c in "0123456789":
            img = Image.new("L", (dw, ch), bg)
            ImageDraw.Draw(img).text((0, DIGIT_SIZE), c, font=f, fill=fill, anchor="ls")
            img.save(d0 / f"{c}.png", "PNG", optimize=True)
            img.crop((0, 0, dw, FLIP_TOP)).save(d0 / f"{c}_t.png", "PNG", optimize=True)
            bot = img.crop((0, FLIP_TOP, dw, ch))
            ImageDraw.Draw(bot).line((0, 0, dw, 0), fill=edge, width=3)
            bot.save(d0 / f"{c}_b.png", "PNG", optimize=True)
    return dw


# ---------------------------------------------------------------- 进度条
def make_bar():
    d0 = OUT / "pomo_ui"
    # 格子
    for nm, fill, ow in (("cell_on", INK, 0), ("cell_off", BG, 4)):
        img = Image.new("L", (CELL_W, CELL_H), BG)
        d = ImageDraw.Draw(img)
        kw = dict(radius=7, fill=fill)
        if ow:
            kw.update(outline=INK, width=ow)
        d.rounded_rectangle((1, 1, CELL_W - 2, CELL_H - 2), **kw)
        img.save(d0 / f"{nm}.png", "PNG", optimize=True)
    # 方括号（粗壮款，手绘）
    for nm, x_v, x_h0 in (("bracket_l", 0, 0), ("bracket_r", BR_W - 9, BR_W - 19)):
        img = Image.new("L", (BR_W, BR_H), BG)
        d = ImageDraw.Draw(img)
        d.line((x_v, 2, x_v, BR_H - 2), fill=INK, width=9)                  # 竖杆
        d.line((x_h0, 2, x_h0 + 18, 2), fill=INK, width=9)                  # 上横臂
        d.line((x_h0, BR_H - 2, x_h0 + 18, BR_H - 2), fill=INK, width=9)    # 下横臂
        img.save(d0 / f"{nm}.png", "PNG", optimize=True)


# ---------------------------------------------------------------- 文本行 / 按钮 / 图标
def make_texts():
    d0 = OUT / "pomo_ui"
    widths = {}
    # 左上角：第 N / den 轮 · FOCUS MODE（den 覆盖 2..8，POMO_EVERY 随便配）
    for den in range(2, 9):
        for n in range(1, den + 1):
            img, w = text_img(f"第 {n} / {den} 轮 · FOCUS MODE", 44)
            img.save(d0 / f"round_{den}_{n}.png", "PNG", optimize=True)
    # 右上角状态行（右对齐贴图需要宽度）
    for nm, txt in (("run_true", "timer.running = true"), ("run_false", "timer.running = false")):
        img, w = text_img(txt, 34)
        img.save(d0 / f"{nm}.png", "PNG", optimize=True)
        widths[nm.upper()] = w
    # TOMATO 行 / 今日完成行
    img, w = text_img("TOMATO", 40)
    img.save(d0 / "tomato_label.png", "PNG", optimize=True)
    widths["TOMATO_LW"] = w
    img, w = text_img("今日完成：", 40)
    img.save(d0 / "done_label.png", "PNG", optimize=True)
    widths["DONE_LW"] = w
    img, _ = text_img("番茄", 40)
    img.save(d0 / "done_tail.png", "PNG", optimize=True)
    # 胶囊按钮（黑底白字，即触摸热区）：休息(运行中)/继续(已暂停)同热区，动态换图；
    # 调时态（armed）三件套：btn_minus/btn_start/btn_plus（左−5分 中开始 右+5分，
    #   标签里的 5 与 env.conf POMO_STEP 对应，改步长需同步重生成）
    for nm, txt in (("btn_rest", "休息"), ("btn_go", "继续"), ("btn_exit", "退出"), ("btn_reset", "重置"),
                    ("btn_minus", "-5分"), ("btn_start", "开始"), ("btn_plus", "+5分")):
        img = Image.new("L", (BTN_W, BTN_H), BG)
        d = ImageDraw.Draw(img)
        rrect(d, (2, 2, BTN_W - 3, BTN_H - 3), BTN_H // 2 - 2, fill=INK)
        f = fnt(SANS_B, 52)
        d.text((BTN_W / 2, BTN_H / 2), txt, font=f, fill=BG, anchor="mm")   # mm 锚点=中心点，直接给中心
        img.save(d0 / f"{nm}.png", "PNG", optimize=True)
    # 番茄小图标（黑白简笔）
    img = Image.new("L", (48, 52), BG)
    d = ImageDraw.Draw(img)
    d.ellipse((4, 14, 44, 50), outline=INK, width=5)                    # 果身
    d.polygon([(24, 4), (31, 14), (24, 20), (17, 14)], fill=INK)        # 蒂叶
    d.arc((12, 22, 30, 42), 120, 220, fill=INK, width=4)                # 高光
    img.save(d0 / "tomato_icon.png", "PNG", optimize=True)
    return widths


# ---------------------------------------------------------------- 布局常量
def layout_lines(digit_w, widths):
    sw = max(1, int(DIGIT_SIZE * 0.30))
    total_bar = BR_W + 8 + BAR_CELLS * CELL_W + (BAR_CELLS - 1) * CELL_GAP + 8 + BR_W \
        + 20 + 2 * digit_w + 44        # 括号+格子+百分数（约）
    return [
        "# ---- 番茄钟 flip-clock UI（make_pomo_ui.py 生成）----",
        f"POMO_CARD_X0={CARD_X0}", f"POMO_CARD_Y={CARD_Y}",
        f"POMO_CARD_W={CARD_W}", f"POMO_CARD_H={CARD_H}", f"POMO_CARD_GAP={CARD_GAP}",
        f"S_HUGE_W={DIGIT_SIZE}", f"DIGIT_W_HUGE_W={digit_w}", f"SYM_W_HUGE_W={sw}",
        f"S_HUGE_K={DIGIT_SIZE}", f"DIGIT_W_HUGE_K={digit_w}", f"SYM_W_HUGE_K={sw}",
        f"POMO_BAR_Y={BAR_Y}", f"POMO_BAR_CELLS={BAR_CELLS}",
        f"POMO_CELL_W={CELL_W}", f"POMO_CELL_H={CELL_H}", f"POMO_CELL_GAP={CELL_GAP}",
        f"POMO_BR_W={BR_W}", f"POMO_BR_H={BR_H}", f"POMO_BAR_TOTAL={total_bar}",
        f"POMO_TOMATO_X={TOMATO_X}", f"POMO_TOMATO_Y={TOMATO_Y}",
        f"POMO_DONE_Y={DONE_Y}",
        f"POMO_BTN_X0={BTN_X0}", f"POMO_BTN_Y={BTN_Y}", f"POMO_BTN_H={BTN_H}",
        f"POMO_BTN_W={BTN_W}", f"POMO_BTN_GAP={BTN_GAP}",
        f"POMO_ROUND_X={ROUND_X}", f"POMO_ROUND_Y={ROUND_Y}", f"POMO_RUN_Y={RUN_Y}",
        f"POMO_CARD_DY={int(DIGIT_SIZE * 0.24)}",   # 卡内数字贴图 y 偏移（视觉居中）
        f"POMO_FLIP_TOP={FLIP_TOP}",                # 翻牌动画折线（数字画布内 y）
        f"TOMATO_LW={widths['TOMATO_LW']}", f"DONE_LW={widths['DONE_LW']}",
        f"RUN_TRUE_W={widths['RUN_TRUE']}", f"RUN_FALSE_W={widths['RUN_FALSE']}",
    ]


def generate_all():
    make_cards()
    dw = make_card_digits()
    make_bar()
    widths = make_texts()
    return dw, widths


if __name__ == "__main__":
    dw, widths = generate_all()
    print("\n".join(layout_lines(dw, widths)))
