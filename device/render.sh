#!/bin/sh
# ============================================================
# 照片墙 · 主循环
#
# 常亮模式（默认）：插电挂墙，每分钟刷新一次，FTP 服务开着，
#   手机随时可以传/删照片。
# 休眠模式：RTC 定时唤醒，电池可用数周，时间最多旧一个间隔。
#
# 退出：插上数据线（脚本检测到后自动恢复界面），或长按电源键。
# ============================================================

DIR="/mnt/us/kindle-photo-wall"
LOG="$DIR/device/dash.log"
PIDFILE="$DIR/device/dash.pid"

. "$DIR/device/env.conf" 2>/dev/null
. "$DIR/device/pomo.sh" 2>/dev/null
. "$DIR/assets/layout.sh" 2>/dev/null

PAINT="${PAINT_SH:-paint.sh}"   # 合成脚本：v1=paint.sh，v2 双信息带版=paint2.sh
MODE="${DASH_MODE:-always}"
INTERVAL="${DASH_INTERVAL:-60}"
SLEEP_INTERVAL="${DASH_SLEEP_INTERVAL:-1800}"

# 当前应使用的刷新间隔：白天 = DASH_INTERVAL；
# 夜间（NIGHT_START~次日 NIGHT_END，含头含尾前）= NIGHT_INTERVAL。
# 夜间模式省电：刷新少 = CPU/墨水屏/EPDC 活动都少，且凌晨的"新时间"没人看。
cur_interval() {
    if [ "${NIGHT_MODE:-0}" = "1" ]; then
        _h=$(date +%H | sed 's/^0//')
        _ns=${NIGHT_START:-23}; _ne=${NIGHT_END:-7}
        case "$_ns" in ''|*[!0-9]*) _ns=23 ;; esac
        case "$_ne" in ''|*[!0-9]*) _ne=7 ;; esac
        if [ "$_h" -ge "$_ns" ] || [ "$_h" -lt "$_ne" ]; then
            case "${NIGHT_INTERVAL:-600}" in ''|*[!0-9]*) echo 600 ;; *) echo "$NIGHT_INTERVAL" ;; esac
            return 0
        fi
    fi
    echo "$INTERVAL"
}

FTP_PORT="${FTP_PORT:-2121}"
# 运维通道：第二个 FTP，根目录是整个项目（不是 photos/），用来无线改脚本 + 读日志。
# 设 0 关闭。
ADMIN_PORT="${ADMIN_PORT:-2122}"
# 横屏：1=把 framebuffer 转成 1448x1072（layout-land.sh 配套）；FB_ROTATE 是旋转值
LANDSCAPE="${LANDSCAPE:-0}"
FB_ROTATE="${FB_ROTATE:-0}"
FIXED_IP="${FIXED_IP:-}"
FIXED_MASK="${FIXED_MASK:-255.255.255.0}"

# 设备时钟是 UTC，日志与画面统一按东八区（POSIX 串，不依赖 zoneinfo）
TZ="${KPW_TZ:-CST-8}"; export TZ   # 想换时区就设 KPW_TZ，别指望系统已有的 TZ

if [ "${LANDSCAPE:-0}" != "1" ]; then PAINT="paint.sh"; fi

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>&1; }

# 免疫死亡信号：系统清理后台/应用退出时会向进程组发 SIGHUP/SIGTERM，
# 不拦住的话脚本会无声无息地死掉（社区同类项目的标配）。
trap "" 1 15

# 日志轮转：心跳每 15 秒一条，长期挂着不轮转会撑爆 /mnt/us
if [ -f "$LOG" ]; then
    _lsz=$(wc -c <"$LOG" 2>/dev/null)
    [ -n "$_lsz" ] || _lsz=0
    if [ "$_lsz" -gt 262144 ]; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi
fi

# ------------------------------------------------------------
# 屏幕所有权：这是整件事的核心矛盾。
#
#   A. framework 活着 → 它随时会把整屏刷成"资料库"，我们的画一秒钟就没了
#      （现象：点启动后画面闪一下又弹回书架 / 一进去就退回来）
#   B. framework 停掉 + powerd 也停掉 → 60~90 秒后画面定格
#      （现象：时间停在启动那一刻。真因不是面板，是没人持 wakelock，
#       内核 autosleep 把 CPU 挂了，我们的 sleep 循环就此停在半路）
#
# 所以取中间：停 framework（抢屏幕的）、留 powerd（管电源和 USB 的）。
# powerd 在，preventScreenSaver 才生效，系统不会休眠；USB 也能正常交给电脑。
# ------------------------------------------------------------
framework_running() {
    initctl status framework 2>/dev/null | grep -q "start/running"
}

# 心跳日志用的短状态：running / stop-waiting / ?
_fw_s() {
    _x=$(initctl status framework 2>/dev/null | awk 'NR==1{print $1"-"$2}')
    echo "${_x:-?}"
}

# 复活就停掉；真的停过则返回 0（调用方据此立刻重画一帧，把弹窗像素盖掉）
ensure_framework_stopped() {
    framework_running || return 1
    log "看门狗: framework 复活，立即停止"
    initctl stop framework >>"$LOG" 2>&1
    sleep 2
    stay_awake
    return 0
}

# framework 停掉之后，appmgrd / cvm 仍在跑：它们会弹
# "应用程序出错，无法启动选定的应用程序"，抢走触摸并盖住画面。
#
# ⚠️ 绝对不能用 kill：我们的脚本就挂在它的进程树下，
#    kill 会连自己一起带走（实测 killall cvm 后脚本当场死亡 → 屏幕全白）。
#    改成 SIGSTOP 冻结：不画、不弹、不触发 respawn，退出时 SIGCONT 唤醒即可。
_app_pids() {
    ps 2>/dev/null | grep -E "[ /]$1( |\$)" | grep -v grep | awk '{print $1}'
}

freeze_apps() {
    [ "${FREEZE_APP:-1}" = "1" ] || return 0
    _f=""
    for _n in cvm appmgrd; do
        for _p in $(_app_pids "$_n"); do
            kill -STOP "$_p" 2>/dev/null && _f="$_f $_n:$_p"
        done
    done
    if [ -n "$_f" ] && [ -z "$_FR_LOGGED" ]; then
        log "已冻结后台应用(防弹窗):$_f"
        _FR_LOGGED=1
    fi
    return 0
}

resume_apps() {
    for _n in cvm appmgrd; do
        for _p in $(_app_pids "$_n"); do
            kill -CONT "$_p" 2>/dev/null
        done
    done
}

# 前置阅读灯：挂墙时关掉，画面接近纸感、也省电。
# 不同固件属性名不同，逐个试；sysfs 兜底。framework 复活/系统调光后会被
# 重置，所以每轮都刷一次。
set_frontlight() {
    [ "$POWERD_OFF" = "1" ] && return 0
    _v="${FRONTLIGHT:-0}"
    # 第一次先把原亮度记下来，退出时还原，别把设备留在黑屏状态
    if [ ! -f "$DIR/device/.fl.orig" ]; then
        _orig=$(lipc-get-prop -i com.lab126.powerd flIntensity 2>/dev/null)
        printf '%s' "${_orig:-12}" >"$DIR/device/.fl.orig"
        log "前置灯: 原亮度=${_orig:-?} → 目标=${_v}"
        _FL_LOGGED=1
    fi
    lipc-set-prop -i com.lab126.powerd flIntensity "$_v" >/dev/null 2>&1 \
        || lipc-set-prop com.lab126.powerd flIntensity "$_v" >/dev/null 2>&1
    lipc-set-prop -i com.lab126.powerd frontlightIntensity "$_v" >/dev/null 2>&1
    for _b in /sys/class/backlight/*/brightness; do
        [ -w "$_b" ] && echo "$_v" >"$_b" 2>/dev/null
    done
    if [ -z "$_FL_LOGGED" ]; then
        _fl=$(lipc-get-prop -i com.lab126.powerd flIntensity 2>/dev/null)
        log "前置灯: 目标=${_v} 读回=${_fl:-?}"
        _FL_LOGGED=1
    fi
}

# 排查用：把服务状态和进程表写进日志，看谁在弹窗/抢屏
debug_dump() {
    [ "${KPW_DEBUG:-0}" = "1" ] || return 0
    log "---- debug ----"
    for _j in framework appmgrd cvm powerd; do
        echo "  $(initctl status "$_j" 2>&1)" >>"$LOG"
    done
    ps 2>/dev/null | grep -E "cvm|appmgrd|java|framework|lab126" | grep -v grep >>"$LOG" 2>&1
}

# powerd 唯一会写 /sys/power/state 的进程，停了就没人发起休眠。
# 但现在默认不停它：停了 USB 就没法把存储交给电脑，而且没人持 wakelock
# 时内核 autosleep 会直接挂起 —— 那才是"时间定格"的真正原因。
stop_powerd() {
    [ "${STOP_POWERD:-0}" = "1" ] || return 0
    if initctl status powerd 2>/dev/null | grep -q "start/running"; then
        initctl stop powerd >>"$LOG" 2>&1
        POWERD_OFF=1
        if [ -z "$_PD_LOGGED" ]; then
            log "已停止 powerd（注意：USB 可能无法挂载）"
            _PD_LOGGED=1
        fi
    else
        POWERD_OFF=1
    fi
}

# 防休眠：powerd 在时，preventScreenSaver=1 是唯一真正管用的开关
# （stayAwake 在 5.12.2 上不存在，rc=8）。每 15 秒续一次。
stay_awake() {
    [ "$POWERD_OFF" = "1" ] && return 0
    lipc-set-prop -i com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1 \
        || lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1
    lipc-set-prop -i com.lab126.powerd stayAwake 1 >/dev/null 2>&1 \
        || lipc-set-prop com.lab126.powerd stayAwake 1 >/dev/null 2>&1
    [ -w /sys/power/wake_lock ] && echo kpw-wall >/sys/power/wake_lock 2>/dev/null
    # WiFi 省电模式：默认开启（实测静置电流 73mA→41mA，FTP/网页都正常）。
    # WIFI_POWERSAVE=0 时恢复"关省电"（若 FTP 出现莫名断连再改回来）。
    if [ "${WIFI_POWERSAVE:-1}" = "1" ]; then
        iw wlan0 set power_save on >/dev/null 2>&1
    else
        iw wlan0 set power_save off >/dev/null 2>&1
        ifconfig wlan0 power 0 >/dev/null 2>&1
    fi
    if [ -z "$_AWAKE_LOGGED" ]; then
        _ss=$(lipc-get-prop -i com.lab126.powerd preventScreenSaver 2>/dev/null)
        _sa=$(lipc-get-prop -i com.lab126.powerd stayAwake 2>/dev/null)
        log "防休眠: preventScreenSaver=${_ss:-?} stayAwake=${_sa:-?} powerd=$(initctl status powerd 2>&1 | head -1)"
        _AWAKE_LOGGED=1
    fi
}

# 关掉 EPDC 的自动挂起（面板空闲几十秒后不再接受 update 的常见原因）。
# 不同固件路径不同，逐个试，结果只记一次日志 —— 有则更好，没有不影响主流程。
epdc_no_autosuspend() {
    [ -z "$_EPDC_LOGGED" ] || return 0
    _EPDC_LOGGED=1
    # EPDC_POWER=on   → 禁自动挂起（刷新稳，功耗略高）
    # EPDC_POWER=auto → 空闲自动挂起（省几 mA，刷新前由内核自动唤醒）
    _mode="${EPDC_POWER:-on}"
    _ok=""
    for _p in \
        /sys/class/graphics/fb0/device/power/control \
        /sys/bus/platform/devices/mxc_epdc_fb.0/power/control \
        /sys/devices/platform/mxc_epdc_fb.0/power/control
    do
        if [ -w "$_p" ]; then
            echo "$_mode" >"$_p" 2>/dev/null && _ok="$_ok $_p=$_mode"
        fi
    done
    log "EPDC 电源策略: ${_ok:-无可用节点}"
}

# 给 wlan0 挂一个固定别名地址：留空则跳过。
# 不改系统 Wi-Fi 配置（那会被 wifid 覆盖），只是多挂一个入口，
# 掉线重连后别名会消失，所以每轮循环都补挂一次 —— 自愈。
has_fixed_ip() {
    ifconfig -a 2>/dev/null | grep -q "addr:$FIXED_IP " && return 0
    ip addr 2>/dev/null | grep -q "inet $FIXED_IP/" && return 0
    return 1
}

ensure_fixed_ip() {
    [ -n "$FIXED_IP" ] || return 0
    _ifcfg=$(ifconfig wlan0 2>/dev/null)
    # WiFi 没连上（无 inet addr）就跳过，等下一轮
    printf '%s' "$_ifcfg" | grep -q "inet addr" || return 0
    # 已经挂过就不重复（别名地址不会出现在 ifconfig wlan0 里，要查 -a）
    has_fixed_ip && return 0
    # 优先 busybox 别名写法，其次 iproute 的别名标签
    ifconfig "wlan0:0" "$FIXED_IP" netmask "$FIXED_MASK" up >/dev/null 2>"$DIR/device/.iperr" \
        || ip addr add "$FIXED_IP/24" dev wlan0 label "wlan0:0" >/dev/null 2>>"$DIR/device/.iperr" \
        || ip addr add "$FIXED_IP/24" dev wlan0 >/dev/null 2>>"$DIR/device/.iperr"
    if has_fixed_ip; then
        log "固定 IP 已挂载: $FIXED_IP"
        rm -f "$DIR/device/.iperr"
    else
        _err=$(head -2 "$DIR/device/.iperr" 2>/dev/null | tr '\n' ' ')
        log "固定 IP 挂载失败: $FIXED_IP ${_err}"
    fi
}

# 退出判定：插上"电脑"时系统会把 /mnt/us 卸载交给电脑，这是唯一可靠的信号。
# 曾经加过 /sys/class/udc/*/state == configured 的判断，但实测该值在拔线后
# 仍可能读到 configured，导致"一启动就自己退出" —— 已去掉。
usb_attached() {
    if [ -r /proc/mounts ]; then
        grep -q " /mnt/us " /proc/mounts && return 1
        return 0
    fi
    [ -f "$DIR/device/keep-running" ] || return 0
    return 1
}

# 连续两次判定都为真才算插入，避免瞬时抖动把脚本踢出去
usb_confirm() {
    usb_attached || return 1
    sleep 2
    usb_attached || return 1
    return 0
}

# 屏幕方向：横屏直接写 /sys/class/graphics/fb0/rotate（实测本机支持，无需 fbdepth）。
# 原值存 device/.rotate.orig，退出/下次竖屏启动时还原 —— 否则书架界面是横的。
apply_orientation() {
    _rs=/sys/class/graphics/fb0/rotate
    [ -e "$_rs" ] || { log "方向: 无 $_rs，跳过"; return 0; }
    if [ "$LANDSCAPE" = "1" ]; then
        if ! [ -f "$DIR/device/.rotate.orig" ]; then
            cat "$_rs" >"$DIR/device/.rotate.orig" 2>/dev/null
        fi
        echo "$FB_ROTATE" >"$_rs" 2>"$DIR/device/.fberr" || {
            log "方向: 写 rotate=$FB_ROTATE 失败: $(tr '\n' ' ' <"$DIR/device/.fberr" 2>/dev/null)"
            rm -f "$DIR/device/.fberr"
            return 0
        }
        rm -f "$DIR/device/.fberr"
        log "方向: 横屏 rotate=$FB_ROTATE（原值 $(cat "$DIR/device/.rotate.orig" 2>/dev/null)），vs=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
    elif [ -f "$DIR/device/.rotate.orig" ]; then
        restore_orientation
    fi
}

restore_orientation() {
    if [ -f "$DIR/device/.rotate.orig" ]; then
        cat "$DIR/device/.rotate.orig" >/sys/class/graphics/fb0/rotate 2>/dev/null
        rm -f "$DIR/device/.rotate.orig"
        log "方向: 已还原竖屏 rotate=$(cat /sys/class/graphics/fb0/rotate 2>/dev/null)"
    fi
}


restore_ui() {
    _why="${1:-USB 连接}"
    _m=$(grep -c " /mnt/us " /proc/mounts 2>/dev/null)
    if [ -f "$DIR/device/keep-running" ]; then _k=有; else _k=无; fi
    log "退出（$_why），恢复原生界面（/mnt/us 挂载=$_m，keep-running=$_k）"
    stop_ftp
    stop_powerwatch
    stop_pomowatch
    rm -f "$PIDFILE" "$DIR/device/keep-running"
    # 把前置灯还原成启动前的亮度，别把设备留在全暗
    if [ -f "$DIR/device/.fl.orig" ]; then
        _o=$(cat "$DIR/device/.fl.orig" 2>/dev/null)
        [ -n "$_o" ] && lipc-set-prop -i com.lab126.powerd flIntensity "$_o" >/dev/null 2>&1
        log "前置灯已恢复: ${_o:-?}"
        rm -f "$DIR/device/.fl.orig"
    fi
    # USB 挂载状态下 framework 有可能起不来：重试几轮，仍失败就重启设备兜底，
    # 否则会留下"界面停了 + 没人画图"的白屏，用户只能手动长按电源。
    restore_orientation
    resume_apps
    initctl start powerd >>"$LOG" 2>&1
    initctl start framework >>"$LOG" 2>&1
    _i=0
    while [ "$_i" -lt 6 ]; do
        initctl status framework 2>/dev/null | grep -q "start/running" && break
        sleep 1
        initctl start framework >>"$LOG" 2>&1
        _i=$((_i + 1))
    done
    if initctl status framework 2>/dev/null | grep -q "start/running"; then
        log "原生界面已恢复"
    else
        log "framework 恢复失败，重启设备兜底"
        sync
        reboot
    fi
    exit 0
}

# ---- FTP 账号：把 FTP_PASS 设到系统 root 账户上 ----
# busybox 的 ftpd 没有独立账号体系，认证直接走 /etc/shadow，所以要动系统文件。
# 安全措施：① 原文件先备份到 FAT 分区 ② 改完校验行数 ③ 只在有标记前跳过，
# ④ 失败不重启不重试，日志里留证据，下次插线再修。
setup_ftp_auth() {
    [ "${FTP_AUTH:-1}" = "1" ] || return 0
    _u="${FTP_USER:-root}"
    _p="${FTP_PASS:-root}"
    _mark="$DIR/device/.ftp.auth"
    if [ -f "$_mark" ] && grep -qx "${_u}:${_p}" "$_mark" 2>/dev/null; then
        return 0
    fi
    [ -f /etc/shadow ] || { log "FTP账号: 设备无 /etc/shadow，跳过"; return 0; }

    # 生成密码 hash（md5-crypt，兼容性最好）。openssl 没有就用 busybox cryptpw。
    _hash=""
    if command -v openssl >/dev/null 2>&1; then
        _hash=$(openssl passwd -1 -salt kpw "$_p" 2>/dev/null)
    fi
    if [ -z "$_hash" ] && command -v cryptpw >/dev/null 2>&1; then
        _hash=$(cryptpw -m md5 -s kpw "$_p" 2>/dev/null)
    fi
    case $_hash in
        '$1$'*) ;;
        *) log "FTP账号: 无法生成密码 hash（openssl/cryptpw 不可用），保持匿名"; return 0 ;;
    esac

    # 根文件系统默认只读，先试开
    if ! touch /etc/.wtest 2>/dev/null; then
        mount -o remount,rw / >/dev/null 2>&1 || mntroot rw >/dev/null 2>&1
        sleep 1
    fi
    if ! touch /etc/.wtest 2>/dev/null; then
        log "FTP账号: /etc 只读无法写入，保持匿名"
        return 0
    fi
    rm -f /etc/.wtest

    # 备份（只在第一次做，之后不覆盖原备份）
    [ -f "$DIR/device/etc.shadow.bak" ] || cp /etc/shadow "$DIR/device/etc.shadow.bak" 2>/dev/null

    # 只改 root 那一行的密码字段，其余原样保留
    awk -F: -v h="$_hash" 'BEGIN{OFS=":"} $1=="root"{$2=h} {print}' /etc/shadow >/tmp/.shadow.new
    _n1=$(wc -l </etc/shadow); _n2=$(wc -l </tmp/.shadow.new)
    grep -q "^root:" /tmp/.shadow.new || _n2=0
    if [ "$_n1" != "$_n2" ]; then
        log "FTP账号: 改写校验失败（$_n1→$_n2 行），放弃"
        return 0
    fi
    cat /tmp/.shadow.new >/etc/shadow && chmod 600 /etc/shadow
    rm -f /tmp/.shadow.new

    # 万一这台固件不用 shadow（/etc/passwd 里直接存 hash），也一并处理
    _pf=$(awk -F: '$1=="root"{print $2}' /etc/passwd 2>/dev/null)
    if [ -n "$_pf" ] && [ "$_pf" != "x" ]; then
        [ -f "$DIR/device/etc.passwd.bak" ] || cp /etc/passwd "$DIR/device/etc.passwd.bak" 2>/dev/null
        awk -F: -v h="$_hash" 'BEGIN{OFS=":"} $1=="root"{$2=h} {print}' /etc/passwd >/tmp/.passwd.new
        cat /tmp/.passwd.new >/etc/passwd && chmod 644 /etc/passwd
        rm -f /tmp/.passwd.new
    fi

    sync
    mount -o remount,ro / >/dev/null 2>&1 || mntroot ro >/dev/null 2>&1
    echo "${_u}:${_p}" >"$_mark"
    log "FTP账号: 已设置 ${_u}/******（原 /etc/shadow 备份于 device/etc.shadow.bak）"
}

# 起来之后自己连一次，把结果写进日志 —— 手机连不上时插线看日志就知道为什么
# tcpsvd 刚 fork 完可能有零点几秒的窗口连不上，失败重试一次再下结论
ftp_selftest() {
    _u="${FTP_USER:-root}"; _p="${FTP_PASS:-root}"
    _rc=1; _out=""; _try=0
    while [ "$_try" -lt 2 ]; do
        _out=$(curl -s --max-time 8 -u "${_u}:${_p}" "ftp://127.0.0.1:${FTP_PORT}/" 2>&1)
        _rc=$?
        [ "$_rc" -eq 0 ] && break
        _try=$((_try + 1))
        [ "$_try" -lt 2 ] && sleep 3
    done
    if [ "$_rc" -eq 0 ]; then
        _n=$(printf '%s' "$_out" | grep -c .)
        log "FTP 自检: ${_u} 登录成功（本机 127.0.0.1，根目录 photos/，列出 $_n 项）"
        return 0
    fi
    case $_out in
        *"Protocol ftp not supported"*|*"not supported"*)
            log "FTP 自检: 本机 curl 不支持 ftp 协议，跳过（不影响手机连接）" ;;
        *)
            log "FTP 自检: 失败 rc=$_rc → $(printf '%s' "$_out" | tr '\n' ' ')" ;;
    esac
}

start_ftp() {
    [ -f "$DIR/device/ftp.pid" ] && kill -0 "$(cat "$DIR/device/ftp.pid")" 2>/dev/null && return 0
    # Kindle 自带 iptables 的 INPUT 策略是 DROP，只放行 40317。
    # tcpsvd 起来了外面也连不进来 —— 必须自己补放行规则。
    open_firewall
    setup_ftp_auth
    if command -v tcpsvd >/dev/null 2>&1; then
        # FTP 根目录 = 照片目录本身：手机传上去就在照片目录里，不需要再翻路径。
        # 图库"分享→FTP"默认传到会话当前目录（也就是这个根），正好落对地方。
        tcpsvd -vE 0.0.0.0 "$FTP_PORT" busybox ftpd -w "$DIR/photos" >/dev/null 2>&1 &
        echo $! >"$DIR/device/ftp.pid"
        log "FTP 服务已启动: 端口 $FTP_PORT 账号 ${FTP_USER:-root} 根目录=photos/"
        ftp_selftest
    else
        log "无 tcpsvd，FTP 服务不可用"
    fi
}

# 放行 FTP 控制端口 + PASV 数据端口（busybox ftpd 用系统临时端口）
open_firewall() {
    command -v iptables >/dev/null 2>&1 || return 0
    for _p in "$FTP_PORT" "$ADMIN_PORT" "$ANNIV_WEB_PORT"; do
        [ -n "$_p" ] && [ "$_p" != "0" ] || continue
        iptables -C INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null
    done
    iptables -C INPUT -p tcp --dport 32768:65535 -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p tcp --dport 32768:65535 -j ACCEPT 2>/dev/null
    if [ -z "$_FW_LOGGED" ]; then
        log "防火墙已放行: tcp/$FTP_PORT + tcp/${ADMIN_PORT:-0} + tcp/${ANNIV_WEB_PORT:-0} + PASV 高端口"
        _FW_LOGGED=1
    fi
}

stop_ftp() {
    for _pf in "$DIR/device/ftp.pid" "$DIR/device/admin.pid" "$DIR/device/web.pid"; do
        [ -f "$_pf" ] && kill "$(cat "$_pf")" 2>/dev/null
        rm -f "$_pf"
    done
    # tcpsvd 会 fork 子进程，父进程杀掉后可能有残留的 lua 连接处理进程
    pkill -f "anniv.lua" 2>/dev/null
    return 0
}

# ---- 纪念日登记网页 ----
# 设备没有 httpd，用 BusyBox tcpsvd + Lua 5.1 顶上：
# 每个连接拉起一次 lua，读请求 → 改 anniversaries.conf → 写 cmd=paint 立刻重绘。
# 手机连同一 WiFi，浏览器开 http://<设备IP>:8080/ 就能填，不用装 FTP 客户端。
start_anniv_web() {
    [ "${ANNIV_WEB:-1}" = "1" ] || return 0
    _p="${ANNIV_WEB_PORT:-8080}"
    [ -n "$_p" ] && [ "$_p" != "0" ] || return 0
    command -v tcpsvd >/dev/null 2>&1 || { log "无 tcpsvd，纪念日网页不可用"; return 0; }
    [ -x /usr/bin/lua ] || { log "无 /usr/bin/lua，纪念日网页不可用"; return 0; }
    [ -f "$DIR/device/web/anniv.lua" ] || { log "缺 device/web/anniv.lua，纪念日网页不可用"; return 0; }
    if netstat -ln 2>/dev/null | grep -q "0\.0\.0\.0:$_p "; then
        return 0        # 已在监听（restart 时不要重复起）
    fi
    open_firewall
    tcpsvd -E 0.0.0.0 "$_p" /usr/bin/lua "$DIR/device/web/anniv.lua" >/dev/null 2>>"$LOG" &
    echo $! >"$DIR/device/web.pid"
    log "纪念日网页已启动: http://${FIXED_IP:-192.168.0.250}:$_p/"
}

# 按脚本名清掉所有同名监听进程。pid 文件只知道最新一个，
# 历史部署/强杀留下的孤儿（fork 出来的子 shell 也带脚本名）必须全量扫描：
# evdev 把每个按键/触摸事件发给所有打开者，多实例 = 一次点按被执行多遍
# （跳过按钮轮次 +N、退出命令写多次）。
kill_watch_all() { # $1=脚本名（pomowatch.sh / powerwatch.sh）
    for _p in /proc/[0-9]*; do
        _c=$(tr '\0' ' ' <"$_p/cmdline" 2>/dev/null)
        case "$_c" in *"$1"*) kill -9 "${_p#/proc/}" 2>/dev/null ;; esac
    done
    return 0
}

# ---- 电源键三连击退出 ----
# 后台读电源键的 input 事件（与 powerd 并行，互不影响），3 秒内
# 连按 3 次就写 cmd=stop —— 一个不依赖 WiFi/USB 的物理退出通道。
start_powerwatch() {
    [ "${POWER_EXIT:-1}" = "1" ] || return 0
    kill_watch_all powerwatch.sh      # 永远从零拉起：restart 后也保证新代码生效
    rm -f "$DIR/device/powerwatch.pid"
    if [ ! -f "$DIR/device/powerwatch.sh" ]; then
        log "缺 device/powerwatch.sh，电源键退出不可用"
        return 0
    fi
    sh "$DIR/device/powerwatch.sh" >/dev/null 2>&1 &
    echo $! >"$DIR/device/powerwatch.pid"
}

stop_powerwatch() {
    kill_watch_all powerwatch.sh
    rm -f "$DIR/device/powerwatch.pid"
    return 0
}

# ---- 番茄钟触摸监听（点按/长按手势）----
start_pomowatch() {
    [ "${POMO:-1}" = "1" ] || return 0
    kill_watch_all pomowatch.sh
    rm -f "$DIR/device/pomowatch.pid"
    if [ ! -f "$DIR/device/pomowatch.sh" ]; then
        log "缺 device/pomowatch.sh，番茄钟手势不可用"
        return 0
    fi
    sh "$DIR/device/pomowatch.sh" >/dev/null 2>&1 &
    echo $! >"$DIR/device/pomowatch.pid"
}

stop_pomowatch() {
    kill_watch_all pomowatch.sh
    rm -f "$DIR/device/pomowatch.pid"
    return 0
}

# 番茄钟到点检测（内层 5 秒粒度循环里调用）：
#   返回 0 = 阶段刚切换，调用方应立刻跳出内层循环重画（.pomo.flash 已置，会闪屏提示）
pomo_tick() {
    pomo_read
    [ "$PM_PHASE" != "idle" ] || return 1
    if [ "$PM_PAUSED" != "1" ] && [ "$(date +%s)" -ge "$PM_END" ]; then
        _old="$PM_PHASE"
        _msg=$(pomo_advance)
        touch "$DIR/device/.pomo.flash"
        log "番茄钟: $_old 阶段结束 → $_msg"
        return 0
    fi
    return 1
}

# ---- 运维通道（无线改脚本 / 看日志）----
# 2121 那个 FTP 被 chroot 在 photos/ 里，够不到 device/*.sh、也读不到 dash.log，
# 于是每次调脚本都得插数据线。这里再起一个 ftpd，根目录是整个项目目录：
#   · 读：dash.log（排查不用插线）、任意脚本
#   · 写：脚本先传成 xxx.new，再由 deploy 命令校验+替换，避免写一半被 shell 读到
start_admin_ftp() {
    [ -n "$ADMIN_PORT" ] && [ "$ADMIN_PORT" != "0" ] || return 0
    [ -f "$DIR/device/admin.pid" ] && kill -0 "$(cat "$DIR/device/admin.pid")" 2>/dev/null && return 0
    command -v tcpsvd >/dev/null 2>&1 || { log "无 tcpsvd，运维通道不可用"; return 0; }
    open_firewall
    setup_ftp_auth
    tcpsvd -vE 0.0.0.0 "$ADMIN_PORT" busybox ftpd -w "$DIR" >/dev/null 2>&1 &
    echo $! >"$DIR/device/admin.pid"
    log "运维通道已启动: 端口 $ADMIN_PORT，根目录=$DIR（整个局域网可写）"
}

# 把 *.new 覆盖到正式文件。脚本先过 sh -n，行尾带 CR 的直接拒收 ——
# 这辆车上最痛的两个坑（CRLF 坐标失效、半截脚本猝死）都在这里挡掉。
apply_new() {
    _n_ok=0; _n_bad=0
    for _n in "$DIR"/device/*.new "$DIR"/device/web/*.new "$DIR"/assets/*.new "$DIR"/assets/*/*.new; do
        [ -f "$_n" ] || continue
        _t=${_n%.new}
        case $_n in
            *.sh.new)
                # 用字节数比较判 CRLF：busybox 的 grep 不一定有 -U，这样最稳
                _b1=$(wc -c <"$_n" 2>/dev/null)
                _b2=$(tr -d '\r' <"$_n" 2>/dev/null | wc -c)
                if [ -n "$_b1" ] && [ "$_b1" != "$_b2" ]; then
                    log "部署拒绝: $(basename "$_t") 含 CRLF 行尾"; _n_bad=$((_n_bad+1)); rm -f "$_n"; continue
                fi
                if ! sh -n "$_n" 2>/dev/null; then
                    log "部署拒绝: $(basename "$_t") 语法检查不通过"; _n_bad=$((_n_bad+1)); rm -f "$_n"; continue
                fi
                ;;
        esac
        if mv -f "$_n" "$_t"; then
            log "部署: $(basename "$_t") 已更新"; _n_ok=$((_n_ok+1))
        else
            log "部署失败: $(basename "$_t") 无法覆盖"; _n_bad=$((_n_bad+1))
        fi
    done
    rm -f "$DIR/device/.photo.dims" "$DIR/device/.count"
    log "部署结果: 成功 ${_n_ok} 个，拒绝/失败 ${_n_bad} 个"
}

# 命令文件：把一行命令写进 device/cmd，主循环 5 秒内执行并删掉。
#   restart  只重启脚本（改了 env 的生效方式）
#   deploy   先应用 *.new，再重启
#   stop     恢复原生界面并退出（等于插线效果，但不用插线）
handle_cmd() {
    _cf="$DIR/device/cmd"
    [ -f "$_cf" ] || return 0
    _c=$(head -1 "$_cf" 2>/dev/null | tr -d '\r\n \t')
    rm -f "$_cf"
    [ -n "$_c" ] || return 0
    case $_c in
        restart)
            log "收到命令 restart，重载脚本"
            # exec 换掉自己：PID 不变，dash.pid 继续有效，env.conf 重新读一遍
            exec sh "$DIR/device/render.sh"
            log "restart 失败（exec 返回），继续用旧脚本运行"
            ;;
        deploy)
            log "收到命令 deploy"
            apply_new
            exec sh "$DIR/device/render.sh"
            log "deploy 后重启失败（exec 返回），继续运行"
            ;;
        unpack)
            log "收到命令 unpack"
            if tar xzf "$DIR/assets2.tgz" -C "$DIR" 2>>"$LOG"; then
                rm -f "$DIR/assets2.tgz"
                log "素材包解压完成"
            else
                log "tar.gz 解包失败，改试普通 tar"
                if tar xf "$DIR/assets2.tar" -C "$DIR" 2>>"$LOG"; then
                    rm -f "$DIR/assets2.tar"
                    log "tar 解压完成"
                else
                    log "解包彻底失败，素材保持原样"
                fi
            fi
            ;;
        paint)
            # 网页保存纪念日后触发：立刻重画一帧，不用等下一个 60 秒
            log "收到命令 paint，立即重绘"
            sh "$DIR/device/$PAINT"
            ;;
        stop)
            log "收到命令 stop"
            restore_ui "收到 stop 命令"
            ;;
        fbrot)
            # 试探 /sys/class/graphics/fb0/rotate 能不能真的转屏（能就无需 fbdepth）。
            # 逐个值写一遍，记录写入后的 rotate 与 virtual_size，最后还原原值。
            _r="$DIR/device/.rotate.orig"
            cat /sys/class/graphics/fb0/rotate >"$_r" 2>/dev/null
            _orig=$(cat "$_r" 2>/dev/null)
            log "fbrot: 原 rotate=$_orig vs=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) 可写=$([ -w /sys/class/graphics/fb0/rotate ] && echo 是 || echo 否)"
            for _v in 0 1 2 3; do
                echo "$_v" >/sys/class/graphics/fb0/rotate 2>"$DIR/device/.fberr"
                sleep 1
                log "fbrot: 写 $_v → rotate=$(cat /sys/class/graphics/fb0/rotate 2>/dev/null) vs=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) err=$(tr '\n' ' ' <"$DIR/device/.fberr" 2>/dev/null)"
            done
            [ -n "$_orig" ] && echo "$_orig" >/sys/class/graphics/fb0/rotate
            sleep 1
            log "fbrot: 还原 rotate=$(cat /sys/class/graphics/fb0/rotate 2>/dev/null) vs=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
            rm -f "$DIR/device/.fberr"
            log "fbrot 完成"
            ;;
        shcmd)
            # 应急通道：执行 device/shell.cmd 里的任意命令，输出并入日志
            log "收到命令 shcmd"
            if [ -f "$DIR/device/shell.cmd" ]; then
                sh "$DIR/device/shell.cmd" >>"$LOG" 2>&1
                rm -f "$DIR/device/shell.cmd"
                log "shcmd 完成"
            else
                log "shcmd: 缺少 device/shell.cmd"
            fi
            ;;
        probe)
            # 横屏改造前的摸底：fb 几何 / 旋转能力 / fbdepth 是否在位
            log "probe: fb0 virtual_size=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) bits=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null) rotate=$(cat /sys/class/graphics/fb0/rotate 2>/dev/null)"
            _fb=$(command -v fbink || echo /mnt/us/libkh/bin/fbink)
            # FBInk 眼里的真实情况：屏幕(view)尺寸、是否软件旋转、能否旋转
            _e=$(FBINK_NO_SW_ROTA="${FBINK_NO_SW_ROTA:-}" "$_fb" -q -e screen_width screen_height view_width view_height fb_rotate is_rotated can_rotate 2>&1 | tr '\n' ' ')
            log "probe: fbink -e → ${_e:-无输出}"
            _e2=$(FBINK_NO_SW_ROTA=1 "$_fb" -q -e screen_width screen_height view_width view_height fb_rotate is_rotated 2>&1 | tr '\n' ' ')
            log "probe: fbink -e(NO_SW_ROTA=1) → ${_e2:-无输出}"
            for _d in "$DIR/libkh/bin/fbdepth" /usr/sbin/fbdepth /usr/bin/fbdepth /mnt/us/libkh/bin/fbdepth; do
                [ -e "$_d" ] && log "probe: fbdepth 在位: $_d"
            done
            command -v fbdepth >/dev/null 2>&1 && log "probe: fbdepth 在 PATH"
            log "probe 完成"
            ;;
        *)
            log "收到未知命令: $_c（可用: restart / deploy / stop / probe / fbrot）"
            ;;
    esac
}

# 刚拔掉数据线时，系统要把 /mnt/us 重新挂回来需要几秒。若在这一瞬间启动，
# usb_attached 会误判为"插着电脑"而立刻退出（现象：一进去就弹回资料库）。
# 所以先等它挂回来，最多 30 秒。
_i=0
while [ "$_i" -lt 30 ] && ! grep -q " /mnt/us " /proc/mounts 2>/dev/null; do
    sleep 1
    _i=$((_i + 1))
done
log "启动前等待 /mnt/us 挂载: ${_i}s（$([ -r /proc/mounts ] && grep -c /mnt/us /proc/mounts) 条匹配）"

for _u in /sys/class/udc/*/state; do
    [ -r "$_u" ] && log "USB 控制器: $_u = $(cat "$_u" 2>/dev/null)"
done
log "===== 启动 mode=$MODE interval=$INTERVAL stop_ui=$STOP_UI stop_powerd=$STOP_POWERD ====="
log "服务: framework=$(initctl status framework 2>&1 | head -1) powerd=$(initctl status powerd 2>&1 | head -1)"

# STOP_UI=1（默认）：停 framework —— 它是唯一会把我们的画盖掉的东西。
# STOP_POWERD=0（默认）：保留 powerd —— 它管休眠和 USB 交接。
if [ "$STOP_UI" = "1" ]; then
    initctl stop framework >>"$LOG" 2>&1
    sleep 3
    freeze_apps
fi
epdc_no_autosuspend
set_frontlight
stay_awake
apply_orientation
sh "$DIR/device/$PAINT"
# 启动菜单（Mesquito）收起时会触发一次整屏刷新，正好盖在第一帧上。
# 补两帧（+5s、+15s）：framework 刚重启完再进来时收起得慢，一次补画可能赶不上。
if [ "$STOP_UI" = "1" ]; then
    sleep 5
    ensure_framework_stopped && sleep 2
    freeze_apps
    sh "$DIR/device/$PAINT"
    sleep 10
    ensure_framework_stopped && sleep 2
    freeze_apps
    sh "$DIR/device/$PAINT"
fi
stop_powerd

if [ "$MODE" = "sleep" ]; then
    stop_ftp
    while true; do
        usb_confirm && restore_ui
        lipc-set-prop com.lab126.wifid enable 1 >/dev/null 2>&1
        i=0
        while [ $i -lt 20 ]; do
            [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = "CONNECTED" ] && break
            sleep 1; i=$((i + 1))
        done
        ensure_fixed_ip
        sh "$DIR/device/$PAINT"
        rtcwake -d /dev/rtc1 -m no -s "$SLEEP_INTERVAL" >>"$LOG" 2>&1
        echo mem >/sys/power/state
    done
else
    start_ftp
    start_admin_ftp
    start_anniv_web
    start_powerwatch
    start_pomowatch
    while true; do
        usb_confirm && restore_ui
        handle_cmd
        set_frontlight
        stay_awake
        if [ "$STOP_UI" = "1" ]; then
            ensure_framework_stopped && sh "$DIR/device/$PAINT"
            freeze_apps
        fi
        stop_powerd
        ensure_fixed_ip
        sh "$DIR/device/$PAINT"
        debug_dump
        # 把刷新间隔切成 5 秒一格：每格都查一次 framework，
        # 一旦它复活就停掉并立刻重画 —— 弹窗/书架最多露 5 秒就被盖掉。
        # 每格打一条心跳：日志如果在这里断掉，就说明系统被挂起了（不是面板坏了）。
        # 间隔不是定死的：白天 DASH_INTERVAL，深夜切 NIGHT_INTERVAL（见 cur_interval）。
        _t=0
        # 相位跟踪的初值按当前状态算（含暂停位）：
        # 写死 idle 的话，专注中每次外层迭代都会被误判"刚变化"白吃一格 5 秒。
        pomo_read
        _pp="$PM_PHASE-$PM_PAUSED"
        if [ "$PM_PHASE" = "focus" ] && [ "$PM_PAUSED" != "1" ]; then
            _lim=${POMO_REFRESH:-10}
        elif [ "$PM_PHASE" != "idle" ]; then
            _lim=60
        else
            _lim=$(cur_interval)
        fi
        while :; do
            sleep 5
            _t=$((_t + 5))
            usb_confirm && restore_ui
            pomo_tick && break
            handle_cmd
            if [ "$STOP_UI" = "1" ]; then
                ensure_framework_stopped && break
                freeze_apps
            fi
            if [ $((_t % 15)) -eq 0 ]; then
                stay_awake
                log "心跳 t=${_t}s fw=$(_fw_s 2>/dev/null) blank=$(cat /sys/class/graphics/fb0/blank 2>/dev/null)"
            fi
            # 刷新间隔每 5 秒动态重算：番茄钟可能在等待中途开/关（触摸触发，
            # 不经过外层循环）。专注=POMO_REFRESH 秒翻牌、休息=60s、其余=常规间隔。
            # 相位刚变化时计时从零开始（触摸端刚触发过一帧重绘，立刻再画会重复闪屏）。
            pomo_read
            if [ "$PM_PHASE" = "focus" ] && [ "$PM_PAUSED" != "1" ]; then
                _nlim=${POMO_REFRESH:-10}
            elif [ "$PM_PHASE" != "idle" ]; then
                _nlim=60
            else
                _nlim=$(cur_interval)
            fi
            if [ "$PM_PHASE-$PM_PAUSED" = "$_pp" ]; then
                _lim=$_nlim
            else
                _pp="$PM_PHASE-$PM_PAUSED"; _t=0; _lim=$_nlim
            fi
            [ "$_t" -lt "$_lim" ] || break
        done
    done
fi
