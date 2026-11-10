#!/bin/sh
# ============================================================
# 无线运维工具（电脑端）：不用插数据线就能改 Kindle 上的脚本、看日志
#
#   前提：照片墙正在运行（运维通道随它起停），Kindle 与电脑同一 WiFi
#
#   sh tools/wireless.sh log [行数]          看日志末尾（默认 40 行）
#   sh tools/wireless.sh grep 选图           在日志里搜关键词
#   sh tools/wireless.sh deploy device/paint.sh assets/layout.sh
#                                            上传并生效（自动校验 + 自动重启）
#   sh tools/wireless.sh restart             只重启照片墙
#   sh tools/wireless.sh stop                停照片墙并恢复书架界面
#   sh tools/wireless.sh ls [子目录]          列目录
#   sh tools/wireless.sh get device/dash.log [本地路径]
# ============================================================
set -u

KINDLE="${KINDLE:-192.168.0.250}"
ALT="${KINDLE_ALT:-192.168.0.112}"
APORT="${ADMIN_PORT:-2122}"
USER_="${FTP_USER:-root}"
PASS_="${FTP_PASS:-root}"

HERE=$(cd "$(dirname "$0")/.." && pwd)   # kindle-photo-wall/
TMP="${TMPDIR:-/tmp}/kpw.$$"
mkdir -p "$TMP" 2>/dev/null

# 两个 IP 都试（固定别名掉了还有 DHCP 的）
pick_host() {
    for h in "$KINDLE" "$ALT"; do
        if curl -s -m 4 --ftp-method nocwd -u "$USER_:$PASS_" "ftp://$h:$APORT/" >/dev/null 2>&1; then
            echo "$h"; return 0
        fi
    done
    return 1
}

ftp_get()  { curl -s -m 20 --ftp-method nocwd -u "$USER_:$PASS_" "ftp://$HOST:$APORT/$1"; }
ftp_put()  { curl -s -m 60 -T "$1" -u "$USER_:$PASS_" "ftp://$HOST:$APORT/$2"; }
ftp_dele() { curl -s -m 10 -Q "-DELE /$1" -u "$USER_:$PASS_" "ftp://$HOST:$APORT/" >/dev/null 2>&1; }

# 命令文件：写进 device/cmd，设备 5 秒内执行
send_cmd() {
    printf '%s\n' "$1" >"$TMP/cmd"
    if ftp_put "$TMP/cmd" "device/cmd"; then
        echo "已发送命令: $1（设备 ≤5 秒内执行）"
    else
        echo "命令发送失败"; return 1
    fi
}

cmd="${1:-}"; shift 2>/dev/null || true

HOST=$(pick_host) || {
    echo "连不上 Kindle（试过 $KINDLE 和 $ALT 的 $APORT 端口）"
    echo "· 照片墙没在运行？运维通道随它起停"
    echo "· 不在同一 WiFi？或者固定 IP 没挂上"
    exit 1
}
echo "→ 设备: $HOST:$APORT"

case "$cmd" in
    log)
        n="${1:-40}"
        ftp_get "device/dash.log" | tail -n "$n"
        ;;
    grep)
        ftp_get "device/dash.log" | grep -- "$1" | tail -n "${2:-30}"
        ;;
    ls)
        ftp_get "${1:-}" | sed -n '2,200p'
        ;;
    get)
        out="${2:-$(basename "$1")}"
        if ftp_get "$1" >"$out"; then echo "已保存: $out（$(wc -c <"$out") 字节）"; else echo "下载失败"; fi
        ;;
    deploy)
        [ $# -ge 1 ] || { echo "用法: deploy device/paint.sh [...]"; exit 1; }
        ok=0; bad=0
        for rel in "$@"; do
            src="$HERE/$rel"
            [ -f "$src" ] || { echo "找不到: $src"; bad=$((bad + 1)); continue; }
            # 本地先拦一遍 CRLF，省得白跑一趟
            if [ "$(wc -c <"$src")" != "$(tr -d '\r' <"$src" | wc -c)" ]; then
                echo "跳过（含 CRLF）: $rel"; bad=$((bad + 1)); continue
            fi
            if ftp_put "$src" "$rel.new"; then
                echo "已上传: $rel.new"; ok=$((ok + 1))
            else
                echo "上传失败: $rel"; bad=$((bad + 1))
            fi
        done
        [ "$ok" -gt 0 ] && send_cmd deploy
        echo "完成: 上传 $ok 个，失败 $bad 个"
        echo "（设备会在日志里写「部署: xxx 已更新」或「部署拒绝: ...」，用 log 命令可查）"
        ;;
    restart) send_cmd restart ;;
    stop)    send_cmd stop ;;
    *)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac

rm -rf "$TMP" 2>/dev/null
