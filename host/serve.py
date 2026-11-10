#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
宿主机渲染服务
------------------------------------------------------------
跑在任何一台开着电脑 / NAS 上，每次 Kindle 来请求时实时渲染一张新图。
Kindle 端只需要一句：curl http://<本机IP>:8810/dash.png

用法：
    python serve.py               # 默认 0.0.0.0:8810
    python serve.py --port 8810
"""

import argparse
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent   # kindle-photo-wall/
PNG = BASE / "render" / "dash.png"
ROTATE = "cw"   # cw = 设备顺时针横放；ccw = 逆时针；方向不对就改这里


def render_now():
    py = sys.executable
    subprocess.run(
        [py, str(BASE / "render" / "render.py"), "--out", str(PNG),
         "--no-battery", "--rotate", ROTATE],
        cwd=str(BASE / "render"), check=True, capture_output=True,
    )


DIAG = BASE / "diag.txt"
UPLOAD_DIR = BASE / "incoming"
UPLOAD_DIR.mkdir(exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        """接收设备回传的诊断文本 / 手机上传的图片。"""
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""

        if self.path.startswith("/diag"):
            DIAG.write_bytes(body)
            print(f"[diag] 收到 {len(body)} 字节 -> {DIAG}")
            self._ok("diag saved\n")
            return

        if self.path.startswith("/upload"):
            from urllib.parse import unquote
            q = self.path.split("?", 1)[1] if "?" in self.path else ""
            name = "upload.png"
            for kv in q.split("&"):
                if kv.startswith("name="):
                    name = unquote(kv[5:]) or name
                elif kv.startswith("b64="):
                    import base64
                    body = base64.b64decode(unquote(kv[5:]))
            safe = "".join(c for c in name if c.isalnum() or c in "._-") or "upload.png"
            (UPLOAD_DIR / safe).write_bytes(body)
            print(f"[upload] {safe} {len(body)} 字节")
            self._ok(f"saved {safe} {len(body)}\n")
            return

        self.send_error(404)

    def _ok(self, text):
        data = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.path.startswith("/dash.png"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write("Kindle 照片墙服务运行中\n".encode("utf-8"))
            return
        try:
            render_now()
            data = PNG.read_bytes()
        except Exception as e:
            self.send_error(500, f"render failed: {e}")
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        print(f"[{self.address_string()}] {fmt % args}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8810)
    a = ap.parse_args()
    print(f"服务已启动: http://0.0.0.0:{a.port}/dash.png  （Ctrl+C 停止）")
    try:
        ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
