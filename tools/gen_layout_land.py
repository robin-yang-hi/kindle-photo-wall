"""由 layout.sh（竖屏）生成 layout-land.sh（横屏）。

只改几何：字号/字模宽度（S_*/DIGIT_W_*/SYM_W_*/PCT_W_*）与素材几何
（CAL_*/HL_W）全部原样继承 —— 字模只有一套，改动这些就要重做全部素材。

用法：py -3.11 gen_layout_land.py
"""
from pathlib import Path

A = Path(__file__).resolve().parent.parent / "render" / "assets"
SRC = A / "layout.sh"
DST = A / "layout-land.sh"

# 横屏 1448x1072：左边照片，右边 500px 信息栏（内容宽 480，与 rule/月历同宽）
OVERRIDE = {
    "W": 1448,
    "H": 1072,
    "PHOTO_X": 0,
    "PHOTO_Y": 0,
    "PHOTO_W": 948,
    "PHOTO_H": 1072,
    "COL1_X": 958,
    "COL2_X": 958,
    "COL_W": 480,
    "Y_DATE": 20,
    "Y_WEEK": 88,
    "Y_TIME": 142,
    "Y_RULE1": 316,
    "Y_ICON": 330,
    "Y_TEMP": 336,
    "Y_DESC": 456,
    "Y_RANGE": 508,
    "Y_POP": 554,
    "Y_RULE2": 610,
    "Y_CAL": 622,
    "Y_HUM": 940,
    "Y_BATT": 996,
    # 横屏右栏只有 480 宽，明天/后天两块横排放不下 → 不画（月历已承担日期）
    "FC_ROWS": 0,
}

lines = ["# 由 tools/gen_layout_land.py 自动生成（横屏 1448x1072），勿手改"]
seen = set()
for raw in SRC.read_text(encoding="utf-8").splitlines():
    s = raw.strip()
    if not s or s.startswith("#") or "=" not in s:
        continue
    k, v = s.split("=", 1)
    seen.add(k)
    lines.append(f"{k}={OVERRIDE.get(k, v)}")
# 竖屏布局里没有的新键（照片区/第二列预报）补在后面
for k, v in OVERRIDE.items():
    if k not in seen:
        lines.append(f"{k}={v}")

DST.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
print("已生成", DST.name, len(lines) - 1, "项")
