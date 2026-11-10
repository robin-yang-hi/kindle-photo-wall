#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kindle 照片墙渲染器
------------------------------------------------------------
左半（横屏）或上半（竖屏）放一张照片，另一侧排日期、时间、天气和月历。
输出 8-bit 灰度 PNG，可直接用 fbink 刷到 Kindle 屏幕。

针对 Kindle Paperwhite 4：横屏 1448x1072 / 竖屏 1072x1448

用法：
    python render.py                     # 正常渲染，联网取天气
    python render.py --offline           # 不联网，用缓存或占位数据
    python render.py --layout portrait   # 竖屏
    python render.py --out dash.png      # 指定输出
    python render.py --photo a.jpg       # 指定照片
"""

from __future__ import annotations

import argparse
import calendar
import datetime as dt
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps
except ImportError:
    sys.exit("缺少 Pillow，请先运行：pip install pillow")


# ============================================================
#  配置区：改这里就够了
# ============================================================
CFG = {
    # --- 屏幕 ---
    "width": 1448,
    "height": 1072,
    "layout": "landscape",        # landscape = 左图右信息；portrait = 上图下信息

    # --- 照片 ---
    "photo_dir": "photos",        # 照片目录，支持 jpg/png/webp
    "photo_ratio": 0.50,          # 照片占多大比例（0.5 = 一半）
    "photo_zoom": 1.00,           # 照片稍微放大一点点可裁掉边缘杂质

    # --- 位置（示例：北京，改成自己的城市）---
    "lat": 39.9042,
    "lon": 116.4074,
    "city": "北京·东城",
    "forecast_days": 7,

    # --- 其它 ---
    "cache": "weather_cache.json",   # 天气缓存，断网时兜底
    "out": "dash.png",
    "battery": True,                 # 在 Kindle 上运行时会读电量
}

# ============================================================
#  素材
# ============================================================
INK = 0          # 纯黑
MID = 80         # 次要文字
SOFT = 150       # 说明文字
FAINT = 205      # 分隔线
PAPER = 255      # 纸白

BASE = Path(__file__).resolve().parent

FONT_FILES = [
    ("fonts/msyh.ttc", 0),
    ("fonts/NotoSansSC-Regular.otf", 0),
    ("fonts/SourceHanSansSC-Regular.otf", 0),
    ("C:/Windows/Fonts/msyh.ttc", 0),
    ("/System/Library/Fonts/PingFang.ttc", 0),
    ("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 0),
    ("/usr/java/lib/fonts/STHeiti-Medium.ttf", 0),
    ("/var/local/font/mnt/STHeiti-Medium.ttf", 0),
    ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 0),
]

_font_cache: dict = {}


def get_font(size: int):
    size = max(int(size), 8)
    if size in _font_cache:
        return _font_cache[size]
    for rel, idx in FONT_FILES:
        p = Path(rel)
        if not p.is_absolute():
            p = BASE / rel
        if p.exists():
            try:
                f = ImageFont.truetype(str(p), size, index=idx)
                _font_cache[size] = f
                return f
            except Exception:
                continue
    f = ImageFont.load_default()
    _font_cache[size] = f
    return f


# 天气代码 -> (中文描述, 图标类型)
WCODE = {
    0: ("晴", "sun"), 1: ("少云", "suncloud"), 2: ("多云", "cloud"), 3: ("阴", "cloud"),
    45: ("雾", "fog"), 48: ("雾凇", "fog"),
    51: ("毛毛雨", "drizzle"), 53: ("小雨", "drizzle"), 55: ("细雨", "rain"),
    56: ("冻雨", "rain"), 57: ("冻雨", "rain"),
    61: ("小雨", "rain"), 63: ("中雨", "rain"), 65: ("大雨", "rain"),
    66: ("冻雨", "rain"), 67: ("冻雨", "rain"),
    71: ("小雪", "snow"), 73: ("中雪", "snow"), 75: ("大雪", "snow"), 77: ("霰", "snow"),
    80: ("阵雨", "rain"), 81: ("阵雨", "rain"), 82: ("暴雨", "rain"),
    85: ("阵雪", "snow"), 86: ("阵雪", "snow"),
    95: ("雷阵雨", "storm"), 96: ("雷阵雨", "storm"), 99: ("雷暴", "storm"),
}


def describe_code(code):
    try:
        return WCODE.get(int(code), ("—", "cloud"))
    except (TypeError, ValueError):
        return ("—", "cloud")


# ============================================================
#  数据
# ============================================================
def fetch_weather(cfg, offline=False):
    """取 Open-Meteo 数据（免费、无需 API key），失败时回落到缓存。"""
    cache_path = BASE / cfg["cache"]

    def load_cache():
        try:
            return json.loads(cache_path.read_text("utf-8"))
        except Exception:
            return None

    if offline:
        return load_cache()

    params = {
        "latitude": cfg["lat"],
        "longitude": cfg["lon"],
        "current": "temperature_2m,apparent_temperature,weather_code",
        "daily": ("weather_code,temperature_2m_max,temperature_2m_min,"
                  "precipitation_probability_max,sunrise,sunset"),
        "hourly": "precipitation_probability",
        "timezone": "auto",
        "forecast_days": str(cfg["forecast_days"]),
    }
    url = "https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(params)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "kindle-photo-wall/1.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
        data["_fetched_at"] = dt.datetime.now().isoformat(timespec="seconds")
        try:
            cache_path.write_text(json.dumps(data, ensure_ascii=False), "utf-8")
        except Exception:
            pass
        return data
    except Exception as e:
        print(f"[warn] 天气获取失败（{e}），改用缓存", file=sys.stderr)
        return load_cache()


def read_battery():
    for p in ("/sys/class/power_supply/battery/capacity",
              "/sys/class/power_supply/max77696_battery/capacity"):
        try:
            return int(Path(p).read_text().strip())
        except Exception:
            continue
    return None


# ============================================================
#  照片
# ============================================================
EXTS = (".jpg", ".jpeg", ".png", ".bmp", ".webp", ".gif")


def list_photos(folder: Path):
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir() if p.suffix.lower() in EXTS)


def pick_photo(folder: Path, day: dt.date):
    """按日期选图：同一天内多次刷新不会变，换天才换照片。"""
    files = list_photos(folder)
    if not files:
        return None
    h = int(hashlib.md5(day.isoformat().encode()).hexdigest(), 16)
    return files[h % len(files)]


def fit_photo(path, w, h, zoom=1.0):
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)
    # 先按比例裁切填满，再转灰度
    im = ImageOps.fit(im, (int(w * zoom), int(h * zoom)),
                      method=Image.LANCZOS, centering=(0.5, 0.42))
    if zoom != 1.0:
        left = (im.width - w) // 2
        top = (im.height - h) // 2
        im = im.crop((left, top, left + w, top + h))
    im = im.convert("L")
    im = ImageOps.autocontrast(im, cutoff=0.2)
    im = ImageEnhance.Contrast(im).enhance(1.06)
    return im


def placeholder_photo(w, h):
    """没有照片时画一块安静的灰底，不刺眼。"""
    im = Image.new("L", (w, h), 236)
    d = ImageDraw.Draw(im)
    cx, cy = w // 2, h // 2
    d.ellipse((cx - 46, cy - 76, cx + 46, cy + 16), outline=190, width=3)
    d.line((cx - 70, cy + 50, cx - 20, cy - 6, cx + 14, cy + 28, cx + 74, cy - 30),
           fill=190, width=3, joint="curve")
    return im


# ============================================================
#  绘图小工具
# ============================================================
def text(d, xy, s, size, fill=INK, anchor="la"):
    d.text(xy, s, font=get_font(size), fill=fill, anchor=anchor)


def rule(d, x0, x1, y, fill=FAINT, width=1):
    d.line((x0, y, x1, y), fill=fill, width=width)


def draw_weather_icon(d, cx, cy, r, kind):
    """全部用几何图形画，适合电子墨水。"""
    lw = max(2, int(r * 0.10))

    def sun(radius, ox=0, oy=0, rays=True):
        d.ellipse((cx + ox - radius, cy + oy - radius, cx + ox + radius, cy + oy + radius),
                  outline=INK, width=lw)
        if rays:
            import math
            for i in range(8):
                a = math.pi * i / 4
                x1 = cx + ox + math.cos(a) * radius * 1.35
                y1 = cy + oy + math.sin(a) * radius * 1.35
                x2 = cx + ox + math.cos(a) * radius * 1.85
                y2 = cy + oy + math.sin(a) * radius * 1.85
                d.line((x1, y1, x2, y2), fill=INK, width=lw)

    def _cloud(cx, cy, w, h, fill):
        d.rounded_rectangle((cx - w / 2, cy - h * 0.12, cx + w / 2, cy + h / 2),
                            radius=int(h * 0.30), fill=fill)
        d.ellipse((cx - w * 0.48, cy - h * 0.34, cx - w * 0.04, cy + h * 0.28), fill=fill)
        d.ellipse((cx - w * 0.26, cy - h * 0.66, cx + w * 0.28, cy + h * 0.12), fill=fill)
        d.ellipse((cx + w * 0.04, cy - h * 0.38, cx + w * 0.48, cy + h * 0.26), fill=fill)

    def cloud(ox=0.0, oy=0.0, s=1.0):
        cx2, cy2 = cx + ox, cy + oy
        w, h = r * 2.0 * s, r * 1.5 * s
        _cloud(cx2, cy2, w, h, INK)
        _cloud(cx2, cy2, w - lw * 2.4, h - lw * 2.4, PAPER)

    if kind == "sun":
        sun(r * 0.52)
    elif kind == "suncloud":
        sun(r * 0.28, ox=-r * 0.46, oy=-r * 0.50, rays=True)
        cloud(ox=r * 0.14, oy=r * 0.34, s=0.95)
    elif kind == "cloud":
        cloud(s=1.0)
    elif kind == "fog":
        cloud(oy=-r * 0.20, s=0.92)
        for i in range(3):
            y = cy + r * (0.44 + i * 0.24)
            d.line((cx - r * 0.78, y, cx + r * 0.78, y), fill=INK, width=lw)
    elif kind == "drizzle":
        cloud(oy=-r * 0.26, s=1.0)
        for i in (-0.42, 0.0, 0.42):
            d.line((cx + r * i, cy + r * 0.50, cx + r * (i - 0.12), cy + r * 0.80),
                   fill=INK, width=lw)
    elif kind == "rain":
        cloud(oy=-r * 0.26, s=1.0)
        for i in (-0.45, 0.0, 0.45):
            d.line((cx + r * i, cy + r * 0.48, cx + r * (i - 0.18), cy + r * 1.04),
                   fill=INK, width=lw)
    elif kind == "snow":
        cloud(oy=-r * 0.26, s=1.0)
        for i in (-0.45, 0.0, 0.45):
            for dx in (-0.10, 0.0, 0.10):
                d.line((cx + r * (i + dx), cy + r * 0.60, cx + r * (i + dx), cy + r * 0.86),
                       fill=INK, width=lw)
            d.line((cx + r * (i - 0.10), cy + r * 0.73, cx + r * (i + 0.10), cy + r * 0.73),
                   fill=INK, width=lw)
    elif kind == "storm":
        cloud(oy=-r * 0.32, s=1.0)
        d.line((cx + r * 0.10, cy + r * 0.36, cx - r * 0.16, cy + r * 0.72,
                cx + r * 0.06, cy + r * 0.72, cx - r * 0.14, cy + r * 1.06),
               fill=INK, width=lw, joint="curve")
    else:
        cloud(s=1.0)


def draw_month(d, box, today, head_size, num_size):
    x, y, w, h = box
    cols = 7
    cw = w / cols
    # 星期表头
    for i, ch in enumerate("一二三四五六日"):
        text(d, (x + cw * (i + 0.5), y), ch, head_size, SOFT, "mt")

    head_h = head_size * 1.9
    weeks = calendar.Calendar(firstweekday=0).monthdayscalendar(today.year, today.month)
    rows = max(len(weeks), 5)
    rh = (h - head_h) / rows
    num_font = get_font(num_size)

    for r, week in enumerate(weeks):
        cy = y + head_h + rh * r + rh / 2
        for c, day in enumerate(week):
            if day == 0:
                continue
            cxp = x + cw * (c + 0.5)
            if day == today.day:
                pad = num_size * 0.72
                d.rounded_rectangle((cxp - pad, cy - pad, cxp + pad, cy + pad),
                                    radius=int(pad * 0.55), fill=INK)
                d.text((cxp, cy), str(day), font=num_font, fill=PAPER, anchor="mm")
            else:
                d.text((cxp, cy), str(day), font=num_font, fill=INK, anchor="mm")


# ============================================================
#  布局：横屏（左图 + 右信息）
# ============================================================
def render_landscape(cfg, now, weather, photo_path):
    W, H = cfg["width"], cfg["height"]
    img = Image.new("L", (W, H), PAPER)
    d = ImageDraw.Draw(img)

    pw = int(W * cfg["photo_ratio"])
    ph = H

    # ---- 照片 ----
    try:
        im = fit_photo(photo_path, pw, ph, cfg["photo_zoom"]) if photo_path else placeholder_photo(pw, ph)
    except Exception as e:
        print(f"[warn] 照片处理失败：{e}", file=sys.stderr)
        im = placeholder_photo(pw, ph)
    img.paste(im, (0, 0))

    # 分隔线
    d.line((pw, 0, pw, H), fill=180, width=2)

    # ---- 右侧信息区 ----
    P = int(H * 0.043)
    x = pw + P
    cw = W - x - P

    y_date = H * 0.044
    y_week = H * 0.105
    y_time = H * 0.155
    y_r1 = H * 0.352
    y_wx = H * 0.378
    y_r2 = H * 0.535
    y_fc = H * 0.558
    y_cal = H * 0.700
    y_foot = H * 0.952

    # 日期
    text(d, (x, y_date), f"{now.month}月{now.day}日", int(H * 0.058), INK)
    text(d, (x, y_week), f"星期{'一二三四五六日'[now.weekday()]}", int(H * 0.031), SOFT)

    # 时间
    text(d, (x, y_time), now.strftime("%H:%M"), int(H * 0.128), INK)

    rule(d, x, x + cw, y_r1)

    # 天气
    cur = (weather or {}).get("current") or {}
    daily = (weather or {}).get("daily") or {}
    code = cur.get("weather_code")
    desc, kind = describe_code(code)
    temp = cur.get("temperature_2m")
    feels = cur.get("apparent_temperature")

    icon_r = H * 0.050
    icon_cx, icon_cy = x + icon_r * 1.15, y_wx + icon_r * 1.30
    draw_weather_icon(d, icon_cx, icon_cy, icon_r, kind)

    tx = x + icon_r * 2.7
    if temp is not None:
        text(d, (tx, y_wx), f"{round(temp)}°", int(H * 0.075), INK)
        tw = d.textlength(f"{round(temp)}°", font=get_font(int(H * 0.075)))
        text(d, (tx + tw + H * 0.020, y_wx + H * 0.048), desc, int(H * 0.028), MID)
    else:
        text(d, (tx, y_wx), "--°", int(H * 0.075), INK)
        text(d, (tx + H * 0.13, y_wx + H * 0.048), "无数据", int(H * 0.028), SOFT)

    tmax = (daily.get("temperature_2m_max") or [None])[0]
    tmin = (daily.get("temperature_2m_min") or [None])[0]
    pop = (daily.get("precipitation_probability_max") or [None])[0]
    feels = cur.get("apparent_temperature")
    bits = []
    if tmin is not None and tmax is not None:
        bits.append(f"{round(tmin)}°–{round(tmax)}°")
    if pop is not None:
        bits.append(f"降水 {round(pop)}%")
    if feels is not None and temp is not None and abs(feels - temp) >= 2:
        bits.append(f"体感 {round(feels)}°")
    if bits:
        text(d, (tx, y_wx + H * 0.086), " · ".join(bits), int(H * 0.023), SOFT)

    # 未来几天
    rule(d, x, x + cw, y_r2)
    dates = daily.get("time") or []
    codes = daily.get("weather_code") or []
    n = min(len(dates), cfg["forecast_days"])
    if n:
        colw = cw / n
        for i in range(n):
            try:
                dd = dt.date.fromisoformat(dates[i])
            except Exception:
                continue
            label = "今" if i == 0 else "一二三四五六日"[dd.weekday()]
            cxp = x + colw * (i + 0.5)
            text(d, (cxp, y_fc), label, int(H * 0.022), SOFT, "mt")
            _, k2 = describe_code(codes[i] if i < len(codes) else None)
            draw_weather_icon(d, cxp, y_fc + H * 0.062, H * 0.023, k2)
            hi = (daily.get("temperature_2m_max") or [None] * n)[i]
            lo = (daily.get("temperature_2m_min") or [None] * n)[i]
            if hi is not None and lo is not None:
                text(d, (cxp, y_fc + H * 0.096), f"{round(hi)}°/{round(lo)}°",
                     int(H * 0.021), MID, "mt")

    # 月历
    draw_month(d, (x, y_cal, cw, y_foot - y_cal - H * 0.020), now.date(),
               int(H * 0.021), int(H * 0.027))

    # 脚注
    sunrise = (daily.get("sunrise") or [""])[0]
    sunset = (daily.get("sunset") or [""])[0]
    foot = []
    if sunrise and sunset:
        foot.append(f"日出 {sunrise[-5:]} · 日落 {sunset[-5:]}")
    bat = read_battery() if cfg["battery"] else None
    if bat is not None:
        foot.append(f"电量 {bat}%")
    if foot:
        text(d, (x, y_foot), "   ".join(foot), int(H * 0.021), SOFT)

    return img


# ============================================================
#  布局：竖屏（上图 + 下信息）
# ============================================================
def render_portrait(cfg, now, weather, photo_path):
    W, H = cfg["width"], cfg["height"]
    img = Image.new("L", (W, H), PAPER)
    d = ImageDraw.Draw(img)

    ph = int(H * cfg["photo_ratio"])
    try:
        im = fit_photo(photo_path, W, ph, cfg["photo_zoom"]) if photo_path else placeholder_photo(W, ph)
    except Exception:
        im = placeholder_photo(W, ph)
    img.paste(im, (0, 0))
    d.line((0, ph, W, ph), fill=180, width=2)

    P = int(W * 0.048)
    x = P
    cw = W - 2 * P
    top = ph + P
    bottom = H - P
    inner_h = bottom - top

    # 上部：日期 + 时间
    text(d, (x, top), f"{now.month}月{now.day}日 星期{'一二三四五六日'[now.weekday()]}",
         int(W * 0.036), INK)
    text(d, (x, top + inner_h * 0.095), now.strftime("%H:%M"), int(W * 0.095), INK)
    tw = d.textlength(now.strftime("%H:%M"), font=get_font(int(W * 0.095)))

    cur = (weather or {}).get("current") or {}
    daily = (weather or {}).get("daily") or {}
    desc, kind = describe_code(cur.get("weather_code"))
    temp = cur.get("temperature_2m")

    # 右侧：天气
    wcx = x + cw * 0.62
    draw_weather_icon(d, wcx, top + inner_h * 0.115, W * 0.038, kind)
    wx = wcx + W * 0.062
    if temp is not None:
        t_font = int(W * 0.058)
        text(d, (wx, top + inner_h * 0.060), f"{round(temp)}°", t_font, INK)
        tw = d.textlength(f"{round(temp)}°", font=get_font(t_font))
        text(d, (wx + tw + W * 0.014, top + inner_h * 0.105), desc, int(W * 0.024), MID)

    # 中部：未来几天
    y_fc = top + inner_h * 0.305
    dates = daily.get("time") or []
    codes = daily.get("weather_code") or []
    n = min(len(dates), cfg["forecast_days"]) or 0
    if n:
        colw = cw / n
        for i in range(n):
            try:
                dd = dt.date.fromisoformat(dates[i])
            except Exception:
                continue
            label = "今" if i == 0 else "一二三四五六日"[dd.weekday()]
            cxp = x + colw * (i + 0.5)
            text(d, (cxp, y_fc), label, int(W * 0.022), SOFT, "mt")
            _, k2 = describe_code(codes[i] if i < len(codes) else None)
            draw_weather_icon(d, cxp, y_fc + inner_h * 0.078, W * 0.023, k2)
            hi = (daily.get("temperature_2m_max") or [None] * n)[i]
            lo = (daily.get("temperature_2m_min") or [None] * n)[i]
            if hi is not None and lo is not None:
                text(d, (cxp, y_fc + inner_h * 0.128), f"{round(hi)}°/{round(lo)}°",
                     int(W * 0.021), MID, "mt")

    # 下部：月历
    y_cal = top + inner_h * 0.525
    draw_month(d, (x, y_cal, cw, bottom - y_cal), now.date(),
               int(W * 0.021), int(W * 0.026))

    return img


# ============================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true", help="不联网，用缓存数据")
    ap.add_argument("--layout", choices=["landscape", "portrait"], default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--photo", default=None, help="指定一张照片")
    ap.add_argument("--date", default=None, help="调试用：YYYY-MM-DD")
    ap.add_argument("--rotate", choices=["cw", "ccw"], default=None,
                    help="给 eips 用：cw = 设备顺时针横放（原顶部朝右）；ccw = 逆时针。"
                         "输出会变成 1072x1448 的预旋转图")
    ap.add_argument("--no-battery", action="store_true")
    a = ap.parse_args()

    cfg = dict(CFG)
    if a.layout:
        cfg["layout"] = a.layout
        if a.layout == "portrait":
            cfg["width"], cfg["height"] = 1072, 1448
        else:
            cfg["width"], cfg["height"] = 1448, 1072
    if a.no_battery:
        cfg["battery"] = False

    now = dt.datetime.now()
    if a.date:
        d0 = dt.date.fromisoformat(a.date)
        now = now.replace(year=d0.year, month=d0.month, day=d0.day)

    weather = fetch_weather(cfg, offline=a.offline)

    if a.photo:
        photo = Path(a.photo)
    else:
        photo = pick_photo(BASE / cfg["photo_dir"], now.date())
    print(f"[info] 照片：{photo if photo else '（无，使用占位图）'}")

    if cfg["layout"] == "portrait":
        img = render_portrait(cfg, now, weather, photo)
    else:
        img = render_landscape(cfg, now, weather, photo)

    if a.rotate == "cw":
        img = img.rotate(-90, expand=True, fillcolor=255)
    elif a.rotate == "ccw":
        img = img.rotate(90, expand=True, fillcolor=255)

    out = Path(a.out or cfg["out"])
    if not out.is_absolute():
        out = BASE / out
    img.save(out, "PNG", optimize=True)
    print(f"[ok] 已生成 {out}  ({img.width}x{img.height}, mode={img.mode})")


if __name__ == "__main__":
    main()
