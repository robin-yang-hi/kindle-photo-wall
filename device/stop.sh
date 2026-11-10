#!/bin/sh
# 停止照片墙，恢复 Kindle 原生界面
pkill -f dash-fetch.sh 2>/dev/null
initctl start framework 2>/dev/null
echo "已停止，界面恢复"
