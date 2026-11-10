#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 Kindle 端合成所需的全套素材（点阵风格）。

设备上没有 Python，也不能渲染中文，所以这里把所有"字"和"图"都
预先做成小 PNG，设备端只用 fbink 按坐标贴图即可合成整幅画面。

产出：
  assets/digits/<size>/0-9.png     数字（big/mid/small/cal 四套）
  assets/cn/*.png                  中文词（月、日、星期X、天气描述等）
  assets/icons/*.png               天气图标（大 130 / 小 48 两套）
  assets/cal/YYYY-MM.png           月历模板（含月份标题、星期表头、日期数字）
  assets/hl.png                    今天的高亮框
  assets/layout.sh                 所有坐标与字号，设备脚本 source 它
"""

from datetime import date
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "assets"
FONT_PATH = str(ROOT / "fonts" / "msyh.ttc")
FONT_PATH = FONT_PATH if Path(FONT_PATH).exists() else "C:/Windows/Fonts/msyh.ttc"

# ---------- 布局（竖屏 1072x1448，照片上、信息下两栏）----------
W, H = 1072, 1448
PHOTO_H = 730
COL1_X, COL2_X = 36, 556
COL_W = 484

Y_DATE, S_DATE = 800, 48
Y_WEEK, S_WEEK = 866, 34
Y_TIME, S_TIME = 920, 140
Y_RULE1 = 1080
Y_ICON, ICON_R = 1100, 100
Y_TEMP, S_TEMP = 1104, 100
Y_DESC, S_DESC = 1228, 40
Y_RANGE, S_SMALL = 1284, 34
Y_POP = 1332
Y_RULE2 = 1108
Y_FC1, Y_FC2 = 1124, 1176
Y_HUM = 1240
Y_BATT = 1294                     # 电量行：紧贴"更新 xx:xx"下面
Y_CAL = 790
CAL_W, CAL_H = 480, 292
CAL_COL = CAL_W / 7.0
CAL_HEAD = 34
CAL_ROW = 32
CAL_TOP = 56 + CAL_HEAD + 2      # 日历网格第一行的 y 偏移（相对日历模板顶部）
CALENDAR_YEAR = date.today().year
# 月历是"预生成 PNG"，设备端不会算日历，只会按 date 去 cal/YYYY-MM.png 里取。
# 所以必须提前把未来若干年都生成好，否则跨年那天月历会凭空消失。
CAL_YEARS = 10

# 单通道灰度值（PIL 的 L 模式不接受三元组颜色）
INK, MID, SOFT, LINE, BG = 0, 80, 110, 170, 255


def font(size):
    return ImageFont.truetype(FONT_PATH, size)


def text_size(d, s, size):
    b = d.textbbox((0, 0), s, font=font(size))
    return b[2] - b[0], b[3] - b[1]


# ---------- 数字 ----------
DIGIT_SETS = {"big": S_TIME, "mid": S_TEMP, "date": S_DATE,
              "week": S_WEEK, "small": S_SMALL, "cal": 28}

# 符号 → 文件名。注意：% 和 ⋅ 的字形宽度远大于数字宽度的 0.52 倍，
# 画布如果固定成 SYM_W 就会把字形右侧裁掉（实测 % 在 34px 字号下宽 30px，
# 而画布只有 17px，右半边整个没了 —— 这就是"湿度 45% 的百分号被切掉"）。
SYM_CHARS = [(":", "colon"), ("°", "deg"), ("–", "dash"), ("⋅", "dot"), ("%", "pct")]
PCT_W = {}


def make_digits():
    _m = ImageDraw.Draw(Image.new("L", (8, 8), 255))   # 只用来量字宽
    for name, s in DIGIT_SETS.items():
        d0 = OUT / "digits" / name
        d0.mkdir(parents=True, exist_ok=True)
        cw = int(s * 0.62)
        ch = int(s * 1.30)
        sw = int(s * 0.52)
        for c in "0123456789":
            img = Image.new("L", (cw, ch), 255)
            d = ImageDraw.Draw(img)
            d.text((cw / 2, ch / 2), c, font=font(s), fill=0, anchor="mm")
            img.save(d0 / f"{c}.png", "PNG", optimize=True)
        # 常用符号：默认画布仍取 SYM_W（layout.sh 里的步进宽度靠它对齐，
        # 数字串定位才不会跑偏）；字形比画布宽时改用"刚好装下"的宽度并从
        # 左边缘开始画，保证不裁切。
        for ch_, nm in SYM_CHARS:
            adv = int(round(_m.textlength(ch_, font=font(s))))
            if adv + 2 > sw:
                wpx, anchor, tx = adv + 3, "lm", 1
            else:
                wpx, anchor, tx = sw, "mm", sw / 2
            img = Image.new("L", (wpx, ch), 255)
            d = ImageDraw.Draw(img)
            d.text((tx, ch / 2), ch_, font=font(s), fill=0, anchor=anchor)
            img.save(d0 / f"{nm}.png", "PNG", optimize=True)
            if nm == "pct":
                PCT_W[name] = wpx


# ---------- 中文词 ----------
CN_WORDS = [
    "月", "日", "年",
    "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日",
    "今天", "明天", "后天",
    "降水", "湿度", "体感", "日出", "日落", "更新",
    "电量", "充电中", "已充满",
    "晴", "多云", "阴", "小雨", "中雨", "大雨", "暴雨",
    "雷阵雨", "阵雨", "小雪", "中雪", "大雪", "雨夹雪",
    "雾", "霾", "浮尘", "沙尘暴", "风", "大风", "未知",
]
CN_SETS = {"date": S_DATE, "week": S_WEEK, "desc": S_DESC, "small": S_SMALL}


def make_cn():
    """中文词模画布宽度固定为 字数×字号，设备端可直接按 x += 字数×字号 累加定位。"""
    for setname, s in CN_SETS.items():
        d0 = OUT / "cn" / setname
        d0.mkdir(parents=True, exist_ok=True)
        for w in CN_WORDS:
            img = Image.new("L", (len(w) * s, int(s * 1.34)), 255)
            d = ImageDraw.Draw(img)
            d.text((img.width / 2, img.height / 2), w, font=font(s), fill=0, anchor="mm")
            img.save(d0 / f"{w}.png", "PNG", optimize=True)


# ---------- 天气图标 ----------
def draw_icon(size, kind):
    img = Image.new("L", (size, size), 255)
    d = ImageDraw.Draw(img)
    r = size * 0.5
    cx = cy = size / 2
    lw = max(2, int(size * 0.045))

    def sun(rr, ox=0, oy=0, rays=True):
        x, y = cx + ox, cy + oy
        d.ellipse((x - rr * 0.52, y - rr * 0.52, x + rr * 0.52, y + rr * 0.52), outline=0, width=lw)
        if rays:
            import math
            for i in range(8):
                a = i * math.pi / 4
                d.line((x + math.cos(a) * rr * 0.66, y + math.sin(a) * rr * 0.66,
                        x + math.cos(a) * rr * 0.92, y + math.sin(a) * rr * 0.92), fill=0, width=lw)

    def cloud(s=1.0, oy=0.0, ox=0.0):
        w = r * 1.86 * s
        h = r * 1.10 * s
        x0, y0 = cx + ox - w / 2, cy + oy - h / 2
        d.ellipse((x0 + w * 0.03, y0 + h * 0.42, x0 + w * 0.45, y0 + h * 1.00), outline=0, width=lw)
        d.ellipse((x0 + w * 0.26, y0 + h * 0.04, x0 + w * 0.72, y0 + h * 0.84), outline=0, width=lw)
        d.ellipse((x0 + w * 0.55, y0 + h * 0.36, x0 + w * 0.97, y0 + h * 1.00), outline=0, width=lw)

    def drops(k, long=0.5, slant=0.14):
        for i in range(k):
            px = cx + r * (-0.42 + i * 0.42)
            d.line((px, cy + r * 0.34, px - r * slant, cy + r * (0.34 + long)), fill=0, width=lw)

    if kind == "sun":
        sun(r * 0.9)
    elif kind == "suncloud":
        sun(r * 0.52, ox=-r * 0.40, oy=-r * 0.40)
        cloud(0.92, oy=r * 0.34)
    elif kind == "cloud":
        cloud(1.0)
    elif kind == "fog":
        cloud(0.9, oy=-r * 0.20)
        for i in range(3):
            y = cy + r * (0.40 + i * 0.22)
            d.line((cx - r * 0.74, y, cx + r * 0.74, y), fill=0, width=lw)
    elif kind == "haze":
        cloud(0.82, oy=-r * 0.28)
        for i in range(4):
            y = cy + r * (0.34 + i * 0.19)
            d.line((cx - r * 0.70, y, cx + r * 0.70, y), fill=170, width=lw)
    elif kind == "drizzle":
        cloud(1.0, oy=-r * 0.26)
        drops(3, 0.30, 0.10)
    elif kind == "rain":
        cloud(1.0, oy=-r * 0.26)
        drops(3, 0.56)
    elif kind == "heavyrain":
        cloud(1.0, oy=-r * 0.30)
        drops(4, 0.68, 0.18)
    elif kind == "storm":
        cloud(1.0, oy=-r * 0.32)
        d.line((cx + r * 0.12, cy + r * 0.28, cx - r * 0.14, cy + r * 0.64,
                cx + r * 0.06, cy + r * 0.64, cx - r * 0.12, cy + r * 0.96),
               fill=0, width=lw, joint="curve")
    elif kind == "snow":
        cloud(1.0, oy=-r * 0.28)
        for i in range(3):
            px, py = cx + r * (-0.42 + i * 0.42), cy + r * 0.62
            for dx in (-0.09, 0, 0.09):
                d.line((px + r * dx, py - r * 0.14, px + r * dx, py + r * 0.14), fill=0, width=lw)
            d.line((px - r * 0.10, py, px + r * 0.10, py), fill=0, width=lw)
    else:
        cloud(1.0)
    return img


ICON_KINDS = ["sun", "suncloud", "cloud", "fog", "haze",
              "drizzle", "rain", "heavyrain", "storm", "snow"]


def make_icons():
    for name, s in [("big", ICON_R), ("small", 48)]:
        d0 = OUT / "icons" / name
        d0.mkdir(parents=True, exist_ok=True)
        for k in ICON_KINDS:
            draw_icon(s, k).save(d0 / f"{k}.png", "PNG", optimize=True)


# ---------- 月历模板 ----------
def make_calendars(year):
    d0 = OUT / "cal"
    d0.mkdir(parents=True, exist_ok=True)
    import calendar as cal
    for month in range(1, 13):
        img = Image.new("L", (CAL_W, CAL_H), 255)
        d = ImageDraw.Draw(img)

        # 月份标题
        d.text((0, 2), f"{year} 年 {month} 月", font=font(34), fill=INK, anchor="la")
        d.line((0, 46, CAL_W, 46), fill=INK, width=2)

        # 星期表头
        y = 56
        for i, wd in enumerate("一二三四五六日"):
            x = CAL_COL * (i + 0.5)
            d.text((x, y), wd, font=font(24), fill=SOFT, anchor="ma")

        # 日期数字
        py = y + CAL_HEAD + 2
        for r, week in enumerate(cal.monthcalendar(year, month)):
            for i, day in enumerate(week):
                if day == 0:
                    continue
                x = CAL_COL * (i + 0.5)
                yy = py + r * CAL_ROW
                d.text((x, yy), str(day), font=font(26), fill=MID, anchor="ma")

        img.save(d0 / f"{year}-{month:02d}.png", "PNG", optimize=True)


def make_hl_digits():
    """今天的高亮：黑底白字的反色数字，直接盖在日历格子上，不依赖 PNG 透明。"""
    d0 = OUT / "digits" / "hl"
    d0.mkdir(parents=True, exist_ok=True)
    for day in range(1, 32):
        img = Image.new("L", (int(CAL_COL) - 8, CAL_ROW - 2), 0)
        d = ImageDraw.Draw(img)
        d.text((img.width / 2, img.height / 2), str(day), font=font(26), fill=255, anchor="mm")
        img.save(d0 / f"{day}.png", "PNG", optimize=True)


# ---------- 分隔线 ----------
def make_rules():
    for nm, wdt in [("rule1", 2), ("rule2", 1)]:
        img = Image.new("L", (CAL_W, 4), 255)
        d = ImageDraw.Draw(img)
        d.line((0, 2, CAL_W, 2), fill=LINE, width=wdt)
        img.save(OUT / f"{nm}.png", "PNG", optimize=True)


# ---------- layout.sh ----------
def write_layout(year):
    lines = [
        "# 由 make_assets.py 自动生成，勿手改",
        f"W={W}", f"H={H}", f"PHOTO_H={PHOTO_H}",
        f"COL1_X={COL1_X}", f"COL2_X={COL2_X}", f"COL_W={COL_W}",
        f"Y_DATE={Y_DATE}", f"S_DATE={S_DATE}",
        f"Y_WEEK={Y_WEEK}", f"S_WEEK={S_WEEK}",
        f"Y_TIME={Y_TIME}", f"S_TIME={S_TIME}",
        f"S_BIG={S_TIME}", f"S_MID={S_TEMP}",
        f"Y_RULE1={Y_RULE1}", f"Y_RULE2={Y_RULE2}",
        f"Y_ICON={Y_ICON}", f"ICON_R={ICON_R}",
        f"Y_TEMP={Y_TEMP}", f"S_TEMP={S_TEMP}",
        f"Y_DESC={Y_DESC}", f"S_DESC={S_DESC}",
        f"Y_RANGE={Y_RANGE}", f"Y_POP={Y_POP}", f"S_SMALL={S_SMALL}",
        f"Y_FC1={Y_FC1}", f"Y_FC2={Y_FC2}", f"Y_HUM={Y_HUM}", f"Y_BATT={Y_BATT}",
        f"Y_CAL={Y_CAL}", f"CAL_W={CAL_W}", f"CAL_H={CAL_H}",
        f"CAL_COL={CAL_COL:.3f}", f"CAL_COL_I={int(CAL_COL)}",
        f"HL_W={int(CAL_COL) - 8}",
        f"CAL_HEAD={CAL_HEAD}", f"CAL_ROW={CAL_ROW}", f"CAL_TOP={CAL_TOP}",
        f"CALENDAR_YEAR={year}",
        f"DIGIT_W_BIG={int(S_TIME * 0.62)}", f"DIGIT_W_MID={int(S_TEMP * 0.62)}",
        f"DIGIT_W_DATE={int(S_DATE * 0.62)}", f"DIGIT_W_WEEK={int(S_WEEK * 0.62)}",
        f"DIGIT_W_SMALL={int(S_SMALL * 0.62)}", f"DIGIT_W_CAL={int(28 * 0.62)}",
        f"SYM_W_BIG={int(S_TIME * 0.52)}", f"SYM_W_MID={int(S_TEMP * 0.52)}",
        f"SYM_W_DATE={int(S_DATE * 0.52)}", f"SYM_W_SMALL={int(S_SMALL * 0.52)}",
        # % 的实际图片宽度（比 SYM_W 宽），后面还要接字时用它算偏移
        f"PCT_W_BIG={PCT_W.get('big', int(S_TIME * 0.52))}",
        f"PCT_W_MID={PCT_W.get('mid', int(S_TEMP * 0.52))}",
        f"PCT_W_DATE={PCT_W.get('date', int(S_DATE * 0.52))}",
        f"PCT_W_SMALL={PCT_W.get('small', int(S_SMALL * 0.52))}",
        "ASSETS=/mnt/us/kindle-photo-wall/assets",
        "PHOTOS=/mnt/us/kindle-photo-wall/photos",
    ]
    # newline="\n" 必须显式指定：Windows 下 text 模式会把 \n 翻成 \r\n，
    # 设备端 source 后每个坐标都带 \r，fbink 会报 trailing characters 全部失败
    (OUT / "layout.sh").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    year = date.today().year
    make_digits()
    make_cn()
    make_icons()
    make_calendars(year)
    # 一次性把未来 10 年的月历都做出来（120 张，约 1 MB），跨年不用管
    for _y in range(year + 1, year + CAL_YEARS):
        make_calendars(_y)
    make_hl_digits()
    make_rules()
    write_layout(year)

    n = sum(1 for _ in OUT.rglob("*.png"))
    total = sum(p.stat().st_size for p in OUT.rglob("*.png"))
    print(f"素材生成完成：{n} 张 PNG，共 {total/1024:.0f} KB")
    print(f"输出: {OUT}")
    for sub in sorted(p for p in OUT.iterdir() if p.is_dir()):
        c = len(list(sub.glob('*.png')))
        print(f"  {sub.name}/  {c} 张")


if __name__ == "__main__":
    main()
