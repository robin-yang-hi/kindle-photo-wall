# 生成模拟触摸事件的二进制文件（evdev 16 字节事件流）
# struct input_event { tv_sec, tv_usec, type(u16), code(u16), value(s32) }
# 用法: py -3.11 tools/make_tap.py  (生成 tools/tap_*.raw)
import struct
import os

def ev(t, c, v):
    return struct.pack("<IIHHi", 0, 0, t, c, v)

def tap(x, y):
    # ABS_MT_POSITION_X(53) / POSITION_Y(54) / TRACKING_ID(57)=-1 抬起
    return ev(3, 53, x) + ev(3, 54, y) + ev(3, 57, -1)

# 三颗按钮中心的原始坐标（映射4反推：屏幕Y 1002 → rawX 69）
#   休息: screenX 424  -> rawY 1023
#   退出: screenX 724  -> rawY 723
#   重置: screenX 1024 -> rawY 423
out = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(out, "tap_rest.raw"), "wb").write(tap(69, 1023))
open(os.path.join(out, "tap_exit.raw"), "wb").write(tap(69, 723))
open(os.path.join(out, "tap_reset.raw"), "wb").write(tap(69, 423))
print("ok:", [f for f in os.listdir(out) if f.endswith(".raw")])
