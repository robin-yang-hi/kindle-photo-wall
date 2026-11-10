#!/bin/sh
# ============================================================
# 番茄钟 · 共享状态库（被 render.sh / pomowatch.sh / paint2.sh source）
#
# 状态文件 device/pomodoro.state（全部 key=value，原子写）：
#   PHASE=idle|focus|break|long   当前阶段
#   END=<epoch 秒>                当前阶段结束时刻（运行中有效）
#   PAUSED=0|1                    暂停标记（仅专注阶段）
#   LEFT=<秒>                     暂停时的剩余秒数
#   ARMED=0|1                     调时确认态：点按进入后先暂停待确认，按「开始」才开跑
#   DUR=<分钟>                    本轮专注时长（±5 按钮调整，跨会话记忆；1..99）
#   CYCLE=<n>                     本组已完成的番茄数（决定下一休是短休还是长休）
#
# 状态机：
#   idle --点按--> armed(暂停的 focus) --按钮[开始]--> focus --到点--> break/long
#        长按任意非 idle 阶段 --> idle
#   番茄计数：CYCLE 每 % POMO_EVERY == 0 时下一休为长休
# ============================================================

POMO_STATE="${POMO_STATE:-${DIR:-/mnt/us/kindle-photo-wall}/device/pomodoro.state}"

# 读状态：设置 PM_PHASE/PM_END/PM_PAUSED/PM_LEFT/PM_ARMED/PM_DUR/PM_CYCLE/PM_TODAY/PM_DAY
# （TODAY=今日完成的番茄数，DAY=归属日期，跨天自动清零）
pomo_read() {
    PM_PHASE=idle; PM_END=0; PM_PAUSED=0; PM_LEFT=0; PM_ARMED=0; PM_DUR=""
    PM_CYCLE=0; PM_TODAY=0; PM_DAY=""
    [ -f "$POMO_STATE" ] || return 0
    eval "$(grep -E '^(PHASE|END|PAUSED|LEFT|ARMED|DUR|CYCLE|TODAY|DAY)=[a-zA-Z0-9-]*$' "$POMO_STATE" 2>/dev/null | sed 's/^/PM_/')"
    return 0
}

pomo_write() {
    printf 'PHASE=%s\nEND=%s\nPAUSED=%s\nLEFT=%s\nARMED=%s\nDUR=%s\nCYCLE=%s\nTODAY=%s\nDAY=%s\n' \
        "$PM_PHASE" "$PM_END" "$PM_PAUSED" "$PM_LEFT" "${PM_ARMED:-0}" "${PM_DUR:-}" "$PM_CYCLE" \
        "${PM_TODAY:-0}" "${PM_DAY:-$(date +%F)}" >"$POMO_STATE.tmp"
    mv -f "$POMO_STATE.tmp" "$POMO_STATE"
    return 0
}

# 今日完成数 +1（跨天先清零）
pomo_count_today() {
    _td=$(date +%F)
    if [ "${PM_DAY:-}" != "$_td" ]; then PM_TODAY=0; PM_DAY=$_td; fi
    PM_TODAY=$(( ${PM_TODAY:-0} + 1 ))
}

# 剩余秒数（暂停时用 LEFT，运行时用 END-now；负数不归零，由调用方决定）
pomo_left() {
    if [ "$PM_PAUSED" = "1" ]; then
        echo "$PM_LEFT"
    else
        echo $(( PM_END - $(date +%s) ))
    fi
}

# 格式化为 MM:SS
pomo_mmss() {
    _s=$1
    case $_s in ''|*[!0-9]*) _s=0 ;; esac
    [ "$_s" -lt 0 ] && _s=0
    printf '%02d:%02d' $((_s / 60)) $((_s % 60))
}

pomo_start_focus() {
    _d=${PM_DUR:-${POMO_FOCUS:-25}}
    case $_d in ''|*[!0-9]*) _d=25 ;; esac
    [ "$_d" -lt 1 ] && _d=1; [ "$_d" -gt 99 ] && _d=99
    PM_PHASE=focus
    PM_END=$(( $(date +%s) + _d * 60 ))
    PM_ARMED=0; PM_PAUSED=0; PM_LEFT=0; PM_DUR=$_d
    pomo_write
}

# 进入调时确认态（armed）：暂停着显示时长，确认后由 pomo_launch 开跑。
# DUR 跨会话记忆：上次调成 45 分钟，这次点按进来还是 45:00。
pomo_arm() {
    _d=${PM_DUR:-${POMO_FOCUS:-25}}
    case $_d in ''|*[!0-9]*) _d=25 ;; esac
    [ "$_d" -lt 1 ] && _d=1; [ "$_d" -gt 99 ] && _d=99
    PM_PHASE=focus
    PM_ARMED=1; PM_PAUSED=1
    PM_END=0; PM_LEFT=$(( _d * 60 )); PM_DUR=$_d
    pomo_write
}

# 调整时长（仅调时态有效）：$1=分钟，可负；范围 1..99（翻牌卡两位分钟）
pomo_adjust() {
    [ "${PM_ARMED:-0}" = "1" ] || return 1
    _m=$(( ${PM_LEFT:-0} / 60 + $1 ))
    [ "$_m" -lt 1 ] && _m=1
    [ "$_m" -gt 99 ] && _m=99
    PM_LEFT=$(( _m * 60 )); PM_DUR=$_m
    pomo_write
    return 0
}

# 调时态确认 → 正式开跑
pomo_launch() {
    [ "${PM_ARMED:-0}" = "1" ] || return 1
    PM_END=$(( $(date +%s) + ${PM_LEFT:-0} ))
    PM_ARMED=0; PM_PAUSED=0
    pomo_write
    return 0
}

# 休息：CYCLE % POMO_EVERY == 0 → 长休，否则短休（调用前 CYCLE 应已加一）
pomo_start_break() {
    _m=$(( ${PM_CYCLE:-0} % ${POMO_EVERY:-4} ))
    _m=${_m#-}
    if [ "$_m" -eq 0 ]; then
        PM_PHASE=long; _d=${POMO_LONG:-15}
    else
        PM_PHASE=break; _d=${POMO_BREAK:-5}
    fi
    PM_END=$(( $(date +%s) + _d * 60 ))
    PM_PAUSED=0; PM_LEFT=0
    pomo_write
}

pomo_idle() {
    PM_PHASE=idle; PM_END=0; PM_PAUSED=0; PM_LEFT=0; PM_ARMED=0
    pomo_write
}

pomo_pause() {
    [ "$PM_PHASE" = "focus" ] || return 1
    PM_LEFT=$(pomo_left)
    [ "$PM_LEFT" -lt 0 ] && PM_LEFT=0
    PM_PAUSED=1
    pomo_write
}

pomo_resume() {
    [ "$PM_PHASE" = "focus" ] || return 1
    PM_END=$(( $(date +%s) + ${PM_LEFT:-0} ))
    PM_PAUSED=0
    pomo_write
}

# 到点推进：focus → 休息（CYCLE+1）；休息 → 下一轮专注（POMO_AUTO）或待命
# stdout 返回一行人类可读的变更说明
pomo_advance() {
    case "$PM_PHASE" in
        focus)
            PM_CYCLE=$(( ${PM_CYCLE:-0} + 1 ))
            pomo_count_today
            pomo_start_break
            if [ "$PM_PHASE" = "long" ]; then echo "专注完成，长休息 ${POMO_LONG:-15} 分钟"
            else echo "专注完成，短休息 ${POMO_BREAK:-5} 分钟"; fi
            ;;
        break|long)
            if [ "${POMO_AUTO:-1}" = "1" ]; then
                pomo_start_focus
                echo "休息结束，自动进入下一轮专注"
            else
                pomo_idle
                echo "休息结束，番茄钟待命"
            fi
            ;;
    esac
}
