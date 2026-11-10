#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v2 版式（横屏 1448x1072，双信息带 + 侧栏）的全套资产生成。

产出：
  assets/v2_digits/<set>/*.png    衬线数字（time120 / temp84 / num46 / date44 / small26 / tiny24）
  assets/v2_cn/<set>/*.png        中文词模（date44 / mid30 / small26 / tiny24）
  assets/v2_icons/*.png           天气图标 96px
  assets/cal2/YYYY-MM.png         420 宽月历（含标题与星期表头）
  assets/v2_hl/N.png              今天的高亮反白块
  assets/quotes/qNNN.png          每日一句（420x100，含出处）
  assets/lunar/YYYY.txt           每日农历 + 节气（设备按 MMDD 查）
  assets/fest.txt                 节日清单（2020-2040，按日期排序，设备倒计时用）
  assets/layout-land2.sh          坐标常量

设备端没有字体渲染能力，所以这里把能想到的字都做成 PNG；
唯一"动态"的是每日一句，也走预渲染（365 条里按日期取一条）。
"""

import calendar as pycal
import datetime as dt
from pathlib import Path

import sxtwl
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "assets"

SANS = "C:/Windows/Fonts/msyh.ttc"          # 中文界面用无衬线
SERIF_CN = "C:/Windows/Fonts/STSONG.TTF"    # 每日一句用宋体（更有"书"的味道）
SERIF_LAT = "C:/Windows/Fonts/times.ttf"   # 数字用 Times：等高数字，时钟排起来端正

INK, MID, SOFT, LINE, BG = 0, 80, 110, 170, 255

# ---------- 版式常量（设备像素）----------
W, H = 1448, 1072
PHOTO_W = 960
PHOTO_BOX_Y = 140          # 照片框上边（上下各留 140 给信息带）
PHOTO_BOX_H = 792          # 照片框高度 → 竖图最多 792 高
LEFT_PAD = 48              # 左区文字左内边距

QUOTE_X, QUOTE_W, QUOTE_H = 520, 420, 100

BB_TIME_X = 44             # 下信息带：时间
BB_ICON_X = 340            # 天气图标
BB_TEMP_X = 456            # 温度
BB_DESC_X = 572            # 天气描述 / 温区
BB_HUM_X = 730             # 湿度 / 空气质量

COL_X, COL_W = 990, 420    # 右侧栏
CAL_Y, CAL_W, CAL_H = 56, 420, 342

RULES = [424, 492, 726, 842, 958]     # 侧栏横线 y
Y_SUNRISE, X_SUNSET = 462, 1200
Y_FEST_LABEL = 528
Y_FEST = [578, 636, 694]
Y_ANN_LABEL, Y_ANN = 762, 808
Y_FC = [884, 926]
Y_UPDATE = 1000
X_BATT = 1288

# 字模档位（huge=番茄钟全屏大倒计时）
DIGIT_SETS = {"time": 120, "temp": 84, "num": 46, "date": 44, "small": 26, "tiny": 24, "huge": 300}
CN_SETS = {"date": 44, "mid": 30, "small": 26, "tiny": 24, "big": 72}
SYM = [(":", "colon"), ("°", "deg"), ("%", "pct"), ("-", "dash"), ("–", "dash")]
PCT_W = {}

CN_WORDS = [
    "月", "日", "年", "星期",
    "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日",
    "今天", "明天", "后天", "明日", "后日",
    "湿度", "空气", "日出", "日落", "更新", "电量", "充电中", "已充满",
    "临近", "节日", "纪念日", "还有", "天", "今日一句",
    # 「特殊日子」= 用户自填的日子（生日/结婚/考试/答辩/考公…），语义比"纪念日"宽
    "特殊日子", "特殊", "日子",
    "晴", "多云", "阴", "小雨", "中雨", "大雨", "暴雨",
    "雷阵雨", "阵雨", "小雪", "中雪", "大雪", "雨夹雪",
    "雾", "霾", "浮尘", "沙尘暴", "风", "大风", "未知",
    "优", "良", "轻度", "中度", "重度", "闰",
    # 番茄钟专用词模（big 档大字标题用）
    "专注中", "暂停中", "休息中", "长休息", "短休息",
]
# 农历月名/日名与节日名也要有字模（农历与节日都是动态内容）

WEATHER_ICONS = ["sun", "suncloud", "cloud", "fog", "haze", "drizzle",
                 "rain", "heavyrain", "storm", "snow"]
FEST_WORDS = ["元旦", "情人节", "妇女节", "植树节", "劳动节", "青年节", "儿童节",
              "建党节", "建军节", "教师节", "国庆节", "平安夜", "圣诞节",
              "春节", "元宵节", "龙抬头", "端午节", "七夕", "中元节", "中秋节",
              "重阳节", "腊八节", "小年", "除夕", "母亲节", "父亲节", "感恩节"]
# 字符图集额外收录：纪念日常见用字（用户可以在 conf 里写这些字）
EXTRA_CHARS = "生日结婚相识纪念爸爸妈妈父母儿子女儿宝宝入宅乔迁毕业考试入职" \
              "周年快乐健康平安如意顺遂春夏秋冬愿你我他一二三四五六七八九十" \
              "年月日周天号点分秒第次日今明前后新旧始终开始结束回家旅行" \
              "工作学习读书写字生活爱情友情亲情家庭孩子老婆老公宝贝" \
              "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz·-/:()（）"

LUNAR_MONTH = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
LUNAR_DAY = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
             "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
             "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]

# 农历月名/日名与节日名也要有字模（农历与节日都是动态内容）
CN_WORDS += [m + "月" for m in LUNAR_MONTH] + LUNAR_DAY + FEST_WORDS

# 24 节气：sxtwl 的 jqIndex 里 0=冬至、1=小寒、2=大寒、3=立春 ……（实测 2026 立春 jqIndex=3）
JIEQI = ["冬至", "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
         "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑", "白露",
         "秋分", "寒露", "霜降", "立冬", "小雪", "大雪"]

SOLAR_FEST = {
    (1, 1): "元旦", (2, 14): "情人节", (3, 8): "妇女节", (3, 12): "植树节",
    (5, 1): "劳动节", (5, 4): "青年节", (6, 1): "儿童节", (7, 1): "建党节",
    (8, 1): "建军节", (9, 10): "教师节", (10, 1): "国庆节",
    (12, 24): "平安夜", (12, 25): "圣诞节",
}
LUNAR_FEST = {
    (1, 1): "春节", (1, 15): "元宵节", (2, 2): "龙抬头", (5, 5): "端午节",
    (7, 7): "七夕", (7, 15): "中元节", (8, 15): "中秋节", (9, 9): "重阳节",
    (12, 8): "腊八节", (12, 23): "小年",
}
YEAR_SPAN = range(2020, 2041)


def fnt(path, size):
    return ImageFont.truetype(path, size)


# ---------------------------------------------------------------- 数字与中文
def make_digits():
    """衬线数字 + 符号。画布宽 = 步进宽，符号过宽时按实际宽度（防 % 被裁）。"""
    m = ImageDraw.Draw(Image.new("L", (8, 8), BG))
    meta = {}
    for name, s in DIGIT_SETS.items():
        d0 = OUT / "v2_digits" / name
        d0.mkdir(parents=True, exist_ok=True)
        f = fnt(SERIF_LAT, s)
        dw = max(1, int(round(f.getlength("0"))))
        ch = int(s * 1.30)
        sw = max(1, int(s * 0.42))
        # 画布约定：左上角起、基线落在 y=size 处（anchor="ls"），
        # 设备端贴图 y 一律 = 目标基线 - 字号，坐标可精确预测。
        for c in "0123456789":
            img = Image.new("L", (dw, ch), BG)
            ImageDraw.Draw(img).text((0, s), c, font=f, fill=INK, anchor="ls")
            img.save(d0 / f"{c}.png", "PNG", optimize=True)
        for ch_, nm in SYM:
            adv = int(round(f.getlength(ch_)))
            colw = adv + 3 if adv + 3 > sw else sw
            img = Image.new("L", (colw, ch), BG)
            ImageDraw.Draw(img).text((0, s), ch_, font=f, fill=INK, anchor="ls")
            img.save(d0 / f"{nm}.png", "PNG", optimize=True)
            if nm == "pct":
                PCT_W[name] = colw
        meta[name] = {"digit_w": dw, "sym_w": sw, "size": s}
    return meta


def make_cn():
    for name, s in CN_SETS.items():
        d0 = OUT / "v2_cn" / name
        d0.mkdir(parents=True, exist_ok=True)
        f = fnt(SANS, s)
        for w in CN_WORDS:
            # 同上：基线固定在 y=size，字模左缘对齐，字数×字号 就是步进宽
            img = Image.new("L", (len(w) * s, int(s * 1.30)), BG)
            ImageDraw.Draw(img).text((0, s), w, font=f, fill=INK, anchor="ls")
            img.save(d0 / f"{w}.png", "PNG", optimize=True)


# ---------------------------------------------------------------- 字符图集
def gb2312_char():
    """GB2312 一级汉字（3755 个常用字，按拼音序）。写的是"考试/答辩/考公"
    这类随手的词，字数需求不可预测，索性把常用字全套上，用户写什么都不缺字。"""
    out = []
    for hi in range(0xB0, 0xD8):
        for lo in range(0xA1, 0xFF):
            try:
                ch = bytes([hi, lo]).decode("gb2312")
            except UnicodeDecodeError:
                continue
            out.append(ch)
    return out


def make_charset(quote_texts):
    """任意中文名的兜底：把用得到的每个字单独做成 26px 小图，设备逐字贴。
    覆盖范围 = GB2312 一级常用字（3755）+ 每日一句用字 + 节日名 + 固定词模 + 专用字。"""
    chars = set()
    for t in quote_texts:
        chars |= set(t)
    for w in CN_WORDS + FEST_WORDS:
        chars |= set(w)
    chars |= set(EXTRA_CHARS)
    chars |= set(gb2312_char())
    chars = {c for c in chars if c.strip()}
    d0 = OUT / "v2_chars"
    d0.mkdir(parents=True, exist_ok=True)
    for old_png in d0.glob("*.png"):
        old_png.unlink()
    f = fnt(SANS, 26)
    for c in chars:
        nm = c
        # 设备存储是 FAT32，大小写不敏感：a.png 和 A.png 会互相覆盖。
        # ASCII 字母改用字节值命名（l97=w、u65=W），设备端 draw_chars 做同样映射。
        if c.isascii() and c.isalpha():
            nm = ("l" if c.islower() else "u") + str(ord(c))
        elif c in "/\\:*?\"<>|":
            nm = "%02X" % ord(c)
        img = Image.new("L", (26, 34), BG)
        ImageDraw.Draw(img).text((0, 26), c, font=f, fill=INK, anchor="ls")
        img.save(d0 / f"{nm}.png", "PNG", optimize=True)
    return len(chars)


# ---------------------------------------------------------------- 图标
def draw_icon(size, kind):
    from make_assets import draw_icon as _di
    return _di(size, kind)


def make_icons():
    d0 = OUT / "v2_icons"
    d0.mkdir(parents=True, exist_ok=True)
    for k in WEATHER_ICONS:
        draw_icon(96, k).save(d0 / f"{k}.png", "PNG", optimize=True)


# ---------------------------------------------------------------- 月历（420 宽）
# 月历几何：画布高固定 342，必须装下 6 行月份（如 2026-11，30 号在第 6 行）
# 72(标题+表头) + 22 + 6*41 = 340 ≤ 342；行距 44 时第 6 行会超出画布被裁
CAL_ROW = 41
CAL_HEAD = 72
CAL_COL = CAL_W / 7.0


def make_calendars(year, fest_map):
    d0 = OUT / "cal2"
    d0.mkdir(parents=True, exist_ok=True)
    for month in range(1, 13):
        img = Image.new("L", (CAL_W, CAL_H), BG)
        d = ImageDraw.Draw(img)
        d.text((0, 8), f"{year} 年 {month} 月", font=fnt(SANS, 30), fill=INK, anchor="la")
        d.line((0, 50, CAL_W, 50), fill=INK, width=2)
        for i, wd in enumerate("一二三四五六日"):
            d.text((CAL_COL * (i + 0.5), 58), wd, font=fnt(SANS, 24), fill=SOFT, anchor="ma")
        py = CAL_HEAD + 22
        marked = fest_map.get((year, month), {})
        for r, week in enumerate(pycal.monthcalendar(year, month)):
            for i, day in enumerate(week):
                if day == 0:
                    continue
                cx = CAL_COL * (i + 0.5)
                ty = py + r * CAL_ROW
                d.text((cx, ty), str(day), font=fnt(SERIF_LAT, 26), fill=MID, anchor="ma")
                if day in marked:
                    # 节日小框：空心矩形围着数字（数字无下伸部，26 号字形实际高约 18）
                    d.rectangle((cx - 26, ty - 6, cx + 26, ty + 26),
                                outline=INK, width=2)
        img.save(d0 / f"{year}-{month:02d}.png", "PNG", optimize=True)


def make_hl():
    d0 = OUT / "v2_hl"
    d0.mkdir(parents=True, exist_ok=True)
    for day in range(1, 32):
        img = Image.new("L", (52, 36), 0)
        ImageDraw.Draw(img).text((26, 17), str(day), font=fnt(SERIF_LAT, 26), fill=255, anchor="mm")
        img.save(d0 / f"{day}.png", "PNG", optimize=True)
    # 纪念日边框件：设备端贴 4 条细杆拼成空心框（PNG 带白底会盖住数字，
    # 所以拆成不与数字重叠的细条 —— 与月历里烤进去的节日框同一几何）
    Image.new("L", (52, 3), INK).save(d0 / "fr_top.png", "PNG", optimize=True)
    Image.new("L", (52, 6), INK).save(d0 / "fr_bot.png", "PNG", optimize=True)
    Image.new("L", (3, 38), INK).save(d0 / "fr_side.png", "PNG", optimize=True)


def make_rules():
    img = Image.new("L", (COL_W, 4), BG)
    ImageDraw.Draw(img).line((0, 2, COL_W, 2), fill=LINE, width=2)
    img.save(OUT / "hline420.png", "PNG", optimize=True)


# ---------------------------------------------------------------- 每日一句
def wrap(text, f, max_w):
    lines, cur = [], ""
    for ch in text:
        if f.getlength(cur + ch) > max_w and cur:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines


def make_quotes():
    src = ROOT / "quotes.txt"
    items = []
    for raw in src.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        body, _, who = raw.partition("|")
        items.append((body.strip(), who.strip()))
    d0 = OUT / "quotes"
    d0.mkdir(parents=True, exist_ok=True)
    for old in d0.glob("q*.png"):
        old.unlink()
    f_attr = fnt(SANS, 20)
    for i, (body, who) in enumerate(items, 1):
        # 画布固定 420x100：最多两行正文 + 行末出处，字号按篇幅自适应
        for size in (26, 24, 22):
            f = fnt(SERIF_CN, size)
            lines = wrap(body, f, QUOTE_W)
            if len(lines) <= 2:
                break
        img = Image.new("L", (QUOTE_W, QUOTE_H), BG)
        d = ImageDraw.Draw(img)
        step = size + 8
        for j, ln in enumerate(lines):
            d.text((0, 6 + j * step), ln, font=f, fill=INK, anchor="la")
        attr = f"—— {who}" if who else ""
        attr_w = f_attr.getlength(attr)
        last_w = f.getlength(lines[-1]) if lines else 0
        # 出处先试跟在末行右边；正文太长放不下就单独占一行、右对齐，
        # 否则会像「世界上只有一种病，就是穷病 —— 我不是药神」那样叠在正文上。
        if attr and last_w + 12 + attr_w <= QUOTE_W:
            d.text((last_w + 12, 6 + (len(lines) - 1) * step + size * 0.55),
                   attr, font=f_attr, fill=SOFT, anchor="la")
        elif attr:
            d.text((QUOTE_W - attr_w, 6 + len(lines) * step),
                   attr, font=f_attr, fill=SOFT, anchor="la")
        img.save(d0 / f"q{i:03d}.png", "PNG", optimize=True)
    return len(items)


# ---------------------------------------------------------------- 农历 / 节气 / 节日
def lunar_text(day):
    m, d = day.getLunarMonth(), day.getLunarDay()
    head = ("闰" if day.isLunarLeap() else "") + LUNAR_MONTH[m - 1] + "月"
    return head + LUNAR_DAY[d - 1]


def build_lunar():
    """assets/lunar/YYYY.txt：每天一行 MMDD|农历|节气（无节气写 -）"""
    jq = {}
    for y in range(YEAR_SPAN[0] - 1, YEAR_SPAN[-1] + 1):
        for it in sxtwl.getJieQiByYear(y):
            dd = sxtwl.JD2DD(it.jd)
            jq[(dd.Y, dd.M, dd.D)] = JIEQI[it.jqIndex]
    out = OUT / "lunar"
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for y in YEAR_SPAN:
        lines = []
        d = dt.date(y, 1, 1)
        while d.year == y:
            sd = sxtwl.fromSolar(d.year, d.month, d.day)
            leap = sd.isLunarLeap()
            # 五段：MMDD|月名|日名|节气|农历月日键
            # 末段让设备能「按农历反查公历」：正常月 1116，闰月加 R 前缀 R1116，
            # 这样 grep '|1116$' 只会命中正常月（2034 年有闰冬月，不带前缀会撞车）。
            lines.append(f"{d.month:02d}{d.day:02d}|{'闰' if leap else ''}"
                         f"{LUNAR_MONTH[sd.getLunarMonth() - 1]}月"
                         f"|{LUNAR_DAY[sd.getLunarDay() - 1]}|{jq.get((d.year, d.month, d.day), '-')}"
                         f"|{'R' if leap else ''}{sd.getLunarMonth():02d}{sd.getLunarDay():02d}")
            d += dt.timedelta(days=1)
            n += 1
        (out / f"{y}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return n


def build_festivals():
    """assets/fest.txt：YYYY-MM-DD|名称，按日期排序，跨年由设备顺序扫描"""
    rows = []
    for y in YEAR_SPAN:
        d = dt.date(y, 1, 1)
        prev = None
        while d.year == y:
            sd = sxtwl.fromSolar(d.year, d.month, d.day)
            lm, ld = sd.getLunarMonth(), sd.getLunarDay()
            if not sd.isLunarLeap():
                if (lm, ld) in LUNAR_FEST:
                    rows.append((d, LUNAR_FEST[(lm, ld)]))
            if (d.month, d.day) in SOLAR_FEST:
                rows.append((d, SOLAR_FEST[(d.month, d.day)]))
            # 除夕：腊月最后一天（下一天是正月初一）
            nxt = d + dt.timedelta(days=1)
            sn = sxtwl.fromSolar(nxt.year, nxt.month, nxt.day)
            if lm == 12 and sn.getLunarMonth() == 1 and sn.getLunarDay() == 1:
                rows.append((d, "除夕"))
            prev = sd
            d = nxt
        # 按星期的节日
        for name, (mon, nth, wd) in {"母亲节": (5, 2, 6), "父亲节": (6, 3, 6),
                                     "感恩节": (11, 4, 3)}.items():
            c = 0
            for day in range(1, 32):
                try:
                    x = dt.date(y, mon, day)
                except ValueError:
                    break
                if x.weekday() == wd:
                    c += 1
                    if c == nth:
                        rows.append((x, name))
                        break
    rows = sorted(set(rows), key=lambda r: (r[0], r[1]))
    txt = "\n".join(f"{d.isoformat()}|{name}" for d, name in rows) + "\n"
    (OUT / "fest.txt").write_text(txt, encoding="utf-8", newline="\n")
    # 月历烤框用： (年, 月) → {日: 名称}
    fest_map = {}
    for d, name in rows:
        fest_map.setdefault((d.year, d.month), {})[d.day] = name
    return len(rows), fest_map


# ---------------------------------------------------------------- layout
def write_layout(meta, nq):
    d = lambda k: meta[k]["digit_w"]
    s = lambda k: meta[k]["sym_w"]
    lines = [
        "# 由 make_v2.py 自动生成（横屏 v2：双信息带 + 侧栏），勿手改",
        f"W={W}", f"H={H}",
        f"PHOTO_X=0", f"PHOTO_W={PHOTO_W}",
        f"PHOTO_BOX_Y={PHOTO_BOX_Y}", f"PHOTO_BOX_H={PHOTO_BOX_H}",
        f"LEFT_PAD={LEFT_PAD}",
        f"QUOTE_X={QUOTE_X}", f"QUOTE_W={QUOTE_W}", f"QUOTE_H={QUOTE_H}",
        f"BB_TIME_X={BB_TIME_X}", f"BB_ICON_X={BB_ICON_X}", f"BB_ICON_S=96",
        f"BB_TEMP_X={BB_TEMP_X}", f"BB_DESC_X={BB_DESC_X}", f"BB_HUM_X={BB_HUM_X}",
        f"COL_X={COL_X}", f"COL_W={COL_W}",
        f"CAL_Y={CAL_Y}", f"CAL_W={CAL_W}", f"CAL_H={CAL_H}",
        f"CAL_COL={CAL_COL:.3f}", f"CAL_COL_I={int(CAL_COL)}",
        f"CAL_HEAD={CAL_HEAD}", f"CAL_ROW={CAL_ROW}", f"CAL_TOP={CAL_HEAD + 22}",
        "CAL_YEAR_MIN=2020", "CAL_YEAR_MAX=2040",
        *[f"Y_RULE{i + 1}={v}" for i, v in enumerate(RULES)],
        f"Y_SUNRISE={Y_SUNRISE}", f"X_SUNSET={X_SUNSET}",
        f"Y_FEST_LABEL={Y_FEST_LABEL}",
        *[f"Y_FEST{i + 1}={v}" for i, v in enumerate(Y_FEST)],
        f"Y_ANN_LABEL={Y_ANN_LABEL}", f"Y_ANN={Y_ANN}",
        *[f"Y_FC{i + 1}={v}" for i, v in enumerate(Y_FC)],
        f"Y_UPDATE={Y_UPDATE}", f"X_BATT={X_BATT}",
        f"QUOTE_COUNT={nq}",
        *[f"S_{k.upper()}={meta[k]['size']}" for k in DIGIT_SETS],
        *[f"DIGIT_W_{k.upper()}={d(k)}" for k in DIGIT_SETS],
        *[f"SYM_W_{k.upper()}={s(k)}" for k in DIGIT_SETS],
        *[f"S_CN_{k.upper()}={v}" for k, v in CN_SETS.items()],
        *[f"PCT_W_{k.upper()}={PCT_W.get(k, s(k))}" for k in DIGIT_SETS],
        # ---- 番茄钟：休息徽章（专注页素材由 make_pomo_ui.py 生成）----
        "POMO_BADGE_X=16",      # 休息徽章：照片区左上角
        "POMO_BADGE_Y=190",
        "ASSETS=/mnt/us/kindle-photo-wall/assets",
        "PHOTOS=/mnt/us/kindle-photo-wall/photos",
    ]

    # 去重：同一常量只保留第一次出现，免得布局文件里出现重复键
    seen, uniq = set(), []
    for ln in lines:
        if ln in seen:
            continue
        seen.add(ln)
        uniq.append(ln)
    (OUT / "layout-land2.sh").write_text("\n".join(uniq) + "\n", encoding="utf-8", newline="\n")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    meta = make_digits()
    make_cn()
    make_icons()
    nf, fest_map = build_festivals()   # 先出节日表，月历要把节日框烤进图里
    for y in YEAR_SPAN:
        make_calendars(y, fest_map)
    make_hl()
    make_rules()
    qtexts = [ln.split("|")[0] for ln in (ROOT / "quotes.txt").read_text(encoding="utf-8").splitlines() if ln.strip()]
    nq = make_quotes()
    nch = make_charset(qtexts)
    nl = build_lunar()
    write_layout(meta, nq)
    # 番茄钟 flip-clock UI（素材 + 追加布局常量，见 make_pomo_ui.py）
    import make_pomo_ui as mpui
    _dw, _wds = mpui.generate_all()
    with (OUT / "layout-land2.sh").open("a", encoding="utf-8", newline="\n") as _f:
        _f.write("\n".join(mpui.layout_lines(_dw, _wds)) + "\n")
    print("数字档位: " + ", ".join("%s=%s" % (k, v["size"]) for k, v in meta.items()))
    print(f"每日一句: {nq} 条")
    print(f"农历表: {nl} 天（{YEAR_SPAN[0]}-{YEAR_SPAN[-1]}）")
    print(f"节日表: {nf} 条")
    print(f"字符图集: {nch} 字")
    total = sum(p.stat().st_size for p in OUT.rglob("*.png"))
    print(f"PNG 合计 {total / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
