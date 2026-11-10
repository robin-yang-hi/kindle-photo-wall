echo "=== tcpsvd ==="
busybox tcpsvd --help 2>&1 | head -5
command -v tcpsvd
echo "=== /tmp 可执行? ==="
mount | grep " /tmp "
printf '#!/bin/sh\necho ok\n' > /tmp/.t1
chmod +x /tmp/.t1
/tmp/.t1 >/dev/null 2>&1 && echo "/tmp 可执行: 是" || echo "/tmp 可执行: 否"
rm -f /tmp/.t1
echo "=== lua ==="
lua -v 2>&1
printf 'local f=io.open("/mnt/us/kindle-photo-wall/device/.luatest","w") if f then f:write("ok") f:close() print("lua 写文件: OK") else print("lua 写文件: 失败") end' > /tmp/t.lua
lua /tmp/t.lua 2>&1
rm -f /mnt/us/kindle-photo-wall/device/.luatest /tmp/t.lua
echo "=== 监听端口 ==="
netstat -ln 2>/dev/null | head -10
echo "=== httpd/nginx 等其他? ==="
command -v httpd busybox-thttpd lighttpd 2>/dev/null
echo "=== 现有 conf ==="
cat /mnt/us/kindle-photo-wall/device/anniversaries.conf
