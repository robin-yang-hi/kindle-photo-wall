#!/bin/sh
# ============================================================
# 番茄钟 · 触摸监听（点按 / 长按手势，全屏任意位置）
#
# 实测（2026-11-09, goodix-ts /dev/input/event2，16 字节事件）：
#   手指按下 = EV_ABS(code=53/54 POSITION_X/Y) 序列
#   手指抬起 = EV_ABS(code=57 TRACKING_ID) value=-1 (ff ff ff ff)
#   （没有 BTN_TOUCH，全靠 MT 事件判断）
#
# 手势（与状态相关，见 pomo.sh）：
#   照片墙待命：点按任意处=进入调时确认态（armed，暂停着显示时长）
#   调时页（focus+ARMED=1，只认三个按钮热区）：
#     按钮1 −5分 / 按钮2 开始 / 按钮3 +5分
#     长按 ± 键一次 ±3 步；区外长按=取消回照片墙；区外点按忽略
#   专注页（运行中，只认三个按钮热区）：
#     按钮1 休息/继续：运行中按下=暂停（此时按钮变"继续"），已暂停按下=继续
#     按钮2 退出：结束番茄钟回到照片墙
#     按钮3 重置：当前轮倒计时重置回所选时长（轮次/今日完成不变）
#     热区外：点按、长按一律忽略
#   休息中：点按=跳过休息进入专注；长按=结束回照片墙
#
# 反馈链路：改状态 → fbink 立即打印 ASCII 确认 → 写 cmd=paint，
# 主循环 ≤5 秒内按新状态重画整屏。
# ============================================================
DIR="/mnt/us/kindle-photo-wall"
LOG="$DIR/device/dash.log"
CMD="$DIR/device/cmd"

. "$DIR/device/env.conf" 2>/dev/null
. "$DIR/device/pomo.sh"
. "$DIR/assets/layout.sh" 2>/dev/null        # 按钮热区坐标（POMO_BTN_*）

[ "${POMO:-1}" = "1" ] || exit 0

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>&1; }
trap "" 1 15

find_tsdev() {
    for _d in /sys/class/input/input*; do
        _n=$(cat "$_d/name" 2>/dev/null)
        case "$_n" in
            *goodix*|*gt9*|*touch*|*ft5*|*ili2*)
                _i=${_d##*/}
                echo "/dev/input/event${_i#input}"
                return 0 ;;
        esac
    done
    return 1
}

DEV="${POMO_TS_DEV:-$(find_tsdev)}"
if [ -z "$DEV" ] || [ ! -c "$DEV" ]; then
    log "番茄钟: 找不到触摸 input 节点，手势不可用"
    exit 0
fi

LONG_MS="${POMO_LONGPRESS_MS:-800}"

# 触摸瞬间给个 ASCII 确认（fbink 内置字体无中文，正式画面 ≤5 秒内跟上）
feedback() {
    _fb="${FBINK_BIN:-/mnt/us/libkh/bin/fbink}"
    [ -x "$_fb" ] && "$_fb" -q "POMODORO: $1" >/dev/null 2>&1
    return 0
}

# 主循环立刻重画（paint2 会按 pomodoro.state 渲染）
repaint() {
    printf 'paint\n' >"$CMD" 2>/dev/null
    return 0
}

# 触摸原始坐标 → 屏幕坐标。goodix 报竖屏坐标（rawX 0..1071, rawY 0..1447），
# 画面横屏 1448x1072。2026-11-10 按三颗按钮实测校准：
#   屏幕X = rawY（X 轴不镜像，试过 1447-rawY 左右按钮正好对调）
#   屏幕Y = 1071 - rawX                                          → TOUCH_MAP=5
map_xy() { # rawx rawy → SX SY
    case "${POMO_TOUCH_MAP:-0}" in
        1) SX=$2; SY=$1 ;;
        2) SX=$2; SY=$(( 1071 - $1 )) ;;
        3) SX=$(( 1447 - $2 )); SY=$1 ;;
        4) SX=$(( 1447 - $2 )); SY=$(( 1071 - $1 )) ;;
        5) SX=$2; SY=$(( 1071 - $1 )) ;;
        *) SX=$1; SY=$2 ;;
    esac
}

# 专注页三个胶囊按钮热区 → rest|exit|reset（不在区内返回空）
pomo_btn() {
    _by=${POMO_BTN_Y:-952}; _bh=${POMO_BTN_H:-100}
    _bx=${POMO_BTN_X0:-304}; _bw=${POMO_BTN_W:-240}; _bg=${POMO_BTN_GAP:-60}
    [ "$2" -ge "$_by" ] && [ "$2" -le $(( _by + _bh )) ] || return 0
    _zx=$(( $1 - _bx ))
    [ "$_zx" -ge 0 ] || return 0
    _i=$(( _zx / ( _bw + _bg ) ))
    [ "$_i" -le 2 ] || return 0
    [ $(( _zx - _i * ( _bw + _bg ) )) -le "$_bw" ] || return 0
    case $_i in 0) echo rest ;; 1) echo exit ;; 2) echo reset ;; esac
}

on_tap() { # $1=屏幕x $2=屏幕y
    pomo_read
    _act=""
    if [ "$PM_PHASE" = "focus" ]; then
        _b=$(pomo_btn "$1" "$2")
        if [ "$PM_ARMED" = "1" ]; then
            # 调时确认态：左=−5分 中=开始 右=+5分（按钮热区同位置，标签换图）
            _st=${POMO_STEP:-5}
            case "$_b" in
                rest)
                    pomo_adjust $(( -_st )) \
                        && _act="ARMED ${PM_DUR}min (-${_st})"
                    ;;
                exit)
                    pomo_launch \
                        && _act="START ${PM_DUR}min (armed->run)"
                    ;;
                reset)
                    pomo_adjust "$_st" \
                        && _act="ARMED ${PM_DUR}min (+${_st})"
                    ;;
                '')
                    log "番茄钟: 点按($1,$2) 调时页非按钮区，忽略"
                    return 0
                    ;;
            esac
        else
            case "$_b" in
                rest)
                    # 休息/继续合一：运行中按下=暂停，已暂停按下=继续
                    if [ "$PM_PAUSED" = "1" ]; then
                        pomo_resume
                        _act="RESUME (btn, left $(pomo_mmss "$(pomo_left)"))"
                    else
                        pomo_pause
                        _act="PAUSE (btn, left $(pomo_mmss "$(pomo_left)"))"
                    fi
                    ;;
                exit)
                    pomo_idle                 # 退出番茄钟回照片墙待命
                    _act="EXIT (btn)"
                    ;;
                reset)
                    # 重置：当前轮倒计时回到所选时长（DUR），轮次/今日完成不变
                    PM_END=$(( $(date +%s) + ${PM_DUR:-${POMO_FOCUS:-25}} * 60 ))
                    PM_PAUSED=0; PM_LEFT=0
                    pomo_write
                    _act="RESET TIMER (btn, ${PM_DUR:-${POMO_FOCUS:-25}}min)"
                    ;;
                '')
                    log "番茄钟: 点按($1,$2) 专注页非按钮区，忽略"
                    return 0
                    ;;
            esac
        fi
    else
        case "$PM_PHASE" in
            idle)
                pomo_arm
                _act="ARMED (setup, ${PM_DUR}min paused)"
                ;;
            break|long)
                pomo_start_focus
                _act="SKIP BREAK -> FOCUS (${PM_DUR}min)"
                ;;
        esac
    fi
    log "番茄钟: 点按($1,$2) → $_act"
    feedback "$_act"
    repaint
}

on_long() { # $1=屏幕x $2=屏幕y
    pomo_read
    if [ "$PM_PHASE" = "focus" ]; then
        _b=$(pomo_btn "$1" "$2")
        if [ "$PM_ARMED" = "1" ]; then
            # 调时态长按：± 键一次 ±3 步（快速调到 45/90）；开始=按一下；
            # 区外长按 = 取消调时回照片墙（调时态唯一的退出口）
            _st=${POMO_STEP:-5}
            case "$_b" in
                rest)
                    pomo_adjust $(( -3 * _st ))
                    _act="ARMED ${PM_DUR}min (-$(( 3 * _st )))"
                    log "番茄钟: 长按($1,$2) → $_act"
                    feedback "$_act"; repaint
                    return 0
                    ;;
                reset)
                    pomo_adjust $(( 3 * _st ))
                    _act="ARMED ${PM_DUR}min (+$(( 3 * _st )))"
                    log "番茄钟: 长按($1,$2) → $_act"
                    feedback "$_act"; repaint
                    return 0
                    ;;
                exit)
                    on_tap "$1" "$2"; return 0 ;;
                '')
                    pomo_idle
                    log "番茄钟: 长按($1,$2) 取消调时，回照片墙"
                    feedback "CANCEL SETUP"
                    repaint
                    return 0
                    ;;
            esac
        fi
        # 运行中的专注页：长按不响应；落在按钮上则按该按钮处理（防误触更宽容）
        if [ -n "$_b" ]; then
            on_tap "$1" "$2"
        else
            log "番茄钟: 长按($1,$2) 专注页非按钮区，忽略"
        fi
        return 0
    fi
    if [ "$PM_PHASE" = "idle" ]; then
        log "番茄钟: 长按（待命中，忽略）"
        return 0
    fi
    pomo_idle
    log "番茄钟: 长按 → 结束番茄钟，回到照片墙"
    feedback "STOP"
    repaint
}

_down=0
_t0=0
_lx=0; _ly=0
log "番茄钟触摸监听: $DEV（待命点按=调时；调时页 -5/开始/+5；专注页 休息继续/退出/重置；休息中：点按长按通用）"

# 逐条读同一个 fd；只关心两类事件：
#   X/Y(53/54) → 记坐标、记按下时刻
#   TRACKING_ID(57) = -1 → 抬起，按时长分派手势（点按附带落点坐标给按钮热区）
while :; do
    _ev=$(dd bs=16 count=1 2>/dev/null | od -An -tu1)
    [ -n "$_ev" ] || continue
    set -- $_ev
    [ "$9" = "3" ] && [ "${10}" = "0" ] || continue      # 只看 EV_ABS
    if [ "$11" = "53" ] || [ "$11" = "54" ]; then
        _v=$(( ${13} + ${14} * 256 ))                    # value 32bit LE，低两字节够用
        if [ "$11" = "53" ]; then _lx=$_v; else _ly=$_v; fi
        if [ "$_down" -eq 0 ]; then
            _down=1
            _t0=$(date +%s)
        fi
        continue
    fi
    if [ "$11" = "57" ] && [ "$13" = "255" ] && [ "$14" = "255" ] \
        && [ "$15" = "255" ] && [ "$16" = "255" ]; then
        [ "$_down" -eq 1 ] || continue
        _down=0
        _dur=$(( ($(date +%s) - _t0) * 1000 ))
        map_xy "$_lx" "$_ly"
        if [ "$_dur" -ge "$LONG_MS" ]; then
            on_long "$SX" "$SY"
        else
            on_tap "$SX" "$SY"
        fi
    fi
done <"$DEV"
