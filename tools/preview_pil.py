"""按 paint.sh 的真实逻辑复现一帧（竖屏/横屏通用）。

用法：py -3.11 preview_pil.py [布局文件] [输出.png] [HH:MM] [电量]
默认布局 assets/layout.sh；横屏用 assets/layout-land.sh。
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
A = ROOT / "render" / "assets"
PHOTO = ROOT / "render" / "photos_ready" / "IMG_2223.png"

layout = Path(sys.argv[1]) if len(sys.argv) > 1 else A / "layout.sh"
if not layout.is_absolute():
    layout = A / layout
out = sys.argv[2] if len(sys.argv) > 2 else "preview.png"
hhmm = sys.argv[3] if len(sys.argv) > 3 else "21:31"
batt = sys.argv[4] if len(sys.argv) > 4 else "26"

L = {}
for line in layout.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    L[k] = v


def g(k, d=0):
    try:
        return int(float(L.get(k, d)))
    except ValueError:
        return d


W, H = g("W", 1072), g("H", 1448)
PX, PY = g("PHOTO_X", 0), g("PHOTO_Y", 0)
PW, PH = g("PHOTO_W", W), g("PHOTO_H", 730)
img = Image.new("L", (W, H), 255)


def paste(path, x, y):
    p = Path(path)
    if not p.exists():
        print("缺图:", p)
        return
    img.paste(Image.open(p).convert("L"), (int(x), int(y)))


def num(x, y, text, st):
    dw, sw = g(f"DIGIT_W_{st.upper()}", 30), g(f"SYM_W_{st.upper()}", 25)
    sz = g(f"S_{st.upper()}", 34)
    dy = y - sz * 15 // 100
    for c in text:
        if c == ":":
            f, w = A / "digits" / st / "colon.png", sw
        elif c == "%":
            f, w = A / "digits" / st / "pct.png", g(f"PCT_W_{st.upper()}", sw)
        elif c == "-":
            f, w = A / "digits" / st / "dash.png", sw
        else:
            f, w = A / "digits" / st / f"{c}.png", dw
        paste(f, x, dy)
        x += w
    return x


def cn(x, y, word, st, n):
    sz = g(f"S_{st.upper()}", 34)
    paste(A / "cn" / st / f"{word}.png", x, y - sz * 17 // 100)
    return x + n * sz


# 照片：等比铺满照片区、居中裁切
ph = Image.open(PHOTO).convert("L")
sc = max(PW / ph.width, PH / ph.height)
nw, nh = round(ph.width * sc), round(ph.height * sc)
img.paste(ph.resize((nw, nh), Image.LANCZOS).crop(
    ((nw - PW) // 2, (nh - PH) // 2, (nw - PW) // 2 + PW, (nh - PH) // 2 + PH)), (PX, PY))

# 日期（居中）
row_w = 2 * g("DIGIT_W_DATE", 29) + 2 * g("S_DATE", 48)
x = g("COL1_X") + (g("COL_W") - row_w) // 2
x = num(x, g("Y_DATE"), "11", "date")
x = cn(x, g("Y_DATE"), "月", "date", 1)
x = num(x, g("Y_DATE"), "8", "date")
cn(x, g("Y_DATE"), "日", "date", 1)
# 星期（居中）
cn(g("COL1_X") + (g("COL_W") - 3 * g("S_WEEK", 34)) // 2, g("Y_WEEK"), "星期日", "week", 3)
# 时间（居中）
tw = 4 * g("DIGIT_W_BIG", 86) + g("SYM_W_BIG", 72)
num(g("COL1_X") + (g("COL_W") - tw) // 2, g("Y_TIME"), hhmm, "big")
# 分隔线
paste(A / "rule1.png", g("COL1_X"), g("Y_RULE1"))
# 天气
paste(A / "icons" / "big" / "suncloud.png", g("COL1_X"), g("Y_ICON"))
x = num(g("COL1_X") + g("ICON_R") + 22, g("Y_TEMP"), "13", "mid")
paste(A / "digits" / "mid" / "deg.png", x, g("Y_TEMP"))
cn(g("COL1_X"), g("Y_DESC"), "阴", "desc", 1)
x = num(g("COL1_X"), g("Y_RANGE"), "10", "small")
paste(A / "digits" / "small" / "dash.png", x, g("Y_RANGE"))
x = num(x + 22, g("Y_RANGE"), "17", "small")
paste(A / "digits" / "small" / "deg.png", x, g("Y_RANGE"))
x = cn(g("COL1_X"), g("Y_POP"), "湿度", "small", 2)
x = num(x + 8, g("Y_POP"), "61", "small")
paste(A / "digits" / "small" / "pct.png", x, g("Y_POP"))
# 月历
paste(A / "cal" / "2026-11.png", g("COL2_X"), g("Y_CAL"))
paste(A / "rule2.png", g("COL2_X"), g("Y_RULE2"))


def fc(x0, y, label, icon, hi, lo):
    cn(x0, y + 6, label, "small", 2)
    paste(A / "icons" / "small" / f"{icon}.png", x0 + 74, y)
    xx = num(x0 + 134, y + 6, hi, "small")
    paste(A / "digits" / "small" / "deg.png", xx, y + 6)
    paste(A / "digits" / "small" / "dash.png", xx + 22, y + 6)
    xx = num(xx + 46, y + 6, lo, "small")
    paste(A / "digits" / "small" / "deg.png", xx, y + 6)


fc(g("COL2_X"), g("Y_FC1"), "明天", "rain", "12", "8")
fc(g("FC2_X", g("COL2_X")), g("Y_FC2"), "后天", "sun", "15", "6")
# 更新 / 电量
x = cn(g("COL2_X"), g("Y_HUM"), "更新", "small", 2)
num(x + 8, g("Y_HUM"), hhmm, "small")
by = g("Y_BATT", g("Y_HUM") + 54)
x = cn(g("COL2_X"), by, "电量", "small", 2)
x = num(x + 8, by, batt, "small")
paste(A / "digits" / "small" / "pct.png", x, by)

img.save(out)
print("已生成", out, img.size)
