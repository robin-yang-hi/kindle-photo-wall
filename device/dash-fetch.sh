#!/bin/sh
# ============================================================
# Kindle 照片墙 · 设备端（Paperwhite 4 / 固件 5.12.2）
#
# 刷屏优先用 hotfix 自带的 FBInk（/mnt/us/libkh/bin/fbink），
# 它支持波形选择（A2 快刷无闪、GC16 全刷清残影）并自动缩放；
# 如果 FBInk 不可用或调用失败，自动回退到系统自带 eips。
#
# 模式（在 env.conf 里改）：
#   DASH_MODE=always  常亮，插电挂墙，时间分钟级准确
#   DASH_MODE=sleep   RTC 定时唤醒，电池可撑数周，时间最多旧一个间隔
# ============================================================

DIR="/mnt/us/kindle-photo-wall"
OUT="$DIR/device/dash.png"
LOG="$DIR/device/dash.log"
EIPS="/usr/sbin/eips"
FBINK="/mnt/us/libkh/bin/fbink"

# 读配置
[ -f "$DIR/device/env.conf" ] && . "$DIR/device/env.conf"
MODE="${DASH_MODE:-always}"
INTERVAL="${DASH_INTERVAL:-60}"
SLEEP_INTERVAL="${DASH_SLEEP_INTERVAL:-1800}"
FULL_EVERY="${DASH_FULL_EVERY:-15}"
URL="${DASH_URL:-http://192.168.1.100:8810/dash.png}"

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>&1; }

# FBInk 可用性：FAT 分区上 -x 判断不可靠，直接试运行
have_fbink=0
if [ -f "$FBINK" ]; then
    if "$FBINK" -q -V >/dev/null 2>&1; then
        have_fbink=1
        log "FBInk 可用: $("$FBINK" -q -V 2>&1 | head -1)"
    else
        log "FBInk 存在但无法执行，改用 eips"
    fi
else
    log "未找到 FBInk，改用 eips"
fi

wifi_on() {
    lipc-set-prop com.lab126.wifid enable 1 2>/dev/null
    i=0
    while [ $i -lt 20 ]; do
        [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = "CONNECTED" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# 刷一张图。$1=文件路径，$2=1 表示强制全刷（清残影）
paint() {
    _img="$1"
    _full="${2:-0}"
    if [ "$have_fbink" -eq 1 ]; then
        # 注意：FBInk 1.25 的 -g 不接受 ",f" 子选项（那是 FBInk 1.26+ 的写法），
        # 全刷要用独立的 -f 标志。写错会导致每次都回退 eips。
        if [ "$_full" -eq 1 ]; then
            "$FBINK" -q -g "file=$_img,w=-1,h=-1" -W GC16 -f 2>>"$LOG"
        else
            "$FBINK" -q -g "file=$_img,w=-1,h=-1" -W A2 2>>"$LOG"
        fi
        if [ $? -eq 0 ]; then
            return 0
        fi
        log "fbink 刷屏失败，本次回退 eips"
        have_fbink=0
    fi
    eips -g "$_img" >>"$LOG" 2>&1
    [ "$_full" -eq 1 ] && eips '' >>"$LOG" 2>&1
    return 0
}

n=0
draw() {
    if curl -s --max-time 40 -o "$OUT" "$URL"; then
        n=$((n + 1))
        if [ $((n % FULL_EVERY)) -eq 0 ]; then
            paint "$OUT" 1
        else
            paint "$OUT" 0
        fi
        log "已刷新 #$n"
        return 0
    fi
    log "拉取失败: $URL"
    return 1
}

log "===== 启动 mode=$MODE url=$URL fullEvery=$FULL_EVERY ====="

# 停掉原生 GUI，防止它盖掉我们的画面
# 恢复方法：跑"照片墙 - 停止"，或 initctl start framework
initctl stop framework >>"$LOG" 2>&1
sleep 2

# 逃生通道：Kindle 进入 USB 模式时，主机接管 /mnt/us，标记文件随之不可见。
# 借此判断"用户插线了"，自动把界面还回去再退出，避免屏幕被钉住点不了书。
usb_attached() { [ ! -f "$DIR/device/keep-running" ]; }

restore_ui() {
    log "检测到 USB 连接，恢复原生界面并退出"
    initctl start framework >>"$LOG" 2>&1
    rm -f "$DIR/device/dash.pid"
    exit 0
}

if [ "$MODE" = "sleep" ]; then
    while true; do
        usb_attached && restore_ui
        wifi_on && draw
        rtcwake -d /dev/rtc1 -m no -s "$SLEEP_INTERVAL" >>"$LOG" 2>&1
        echo mem >/sys/power/state
    done
else
    while true; do
        usb_attached && restore_ui
        draw
        sleep "$INTERVAL"
    done
fi
