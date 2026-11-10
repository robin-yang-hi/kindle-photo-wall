#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v2 版式本地预览：不重画字体，直接读 assets 里的 PNG 字模，按 paint2.sh 的
几何算法拼一帧出来。这样预览图和设备上出的图是同一套素材，坐标错了立刻能看出。

用法：py -3.11 tools/preview_v2.py [照片路径] [输出路径]
"""
import datetime as dt
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "render" / "assets"
LA = dict()
for line in (ASSETS / "layout-land2.sh").read_text(encoding="utf-8").splitlines():
    m = re.match(r"^([A-Z0-9_]+)=([0-9.\-]+)$", line.strip())
    if m:
        k, v = m.group(1), m.group(2)
        LA[k] = float(v) if "." in v else int(v)

W, H = LA["W"], LA["H"]
MISSING = []


def L(name, default=0):
    return LA.get(name, default)


def paste(canvas, path, x, y):
    p = Path(path)
    if not p.exists():
        MISSING.append(str(p))
        return
    im = Image.open(p).convert("L")
    canvas.paste(im, (int(x), int(y)))


def paste_scaled(canvas, path, x, y, w, h):
    p = Path(path)
    if not p.exists():
        MISSING.append(str(p))
        return
    im = Image.open(p).convert("L").resize((max(1, int(w)), max(1, int(h))), Image.LANCZOS)
    canvas.paste(im, (int(x), int(y)))


def draw_num(canvas, x, baseline, text, st):
    dw = L(f"DIGIT_W_{st.upper()}", 16)
    sw = L(f"SYM_W_{st.upper()}", 12)
    pw = L(f"PCT_W_{st.upper()}", sw)
    size = L(f"S_{st.upper()}", 26)
    dy = baseline - size
    for ch in text:
        if ch == ":":
            f, w = "colon", sw
        elif ch == "°":
            f, w = "deg", sw
        elif ch == "%":
            f, w = "pct", pw
        elif ch in "-–":
            f, w = "dash", sw
        elif ch == ".":
            f, w = "dot", sw
        else:
            f, w = ch, dw
        paste(canvas, ASSETS / "v2_digits" / st / f"{f}.png", x, dy)
        x += w
    return x


def draw_cn(canvas, x, baseline, word, st, n):
    size = L(f"S_CN_{st.upper()}", 26)
    p = ASSETS / "v2_cn" / st / f"{word}.png"
    if p.exists():
        paste(canvas, p, x, baseline - size)
    else:
        draw_chars(canvas, x, baseline, word, size)
    return x + n * size


def draw_chars(canvas, x, baseline, text, size):
    for ch in text:
        paste(canvas, ASSETS / "v2_chars" / f"{ch}.png", x, baseline - size)
        x += size
    return x


def main():
    photo = Path(sys.argv[1]) if len(sys.argv) > 1 else sorted((ROOT / "render" / "photos").glob("*"))[0]
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "tools" / "preview_v2.png"
    canvas = Image.new("L", (W, H), 255)

    # ---- 照片：contain 进照片框 ----
    iw, ih = Image.open(photo).size
    pw, boxh, boxy = L("PHOTO_W"), L("PHOTO_BOX_H"), L("PHOTO_BOX_Y")
    if pw * ih <= boxh * iw:
        sw, sh = pw, ih * pw // iw
    else:
        sh, sw = boxh, iw * boxh // ih
    sx = L("PHOTO_X") + (pw - sw) // 2
    sy = boxy + (boxh - sh) // 2
    paste_scaled(canvas, photo, sx, sy, sw, sh)

    TB = (H - sh) // 2
    BB = H - TB
    tcy = TB // 2
    bcy = (BB + H) // 2

    today = dt.date.today()
    # ---- 上带 ----
    y1 = tcy - 26
    x = L("LEFT_PAD")
    x = draw_num(canvas, x, y1, str(today.month), "date")
    x = draw_cn(canvas, x, y1, "月", "date", 1)
    x = draw_num(canvas, x, y1, str(today.day), "date")
    x = draw_cn(canvas, x, y1, "日", "date", 1)
    wd = "星期一 星期二 星期三 星期四 星期五 星期六 星期日".split()[today.weekday()]
    draw_cn(canvas, x + 22, y1, wd, "mid", 3)

    y2 = tcy + 38
    lunar_line = ""
    lf = ASSETS / "lunar" / f"{today.year}.txt"
    for line in lf.read_text(encoding="utf-8").splitlines():
        if line.startswith(today.strftime("%m%d") + "|"):
            lunar_line = line
            break
    if lunar_line:
        _, mon, day, jq = lunar_line.split("|")
        x = L("LEFT_PAD")
        x = draw_cn(canvas, x, y2, mon, "tiny", 2)
        x = draw_cn(canvas, x, y2, day, "tiny", 2)
        if jq != "-":
            draw_cn(canvas, x + 16, y2, jq, "tiny", 2)

    qidx = today.timetuple().tm_yday % L("QUOTE_COUNT") + 1
    paste(canvas, ASSETS / "quotes" / f"q{qidx:03d}.png", L("QUOTE_X"), (TB - L("QUOTE_H")) // 2)

    # ---- 下带（演示数据）----
    temp, hum, aqi, aqi_txt = "12", "62", "42", "良"
    sunrise, sunset = "06:42", "17:32"
    draw_num(canvas, L("BB_TIME_X"), bcy + 46, "22:10", "time")
    paste(canvas, ASSETS / "v2_icons" / "suncloud.png", L("BB_ICON_X"), bcy - L("BB_ICON_S") // 2)
    x = draw_num(canvas, L("BB_TEMP_X"), bcy + 28, temp, "temp")
    paste(canvas, ASSETS / "v2_digits" / "temp" / "deg.png", x, bcy + 28 - L("S_TEMP"))
    draw_cn(canvas, L("BB_DESC_X"), bcy - 16, "多云", "mid", 2)
    x = draw_num(canvas, L("BB_DESC_X"), bcy + 26, "10", "small")
    paste(canvas, ASSETS / "v2_digits" / "small" / "dash.png", x, bcy + 26 - L("S_SMALL"))
    x = draw_num(canvas, x + L("SYM_W_SMALL") + 4, bcy + 26, "17", "small")
    paste(canvas, ASSETS / "v2_digits" / "small" / "deg.png", x, bcy + 26 - L("S_SMALL"))
    x = draw_cn(canvas, L("BB_HUM_X"), bcy - 16, "湿度", "small", 2)
    x = draw_num(canvas, x + 8, bcy - 16, hum, "small")
    paste(canvas, ASSETS / "v2_digits" / "small" / "pct.png", x, bcy - 16 - L("S_SMALL"))
    x = draw_cn(canvas, L("BB_HUM_X"), bcy + 26, "空气", "small", 2)
    x = draw_cn(canvas, x + 8, bcy + 26, aqi_txt, "small", 2)
    draw_num(canvas, x + 6, bcy + 26, aqi, "small")

    # ---- 侧栏 ----
    paste(canvas, ASSETS / "cal2" / f"{today.year}-{today.month:02d}.png", L("COL_X"), L("CAL_Y"))
    # 今天高亮（Zeller，周一为首列）
    yy, mm2 = today.year, today.month
    if mm2 < 3:
        mm2 += 12
        yy -= 1
    K, J = yy % 100, yy // 100
    h = (1 + int(13 * (mm2 + 1) / 5) + K + int(K / 4) + int(J / 4) + 5 * J) % 7
    f0 = (h + 5) % 7
    idx = f0 + today.day - 1
    row, col = idx // 7, idx % 7
    hx = L("COL_X") + col * L("CAL_COL_I") + (L("CAL_COL_I") - 52) // 2
    hy = L("CAL_Y") + L("CAL_TOP") + row * L("CAL_ROW") - 6
    paste(canvas, ASSETS / "v2_hl" / f"{today.day}.png", hx, hy)

    for k in ("Y_RULE1", "Y_RULE3", "Y_RULE4", "Y_RULE5"):
        paste(canvas, ASSETS / "hline420.png", L("COL_X"), L(k))

    x = draw_cn(canvas, L("COL_X"), L("Y_SUNRISE"), "日出", "tiny", 2)
    x = draw_num(canvas, x + 10, L("Y_SUNRISE"), sunrise, "tiny")
    x = draw_cn(canvas, L("X_SUNSET"), L("Y_SUNRISE"), "日落", "tiny", 2)
    draw_num(canvas, x + 10, L("Y_SUNRISE"), sunset, "tiny")

    draw_cn(canvas, L("COL_X"), L("Y_FEST_LABEL"), "临近节日", "tiny", 4)
    fests = []
    for line in (ASSETS / "fest.txt").read_text(encoding="utf-8").splitlines():
        d, name = line.split("|")
        if d >= today.isoformat():
            fests.append((dt.date.fromisoformat(d), name))
        if len(fests) == 3:
            break
    for i, (d0, name) in enumerate(fests, 1):
        fy = L(f"Y_FEST{i}")
        days = (d0 - today).days
        draw_cn(canvas, L("COL_X"), fy, name, "mid", len(name))
        x = L("COL_X") + 96
        x = draw_num(canvas, x, fy, str(d0.month), "tiny")
        x = draw_cn(canvas, x, fy, "月", "tiny", 1)
        x = draw_num(canvas, x, fy, str(d0.day), "tiny")
        draw_cn(canvas, x, fy, "日", "tiny", 1)
        dx = L("COL_X") + L("COL_W") - 74
        draw_num(canvas, dx + (3 - len(str(days))) * L("DIGIT_W_NUM"), fy, str(days), "num")
        draw_cn(canvas, dx + 3 * L("DIGIT_W_NUM") + 6, fy, "天", "tiny", 1)

    draw_cn(canvas, L("COL_X"), L("Y_ANN_LABEL"), "纪念日", "tiny", 3)
    ann_name, ann_date, ann_days = "生日", dt.date(today.year, 12, 3), None
    if ann_date < today:
        ann_date = dt.date(today.year + 1, 12, 3)
    ann_days = (ann_date - today).days
    draw_chars(canvas, L("COL_X"), L("Y_ANN"), ann_name, 26)
    x = L("COL_X") + 96
    x = draw_num(canvas, x, L("Y_ANN"), str(ann_date.month), "tiny")
    x = draw_cn(canvas, x, L("Y_ANN"), "月", "tiny", 1)
    x = draw_num(canvas, x, L("Y_ANN"), str(ann_date.day), "tiny")
    draw_cn(canvas, x, L("Y_ANN"), "日", "tiny", 1)
    dx = L("COL_X") + L("COL_W") - 74
    draw_num(canvas, dx + (3 - len(str(ann_days))) * L("DIGIT_W_NUM"), L("Y_ANN"), str(ann_days), "num")
    draw_cn(canvas, dx + 3 * L("DIGIT_W_NUM") + 6, L("Y_ANN"), "天", "tiny", 1)

    for i, (lab, lo, hi, ic) in enumerate([("明天", "9", "18", "sun"), ("后天", "8", "14", "rain")], 1):
        fy = L(f"Y_FC{i}")
        draw_cn(canvas, L("COL_X"), fy, lab, "tiny", 2)
        paste(canvas, ASSETS / "v2_icons" / f"{ic}.png", L("COL_X") + 66, fy - 44)
        x = draw_num(canvas, L("COL_X") + 208, fy, lo, "tiny")
        paste(canvas, ASSETS / "v2_digits" / "tiny" / "deg.png", x, fy - L("S_TINY"))
        paste(canvas, ASSETS / "v2_digits" / "tiny" / "dash.png", x + L("SYM_W_TINY") + 2, fy - L("S_TINY"))
        x = draw_num(canvas, x + 2 * L("SYM_W_TINY") + 6, fy, hi, "tiny")
        paste(canvas, ASSETS / "v2_digits" / "tiny" / "deg.png", x, fy - L("S_TINY"))

    x = draw_cn(canvas, L("COL_X"), L("Y_UPDATE"), "更新", "tiny", 2)
    draw_num(canvas, x + 8, L("Y_UPDATE"), "22:10", "tiny")
    bx = L("COL_X") + L("COL_W") - 120
    x = draw_cn(canvas, bx, L("Y_UPDATE"), "电量", "tiny", 2)
    x = draw_num(canvas, x + 8, L("Y_UPDATE"), "23", "tiny")
    paste(canvas, ASSETS / "v2_digits" / "tiny" / "pct.png", x, L("Y_UPDATE") - L("S_TINY"))

    canvas.save(out)
    print(f"预览输出: {out}")
    print(f"照片: {photo.name} {iw}x{ih} → {sw}x{sh} @({sx},{sy})  上带 {TB}px")
    if MISSING:
        print(f"缺失素材 {len(MISSING)} 个: {MISSING[:8]}")


if __name__ == "__main__":
    main()
