#!/bin/sh
# ============================================================
# 照片墙 v2 · 设备端合成（横屏 1448x1072，双信息带 + 侧栏）
#
# 版式思路：
#   照片按 contain 塞进 960x792 的"照片框"，实际照片高度决定上下留白；
#   留白不浪费 —— 上面变信息带（日期 / 农历节气 / 每日一句），
#   下面变信息带（时间 / 天气 / 湿度空气），右侧 420 宽固定栏
#   （月历 / 日出日落 / 临近节日倒计时 / 纪念日 / 明日预报 / 电量）。
#
# 所有文字都是电脑端预渲染的 PNG（设备没有字体渲染能力）：
#   v2_digits/<set>/  数字与符号，画布左上角起、基线在 y=size
#   v2_cn/<set>/      常用词模，步进宽 = 字数 x 字号
#   v2_chars/         单字图集，用于用户自定义的纪念日名称
#   quotes/           每日一句（207 条，按年内第几天取）
#   lunar/YYYY.txt    每天一行「MMDD|月名|日名|节气」
#   fest.txt          节日清单（2020-2040 按日期排序，设备向后扫三条）
# ============================================================

DIR="${KPW_DIR:-/mnt/us/kindle-photo-wall}"
LOG="$DIR/device/dash.log"
FB="${FBINK_BIN:-/mnt/us/libkh/bin/fbink}"
ASSETSDIR="$DIR/assets"
WXCACHE="$DIR/device/wx.cache"

# Kindle 系统时钟是 UTC，画面与日志统一按东八区
TZ="${KPW_TZ:-CST-8}"; export TZ

. "$DIR/device/env.conf" 2>/dev/null
. "$DIR/device/pomo.sh" 2>/dev/null
_LAYOUT="$ASSETSDIR/layout-land2.sh"
if sed 's/\r$//' "$_LAYOUT" >"$DIR/device/.layout2.lf" 2>/dev/null && [ -s "$DIR/device/.layout2.lf" ]; then
    . "$DIR/device/.layout2.lf"
else
    . "$_LAYOUT"
fi

CITY_CODE="${CITY_CODE:-101010100}"     # 示例值，务必在 env.conf 配置自己的城市
LAT="${LAT:-39.9042}"
LON="${LON:-116.4074}"
WAVE="${WAVE:-GL16}"
WAVE_FULL="${WAVE_FULL:-GC16}"
FULL_EVERY="${FULL_EVERY:-10}"
PHOTO_ROTATE_SEC="${PHOTO_ROTATE_SEC:-60}"
PHOTO_NEW_WINDOW="${PHOTO_NEW_WINDOW:-90}"
QUOTE_COUNT="${QUOTE_COUNT:-1}"

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>&1; }

have_fbink=0
if [ -f "$FB" ] && "$FB" -q -V >/dev/null 2>&1; then have_fbink=1; fi

# ---------------- 贴图原语 ----------------
stamp() { # file x y
    [ "$have_fbink" -eq 1 ] || return 0
    "$FB" -q -b -g "file=$1,x=$2,y=$3" >/dev/null 2>>"$LOG"
}

stamp_last() { # file x y —— 最后一笔并触发整屏刷新
    [ "$have_fbink" -eq 1 ] || return 0
    _cnt=$(cat "$DIR/device/.count" 2>/dev/null || echo 0)
    _cnt=$((_cnt + 1))
    echo $_cnt >"$DIR/device/.count"
    # 面板被 blank 掉时驱动会静默丢弃 update，先拉回来
    echo 0 >/sys/class/graphics/fb0/blank 2>/dev/null
    "$FB" -q -b -g "file=$1,x=$2,y=$3" >>"$LOG" 2>&1
    if [ "$_cnt" -eq 1 ] || [ $((_cnt % FULL_EVERY)) -eq 0 ] || [ -f "$DIR/device/.pomo.flash" ]; then
        rm -f "$DIR/device/.pomo.flash"
        _wv="$WAVE_FULL"; _fl="-fs"
    else
        _wv="$WAVE"; _fl="-s"
    fi
    if ! "$FB" -q "$_fl" -W "$_wv" >>"$LOG" 2>&1; then
        log "刷新 #$_cnt 失败，退回 eips -f"
        eips -f >>"$LOG" 2>&1
    fi
}

# ---------------- 读图片尺寸（PNG/JPEG）----------------
img_dims_raw() { # file 块数(4KB)
    dd if="$1" bs=4096 count="$2" 2>/dev/null | od -An -tu1 -v |
        tr -s ' ' '\n' | sed '/^$/d' | awk '
        { a[NR] = $1 }
        END {
            if (NR < 24) exit
            if (a[1]==137 && a[2]==80 && a[3]==78 && a[4]==71) {
                w = a[17]*16777216 + a[18]*65536 + a[19]*256 + a[20]
                h = a[21]*16777216 + a[22]*65536 + a[23]*256 + a[24]
                if (w > 0 && h > 0) { print w, h; exit }
            }
            if (a[1]==255 && a[2]==216) {
                for (i = 1; i < NR - 8; i++) {
                    if (a[i]==255 && a[i+1] >= 192 && a[i+1] <= 195) {
                        h = a[i+5]*256 + a[i+6]
                        w = a[i+7]*256 + a[i+8]
                        if (w > 0 && h > 0) { print w, h; exit }
                    }
                }
            }
        }'
}

img_dims() {
    _r=$(img_dims_raw "$1" 8 2>/dev/null)
    [ -n "$_r" ] || _r=$(img_dims_raw "$1" 32 2>/dev/null)
    printf '%s' "$_r"
}

# ---------------- 照片目录与轮换 ----------------
PHOTOS_DIR="$DIR/photos"

merge_photo_dirs() {
    if [ -d "$DIR/photos_in" ]; then
        for _f in "$DIR/photos_in"/*; do
            [ -f "$_f" ] || continue
            _b=$(basename "$_f"); _t="$PHOTOS_DIR/$_b"
            [ -e "$_t" ] && _t="$PHOTOS_DIR/$(date +%s)_$_b"
            mv -f "$_f" "$_t" 2>/dev/null && log "合并目录: $_b → photos/"
        done
        rmdir "$DIR/photos_in" 2>/dev/null
    fi
    for _d in "$PHOTOS_DIR"/*/; do
        [ -d "$_d" ] && rmdir "$_d" 2>/dev/null
    done
}

scan_photos() {
    PHOTO_COUNT=0; PHOTO_NEWEST=""
    for _x in "$PHOTOS_DIR"/*; do
        [ -f "$_x" ] || continue
        PHOTO_COUNT=$((PHOTO_COUNT + 1))
        if [ -z "$PHOTO_NEWEST" ] || [ "$_x" -nt "$PHOTO_NEWEST" ]; then
            PHOTO_NEWEST=$_x
        fi
    done
}

nth_photo() {
    _i=0
    for _x in "$PHOTOS_DIR"/*; do
        [ -f "$_x" ] || continue
        _i=$((_i + 1))
        [ "$_i" -eq "$1" ] && { echo "$_x"; return 0; }
    done
    return 1
}

pick_photo() {
    scan_photos
    [ "$PHOTO_COUNT" -gt 0 ] || return 0
    _now=$(date +%s)
    _fresh=""; _fresh_age=999999
    while read -r _n; do
        [ -n "$_n" ] || continue
        [ -f "$PHOTOS_DIR/$_n" ] || continue
        _m=$(stat -c %Y "$PHOTOS_DIR/$_n" 2>/dev/null); [ -n "$_m" ] || continue
        _a=$((_now - _m))
        if [ "$_a" -ge -300 ] && [ "$_a" -le "$PHOTO_NEW_WINDOW" ] && [ "$_a" -lt "$_fresh_age" ]; then
            _fresh="$_n"; _fresh_age=$_a
        fi
    done <<EOF
$(ls -t "$PHOTOS_DIR" 2>/dev/null | head -6)
EOF
    if [ -n "$_fresh" ]; then
        log "选图: $_fresh（刚上传 ${_fresh_age}s 前，共 ${PHOTO_COUNT} 张）"
        echo "$PHOTOS_DIR/$_fresh"; return 0
    fi
    if [ "$PHOTO_ROTATE_SEC" -gt 0 ]; then
        _idx=$(( ($(date +%s) / PHOTO_ROTATE_SEC) % PHOTO_COUNT + 1 ))
        _why="每 ${PHOTO_ROTATE_SEC}s 一张"
    else
        _idx=$(( ($(date +%j) % PHOTO_COUNT) + 1 ))
        _why="按天"
    fi
    _p=$(nth_photo "$_idx")
    [ -n "$_p" ] || return 0
    log "选图: $(basename "$_p")（第 ${_idx}/${PHOTO_COUNT} 张，${_why}）"
    echo "$_p"
}

# ---------------- 天气 ----------------
jget() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed 's/^[^:]*:"//;s/"$//'; }

wmo_desc() {
    case $1 in
        0)              echo "晴 sun" ;;
        1|2)            echo "多云 suncloud" ;;
        3)              echo "阴 cloud" ;;
        45)             echo "雾 fog" ;;
        48)             echo "霾 haze" ;;
        51|53|55|56|57) echo "小雨 drizzle" ;;
        61)             echo "小雨 rain" ;;
        63)             echo "中雨 rain" ;;
        65)             echo "大雨 heavyrain" ;;
        66|67)          echo "雨夹雪 snow" ;;
        71)             echo "小雪 snow" ;;
        73)             echo "中雪 snow" ;;
        75|77)          echo "大雪 snow" ;;
        80|81)          echo "阵雨 rain" ;;
        82)             echo "暴雨 heavyrain" ;;
        85|86)          echo "阵雪 snow" ;;
        95|96|99)       echo "雷阵雨 storm" ;;
        *)              echo "未知 cloud" ;;
    esac
}

icon_of() {
    case $1 in
        *雷*) echo storm ;;
        *雪*) echo snow ;;
        *大雨*|*暴雨*) echo heavyrain ;;
        *雨*|*阵雨*) echo rain ;;
        *雾*|*霾*|*尘*) echo haze ;;
        阴) echo cloud ;;
        *多云*) echo suncloud ;;
        晴) echo sun ;;
        *) echo cloud ;;
    esac
}

arr_of() { printf '%s' "$1" | grep -o "\"$2\":\[[^]]*\]" | head -1 | sed 's/^[^[]*\[//;s/\]$//'; }
nth() { printf '%s' "$1" | tr ',' '\n' | sed -n "${2}p" | tr -d ' "' | cut -dT -f2; }

# AQI → 中文档位（用 Open-Meteo 的 us_aqi）
aqi_word() {
    case $1 in
        ''|*[!0-9]*) echo "" ;;
        *) if [ "$1" -le 50 ]; then echo "优"
           elif [ "$1" -le 100 ]; then echo "良"
           elif [ "$1" -le 150 ]; then echo "轻度"
           elif [ "$1" -le 200 ]; then echo "中度"
           else echo "重度"; fi ;;
    esac
}

fetch_openmeteo() {
    _u="http://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&current=temperature_2m,relative_humidity_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset&timezone=Asia%2FShanghai&forecast_days=3"
    _j=$(curl -s --max-time 15 "$_u" 2>/dev/null)
    case $_j in *temperature_2m*) ;; *) return 1 ;; esac
    _cur=$(printf '%s' "$_j" | grep -o '"current":{[^}]*}')
    _t=$(printf '%s' "$_cur" | grep -o '"temperature_2m":-\?[0-9.]*' | sed 's/.*://')
    [ -n "$_t" ] || return 1
    _h=$(printf '%s' "$_cur" | grep -o '"relative_humidity_2m":[0-9.]*' | sed 's/.*://')
    _cc=$(printf '%s' "$_cur" | grep -o '"weather_code":[0-9]*' | sed 's/.*://')
    _codes=$(arr_of "$_j" weather_code)
    _his=$(arr_of "$_j" temperature_2m_max)
    _los=$(arr_of "$_j" temperature_2m_min)
    echo "TEMP=$_t"
    echo "HUM=$_h"
    echo "SRC=openmeteo"
    # 日出日落：ISO 串里取时间部分（06:42）
    echo "SUNRISE=$(arr_of "$_j" sunrise | cut -d, -f1 | sed 's/.*T//;s/"//')"
    echo "SUNSET=$(arr_of "$_j" sunset | cut -d, -f1 | sed 's/.*T//;s/"//')"
    # 空气质量：另一个域名，失败不影响主流程
    _aq=$(curl -s --max-time 10 "http://air-quality-api.open-meteo.com/v1/air-quality?latitude=$LAT&longitude=$LON&current=us_aqi&timezone=Asia%2FShanghai" 2>/dev/null)
    _aqv=$(printf '%s' "$_aq" | grep -o '"us_aqi":[0-9.]*' | sed 's/.*://')
    [ -n "$_aqv" ] && echo "AQI=$(round_num "$_aqv")"
    _i=1
    while [ "$_i" -le 3 ]; do
        _k=$((_i - 1))
        _c=$(printf '%s' "$_codes" | tr ',' '\n' | sed -n "${_i}p" | tr -d ' ')
        [ "$_k" -eq 0 ] && [ -n "$_cc" ] && _c=$_cc
        set -- $(wmo_desc "$_c")
        echo "D${_k}_DESC=$1"
        echo "D${_k}_ICON=$2"
        echo "D${_k}_HI=$(nth "$_his" "$_i")"
        echo "D${_k}_LO=$(nth "$_los" "$_i")"
        _i=$((_i + 1))
    done
}

fetch_itboy() {
    _j=$(curl -s --max-time 15 "http://t.weather.itboy.net/api/weather/city/$CITY_CODE" 2>/dev/null)
    case $_j in *wendu*) ;; *) return 1 ;; esac
    _t=$(jget "$_j" wendu)
    [ -n "$_t" ] || return 1
    echo "TEMP=$_t"
    echo "HUM=$(jget "$_j" shidu | sed 's/[^0-9]//g')"
    echo "SRC=itboy"
    _i=1
    while [ "$_i" -le 3 ]; do
        _k=$((_i - 1))
        _d=$(printf '%s' "$_j" | grep -o '"type":"[^"]*"' | sed -n "${_i}p" | sed 's/"type":"//;s/"//')
        _hi=$(pick_temp "$(printf '%s' "$_j" | grep -o '"high":"[^"]*"' | sed -n "${_i}p")")
        _lo=$(pick_temp "$(printf '%s' "$_j" | grep -o '"low":"[^"]*"' | sed -n "${_i}p")")
        [ -n "$_d" ] || _d="未知"
        echo "D${_k}_DESC=$_d"
        echo "D${_k}_ICON=$(icon_of "$_d")"
        echo "D${_k}_HI=$_hi"
        echo "D${_k}_LO=$_lo"
        _i=$((_i + 1))
    done
}

get_wx() {
    _now=$(date +%s)
    _mtime=$(stat -c %Y "$WXCACHE" 2>/dev/null); [ -n "$_mtime" ] || _mtime=0
    _age=$((_now - _mtime))
    _today=$(date +%F)
    _cacheday=$(sed -n 's/^FETCHDAY=//p' "$WXCACHE" 2>/dev/null | head -1)
    if [ -f "$WXCACHE" ] && [ "$_age" -le 2700 ] && [ "$_cacheday" = "$_today" ]; then
        return 0
    fi
    # 有旧缓存时不再同步等网络：冷缓存时首帧要白等 15~40 秒（open-meteo 串
    # 两个请求），这正是"重新进照片墙要空白几十秒"的主因。先用旧数据立刻
    # 出画，后台刷新缓存，下一帧（≤刷新间隔）自然换成新数据。
    if [ -f "$WXCACHE" ]; then
        _na=$(stat -c %Y "$WXCACHE.new" 2>/dev/null); [ -n "$_na" ] || _na=0
        # 后台刷新进行中（.new 还年轻）就不叠新的，防止连环起 curl
        if [ $((_now - _na)) -gt 180 ]; then
            rm -f "$WXCACHE.new"
            (
                if fetch_openmeteo >"$WXCACHE.new" 2>/dev/null && [ -s "$WXCACHE.new" ]; then
                    echo "FETCHDAY=$_today" >>"$WXCACHE.new"
                    mv "$WXCACHE.new" "$WXCACHE"
                    log "天气源 open-meteo(后台)（$_today）"
                elif fetch_itboy >"$WXCACHE.new" 2>/dev/null && [ -s "$WXCACHE.new" ]; then
                    echo "FETCHDAY=$_today" >>"$WXCACHE.new"
                    mv "$WXCACHE.new" "$WXCACHE"
                    log "天气源 itboy(备份,后台)（$_today）"
                else
                    rm -f "$WXCACHE.new"
                fi
            ) &
        fi
        return 0
    fi
    # 从来没有缓存（首次运行/缓存被删）：同步拉一次，慢也只慢这一回
    if fetch_openmeteo >"$WXCACHE.new" 2>/dev/null && [ -s "$WXCACHE.new" ]; then
        echo "FETCHDAY=$_today" >>"$WXCACHE.new"
        mv "$WXCACHE.new" "$WXCACHE"
        log "天气源 open-meteo（$_today）"
        return 0
    fi
    if fetch_itboy >"$WXCACHE.new" 2>/dev/null && [ -s "$WXCACHE.new" ]; then
        echo "FETCHDAY=$_today" >>"$WXCACHE.new"
        mv "$WXCACHE.new" "$WXCACHE"
        log "天气源 itboy(备份)（$_today）"
        return 0
    fi
    rm -f "$WXCACHE.new"
    log "天气拉取失败，沿用旧缓存"
}

cget() { sed -n "s/^$1=//p" "$WXCACHE" 2>/dev/null | head -1; }
round_num() { awk -v v="$1" 'BEGIN{printf "%d", v + (v>=0 ? 0.5 : -0.5)}'; }
pick_temp() { printf '%s' "$1" | sed 's/[^0-9-]//g' | head -c 4; }

# ---------------- 电量 ----------------
get_batt() {
    batt_pct=""; batt_text=""
    for _b in /sys/class/power_supply/*/capacity; do
        [ -r "$_b" ] || continue
        _v=$(tr -d ' \r\n' <"$_b" 2>/dev/null)
        case $_v in ''|*[!0-9]*) continue ;; esac
        [ "$_v" -le 100 ] || continue
        batt_pct=$_v
        _st=$(tr -d ' \r\n' <"${_b%capacity}status" 2>/dev/null)
        case $_st in
            Charging|charging) batt_text="充电中" ;;
            Full|full)         batt_text="已充满" ;;
        esac
        break
    done
    [ -n "$batt_pct" ] || batt_pct="--"
}

# ---------------- 农历 / 节日 / 纪念日 / 每日一句 ----------------
LUNAR_MON=""; LUNAR_DAY_TXT=""; LUNAR_JQ=""
lunar_today() {
    _f="$ASSETSDIR/lunar/$(date +%Y).txt"
    [ -f "$_f" ] || return 0
    _line=$(grep -m1 "^$(date +%m%d)|" "$_f" 2>/dev/null)
    [ -n "$_line" ] || return 0
    LUNAR_MON=$(printf '%s' "$_line" | cut -d'|' -f2)
    LUNAR_DAY_TXT=$(printf '%s' "$_line" | cut -d'|' -f3)
    _jq=$(printf '%s' "$_line" | cut -d'|' -f4)
    [ "$_jq" = "-" ] && _jq=""
    LUNAR_JQ=$_jq
}

FEST_TMP="$DIR/device/.fest.tmp"
fest_pick() {
    _t=$(date +%F)
    awk -F'|' -v t="$_t" '$1>=t {print $1"|"$2}' "$ASSETSDIR/fest.txt" 2>/dev/null | head -3 >"$FEST_TMP"
}

ANN_NAME=""; ANN_DATE=""; ANN_DAYS=""; ANN_IS_LUNAR=0

# ---------------- 农历生日支持 ----------------
# lunar/YYYY.txt 每行：公历MMDD|月名|日名|节气|农历key
#   农历key = 月两位+日两位（如 1116 表示冬月十六），闰月带 R 前缀（R1116），
#   所以按 key 精确匹配只会命中正常月（2034 年有闰冬月，不加前缀会撞车）。

# 农历 key → 指定公历年内的公历 MMDD（可能 0~2 个：跨公历年初的那次 + 年末的那次）
lunar_mmdd_in_year() { # $1=key $2=公历年
    _f="$ASSETSDIR/lunar/$2.txt"
    [ -f "$_f" ] || return 0
    awk -F'|' -v k="$1" '$5==k{print $1}' "$_f"
}

# 农历 key → 下一次公历 YYYY-MM-DD（今天及以后，最多往后看三年）
lunar_next_date() {
    _k=$1
    _ts0=$(date -d "$(date +%F)" +%s 2>/dev/null) || return 0
    _y=$(date +%Y); _i=0; _best=""; _bs=""
    while [ "$_i" -le 2 ]; do
        _fy=$(( _y + _i ))
        for _md in $(lunar_mmdd_in_year "$_k" "$_fy"); do
            _c="$_fy-$(printf '%s' "$_md" | cut -c1-2)-$(printf '%s' "$_md" | cut -c3-4)"
            _s=$(date -d "$_c" +%s 2>/dev/null) || continue
            [ "$_s" -ge "$_ts0" ] || continue
            if [ -z "$_bs" ] || [ "$_s" -lt "$_bs" ]; then _best="$_c"; _bs="$_s"; fi
        done
        _i=$(( _i + 1 ))
    done
    printf '%s' "$_best"
}

# 公历日期 → 「月名|日名」（侧栏显示农历用，如 冬月|十六）
lunar_label_of() {
    _ly=$(printf '%s' "$1" | cut -d- -f1)
    _lmd=$(printf '%s' "$1" | cut -d- -f2)$(printf '%s' "$1" | cut -d- -f3)
    awk -F'|' -v k="$_lmd" '$1==k{print $2"|"$3; exit}' "$ASSETSDIR/lunar/$_ly.txt" 2>/dev/null
}

anniv_pick() {
    _f="$DIR/device/anniversaries.conf"
    [ -f "$_f" ] || return 0
    _ts=$(date -d "$(date +%F)" +%s 2>/dev/null); [ -n "$_ts" ] || return 0
    _best=999999
    while read -r _ln; do
        case "$_ln" in ''|\#*) continue ;; esac
        _d0=$(printf '%s' "$_ln" | awk '{print $1}')
        _nm=$(printf '%s' "$_ln" | cut -d' ' -f2- | tr -d '\r' | sed 's/^ *//;s/ *$//')
        [ -n "$_nm" ] || _nm="纪念日"
        _lun=0
        case "$_d0" in
            # L11-16 = 农历冬月十六（每年重复，公历日期逐年在变）
            L[0-9][0-9]-[0-9][0-9])
                _lk=$(printf '%s' "$_d0" | sed 's/^L//; s/-//')
                _dd=$(lunar_next_date "$_lk")
                [ -n "$_dd" ] || continue
                _lun=1 ;;
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _dd="$_d0" ;;
            [0-9][0-9]-[0-9][0-9])
                _dd="$(date +%Y)-$_d0"
                _s1=$(date -d "$_dd" +%s 2>/dev/null)
                if [ -n "$_s1" ] && [ "$_s1" -lt "$_ts" ]; then
                    _dd="$(( $(date +%Y) + 1 ))-$_d0"
                fi ;;
            *) continue ;;
        esac
        _s2=$(date -d "$_dd" +%s 2>/dev/null); [ -n "$_s2" ] || continue
        _diff=$(( (_s2 - _ts) / 86400 ))
        [ "$_diff" -ge 0 ] || continue
        if [ "$_diff" -lt "$_best" ]; then
            _best=$_diff; ANN_NAME=$_nm; ANN_DATE=$_dd; ANN_DAYS=$_diff; ANN_IS_LUNAR=$_lun
        fi
    done <"$_f"
}

quote_file() {
    _n="${QUOTE_COUNT:-1}"
    case $_n in ''|*[!0-9]*|0) _n=1 ;; esac
    _i=$(( $(date +%j) % _n + 1 ))
    _f=$(printf "%s/quotes/q%03d.png" "$ASSETSDIR" "$_i")
    [ -f "$_f" ] || _f="$ASSETSDIR/quotes/q001.png"
    printf '%s' "$_f"
}

# 某日在当月月历里的格位：返回 "行 列"（周一是第 0 列，与 cal2 图的排法一致）
cal_pos() {
    awk -v y="$Y" -v m="$M" -v d="$1" 'BEGIN{
        mm=m; yy=y; if (mm<3){mm+=12; yy--}
        K=yy%100; J=int(yy/100)
        h=(1 + int(13*(mm+1)/5) + K + int(K/4) + int(J/4) + 5*J) % 7
        f0=(h+5)%7
        printf "%d %d", int((f0+d-1)/7), (f0+d-1)%7
    }'
}

# 本月内的纪念日（每年重复的 MM-DD 换算到今年；一次性的 YYYY-MM-DD 直接比）
ANN_MARK_DAYS=""
ann_month_days() {
    ANN_MARK_DAYS=""
    _f="$DIR/device/anniversaries.conf"
    [ -f "$_f" ] || return 0
    _ym="$(date +%Y-%m)"
    _y=$(date +%Y)
    while read -r _ln; do
        case "$_ln" in ''|\#*) continue ;; esac
        _d0=$(printf '%s' "$_ln" | awk '{print $1}')
        _cands=""
        case "$_d0" in
            # 农历条目：一个公历年里可能落两次（年初属上一个农历年、年末属本年）
            L[0-9][0-9]-[0-9][0-9])
                _lk=$(printf '%s' "$_d0" | sed 's/^L//; s/-//')
                for _md in $(lunar_mmdd_in_year "$_lk" "$_y"); do
                    _cands="$_cands $_y-$(printf '%s' "$_md" | cut -c1-2)-$(printf '%s' "$_md" | cut -c3-4)"
                done ;;
            [0-9][0-9]-[0-9][0-9])                        _cands="$_y-$_d0" ;;
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])   _cands="$_d0" ;;
            *) continue ;;
        esac
        for _dd in $_cands; do
            case "$_dd" in "$_ym"-*) ;; *) continue ;; esac
            _dy=$(printf '%s' "$_dd" | cut -d- -f3 | sed 's/^0//')
            case " $ANN_MARK_DAYS " in *" $_dy "*) continue ;; esac
            ANN_MARK_DAYS="$ANN_MARK_DAYS $_dy"
        done
    done <"$_f"
}

# ---------------- 绘制原语 ----------------
# 数字串：draw_num2 x 基线y "文本" 档位；返回（stdout）画完后的 x
draw_num2() {
    _x=$1; _y=$2; _t=$3; _st=$4
    _ST=$(echo "$_st" | tr 'a-z' 'A-Z')
    eval "_dw=\$DIGIT_W_$_ST"; eval "_sw=\$SYM_W_$_ST"; eval "_sz=\$S_$_ST"
    eval "_pwt=\$PCT_W_$_ST"
    [ -n "$_sz" ] || _sz=26
    [ -n "$_dw" ] || _dw=16
    [ -n "$_sw" ] || _sw=12
    [ -n "$_pwt" ] || _pwt=$_sw
    _dy=$(( _y - _sz ))
    while [ -n "$_t" ]; do
        _c=${_t%"${_t#?}"}; _t=${_t#?}
        case $_c in
            :) _f=colon; _w=$_sw ;;
            °) _f=deg;   _w=$_sw ;;
            %) _f=pct;   _w=$_pwt ;;
            -|–) _f=dash; _w=$_sw ;;
            .) _f=dot;   _w=$_sw ;;
            *) _f=$_c;   _w=$_dw ;;
        esac
        if [ -f "$ASSETSDIR/v2_digits/$_st/$_f.png" ]; then
            stamp "$ASSETSDIR/v2_digits/$_st/$_f.png" "$_x" "$_dy"
        fi
        _x=$(( _x + _w ))
    done
    echo "$_x"
}

# 翻牌混合帧：flip_digits x 画布顶y 旧串 新串 档位
# 变化的数位 = 新字上半 + 旧字下半（下半自带翻板边缘线），未变的画整字；
# 位置与 draw_num2 完全一致（advance=DIGIT_W，无额外间距）
flip_digits() {
    _x=$1; _y=$2; _old=$3; _new=$4; _st=$5
    eval "_dw=\$DIGIT_W_$(echo "$_st" | tr 'a-z' 'A-Z')"
    _i=1
    while [ "$_i" -le 2 ]; do
        _oc=$(printf '%s' "$_old" | cut -c$_i)
        _nc=$(printf '%s' "$_new" | cut -c$_i)
        if [ -n "$_oc" ] && [ "$_oc" != "$_nc" ] \
            && [ -f "$ASSETSDIR/v2_digits/$_st/${_nc}_t.png" ]; then
            stamp "$ASSETSDIR/v2_digits/$_st/${_nc}_t.png" "$_x" "$_y"
            stamp "$ASSETSDIR/v2_digits/$_st/${_oc}_b.png" "$_x" "$((_y + POMO_FLIP_TOP))"
        else
            stamp "$ASSETSDIR/v2_digits/$_st/$_nc.png" "$_x" "$_y"
        fi
        _x=$((_x + _dw)); _i=$((_i + 1))
    done
}

# 中文词：draw_cn2 x 基线y "词" 档位 字数；返回画完后的 x
draw_cn2() {
    _x=$1; _y=$2; _w=$3; _st=$4; _n=$5
    _ST=$(echo "$_st" | tr 'a-z' 'A-Z')
    eval "_sz=\$S_CN_$_ST"
    [ -n "$_sz" ] || _sz=26
    _f="$ASSETSDIR/v2_cn/$_st/$_w.png"
    if [ -f "$_f" ]; then
        stamp "$_f" "$_x" "$(( _y - _sz ))"
    else
        # 词模没收录就走单字图集，宽度仍按 字数x字号。
        # draw_chars 末尾会 echo 新坐标 —— 必须吞掉，否则混进本函数的返回值
        draw_chars "$_x" "$_y" "$_w" "$_sz" >/dev/null
    fi
    echo $(( _x + _n * _sz ))
}

# 取首字符（UTF-8 安全）：按首字节判长度 —— ASCII 1 字节、
# 两字节区（如 · ° é）2 字节、CJK 3 字节。
# 不能用 ${s#?} —— Kindle 的 busybox 按字节做模式匹配，会把汉字切成半个。
take_char() { # 字符串 → CHR / REMAIN
    case "$1" in
        '') CHR=""; REMAIN=""; return 0 ;;
    esac
    _b1=$(printf '%s' "$1" | od -An -tu1 -N1 | tr -d ' \n')
    if [ "${_b1:-0}" -lt 128 ]; then _n=1
    elif [ "${_b1:-0}" -lt 224 ]; then _n=2
    else _n=3; fi
    CHR=$(printf '%s' "$1" | cut -b1-$_n)
    REMAIN=$(printf '%s' "$1" | cut -b$((_n + 1))-)
}

# 任意文本：逐字贴单字图集（用于用户自定义的纪念日名称）
draw_chars() { # x 基线y "文本" 字号
    _x=$1; _y=$2; _t=$3; _s=${4:-26}
    while [ -n "$_t" ]; do
        take_char "$_t"
        _t=$REMAIN
        [ -n "$CHR" ] || break
        # FAT32 大小写不敏感：字库里的 ASCII 字母按字节值存（l97=w、u65=W），
        # 与 render/make_v2.py 的 make_charset 对齐，否则 ww 会显示成 WW。
        case "$CHR" in
            [a-z]) _nm="l$(printf '%d' "'$CHR")" ;;
            [A-Z]) _nm="u$(printf '%d' "'$CHR")" ;;
            *) _nm="$CHR" ;;
        esac
        _f="$ASSETSDIR/v2_chars/$_nm.png"
        if [ -f "$_f" ]; then
            stamp "$_f" "$_x" "$(( _y - _s ))"
        else
            log "字模缺失: $CHR"
        fi
        _x=$(( _x + _s ))
    done
    echo "$_x"
}

# ---------------- 番茄钟：专注阶段全屏（flip-clock 风格，见 mockup） ----------------
paint_pomo_focus() {
    _left=$(pomo_left)
    [ "$_left" -lt 0 ] && _left=0
    _total=$(( ${PM_DUR:-${POMO_FOCUS:-25}} * 60 )); [ "$_total" -lt 1 ] && _total=1
    _el=$(( _total - _left )); [ "$_el" -gt "$_total" ] && _el=$_total

    # 布局常量兜底（与 make_pomo_ui.py 生成的 layout-land2.sh 一致）
    : "${POMO_CARD_X0:=289}" "${POMO_CARD_Y:=140}" "${POMO_CARD_W:=380}" "${POMO_CARD_GAP:=110}"
    : "${POMO_CARD_DY:=62}" "${POMO_BAR_Y:=700}" "${POMO_BAR_CELLS:=14}"
    : "${POMO_CELL_W:=32}" "${POMO_CELL_H:=44}" "${POMO_CELL_GAP:=4}"
    : "${POMO_BR_W:=30}" "${POMO_BR_H:=64}" "${POMO_TOMATO_X:=330}" "${POMO_TOMATO_Y:=836}"
    : "${POMO_DONE_Y:=906}" "${POMO_BTN_X0:=304}" "${POMO_BTN_Y:=952}" "${POMO_BTN_H:=100}"
    : "${POMO_BTN_W:=240}" "${POMO_BTN_GAP:=60}" "${POMO_ROUND_X:=56}" "${POMO_ROUND_Y:=100}"
    : "${POMO_RUN_Y:=96}" "${TOMATO_LW:=191}" "${DONE_LW:=204}" "${RUN_TRUE_W:=356}" "${RUN_FALSE_W:=367}"
    : "${POMO_FLIP_TOP:=174}"
    _pui="$ASSETSDIR/pomo_ui"

    # 左上角：第 N / den 轮 · FOCUS MODE（整行预烤词图，den 覆盖 2..8）
    _den=${POMO_EVERY:-4}; case $_den in ''|*[!0-9]*) _den=4 ;; esac
    [ "$_den" -lt 2 ] && _den=2; [ "$_den" -gt 8 ] && _den=8
    _rn=$(( ${PM_CYCLE:-0} % _den + 1 ))
    [ -f "$_pui/round_${_den}_${_rn}.png" ] && \
        stamp "$_pui/round_${_den}_${_rn}.png" "$POMO_ROUND_X" "$(( POMO_ROUND_Y - 44 ))"

    # 右上角：timer.running = true / false（右对齐）
    if [ "$PM_PAUSED" = "1" ]; then _rs=run_false; _rw=$RUN_FALSE_W; else _rs=run_true; _rw=$RUN_TRUE_W; fi
    [ -f "$_pui/$_rs.png" ] && stamp "$_pui/$_rs.png" "$(( W - 56 - _rw ))" "$(( POMO_RUN_Y - 34 ))"

    # 翻牌卡片：黑卡=分钟（白字）、白卡=秒（黑字），字模底色与卡面同色无缝
    stamp "$_pui/card_black.png" "$POMO_CARD_X0" "$POMO_CARD_Y"
    stamp "$_pui/card_white.png" "$(( POMO_CARD_X0 + POMO_CARD_W + POMO_CARD_GAP ))" "$POMO_CARD_Y"
    stamp "$_pui/axle.png" "$(( POMO_CARD_X0 + POMO_CARD_W + (POMO_CARD_GAP - 48) / 2 ))" "$(( POMO_CARD_Y + 156 ))"
    _by=$(( POMO_CARD_Y + POMO_CARD_DY + S_HUGE_W ))          # 数字基线
    _ctop=$(( _by - S_HUGE_W ))                               # 数字画布顶
    _mx=$(( POMO_CARD_X0 + (POMO_CARD_W - 2 * DIGIT_W_HUGE_W) / 2 ))
    _sx=$(( POMO_CARD_X0 + POMO_CARD_W + POMO_CARD_GAP + (POMO_CARD_W - 2 * DIGIT_W_HUGE_K) / 2 ))
    _tmm=$(( _left / 60 )); [ "$_tmm" -gt 99 ] && _tmm=99
    _mm=$(printf '%02d' "$_tmm"); _ss=$(printf '%02d' "$((_left % 60))")
    # 翻牌动画：读上一帧缓存，同会话（END 相同）且值有变才走混合帧
    _fv="$DIR/device/.pomo.flipval"
    _oMM=""; _oSS=""; _oEND=""
    [ -f "$_fv" ] && eval "$(grep -E '^(END|MM|SS)=[0-9]+$' "$_fv" 2>/dev/null | sed 's/^/_o/')"
    _anim=0
    if [ "${POMO_FLIP:-1}" = "1" ] && [ -n "$_oMM" ] && [ "$_oEND" = "${PM_END:-0}" ] \
        && [ -f "$ASSETSDIR/v2_digits/huge_w/0_t.png" ]; then
        _anim=1
    fi

    # 进度条：[ ▓▓▓░░░ ] 42%
    _fill=$(( _el * POMO_BAR_CELLS / _total ))
    _bt=$(( POMO_BR_W + 8 + POMO_BAR_CELLS * POMO_CELL_W + (POMO_BAR_CELLS - 1) * POMO_CELL_GAP \
        + 8 + POMO_BR_W + 20 + 2 * DIGIT_W_DATE + PCT_W_DATE ))
    _bx=$(( (W - _bt) / 2 ))
    stamp "$_pui/bracket_l.png" "$_bx" "$(( POMO_BAR_Y + (POMO_CELL_H - POMO_BR_H) / 2 ))"
    _bx=$(( _bx + POMO_BR_W + 8 ))
    _i=0
    while [ "$_i" -lt "$POMO_BAR_CELLS" ]; do
        if [ "$_i" -lt "$_fill" ]; then _cn=cell_on; else _cn=cell_off; fi
        stamp "$_pui/$_cn.png" "$_bx" "$POMO_BAR_Y"
        _bx=$(( _bx + POMO_CELL_W + POMO_CELL_GAP ))
        _i=$((_i + 1))
    done
    _bx=$(( _bx - POMO_CELL_GAP + 8 ))
    stamp "$_pui/bracket_r.png" "$_bx" "$(( POMO_BAR_Y + (POMO_CELL_H - POMO_BR_H) / 2 ))"
    draw_num2 "$((_bx + POMO_BR_W + 20))" "$(( POMO_BAR_Y + POMO_CELL_H ))" "$((_el * 100 / _total))%" date >/dev/null

    # TOMATO 行（当前轮次，与左上角呼应）+ 今日完成行（按天计数）
    stamp "$_pui/tomato_label.png" "$POMO_TOMATO_X" "$(( POMO_TOMATO_Y - 40 ))"
    stamp "$_pui/tomato_icon.png" "$(( POMO_TOMATO_X + TOMATO_LW + 14 ))" "$(( POMO_TOMATO_Y - 46 ))"
    draw_num2 "$(( POMO_TOMATO_X + TOMATO_LW + 76 ))" "$POMO_TOMATO_Y" "$_rn" date >/dev/null
    stamp "$_pui/done_label.png" "$POMO_TOMATO_X" "$(( POMO_DONE_Y - 40 ))"
    _dx=$(draw_num2 "$(( POMO_TOMATO_X + DONE_LW + 6 ))" "$POMO_DONE_Y" "${PM_TODAY:-0}" date)
    stamp "$_pui/done_tail.png" "$((_dx + 8))" "$(( POMO_DONE_Y - 40 ))"

    # 三个胶囊按钮（黑底白字；同时也是 pomowatch 的触摸热区）
    # 调时态（armed）：左=−5分 中=开始 右=+5分，暂停着显示所选时长；
    #   运行中：按钮1 动态换图：运行中=「休息」（按下暂停），已暂停=「继续」；按钮2=退出；按钮3=重置
    if [ "${PM_ARMED:-0}" = "1" ]; then
        stamp "$_pui/btn_minus.png" "$POMO_BTN_X0" "$POMO_BTN_Y"
        stamp "$_pui/btn_start.png" "$(( POMO_BTN_X0 + POMO_BTN_W + POMO_BTN_GAP ))" "$POMO_BTN_Y"
        stamp "$_pui/btn_plus.png" "$(( POMO_BTN_X0 + 2 * (POMO_BTN_W + POMO_BTN_GAP) ))" "$POMO_BTN_Y"
    else
        if [ "$PM_PAUSED" = "1" ]; then _b1=btn_go; else _b1=btn_rest; fi
        stamp "$_pui/$_b1.png" "$POMO_BTN_X0" "$POMO_BTN_Y"
        stamp "$_pui/btn_exit.png" "$(( POMO_BTN_X0 + POMO_BTN_W + POMO_BTN_GAP ))" "$POMO_BTN_Y"
        stamp "$_pui/btn_reset.png" "$(( POMO_BTN_X0 + 2 * (POMO_BTN_W + POMO_BTN_GAP) ))" "$POMO_BTN_Y"
    fi

    # 翻牌数字（最后画）：值有变时先上"新上半+旧下半"混合帧并局部刷新，
    # 停 POMO_FLIP_DELAY 秒让翻板"落"一下，再落完整新帧、走函数末尾的正常刷新。
    # 整幅新画面已就位，混合帧局部刷新时除卡片外都已是新值，视觉上只有卡在翻。
    if [ "$_anim" = "1" ] && { [ "$_mm" != "$_oMM" ] || [ "$_ss" != "$_oSS" ]; }; then
        flip_digits "$_mx" "$_ctop" "$_oMM" "$_mm" huge_w
        flip_digits "$_sx" "$_ctop" "$_oSS" "$_ss" huge_k
        echo 0 >/sys/class/graphics/fb0/blank 2>/dev/null
        "$FB" -q -s -W "$WAVE" >>"$LOG" 2>&1
        sleep "${POMO_FLIP_DELAY:-0.4}" 2>/dev/null || sleep 1
        log "番茄钟: 翻牌 $_oMM:$_oSS → $_mm:$_ss"
    fi
    draw_num2 "$_mx" "$_by" "$_mm" huge_w >/dev/null
    draw_num2 "$_sx" "$_by" "$_ss" huge_k >/dev/null
    printf 'END=%s\nMM=%s\nSS=%s\n' "${PM_END:-0}" "$_mm" "$_ss" >"$_fv"

    log "番茄钟(flip): 剩余 $(pomo_mmss "$_left") 第${_rn}/${_den}轮 今日${PM_TODAY:-0}番茄 进度$((_el * 100 / _total))%"
    # 自行触发整屏刷新（paint_one 的最后一笔不走）
    echo 0 >/sys/class/graphics/fb0/blank 2>/dev/null
    _cnt=$(cat "$DIR/device/.count" 2>/dev/null || echo 0); _cnt=$((_cnt + 1))
    echo $_cnt >"$DIR/device/.count"
    if [ "$_cnt" -eq 1 ] || [ $((_cnt % FULL_EVERY)) -eq 0 ] || [ -f "$DIR/device/.pomo.flash" ]; then
        rm -f "$DIR/device/.pomo.flash"
        "$FB" -q -fs -W "$WAVE_FULL" >>"$LOG" 2>&1
    else
        "$FB" -q -s -W "$WAVE" >>"$LOG" 2>&1
    fi
}

# ---------------- 主流程 ----------------
paint_one() {
    log "---- 合成开始(v2) ----"
    [ "$have_fbink" -eq 1 ] && "$FB" -q -b -c >/dev/null 2>>"$LOG"

    # ---- 番茄钟：专注/暂停中 → 整屏大倒计时，不走照片版式 ----
    pomo_read
    if [ "$PM_PHASE" = "focus" ]; then
        paint_pomo_focus
        return 0
    fi

    # 照片墙帧时间戳：render.sh 靠它判断轮换节拍（按墙钟走），
    # 进/出番茄钟触发的重绘会如实更新它，计时不会被"归零重等"。
    date +%s >"$DIR/device/.lastwall" 2>/dev/null

    merge_photo_dirs
    photo=$(pick_photo)

    # ---- 照片：contain 进 960x792 照片框，居中 ----
    _sh=0
    if [ -n "$photo" ]; then
        _iw=$(img_dims "$photo" | cut -d' ' -f1)
        _ih=$(img_dims "$photo" | cut -d' ' -f2)
        case $_iw in ''|*[!0-9]*) _iw=0 ;; esac
        case $_ih in ''|*[!0-9]*) _ih=0 ;; esac
        if [ "$_iw" -le 0 ] || [ "$_ih" -le 0 ]; then
            _sw=$PHOTO_W; _sh=$PHOTO_BOX_H
        elif [ $(( PHOTO_W * _ih )) -le $(( PHOTO_BOX_H * _iw )) ]; then
            _sw=$PHOTO_W; _sh=$(( _ih * PHOTO_W / _iw ))
        else
            _sh=$PHOTO_BOX_H; _sw=$(( _iw * PHOTO_BOX_H / _ih ))
        fi
        _sx=$(( PHOTO_X + (PHOTO_W - _sw) / 2 ))
        _sy=$(( PHOTO_BOX_Y + (PHOTO_BOX_H - _sh) / 2 ))
        if [ "$have_fbink" -eq 1 ]; then
            "$FB" -q -b -g "file=$photo,x=$_sx,y=$_sy,w=$_sw,h=$_sh" >/dev/null 2>>"$LOG"
        fi
        log "照片: $(basename "$photo") ${_iw}x${_ih} → ${_sw}x${_sh} @(${_sx},${_sy})"
    else
        log "照片: 目录里没有图片（$PHOTOS_DIR）"
        _sh=$PHOTO_BOX_H
    fi

    # ---- 番茄钟：休息阶段在照片上叠一个白底徽章（照片墙照常轮换）----
    if [ "$PM_PHASE" = "break" ] || [ "$PM_PHASE" = "long" ]; then
        if [ "$PM_PHASE" = "long" ]; then _bw="长休息中"; _bn=4; else _bw="休息中"; _bn=3; fi
        _bx=$(draw_cn2 "$POMO_BADGE_X" "$POMO_BADGE_Y" "$_bw" small $_bn)
        draw_num2 "$((_bx + 10))" "$POMO_BADGE_Y" "$(pomo_mmss "$(pomo_left)")" tiny >/dev/null
        log "番茄钟: $_bw $(pomo_mmss "$(pomo_left)")"
    fi

    TB=$(( (H - _sh) / 2 ))          # 上信息带高度
    BB=$(( H - TB ))                  # 下信息带起点
    _tcy=$(( TB / 2 ))
    _bcy=$(( (BB + H) / 2 ))

    # ---- 上带：日期 / 星期 / 农历节气 / 每日一句 ----
    D=$(date +%-d 2>/dev/null || date +%d | sed 's/^0//')
    M=$(date +%-m 2>/dev/null || date +%m | sed 's/^0//')
    Y=$(date +%Y)
    wd=$(( ($(date +%u) + 6) % 7 ))
    wk=$(echo "星期一 星期二 星期三 星期四 星期五 星期六 星期日" | cut -d' ' -f$((wd + 1)))

    _y1=$(( _tcy - 26 ))
    x=$LEFT_PAD
    x=$(draw_num2 "$x" "$_y1" "$M" date)
    x=$(draw_cn2 "$x" "$_y1" "月" date 1)
    x=$(draw_num2 "$x" "$_y1" "$D" date)
    x=$(draw_cn2 "$x" "$_y1" "日" date 1)
    draw_cn2 $((x + 22)) "$_y1" "$wk" mid 3 >/dev/null

    lunar_today
    _y2=$(( _tcy + 38 ))
    if [ -n "$LUNAR_MON" ]; then
        x=$LEFT_PAD
        x=$(draw_cn2 "$x" "$_y2" "$LUNAR_MON" tiny 2)
        x=$(draw_cn2 "$x" "$_y2" "$LUNAR_DAY_TXT" tiny 2)
        [ -n "$LUNAR_JQ" ] && draw_cn2 $((x + 16)) "$_y2" "$LUNAR_JQ" tiny 2 >/dev/null
    fi

    _q=$(quote_file)
    if [ -f "$_q" ]; then
        stamp "$_q" "$QUOTE_X" "$(( (TB - QUOTE_H) / 2 ))"
    fi

    # ---- 下带：时间 / 天气 / 湿度空气 ----
    get_wx
    _wt=$(cget TEMP)
    if [ -n "$_wt" ]; then temp=$(round_num "$_wt"); else temp="--"; fi
    hum=$(cget HUM); [ -n "$hum" ] || hum="--"
    desc=$(cget D0_DESC); [ -n "$desc" ] || desc="未知"
    icon=$(cget D0_ICON); [ -n "$icon" ] || icon="cloud"
    _wh=$(cget D0_HI); _wl=$(cget D0_LO)
    [ -n "$_wh" ] && high=$(round_num "$_wh") || high="--"
    [ -n "$_wl" ] && low=$(round_num "$_wl") || low="--"
    aqi=$(cget AQI); aqi_txt=$(aqi_word "$aqi")
    sunrise=$(cget SUNRISE); sunset=$(cget SUNSET)
    get_batt
    log "天气: $temp° $desc 低$low 高$high 湿度$hum AQI=$aqi($aqi_txt) 日出$sunrise 日落$sunset 电量${batt_pct}%"

    hh=$(date +%H); mm=$(date +%M)
    draw_num2 "$BB_TIME_X" "$(( _bcy + 46 ))" "$hh:$mm" time >/dev/null
    stamp "$ASSETSDIR/v2_icons/$icon.png" "$BB_ICON_X" "$(( _bcy - BB_ICON_S / 2 ))"
    x=$(draw_num2 "$BB_TEMP_X" "$(( _bcy + 28 ))" "$temp" temp)
    stamp "$ASSETSDIR/v2_digits/temp/deg.png" "$x" "$(( _bcy + 28 - S_TEMP ))"
    draw_cn2 "$BB_DESC_X" "$(( _bcy - 16 ))" "$desc" mid 2 >/dev/null
    x=$(draw_num2 "$BB_DESC_X" "$(( _bcy + 26 ))" "$low" small)
    stamp "$ASSETSDIR/v2_digits/small/dash.png" "$x" "$(( _bcy + 26 - S_SMALL ))"
    x=$(draw_num2 "$((x + SYM_W_SMALL + 4 ))" "$(( _bcy + 26 ))" "$high" small)
    stamp "$ASSETSDIR/v2_digits/small/deg.png" "$x" "$(( _bcy + 26 - S_SMALL ))"

    x=$(draw_cn2 "$BB_HUM_X" "$(( _bcy - 16 ))" "湿度" small 2)
    x=$(draw_num2 "$((x + 8))" "$(( _bcy - 16 ))" "$hum" small)
    stamp "$ASSETSDIR/v2_digits/small/pct.png" "$x" "$(( _bcy - 16 - S_SMALL ))"
    if [ -n "$aqi_txt" ]; then
        x=$(draw_cn2 "$BB_HUM_X" "$(( _bcy + 26 ))" "空气" small 2)
        x=$(draw_cn2 "$((x + 8))" "$(( _bcy + 26 ))" "$aqi_txt" small 2)
        draw_num2 "$((x + 6))" "$(( _bcy + 26 ))" "$aqi" small >/dev/null
    fi

    # ---- 侧栏 ----
    calfile="$ASSETSDIR/cal2/$Y-$(date +%m).png"
    if [ -f "$calfile" ]; then
        stamp "$calfile" "$COL_X" "$CAL_Y"
        pos=$(cal_pos "$D")
        row=${pos% *}; col=${pos#* }
        hx=$(( COL_X + col * CAL_COL_I + (CAL_COL_I - 52) / 2 ))
        hy=$(( CAL_Y + CAL_TOP + row * CAL_ROW - 6 ))
        [ -f "$ASSETSDIR/v2_hl/$D.png" ] && stamp "$ASSETSDIR/v2_hl/$D.png" "$hx" "$hy"
        # 纪念日标记：本月内的纪念日，在数字外围拼一个空心框（底部粗边）
        ann_month_days
        for _md in $ANN_MARK_DAYS; do
            [ "$_md" = "$D" ] && continue   # 今天已有反白块，不重复画
            _mp=$(cal_pos "$_md")
            _mrow=${_mp% *}; _mcol=${_mp#* }
            _fx=$(( COL_X + _mcol * CAL_COL_I + 4 ))
            _fy=$(( CAL_Y + CAL_TOP + _mrow * CAL_ROW - 6 ))
            stamp "$ASSETSDIR/v2_hl/fr_top.png"  "$_fx" "$_fy"
            stamp "$ASSETSDIR/v2_hl/fr_bot.png"  "$_fx" "$((_fy + 35))"
            stamp "$ASSETSDIR/v2_hl/fr_side.png" "$_fx" "$_fy"
            stamp "$ASSETSDIR/v2_hl/fr_side.png" "$((_fx + 49))" "$_fy"
        done
    fi

    stamp "$ASSETSDIR/hline420.png" "$COL_X" "$Y_RULE1"
    stamp "$ASSETSDIR/hline420.png" "$COL_X" "$Y_RULE3"
    stamp "$ASSETSDIR/hline420.png" "$COL_X" "$Y_RULE4"
    stamp "$ASSETSDIR/hline420.png" "$COL_X" "$Y_RULE5"

    if [ -n "$sunrise" ] && [ "$sunrise" != "-" ]; then
        x=$(draw_cn2 "$COL_X" "$Y_SUNRISE" "日出" tiny 2)
        x=$(draw_num2 "$((x + 10))" "$Y_SUNRISE" "$sunrise" tiny)
        x=$(draw_cn2 "$X_SUNSET" "$Y_SUNRISE" "日落" tiny 2)
        draw_num2 "$((x + 10))" "$Y_SUNRISE" "$sunset" tiny >/dev/null
    fi

    draw_cn2 "$COL_X" "$Y_FEST_LABEL" "临近节日" tiny 4 >/dev/null
    fest_pick
    _ts=$(date -d "$(date +%F)" +%s 2>/dev/null)
    _i=1
    if [ -n "$_ts" ] && [ -f "$FEST_TMP" ]; then
        while IFS='|' read -r _fd _fn; do
            [ -n "$_fd" ] || continue
            _fs=$(date -d "$_fd" +%s 2>/dev/null); [ -n "$_fs" ] || continue
            _fdays=$(( (_fs - _ts) / 86400 ))
            eval "_fy=\$Y_FEST$_i"
            [ -n "$_fy" ] || break
            draw_cn2 "$COL_X" "$_fy" "$_fn" mid $(( $(echo -n "$_fn" | wc -c) / 3 )) >/dev/null
            _fm=$(printf '%s' "$_fd" | cut -d- -f2 | sed 's/^0//')
            _fdd=$(printf '%s' "$_fd" | cut -d- -f3 | sed 's/^0//')
            x=$(( COL_X + 96 ))
            x=$(draw_num2 "$x" "$_fy" "$_fm" tiny)
            x=$(draw_cn2 "$x" "$_fy" "月" tiny 1)
            x=$(draw_num2 "$x" "$_fy" "$_fdd" tiny)
            draw_cn2 "$x" "$_fy" "日" tiny 1 >/dev/null
            _dx=$(( COL_X + COL_W - 74 ))
            case $_fdays in *[!0-9]*) _fdays=0 ;; esac
            _dwid=$(echo -n "$_fdays" | wc -c)
            draw_num2 $(( _dx + (3 - _dwid) * DIGIT_W_NUM )) "$_fy" "$_fdays" num >/dev/null
            draw_cn2 "$((_dx + 3 * DIGIT_W_NUM + 6))" "$_fy" "天" tiny 1 >/dev/null
            _i=$((_i + 1))
            [ "$_i" -gt 3 ] && break
        done <"$FEST_TMP"
    fi
    rm -f "$FEST_TMP"

    anniv_pick
    draw_cn2 "$COL_X" "$Y_ANN_LABEL" "特殊日子" tiny 4 >/dev/null
    if [ -n "$ANN_NAME" ]; then
        # 名称宽度直接用 draw_chars 的返回值：含 ww/yr 这类 ASCII 也算得准
        _endx=$(draw_chars "$COL_X" "$Y_ANN" "$ANN_NAME" 26)
        x=$(( _endx + 16 ))
        [ "$x" -lt "$(( COL_X + 96 ))" ] && x=$(( COL_X + 96 ))
        _lm=""; _ld=""
        if [ "$ANN_IS_LUNAR" = "1" ]; then
            # 农历日子贴「冬月十六」，和公历的「12月24日」形态区分开
            _lab=$(lunar_label_of "$ANN_DATE")
            _lm=${_lab%%|*}; _ld=${_lab#*|}
        fi
        if [ -n "$_lm" ] && [ -n "$_ld" ] && [ "$_lm" != "$_ld" ]; then
            x=$(draw_cn2 "$x" "$Y_ANN" "$_lm" tiny 2)
            draw_cn2 "$x" "$Y_ANN" "$_ld" tiny 2 >/dev/null
        else
            _am=$(printf '%s' "$ANN_DATE" | cut -d- -f2 | sed 's/^0//')
            _ad=$(printf '%s' "$ANN_DATE" | cut -d- -f3 | sed 's/^0//')
            x=$(draw_num2 "$x" "$Y_ANN" "$_am" tiny)
            x=$(draw_cn2 "$x" "$Y_ANN" "月" tiny 1)
            x=$(draw_num2 "$x" "$Y_ANN" "$_ad" tiny)
            draw_cn2 "$x" "$Y_ANN" "日" tiny 1 >/dev/null
        fi
        _dx=$(( COL_X + COL_W - 74 ))
        _dwid=$(echo -n "$ANN_DAYS" | wc -c)
        draw_num2 $(( _dx + (3 - _dwid) * DIGIT_W_NUM )) "$Y_ANN" "$ANN_DAYS" num >/dev/null
        draw_cn2 "$((_dx + 3 * DIGIT_W_NUM + 6))" "$Y_ANN" "天" tiny 1 >/dev/null
    fi

    # 明日 / 后日预报
    _t_hi=$(cget D1_HI); _t_lo=$(cget D1_LO); _a_hi=$(cget D2_HI); _a_lo=$(cget D2_LO)
    _t_ic=$(cget D1_ICON); _a_ic=$(cget D2_ICON)
    if [ -n "$_t_hi" ]; then
        draw_cn2 "$COL_X" "$Y_FC1" "明天" tiny 2 >/dev/null
        # 图标 48px：y=-40 时顶端压到 Y_RULE4 横线(842)，收到 -34 留出空隙
        stamp "$ASSETSDIR/icons/small/${_t_ic:-cloud}.png" "$(( COL_X + 62 ))" "$(( Y_FC1 - 34 ))"
        _x=$(draw_num2 "$(( COL_X + 208 ))" "$Y_FC1" "$(round_num "$_t_lo")" tiny)
        stamp "$ASSETSDIR/v2_digits/tiny/deg.png" "$_x" "$(( Y_FC1 - S_TINY ))"
        stamp "$ASSETSDIR/v2_digits/tiny/dash.png" "$((_x + SYM_W_TINY + 2))" "$(( Y_FC1 - S_TINY ))"
        _x=$(draw_num2 "$((_x + 2 * SYM_W_TINY + 6))" "$Y_FC1" "$(round_num "$_t_hi")" tiny)
        stamp "$ASSETSDIR/v2_digits/tiny/deg.png" "$_x" "$(( Y_FC1 - S_TINY ))"
    fi
    if [ -n "$_a_hi" ]; then
        draw_cn2 "$COL_X" "$Y_FC2" "后天" tiny 2 >/dev/null
        stamp "$ASSETSDIR/icons/small/${_a_ic:-cloud}.png" "$(( COL_X + 62 ))" "$(( Y_FC2 - 34 ))"
        _x=$(draw_num2 "$(( COL_X + 208 ))" "$Y_FC2" "$(round_num "$_a_lo")" tiny)
        stamp "$ASSETSDIR/v2_digits/tiny/deg.png" "$_x" "$(( Y_FC2 - S_TINY ))"
        stamp "$ASSETSDIR/v2_digits/tiny/dash.png" "$((_x + SYM_W_TINY + 2))" "$(( Y_FC2 - S_TINY ))"
        _x=$(draw_num2 "$((_x + 2 * SYM_W_TINY + 6))" "$Y_FC2" "$(round_num "$_a_hi")" tiny)
        stamp "$ASSETSDIR/v2_digits/tiny/deg.png" "$_x" "$(( Y_FC2 - S_TINY ))"
    fi

    # 更新 + 电量：电量段按内容总宽算起点，右对齐到栏右缘，
    # 否则"充电中/已充满"三字会超出屏幕右缘被裁掉
    x=$(draw_cn2 "$COL_X" "$Y_UPDATE" "更新" tiny 2)
    draw_num2 "$((x + 8))" "$Y_UPDATE" "$(date +%H:%M)" tiny >/dev/null
    _bp=$(echo -n "$batt_pct" | wc -c)
    case $_bp in *[!0-9]*) _bp=2 ;; esac
    _bw=$(( 2 * 24 + 8 + _bp * DIGIT_W_TINY + PCT_W_TINY ))
    [ -n "$batt_text" ] && _bw=$(( _bw + 26 + 3 * 24 ))
    _bx=$(( COL_X + COL_W - _bw - 2 ))
    x=$(draw_cn2 "$_bx" "$Y_UPDATE" "电量" tiny 2)
    x=$(draw_num2 "$((x + 8))" "$Y_UPDATE" "$batt_pct" tiny)
    stamp "$ASSETSDIR/v2_digits/tiny/pct.png" "$x" "$(( Y_UPDATE - S_TINY ))"
    [ -n "$batt_text" ] && draw_cn2 "$((x + 26))" "$Y_UPDATE" "$batt_text" tiny 3 >/dev/null

    stamp_last "$ASSETSDIR/hline420.png" "$COL_X" "$Y_RULE2"
    log "合成完成"
}

paint_one
