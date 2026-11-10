echo "=== busybox 版本 ==="
busybox 2>&1 | head -2
echo "=== 关键 applet ==="
busybox --list 2>/dev/null | tr '\n' ' ' | fold -w 900 | head -4
echo
echo "=== httpd / nc 支持 ==="
busybox httpd --help 2>&1 | head -6
echo "--- nc ---"
busybox nc --help 2>&1 | head -4
echo "=== 解释器 ==="
ls -l /bin/sh 2>&1
for c in python3 python perl lua node php; do
    command -v $c >/dev/null 2>&1 && echo "有 $c: $(command -v $c)"
done
ls /usr/bin 2>/dev/null | grep -iE "python|perl|node|lua|php" | head -5
echo "=== /mnt/us 挂载参数与可执行位 ==="
mount | grep -E "mnt/us" 
ls -l /mnt/us/kindle-photo-wall/device/render.sh
echo "test-exec" > /mnt/us/kindle-photo-wall/device/.extest
chmod +x /mnt/us/kindle-photo-wall/device/.extest 2>&1
ls -l /mnt/us/kindle-photo-wall/device/.extest
/mnt/us/kindle-photo-wall/device/.extest >/dev/null 2>&1 && echo "FAT32 上可执行: 是" || echo "FAT32 上可执行: 否"
rm -f /mnt/us/kindle-photo-wall/device/.extest
echo "=== iptables 现有规则 ==="
iptables -S 2>&1 | head -10
echo "=== 内存 ==="
free -m 2>/dev/null | head -3
