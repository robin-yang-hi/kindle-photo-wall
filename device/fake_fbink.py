#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fbink 模拟器 —— 在电脑上模拟 Kindle 的 fbink 贴图行为。

用法（由 paint.sh 的 FBINK_BIN 变量调用）：
    py -3.11 fake_fbink.py <原fbink路径> -q -b -g "file=X.png,x=36,y=800"

画布保存在 $KPW_CANVAS（默认 ./testrun/canvas.png）。
"""
import os
import re
import sys

from PIL import Image

CANVAS = os.environ.get("KPW_CANVAS", "testrun/canvas.png")
W = int(os.environ.get("KPW_W", 1072))
H = int(os.environ.get("KPW_H", 1448))

args = sys.argv[1:]
g = None
for i, a in enumerate(args):
    if a == "-g" and i + 1 < len(args):
        g = args[i + 1]
    elif a.startswith("file="):
        g = a
if not g:
    sys.exit(0)

m = re.search(r"file=([^,]+)", g)
if not m:
    sys.exit(0)
path = m.group(1)
x = int(re.search(r"x=(-?\d+)", g).group(1)) if re.search(r"x=(-?\d+)", g) else 0
y = int(re.search(r"y=(-?\d+)", g).group(1)) if re.search(r"y=(-?\d+)", g) else 0

canvas = Image.open(CANVAS) if os.path.exists(CANVAS) else Image.new("L", (W, H), 255)
try:
    im = Image.open(path).convert("L")
except Exception as e:
    print(f"[fake-fbink] 无法打开 {path}: {e}", file=sys.stderr)
    sys.exit(1)
canvas.paste(im, (x, y))
canvas.save(CANVAS)
print(f"[fbink] {os.path.basename(path):<24} x={x:<5} y={y}", file=sys.stderr)
