"""在电脑上复现 paint.sh 的一帧，用来核对版式（不需要 Kindle）。

用法：python compose.py [输出文件] [HH:MM]
几何逻辑与 device/paint.sh、assets/layout.sh 一一对应，改版式时先在这里看效果。
"""
import sys, zlib, struct, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pngtool import gray_of

BASE = "K:/kindle-photo-wall"
A = BASE + "/assets"

W, H = 1072, 1448
PHOTO_H = 760
COL1_X, COL2_X, COL_W = 36, 556, 484
Y_DATE, S_DATE = 800, 48
Y_WEEK, S_WEEK = 866, 34
Y_TIME, S_BIG, S_MID = 920, 140, 100
Y_RULE1, Y_RULE2 = 1080, 1108
Y_ICON, ICON_R, Y_TEMP = 1100, 100, 1104
Y_DESC, S_DESC = 1228, 40
Y_RANGE, Y_POP, S_SMALL = 1284, 1332, 34
Y_FC1, Y_FC2, Y_HUM = 1124, 1176, 1240
Y_CAL, CAL_COL_I, CAL_TOP, CAL_ROW, HL_W = 790, 68, 92, 32, 60
DIGIT_W = {"big": 86, "mid": 62, "date": 29, "week": 21, "small": 21, "cal": 17}
SYM_W = {"big": 72, "mid": 52, "date": 24, "small": 17, "week": 17, "cal": 14}
SIZE = {"big": S_BIG, "mid": S_MID, "date": S_DATE, "week": S_WEEK,
        "small": S_SMALL, "desc": S_DESC}


class Canvas:
    def __init__(self):
        self.buf = bytearray([255]) * (W * H)

    def paste(self, path, x, y):
        try:
            w, h, g = gray_of(path)
        except Exception as e:
            print("  贴图失败", path, e)
            return
        for r in range(h):
            ty = y + r
            if ty < 0 or ty >= H:
                continue
            s = r * w
            row = g[s:s + w]
            for c in range(w):
                tx = x + c
                if 0 <= tx < W:
                    self.buf[ty * W + tx] = row[c]

    def save(self, path):
        raw = b"".join(b"\x00" + bytes(self.buf[y * W:(y + 1) * W]) for y in range(H))

        def chunk(t, d):
            return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 0, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(raw, 6))
               + chunk(b"IEND", b""))
        open(path, "wb").write(png)


def num(cv, x, y, text, st):
    dy = y - SIZE[st] * 15 // 100
    for ch in text:
        if ch == ":":
            f, w = A + f"/digits/{st}/colon.png", SYM_W[st]
        elif ch == "%":
            f, w = A + f"/digits/{st}/pct.png", SYM_W[st]
        elif ch == "-":
            f, w = A + f"/digits/{st}/dash.png", SYM_W[st]
        elif ch == ".":
            f, w = A + f"/digits/{st}/dot.png", SYM_W[st]
        else:
            f, w = A + f"/digits/{st}/{ch}.png", DIGIT_W[st]
        if os.path.exists(f):
            cv.paste(f, x, dy)
        x += w
    return x


def cn(cv, x, y, word, st):
    sz = SIZE[st]
    f = A + f"/cn/{st}/{word}.png"
    if not os.path.exists(f):
        f = A + f"/cn/{st}/未知.png"
    cv.paste(f, x, y - sz * 17 // 100)
    return x + len(word) * sz


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "preview.png"
    hhmm = sys.argv[2] if len(sys.argv) > 2 else "01:23"
    Y, M, D = 2026, 11, 8
    wk = "星期日"
    temp, low, high, hum, desc, icon = "16", "12", "17", "98", "小雨", "drizzle"

    cv = Canvas()
    cv.paste(BASE + "/photos/IMG_2223.png", 0, 0)

    # 左栏：日期
    row_w = len(f"{M}{D}") * DIGIT_W["date"] + 2 * S_DATE
    x = COL1_X + (COL_W - row_w) // 2
    x = num(cv, x, Y_DATE, str(M), "date")
    x = cn(cv, x, Y_DATE, "月", "date")
    x = num(cv, x, Y_DATE, str(D), "date")
    cn(cv, x, Y_DATE, "日", "date")

    x = COL1_X + (COL_W - 3 * S_WEEK) // 2
    cn(cv, x, Y_WEEK, wk, "week")

    tw = 4 * DIGIT_W["big"] + SYM_W["big"]
    x = COL1_X + (COL_W - tw) // 2
    num(cv, x, Y_TIME, hhmm, "big")

    cv.paste(A + "/rule1.png", COL1_X, Y_RULE1)
    cv.paste(f"{A}/icons/big/{icon}.png", COL1_X, Y_ICON)
    x = COL1_X + ICON_R + 22
    x = num(cv, x, Y_TEMP, temp, "mid")
    cv.paste(A + "/digits/mid/deg.png", x, Y_TEMP)
    cn(cv, COL1_X, Y_DESC, desc, "desc")
    x = num(cv, COL1_X, Y_RANGE, low, "small")
    cv.paste(A + "/digits/small/dash.png", x, Y_RANGE)
    x = num(cv, x + 22, Y_RANGE, high, "small")
    cv.paste(A + "/digits/small/deg.png", x, Y_RANGE)
    x = cn(cv, COL1_X, Y_POP, "湿度", "small")
    x = num(cv, x + 8, Y_POP, hum, "small")
    cv.paste(A + "/digits/small/pct.png", x, Y_POP)

    # 右栏：月历
    cv.paste(f"{A}/cal/{Y}-{M:02d}.png", COL2_X, Y_CAL)
    mm, yy = M, Y
    if mm < 3:
        mm += 12
        yy -= 1
    K, J = yy % 100, yy // 100
    hh = (1 + (13 * (mm + 1)) // 5 + K + K // 4 + J // 4 + 5 * J) % 7
    f0 = (hh + 5) % 7
    row, col = (f0 + D - 1) // 7, (f0 + D - 1) % 7
    hx = COL2_X + col * CAL_COL_I + (CAL_COL_I - HL_W) // 2
    hy = Y_CAL + CAL_TOP + row * CAL_ROW - 2
    hl = f"{A}/digits/hl/{D}.png"
    if os.path.exists(hl):
        cv.paste(hl, hx, hy)
    cv.paste(A + "/rule2.png", COL2_X, Y_RULE2)

    def fc(y, label, ic, hi, lo):
        cn(cv, COL2_X, y + 6, label, "small")
        cv.paste(f"{A}/icons/small/{ic}.png", COL2_X + 74, y)
        xx = num(cv, COL2_X + 134, y + 6, hi, "small")
        cv.paste(A + "/digits/small/deg.png", xx, y + 6)
        cv.paste(A + "/digits/small/dash.png", xx + 22, y + 6)
        xx = num(cv, xx + 46, y + 6, lo, "small")
        cv.paste(A + "/digits/small/deg.png", xx, y + 6)

    fc(Y_FC1, "明天", "cloud", "18", "13")
    fc(Y_FC2, "后天", "suncloud", "20", "14")

    x = cn(cv, COL2_X, Y_HUM, "更新", "small")
    num(cv, x + 8, Y_HUM, hhmm, "small")

    cv.save(out)
    print("已生成", out)


if __name__ == "__main__":
    main()
