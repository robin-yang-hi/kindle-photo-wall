# -*- coding: utf-8 -*-
"""把番茄钟 big 词模复制成 ASCII 临时名，供 curl 上传（绕开 FTP 中文路径）"""
import shutil, os, sys

os.makedirs("incoming_tmp", exist_ok=True)
words = ["专注中", "暂停中", "休息中", "长休息", "短休息"]
ok = True
for i, w in enumerate(words, 1):
    src = f"render/assets/v2_cn/big/{w}.png"
    if not os.path.exists(src):
        print(f"MISSING: {src}", file=sys.stderr)
        ok = False
        continue
    shutil.copy(src, f"incoming_tmp/pomo_w{i}.png")
print("copied" if ok else "INCOMPLETE")
