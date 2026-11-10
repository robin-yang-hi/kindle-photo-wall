#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
合成预览 —— 在电脑上模拟设备端的贴图过程。

坐标、字模、叠放顺序与设备脚本 render.sh 完全一致，用来在上机之前
检查排版。改完布局先跑这个，看没问题再拷进 Kindle。
"""

import argparse
import calendar
from datetime import date
from pathlib import Path

from PIL import Image

import make_assets as M

A = M.OUT
WEEKS = "星期一星期二星期三星期四星期五星期六星期日"
DIGIT_W = {"big": int(M.S_TIME * 0.62), "mid": int(M.S_TEMP * 0.62),
           "date": int(M.S_DATE * 0.62), "week": int(M.S_WEEK * 0.62),
           "small": int(M.S_SMALL * 0.62), "cal": int(28 * 0.62)}
SYM = {":": "colon", "°": "deg", "–": "dash", "⋅": "dot", "%": "pct"}


def stamp(img, path, x, y):
    p = A / path
    if not p.exists():
        print(f"  缺素材 {path}")
        return int(x)
    im = Image.open(p).convert("L")
    img.paste(im, (int(x), int(y)))
    return int(x) + im.width


def stamp_mid(img, path, x, y, size):
    p = A / path
    if not p.exists():
        return int(x)
    im = Image.open(p).convert("L")
    img.paste(im, (int(x), int(y - (im.height - size) / 2)))
    return int(x) + im.width


def digits(img, x, y, text, st):
    s = {"big": M.S_TIME, "mid": M.S_TEMP, "date": M.S_DATE,
         "week": M.S_WEEK, "small": M.S_SMALL, "cal": 28}[st]
    for ch in text:
        if ch.isdigit() or ch == " ":
            x = stamp_mid(img, f"digits/{st}/{ch}.png" if ch.isdigit() else "", x, y, s) if ch.isdigit() else x + DIGIT_W[st] // 2
        elif ch in SYM:
            x = stamp_mid(img, f"digits/{st}/{SYM[ch]}.png", x, y, s)
    return int(x)


def cn(img, x, y, word, st):
    s = M.CN_SETS[st]
    p = A / f"cn/{st}/{word}.png"
    if not p.exists():
        p = A / f"cn/{st}/未知.png"
    if not p.exists():
        return int(x)
    im = Image.open(p).convert("L")
    img.paste(im, (int(x), int(y - (im.height - s) / 2)))
    return int(x) + im.width


def digit_w(st, text):
    s = {"big": M.S_TIME, "mid": M.S_TEMP, "date": M.S_DATE,
         "week": M.S_WEEK, "small": M.S_SMALL, "cal": 28}[st]
    w = 0
    for ch in text:
        w += DIGIT_W[st] if ch.isdigit() else int(s * 0.52)
    return w


def compose(photo_path, d: date, wx, out_path):
    img = Image.new("L", (M.W, M.H), 255)

    # 顶部照片
    if photo_path and Path(photo_path).exists():
        ph = Image.open(photo_path).convert("L")
        scale = max(M.W / ph.width, M.PHOTO_H / ph.height)
        ph = ph.resize((int(ph.width * scale + 0.5), int(ph.height * scale + 0.5)), Image.LANCZOS)
        left = (ph.width - M.W) // 2
        top = (ph.height - M.PHOTO_H) // 2
        img.paste(ph.crop((left, top, left + M.W, top + M.PHOTO_H)), (0, 0))

    X, CX, W = M.COL1_X, M.COL2_X, M.COL_W

    # ===== 左栏 =====
    row_w = digit_w("date", f"{d.month}{d.day}") + 2 * M.S_DATE
    x = X + (W - row_w) / 2
    x = digits(img, x, M.Y_DATE, f"{d.month}", "date")
    x = cn(img, x, M.Y_DATE, "月", "date")
    x = digits(img, x, M.Y_DATE, f"{d.day}", "date")
    x = cn(img, x, M.Y_DATE, "日", "date")

    wk = WEEKS[d.weekday() * 3: d.weekday() * 3 + 3]
    x = X + (W - len(wk) * M.S_WEEK) / 2
    cn(img, x, M.Y_WEEK, wk, "week")

    t = f"{wx['hour']:02d}:{wx['minute']:02d}"
    x = X + (W - digit_w("big", t)) / 2
    digits(img, x, M.Y_TIME, t, "big")

    stamp(img, "rule1.png", X, M.Y_RULE1)

    stamp(img, f"icons/big/{wx['icon']}.png", X, M.Y_ICON)
    tx = X + M.ICON_R + 22
    tx = digits(img, tx, M.Y_TEMP, str(int(round(abs(wx["temp"])))), "mid")
    stamp(img, "digits/mid/deg.png", tx, M.Y_TEMP)

    cn(img, X, M.Y_DESC, wx["desc"], "desc")
    x = digits(img, X, M.Y_RANGE, str(int(round(wx["low"]))), "small")
    stamp(img, "digits/small/dash.png", x, M.Y_RANGE)
    x = digits(img, x + 22, M.Y_RANGE, str(int(round(wx["high"]))), "small")
    stamp(img, "digits/small/deg.png", x, M.Y_RANGE)

    x = cn(img, X, M.Y_POP, "湿度", "small")
    x = digits(img, x + 8, M.Y_POP, str(wx["hum"]), "small")
    stamp(img, "digits/small/pct.png", x, M.Y_POP)

    # ===== 右栏 =====
    stamp(img, f"cal/{M.CALENDAR_YEAR}-{d.month:02d}.png", CX, M.Y_CAL)
    stamp(img, "rule2.png", CX, M.Y_RULE2)
    for y, label, w2 in [(M.Y_FC1, "明天", wx["tomorrow"]), (M.Y_FC2, "后天", wx["dayafter"])]:
        cn(img, CX, y + 6, label, "small")
        stamp(img, f"icons/small/{w2['icon']}.png", CX + 74, y)
        x = digits(img, CX + 134, y + 6, str(int(round(w2["high"]))), "small")
        stamp(img, "digits/small/deg.png", x, y + 6)
        stamp(img, "digits/small/dash.png", x + 22, y + 6)
        x = digits(img, x + 46, y + 6, str(int(round(w2["low"]))), "small")
        stamp(img, "digits/small/deg.png", x, y + 6)

    x = cn(img, CX, M.Y_HUM, "更新", "small")
    digits(img, x + 8, M.Y_HUM, f"{wx['hour']:02d}:{wx['minute']:02d}", "small")

    weeks = calendar.monthcalendar(d.year, d.month)
    row_idx = next(i for i, wkk in enumerate(weeks) if d.day in wkk)
    col_idx = [i for i, v in enumerate(weeks[row_idx]) if v == d.day][0]
    hl = Image.open(A / "digits" / "hl" / f"{d.day}.png")
    hx = CX + M.CAL_COL * col_idx + (M.CAL_COL - hl.width) / 2
    hy = M.Y_CAL + M.CAL_TOP + row_idx * M.CAL_ROW - 2
    stamp(img, f"digits/hl/{d.day}.png", hx, hy)

    img.save(out_path, "PNG", optimize=True)
    print(f"预览已生成: {out_path}  {img.size}")
    return img


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--photo", default=str(M.ROOT / "photos_ready" / "demo.png"))
    ap.add_argument("--out", default=str(M.ROOT / "preview-device.png"))
    ap.add_argument("--date", default=None)
    a = ap.parse_args()

    d = date.fromisoformat(a.date) if a.date else date.today()
    wx = {
        "hour": 14, "minute": 32, "temp": 5, "desc": "多云", "icon": "suncloud",
        "low": 1, "high": 7, "hum": 57,
        "tomorrow": {"icon": "rain", "high": 6, "low": 0},
        "dayafter": {"icon": "sun", "high": 9, "low": 2},
    }
    compose(a.photo, d, wx, a.out)
