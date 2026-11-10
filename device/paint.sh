#!/bin/sh
# ============================================================
# 照片墙 · 设备端合成（Kindle 自己出图，不依赖电脑）
#
# 每次运行做一轮：
#   1. 选照片：photos/ 里 24 小时内传进来的最新一张优先，
#      否则按日期在 photos/ 里轮换
#   2. 拉/解析天气（中国天气接口，纯 HTTP；失败用缓存）
#   3. 用 FBInk 按坐标贴图合成整幅画面（累积绘制，只刷一次屏）
#
# 坐标与字号全部来自 assets/layout.sh（电脑生成，勿手改）
# ============================================================

DIR="${KPW_DIR:-/mnt/us/kindle-photo-wall}"
LOG="$DIR/device/dash.log"
FB="${FBINK_BIN:-/mnt/us/libkh/bin/fbink}"
WXCACHE="$DIR/device/wx.cache"
EIPS=$(command -v eips 2>/dev/null || echo /usr/sbin/eips)
[ -x "$EIPS" ] || EIPS=/usr/bin/eips

# Kindle 系统时钟走的是 UTC，必须显式给时区才会显示本地时间。
# CST-8 是 POSIX 时区串（东八区、无夏令时），不依赖设备上有没有 zoneinfo 文件。
TZ="${KPW_TZ:-CST-8}"; export TZ   # 想换时区就设 KPW_TZ，别指望系统已有的 TZ

# 坐标与字号全部来自 assets/layout.sh（电脑生成，勿手改）
# 注意：先读 env.conf 再选布局 —— LANDSCAPE 决定用哪套坐标，顺序不能反
. "$DIR/device/env.conf" 2>/dev/null
# 横屏模式（env.conf LANDSCAPE=1）改用 layout-land.sh —— 同一套字模素材，
# 只是画布换成 1448x1072：左边照片、右边信息栏。framebuffer 的旋转由 render.sh 负责。
_LAYOUT="$DIR/assets/layout.sh"
if [ "${LANDSCAPE:-0}" = "1" ] && [ -f "$DIR/assets/layout-land.sh" ]; then
    _LAYOUT="$DIR/assets/layout-land.sh"
fi
# 兜底：若 layout.sh 是 CRLF（Windows 下生成常见），坐标会带 \r，fbink 会报
# "Found trailing characters" 导致所有贴图失败 —— 先清洗成 LF 副本再 source。
if sed 's/\r$//' "$_LAYOUT" >"$DIR/device/.layout.lf" 2>/dev/null && [ -s "$DIR/device/.layout.lf" ]; then
    . "$DIR/device/.layout.lf"
else
    . "$_LAYOUT"
fi

# 配置（env.conf 可覆盖；上面已 source，这里只放默认值兜底）
CITY_CODE="${CITY_CODE:-101010100}"     # 天气城市代码（示例，务必在 env.conf 配置自己的城市）
LAT="${LAT:-39.9042}"                   # 纬度（示例：北京）
LON="${LON:-116.4074}"                  # 经度
WAVE="${WAVE:-GL16}"                    # 日常刷新波形；残影重就换 GC16
WAVE_FULL="${WAVE_FULL:-GC16}"          # 全刷波形
FULL_EVERY="${FULL_EVERY:-60}"          # 每 N 轮一次全刷
PHOTO_ROTATE_SEC="${PHOTO_ROTATE_SEC:-60}"   # 每 N 秒换一张照片；0=按天换
PHOTO_NEW_WINDOW="${PHOTO_NEW_WINDOW:-90}"   # 刚上传的图优先显示多少秒

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>&1; }

have_fbink=0
if [ -n "$FBINK_BIN" ] || { [ -f "$FB" ] && "$FB" -q -V >/dev/null 2>&1; }; then
    have_fbink=1
fi

# ---- 贴图原语 ----
# 累积绘制（不触发刷新），必须由 stamp_last 结尾
stamp() { # file x y
    if [ "$have_fbink" -eq 1 ]; then
        $FBINK_BIN $FB -q -b -g "file=$1,x=$2,y=$3" >/dev/null 2>>"$LOG"
    fi
}
stamp_last() { # file x y —— 最后一笔，触发刷新；每 FULL_EVERY 轮强制全刷清残影
    if [ "$have_fbink" -eq 1 ]; then
        cnt=$(cat "$DIR/device/.count" 2>/dev/null || echo 0)
        cnt=$((cnt + 1))
        echo $cnt >"$DIR/device/.count"
        # ① 先强制点亮屏幕。
        #    面板被 blank 掉时，驱动对 update 一律静默丢弃：帧缓冲内容在变、
        #    命令退出码 0、屏幕一动不动。每帧写 0 把它拉回来。
        _bl0=$(cat /sys/class/graphics/fb0/blank 2>/dev/null)
        echo 0 >/sys/class/graphics/fb0/blank 2>/dev/null
        _ubl=$?
        _bl1=$(cat /sys/class/graphics/fb0/blank 2>/dev/null)
        if [ "$cnt" -le 2 ] || [ "$_bl0" != "$_bl1" ] || [ $((cnt % 10)) -eq 0 ]; then
            log "屏幕 blank=$_bl1（原 $_bl0, unblank rc=$_ubl）"
        fi

        # ② 最后一笔画进帧缓冲，不触发刷新
        $FBINK_BIN $FB -q -b -g "file=$1,x=$2,y=$3" >>"$LOG" 2>&1

        # ③ 整屏刷新当前帧缓冲 —— 必须用 fbink 自己的 -s！
        #    之前用 eips -f：rc=0 但面板不认，实测只有本次会话的第一帧上屏，
        #    之后每一帧都被静默丢弃（帧缓冲在变、屏幕定格）—— 长期以来
        #    "画面永远停在第一帧"的真正根因。FBInk 的 -s（不带子选项）就是
        #    "整屏刷新当前帧缓冲"，并且它会正确跟踪驱动更新标记，专门适配
        #    PW4 这类 MTK 屏控。社区同类项目（Kindle-Dashboard 等）全程只用
        #    FBInk 刷新，从不走 eips。
        #    波形：平时 WAVE（GL16 轻刷，整屏换图但屏幕不闪黑，残影很淡）；
        #    每 FULL_EVERY 帧（默认 10 分钟）和每次启动的第一帧用 WAVE_FULL
        #    （GC16 闪一下），把累积的残影彻底清干净。
        if [ "$cnt" -eq 1 ] || [ $((cnt % FULL_EVERY)) -eq 0 ]; then
            _wv="$WAVE_FULL"; _fl="-fs"
            _kind="闪刷"
        else
            _wv="$WAVE"; _fl="-s"
            _kind="轻刷"
        fi
        _rc=1
        [ "$have_fbink" -eq 1 ] && $FBINK_BIN $FB -q "$_fl" -W "$_wv" >>"$LOG" 2>&1 && _rc=0
        if [ "$_rc" -ne 0 ]; then
            log "刷新 #$cnt $_kind($_wv) 失败 rc=$_rc，退回 eips -f"
            "$EIPS" -f >>"$LOG" 2>&1
            _rc=$?
            [ "$_rc" -ne 0 ] && log "eips -f 也失败 rc=$_rc"
        elif [ "$_kind" = "闪刷" ]; then
            log "刷新 #$cnt $_kind($_wv)"
        fi
        return 0
    fi
    # 无 FBInk 时的兜底：eips 无法精确合成，直接贴单图
    "$EIPS" -g "$1" >>"$LOG" 2>&1
}

# ---- 读图片尺寸（PNG / JPEG），读不到返回空 ----
# 为什么要读：fbink 贴图默认按原始像素画，手机直传的 4000x3000 照片（而且
# 旋转信息还在 EXIF 里）会只露出左上角一小块。这里先量尺寸，再按"铺满照片区
# 后居中裁掉多余"算缩放和负偏移（fbink 的 w=/h= 只能等比缩放，不能裁切，
# 所以裁切是用负的 x/y 让超出的部分跑到屏幕外实现的）。
img_dims_raw() { # file 块数(4KB/块) → "宽 高"
    dd if="$1" bs=4096 count="$2" 2>/dev/null | od -An -tu1 -v |
        tr -s ' ' '\n' | sed '/^$/d' | awk '
        { a[NR] = $1 }
        END {
            if (NR < 24) exit
            # PNG: 89 50 4e 47，IHDR 宽高在 16~23 字节，大端
            if (a[1]==137 && a[2]==80 && a[3]==78 && a[4]==71) {
                w = a[17]*16777216 + a[18]*65536 + a[19]*256 + a[20]
                h = a[21]*16777216 + a[22]*65536 + a[23]*256 + a[24]
                if (w > 0 && h > 0) { print w, h; exit }
            }
            # JPEG: FF D8 开头，找 SOF0~SOF3 段（FF C0/C1/C2/C3），
            # 字段顺序是 长度(2) 精度(1) 高(2) 宽(2)
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

# 两级读取：绝大多数图（手机 JPEG、PNG）的 SOF/IHDR 就在前 32KB 内，先读 32KB；
# 解析不出来（EXIF 特别大、SOF 被推到后面）再读 128KB。
# 为什么不一上来就读 128KB：od/awk 要处理 12 万个数字，在这台机器上要多花好几秒，
# 而绝大多数时候根本用不到第二级。
img_dims() { # file → "宽 高"
    _r=$(img_dims_raw "$1" 8 2>/dev/null)
    [ -n "$_r" ] || _r=$(img_dims_raw "$1" 32 2>/dev/null)
    printf '%s' "$_r"
}

# 照片贴图：把任意尺寸的图铺满顶部照片区（W × PHOTO_H），居中裁切
stamp_photo() { # file
    # 尺寸只在"图片本身变了"时才解析一次：每帧都 dd+od+awk 解一遍，
    # 在这台机器上要好几秒，白白拖慢每分钟的刷新。用 修改时间+大小 做缓存键。
    _dkey="$1:$(stat -c '%Y-%s' "$1" 2>/dev/null)"
    _d=""
    if [ -f "$DIR/device/.photo.dims" ]; then
        _dk=$(sed -n 1p "$DIR/device/.photo.dims" 2>/dev/null)
        if [ "$_dk" = "$_dkey" ]; then _d=$(sed -n 2p "$DIR/device/.photo.dims" 2>/dev/null); fi
    fi
    if [ -z "$_d" ]; then
        _d=$(img_dims "$1" 2>/dev/null)
        printf '%s\n%s\n' "$_dkey" "$_d" >"$DIR/device/.photo.dims" 2>/dev/null
        log "照片尺寸解析: $(basename "$1") → '$_d'"
    fi
    _iw=$(printf '%s' "$_d" | cut -d' ' -f1)
    _ih=$(printf '%s' "$_d" | cut -d' ' -f2)
    case $_iw in ''|*[!0-9]*) _iw=0 ;; esac
    case $_ih in ''|*[!0-9]*) _ih=0 ;; esac
    # 照片区几何：横屏时照片在左边一块（PHOTO_X/Y/W/H），竖屏时占顶部整行
    _px="${PHOTO_X:-0}"; _py="${PHOTO_Y:-0}"
    _pw="${PHOTO_W:-$W}"; _ph="${PHOTO_H:-730}"
    # 尺寸解析不出来（罕见格式、异常 EXIF）：宁可拉伸变形，也别只露左上角一块
    if [ "$_iw" -le 0 ] || [ "$_ih" -le 0 ]; then
        $FBINK_BIN $FB -q -b -g "file=$1,x=$_px,y=$_py,w=$_pw,h=$_ph" >/dev/null 2>>"$LOG"
        log "照片尺寸未知 → 强制拉伸到 ${_pw}x${_ph}"
        return 0
    fi
    # 本来就是照片区的尺寸：原样贴，不折腾
    if [ "$_iw" = "$_pw" ] && [ "$_ih" = "$_ph" ]; then
        stamp "$1" "$_px" "$_py"
        return 0
    fi
    # ---- 贴图方式（env.conf 的 PHOTO_FIT）----
    #   contain = 等比缩小到"完整装进"照片区，多余的地方留白，一个像素都不裁（默认）
    #   cover   = 等比放大"铺满"照片区，裁掉溢出部分（无留白，但会切掉画面边缘）
    if [ "${PHOTO_FIT:-contain}" != "cover" ]; then
        # 缩放取 min(pw/iw, ph/ih)：
        #   pw*ih <= ph*iw  → 宽度是瓶颈，按宽缩满，上下留白
        #   否则            → 高度是瓶颈，按高缩满，左右留白
        if [ $(( _pw * _ih )) -le $(( _ph * _iw )) ]; then
            _sw=$_pw; _sh=$(( _ih * _pw / _iw ))
        else
            _sh=$_ph; _sw=$(( _iw * _ph / _ih ))
        fi
        _sx=$(( _px + (_pw - _sw) / 2 ))
        _sy=$(( _py + (_ph - _sh) / 2 ))
        $FBINK_BIN $FB -q -b -g "file=$1,x=$_sx,y=$_sy,w=$_sw,h=$_sh" >/dev/null 2>>"$LOG"
        log "照片完整适配: ${_iw}x${_ih} → ${_sw}x${_sh} 居中(${_sx},${_sy}) 留白$(( _pw - _sw ))x$(( _ph - _sh ))"
        return 0
    fi
    # 先按宽度铺满；算出来比照片区还矮，说明图更扁，改按高度铺满
    _sh=$(( _ih * _pw / _iw ))
    if [ "$_sh" -ge "$_ph" ]; then
        # 按宽铺满：竖向超出的部分上下居中挪出屏幕外
        # （两种布局照片区都顶到屏幕上缘，往上推永远出屏）
        _sw=$_pw; _sx=$_px; _sy=$(( _py - (_sh - _ph) / 2 ))
    else
        # 按高铺满：横向超出的部分整体推到照片区左边之外。
        # 不能上下/左右居中裁：横屏时照片区只占左半屏，右边是信息栏，
        # 居中的话右侧多出的一截落在屏幕内，会压在日历/时间底下
        # （日志实测 2446x1920 → 1365 宽、右缘跑到 1157）。照片区左缘
        # 就是屏幕左缘（两种布局 PHOTO_X 都是 0），往左推永远在屏幕外。
        _sh=$_ph; _sw=$(( _iw * _ph / _ih ))
        _sx=$(( _px - (_sw - _pw) )); _sy=$_py
    fi
    $FBINK_BIN $FB -q -b -g "file=$1,x=$_sx,y=$_sy,w=$_sw,h=$_sh" >/dev/null 2>>"$LOG"
    log "照片自适应: ${_iw}x${_ih} → ${_sw}x${_sh} 偏移(${_sx},${_sy})"
}

# ---- 数字串：draw_num x y "文本" 尺寸档 ----
# 尺寸档: big mid date week small cal
# 返回（stdout）：画完后的 x，供下一个元素继续排
draw_num() {
    _x=$1; _y=$2; _t=$3; _st=$4
    _ST=$(echo "$_st" | tr 'a-z' 'A-Z')
    eval "_dw=\$DIGIT_W_$_ST"
    eval "_sw=\$SYM_W_$_ST"
    eval "_sz=\$S_$_ST"
    [ -n "$_dw" ] || _dw=30
    [ -n "$_sw" ] || _sw=25
    [ -n "$_sz" ] || _sz=34
    _dy=$(( _y - (_sz * 15) / 100 ))
    while [ -n "$_t" ]; do
        _c=${_t%"${_t#?}"}; _t=${_t#?}
        case $_c in
            :) _f="$ASSETS/digits/$_st/colon.png"; _w=$_sw ;;
            %)  _f="$ASSETS/digits/$_st/pct.png";  _w=$_sw ;;
            -)  _f="$ASSETS/digits/$_st/dash.png"; _w=$_sw ;;
            .)  _f="$ASSETS/digits/$_st/dot.png";  _w=$_sw ;;
            *)  _f="$ASSETS/digits/$_st/$_c.png";  _w=$_dw ;;
        esac
        if [ -f "$_f" ]; then
            stamp "$_f" "$_x" "$_dy"
        fi
        _x=$(( _x + _w ))
    done
    echo "$_x"
}

# ---- 中文词：draw_cn x y "词" 尺寸档 字数 ----
draw_cn() {
    _x=$1; _y=$2; _w=$3; _st=$4; _n=$5
    _ST=$(echo "$_st" | tr 'a-z' 'A-Z')
    eval "_sz=\$S_$_ST"
    [ -n "$_sz" ] || _sz=34
    _f="$ASSETS/cn/$_st/$_w.png"
    [ -f "$_f" ] || _f="$ASSETS/cn/$_st/未知.png"
    _dy=$(( _y - (_sz * 17) / 100 ))
    stamp "$_f" "$_x" "$_dy"
    echo $(( _x + _n * _sz ))
}

# ---- 天气类型 → 图标名 ----
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

# 从 JSON 取第一个 "key":"value"（sed 的 .* 贪婪会取最后一个，不能用）
jget() { # json key
    printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 |
        sed 's/^[^:]*:"//;s/"$//'
}

# ---- WMO 天气代码 → "中文描述 图标" ----
wmo_desc() { # code
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

# 取 JSON 数组内容（"weather_code":[80,3,1] → 80,3,1）
arr_of() { printf '%s' "$1" | grep -o "\"$2\":\[[^]]*\]" | head -1 | sed 's/^[^[]*\[//;s/\]$//'; }
nth() { printf '%s' "$1" | tr ',' '\n' | sed -n "${2}p" | tr -d ' '; }

# ---- 数据源 1：Open-Meteo（按经纬度，无 key、无频率限制，精确定位到区）----
fetch_openmeteo() {
    _u="http://api.open-meteo.com/v1/forecast?latitude=$LAT&longitude=$LON&current=temperature_2m,relative_humidity_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=Asia%2FShanghai&forecast_days=3"
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
    _i=1
    while [ "$_i" -le 3 ]; do
        _k=$(( _i - 1 ))
        _c=$(nth "$_codes" "$_i")
        [ "$_k" -eq 0 ] && [ -n "$_cc" ] && _c=$_cc
        set -- $(wmo_desc "$_c")
        echo "D${_k}_DESC=$1"
        echo "D${_k}_ICON=$2"
        echo "D${_k}_HI=$(nth "$_his" "$_i")"
        echo "D${_k}_LO=$(nth "$_los" "$_i")"
        _i=$(( _i + 1 ))
    done
}

# ---- 数据源 2：中国天气网镜像（中文描述，作备份）----
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
        _k=$(( _i - 1 ))
        _d=$(printf '%s' "$_j" | grep -o '"type":"[^"]*"' | sed -n "${_i}p" | sed 's/"type":"//;s/"//')
        _hi=$(pick_temp "$(printf '%s' "$_j" | grep -o '"high":"[^"]*"' | sed -n "${_i}p")")
        _lo=$(pick_temp "$(printf '%s' "$_j" | grep -o '"low":"[^"]*"' | sed -n "${_i}p")")
        [ -n "$_d" ] || _d="未知"
        echo "D${_k}_DESC=$_d"
        echo "D${_k}_ICON=$(icon_of "$_d")"
        echo "D${_k}_HI=$_hi"
        echo "D${_k}_LO=$_lo"
        _i=$(( _i + 1 ))
    done
}

# ---- 取天气：归一化缓存，45 分钟有效；两个源都失败就沿用旧缓存 ----
# 跨零点必须强制重取：预报按"今天/明天/后天"取，23:50 拉的那份缓存如果
# 一直用到 00:35，画面上的"今天"其实还是昨天。所以缓存里记 FETCHDAY，
# 日期一变就立刻重拉（跨月/跨年同理）。
get_wx() {
    _now=$(date +%s)
    _mtime=$(stat -c %Y "$WXCACHE" 2>/dev/null)
    [ -n "$_mtime" ] || _mtime=0
    _age=$(( _now - _mtime ))
    _today=$(date +%F)
    _cacheday=$(sed -n 's/^FETCHDAY=//p' "$WXCACHE" 2>/dev/null | head -1)
    if [ -f "$WXCACHE" ] && [ "$_age" -le 2700 ] && [ "$_cacheday" = "$_today" ]; then
        return 0
    fi
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

json_field() { # json片段 模式1 模式2 ...
    _json=$1
    shift
    for _p in "$@"; do
        _v=$(printf '%s' "$_json" | sed -n "s/.*$_p.*/\\1/p" | head -1)
        [ -n "$_v" ] && { echo "$_v"; return 0; }
    done
    echo ""
}

round_num() { awk -v v="$1" 'BEGIN{printf "%d", v + (v>=0 ? 0.5 : -0.5)}'; }

pick_temp() { # 从 "高温 7℃"/"低温 -3℃" 里取数字
    printf '%s' "$1" | sed 's/[^0-9-]//g' | head -c 4
}

# ---- 电量 ----
# 电池节点名各固件不同（max170xx_battery / bd71827_battery …），
# 直接扫所有 power_supply 子目录的 capacity，第一个有合理数值的即用。
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
            *)                 batt_text="" ;;
        esac
        break
    done
    [ -n "$batt_pct" ] || batt_pct="--"
}

# ---- 照片目录：只有一个，既是轮换池也是 FTP 根目录 ----
PHOTOS_DIR="$DIR/photos"

# 老版本有 photos_in/（手机上传专用）。现在合并成一个目录，这里做一次迁移：
# photos_in 里的文件搬到 photos/，子目录里的图片也平铺上来。
merge_photo_dirs() {
    if [ -d "$DIR/photos_in" ]; then
        for _f in "$DIR/photos_in"/*; do
            [ -f "$_f" ] || continue
            _b=$(basename "$_f")
            _t="$PHOTOS_DIR/$_b"
            [ -e "$_t" ] && _t="$PHOTOS_DIR/$(date +%s)_$_b"
            mv -f "$_f" "$_t" 2>/dev/null && log "合并目录: $_b → photos/"
        done
        rmdir "$DIR/photos_in" 2>/dev/null && log "已删除空目录 photos_in/"
    fi
    # FTP 根目录就是 photos/，若有人在里面新建子目录上传，也平铺回来
    for _f in "$PHOTOS_DIR"/*/*; do
        [ -f "$_f" ] || continue
        case $_f in *.jpg|*.jpeg|*.JPG|*.JPEG|*.png|*.PNG|*.bmp|*.gif) ;; *) continue ;; esac
        _b=$(basename "$_f")
        _t="$PHOTOS_DIR/$_b"
        [ -e "$_t" ] && _t="$PHOTOS_DIR/$(date +%s)_$_b"
        mv -f "$_f" "$_t" 2>/dev/null && log "子目录归位: $_b → photos/"
    done
    # 掏空的子目录顺手删掉，免得被当成照片（ls 会把目录也列出来）
    for _d in "$PHOTOS_DIR"/*/; do
        [ -d "$_d" ] && rmdir "$_d" 2>/dev/null && log "清理空目录: $_d"
    done
}

# 遍历照片目录：纯 shell 循环 + test，不 fork。
# 原来的 `ls -t | head -1` 会给目录里每张图各做一次 stat 再全排序（照片有
# 几百张时明显卡顿），而且依赖 `ls -p` 这种非所有 busybox 都带的选项。
scan_photos() {   # 设置 PHOTO_COUNT / PHOTO_NEWEST
    PHOTO_COUNT=0; PHOTO_NEWEST=""
    for _x in "$PHOTOS_DIR"/*; do
        [ -f "$_x" ] || continue
        PHOTO_COUNT=$((PHOTO_COUNT + 1))
        if [ -z "$PHOTO_NEWEST" ] || [ "$_x" -nt "$PHOTO_NEWEST" ]; then
            PHOTO_NEWEST=$_x
        fi
    done
}

nth_photo() { # N（1 起）→ 第 N 张路径
    _i=0
    for _x in "$PHOTOS_DIR"/*; do
        [ -f "$_x" ] || continue
        _i=$((_i + 1))
        [ "$_i" -eq "$1" ] && { echo "$_x"; return 0; }
    done
    return 1
}

# 选这一帧显示哪张：
#   ① 刚上传（PHOTO_NEW_WINDOW 秒内）的那张 → 优先，保证"传完马上看到"
#   ② 其余时间 → 每 PHOTO_ROTATE_SEC 秒换一张（epoch/间隔 % 张数）
#      PHOTO_ROTATE_SEC=0 则退化成"每天一张"
# 旧逻辑是"永远显示最新那张"，一张都不换 —— 放十张图进去也只会显示同一张，
# 现象就是"时间在跳、图片不动"。
pick_photo() {
    scan_photos
    [ "$PHOTO_COUNT" -gt 0 ] || return 0

    # ---- ① 刚上传的那张优先 ----
    # 不能只看"mtime 最新的那个文件"：FAT32 时间戳不带时区，Windows 拷进来的
    # 文件按本地时间写、设备按 UTC 读，mtime 会整整晚 8 小时 —— 它永远排第一，
    # 而且 now-mtime 是负数（日志里出现过 -28021s），"在窗口内"的判断恒成立，
    # 结果就是每帧都贴它、轮换彻底卡死；同时真正刚用 FTP 传的那张（mtime 正常）
    # 会被它一直挡在后面。
    # 做法：ls -t 排一次序（busybox 内部 stat，不额外 fork），只看最前面几个，
    # 谁的 mtime 落在 [now-300, now+PHOTO_NEW_WINDOW] 就用它。
    # 下界 -300 是留给时钟误差的；USB 拷入那种"晚 8 小时"的会被正确排除。
    _now=$(date +%s)
    _fresh=""; _fresh_age=999999
    while read -r _n; do
        [ -n "$_n" ] || continue
        [ -f "$PHOTOS_DIR/$_n" ] || continue
        _m=$(stat -c %Y "$PHOTOS_DIR/$_n" 2>/dev/null); [ -n "$_m" ] || continue
        _a=$(( _now - _m ))
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

    # ---- ② 定时轮换 ----
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

# ============================================================
# 主流程
# ============================================================
n=0
paint_one() {
    log "---- 合成开始 ----"

    # 0. 先把整屏缓冲清成白色（只写不刷）：每帧都从干净画布开始，
    #    上一次残留的弹窗像素、上一帧的残影都会被覆盖掉。
    [ "$have_fbink" -eq 1 ] && $FBINK_BIN $FB -q -b -c >/dev/null 2>>"$LOG"

    # 1. 照片（单目录 photos/，也是 FTP 根目录）
    merge_photo_dirs
    photo=$(pick_photo)
    if [ -n "$photo" ]; then
        stamp_photo "$photo"
        log "照片: $(basename "$photo")"
    else
        log "照片: 目录里没有图片（$PHOTOS_DIR）"
    fi

    # 2. 天气（归一化缓存：TEMP/HUM/D0_*/D1_*/D2_*）
    get_wx
    _wt=$(cget TEMP)
    if [ -n "$_wt" ]; then temp=$(round_num "$_wt"); else temp="--"; fi
    hum=$(cget HUM); [ -n "$hum" ] || hum="--"
    desc=$(cget D0_DESC); [ -n "$desc" ] || desc="未知"
    icon=$(cget D0_ICON); [ -n "$icon" ] || icon="cloud"
    _wh=$(cget D0_HI); _wl=$(cget D0_LO)
    if [ -n "$_wh" ] && [ -n "$_wl" ]; then
        high=$(round_num "$_wh"); low=$(round_num "$_wl")
    else
        high="--"; low="--"
    fi
    # 明天 / 后天
    _a=$(cget D1_HI); _b=$(cget D1_LO); _c=$(cget D2_HI); _e=$(cget D2_LO)
    t_hi=""; t_lo=""; a_hi=""; a_lo=""
    [ -n "$_a" ] && t_hi=$(round_num "$_a")
    [ -n "$_b" ] && t_lo=$(round_num "$_b")
    [ -n "$_c" ] && a_hi=$(round_num "$_c")
    [ -n "$_e" ] && a_lo=$(round_num "$_e")
    t_icon=$(cget D1_ICON); [ -n "$t_icon" ] || t_icon="cloud"
    a_icon=$(cget D2_ICON); [ -n "$a_icon" ] || a_icon="cloud"

    log "天气: temp=$temp desc=$desc icon=$icon low=$low high=$high hum=$hum src=$(cget SRC)"

    # 2.5 电量
    get_batt
    log "电量: ${batt_pct}% ${batt_text}"

    # 3. 左栏：日期
    D=$(date +%-d 2>/dev/null || date +%d | sed 's/^0//')
    M=$(date +%-m 2>/dev/null || date +%m | sed 's/^0//')
    Y=$(date +%Y)
    dw=$(( $(echo -n "$M$D" | wc -c) ))
    row_w=$(( $(echo -n "$M$D" | wc -c) * $DIGIT_W_DATE + 2 * $S_DATE ))
    x=$(( COL1_X + (COL_W - row_w) / 2 ))
    x=$(draw_num "$x" "$Y_DATE" "$M" date)
    x=$(draw_cn "$x" "$Y_DATE" "月" date 1)
    x=$(draw_num "$x" "$Y_DATE" "$D" date)
    draw_cn "$x" "$Y_DATE" "日" date 1 >/dev/null

    # 星期
    wd=$(( ($(date +%u) + 6) % 7 ))   # 0=周一
    wk=$(echo "星期一 星期二 星期三 星期四 星期五 星期六 星期日" | cut -d' ' -f$((wd+1)))
    x=$(( COL1_X + (COL_W - 3 * $S_WEEK) / 2 ))
    draw_cn "$x" "$Y_WEEK" "$wk" week 3 >/dev/null

    # 时间（居中）
    hh=$(date +%H); mm=$(date +%M)
    tw=$(( 4 * $DIGIT_W_BIG + $SYM_W_BIG ))
    x=$(( COL1_X + (COL_W - tw) / 2 ))
    draw_num "$x" "$Y_TIME" "$hh:$mm" big >/dev/null

    stamp "$ASSETS/rule1.png" "$COL1_X" "$Y_RULE1"

    # 天气图标 + 温度
    stamp "$ASSETS/icons/big/$icon.png" "$COL1_X" "$Y_ICON"
    x=$(( COL1_X + ICON_R + 22 ))
    x=$(draw_num "$x" "$Y_TEMP" "$temp" mid)
    stamp "$ASSETS/digits/mid/deg.png" "$x" "$Y_TEMP"

    # 描述
    draw_cn "$COL1_X" "$Y_DESC" "$desc" desc $(( $(echo -n "$desc" | wc -c) / 3 )) >/dev/null

    # 高低温
    x=$(draw_num "$COL1_X" "$Y_RANGE" "$low" small)
    stamp "$ASSETS/digits/small/dash.png" "$x" "$Y_RANGE"
    x=$(draw_num "$((x+22))" "$Y_RANGE" "$high" small)
    stamp "$ASSETS/digits/small/deg.png" "$x" "$Y_RANGE"

    # 湿度
    x=$(draw_cn "$COL1_X" "$Y_POP" "湿度" small 2)
    x=$(draw_num "$((x+8))" "$Y_POP" "$hum" small)
    stamp "$ASSETS/digits/small/pct.png" "$x" "$Y_POP"

    # 4. 右栏：月历
    calfile="$ASSETS/cal/$Y-$(date +%m).png"
    if [ -f "$calfile" ]; then
        stamp "$calfile" "$COL2_X" "$Y_CAL"
        # 今天的高亮（Zeller 公式算行列）
        pos=$(awk -v y="$Y" -v m="$M" -v d="$D" 'BEGIN{
            mm=m; yy=y; if (mm<3){mm+=12; yy--}
            K=yy%100; J=int(yy/100)
            h=(1 + int(13*(mm+1)/5) + K + int(K/4) + int(J/4) + 5*J) % 7
            f0=(h+5)%7
            printf "%d %d", int((f0+d-1)/7), (f0+d-1)%7
        }')
        row=${pos% *}; col=${pos#* }
        hx=$(( COL2_X + col * CAL_COL_I + (CAL_COL_I - HL_W) / 2 ))
        hy=$(( Y_CAL + CAL_TOP + row * CAL_ROW - 2 ))
        [ -f "$ASSETS/digits/hl/$D.png" ] && stamp "$ASSETS/digits/hl/$D.png" "$hx" "$hy"
    fi

    stamp "$ASSETS/rule2.png" "$COL2_X" "$Y_RULE2"

    # 明天 / 后天（横屏右栏放不下，layout-land 用 FC_ROWS=0 关掉）
    draw_fc() { # y label icon hi lo
        _y=$1; _label=$2; _ic=$3; _hi=$4; _lo=$5
        [ -n "$_hi" ] || return 0
        [ -n "$_ic" ] || _ic=cloud
        draw_cn "$COL2_X" "$((_y+6))" "$_label" small 2 >/dev/null
        stamp "$ASSETS/icons/small/$_ic.png" "$((COL2_X+74))" "$_y"
        _x=$(draw_num "$((COL2_X+134))" "$((_y+6))" "$_hi" small)
        stamp "$ASSETS/digits/small/deg.png" "$_x" "$((_y+6))"
        stamp "$ASSETS/digits/small/dash.png" "$((_x+22))" "$((_y+6))"
        _x=$(draw_num "$((_x+46))" "$((_y+6))" "$_lo" small)
        stamp "$ASSETS/digits/small/deg.png" "$_x" "$((_y+6))"
    }
    if [ "${FC_ROWS:-1}" = "1" ]; then
        draw_fc "$Y_FC1" "明天" "$t_icon" "$t_hi" "$t_lo"
        draw_fc "$Y_FC2" "后天" "$a_icon" "$a_hi" "$a_lo"
    fi

    # 更新时间
    x=$(draw_cn "$COL2_X" "$Y_HUM" "更新" small 2)
    draw_num "$((x+8))" "$Y_HUM" "$(date +%H:%M)" small >/dev/null

    # 电量（紧贴更新行下方）
    _by="${Y_BATT:-$((Y_HUM + 54))}"
    x=$(draw_cn "$COL2_X" "$_by" "电量" small 2)
    x=$(draw_num "$((x+8))" "$_by" "$batt_pct" small)
    stamp "$ASSETS/digits/small/pct.png" "$x" "$_by"
    # "%"的图片比步进宽，接在后面的字要按真实宽度让开
    _px=$(( x + ${PCT_W_SMALL:-33} + 12 ))
    case $batt_text in
        "") ;;
        *) draw_cn "$_px" "$_by" "$batt_text" small 3 >/dev/null ;;
    esac

    # 5. 最后一笔触发刷新
    stamp_last "$ASSETS/rule1.png" "$COL1_X" "$Y_RULE1"
    log "合成完成"
}

paint_one
