#!/bin/sh
# ============================================================
# 电源键三连击 → 退出照片墙（纯物理手势，不依赖网络/USB）
#
# 原理：stay_awake 一直设着 preventScreenSaver=1，所以电源键短按
#   powerd 不会真的休眠（本机实测），按键事件完全空转 —— 正好
#   拿来当退出开关：3 秒内连按 3 次 → 写一行 stop 到 device/cmd，
#   主循环 5 秒内执行恢复原生界面。
#
# 事件格式（32 位内核，16 字节/事件）：
#   sec(4) usec(4) type(2) code(2) value(4)
#   电源键：type=1(EV_KEY) code=116(KEY_POWER) value 1=按下 0=松开
#   （本机 2026-11-09 实测：按下/松开各一条，无重复事件）
#
# 读法：对同一个 fd 逐条 dd（evdev 一次 read 恰好返回一条事件）。
#   空闲时 dd 阻塞在 read 上，零轮询；od 每次只吃 16 字节、跑完即
#   退出，不受 stdio 缓冲影响（cat|od 会攒 4KB 不吐，绝对不能用）。
#
# 由 render.sh 拉起并记录 pid；触发后自行退出，恢复动作交给主循环。
# ============================================================
DIR="/mnt/us/kindle-photo-wall"
LOG="$DIR/device/dash.log"
CMD="$DIR/device/cmd"

. "$DIR/device/env.conf" 2>/dev/null

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>&1; }

# 系统清理后台时会向进程组广播 HUP/TERM，不拦住会无声死掉
trap "" 1 15

# 找电源键的 input 节点：本机实测事件在 bd71827-power（PMIC 电源键），
# snvs-powerkey 挂着但按键不产生事件，跳过它。可用 POWER_DEV 手动指定。
# 注意：sysfs 目录叫 input1，对应的设备节点是 /dev/input/event1。
find_pwdev() {
    for _d in /sys/class/input/input*; do
        _n=$(cat "$_d/name" 2>/dev/null)
        case "$_n" in
            *snvs*) continue ;;
            *bd71827*|*power*|*onkey*|*pwrkey*)
                _i=${_d##*/}
                echo "/dev/input/event${_i#input}"
                return 0 ;;
        esac
    done
    return 1
}

DEV="${POWER_DEV:-$(find_pwdev)}"
if [ -z "$DEV" ] || [ ! -c "$DEV" ]; then
    log "电源键: 找不到可用的 input 节点，三连击退出不可用"
    exit 0
fi

WIN="${POWER_PRESS_WINDOW:-3}"     # 连击窗口（秒）
NEED="${POWER_EXIT_PRESSES:-3}"    # 触发退出的按键次数
[ -n "$WIN" ] || WIN=3
[ -n "$NEED" ] || NEED=3

_n=0
_first=0
log "电源键监听: $DEV（${WIN}s 内连按 ${NEED} 次退出）"

# 只认「按下」(value=1)：字段 9/10=type，11/12=code，13/14/15/16=value
while :; do
    _ev=$(dd bs=16 count=1 2>/dev/null | od -An -tu1)
    [ -n "$_ev" ] || continue
    set -- $_ev
    [ "$9" = "1" ] && [ "${10}" = "0" ] || continue
    [ "$11" = "116" ] && [ "${12}" = "0" ] || continue
    [ "$13" = "1" ] && [ "${14}" = "0" ] && [ "${15}" = "0" ] && [ "${16}" = "0" ] || continue

    _now=$(date +%s)
    if [ $((_now - _first)) -le "$WIN" ]; then
        _n=$((_n + 1))
    else
        _n=1
    fi
    _first=$_now
    log "电源键: 第 ${_n}/${NEED} 次"
    [ "$_n" -ge "$NEED" ] || continue

    log "电源键: ${NEED} 连击达成，发送退出命令"
    # 立刻在屏幕上给个反馈：主循环 ≤5 秒才执行退出，framework 启动还要
    # 十几秒 —— 不提示的话会以为按键没反应（fbink 内置字体无中文，用 ASCII）
    _fb="${FBINK_BIN:-/mnt/us/libkh/bin/fbink}"
    [ -x "$_fb" ] && "$_fb" -q "Exiting photo wall ..." >/dev/null 2>&1
    printf 'stop\n' >"$CMD" 2>/dev/null
    exit 0
done <"$DEV"
