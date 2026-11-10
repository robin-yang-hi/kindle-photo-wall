# -*- coding: utf-8 -*-
"""通过 GitHub Git Data API（api.github.com）创建 tree/commit/ref，
绕过被代理拦截的 github.com 主站。输入：git ls-files 的当前文件集。"""
import base64
import json
import subprocess
import sys
import urllib.request

REPO = "robin-yang-hi/kindle-photo-wall"
API = f"https://api.github.com/repos/{REPO}"
# token 路径由命令行传入（Git Bash 的 /tmp 对 Windows Python 不可见，需 cygpath 转换）
TOKEN = open(sys.argv[1], encoding="ascii").read().strip()

MESSAGE = """Kindle 照片墙：电子墨水相框 + 万年历 + 天气 + 翻牌番茄钟（首个开源版本）

- 设备端纯 BusyBox shell 实现（render/paint/pomo/touch/power/ftp/web）
- 电脑端 Pillow 素材预烘焙 + 布局坐标表两端共用
- 翻牌番茄钟：调时确认页（armed）、±5min 调时、逐位翻牌动画
- 无线运维协议（.new 原子部署 + cmd 单槽命令）
- 详细设计文档 DESIGN.md（12 条真机踩坑实录）
- 素材以 assets2.tgz 打包分发（设备端 unpack 命令解包）"""


def api(method, path, payload=None):
    req = urllib.request.Request(f"{API}{path}", method=method)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=data, timeout=120) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:500]
        print(f"API {method} {path} -> HTTP {e.code}: {body}", file=sys.stderr)
        raise


# ---- 空仓库无法用 Git Data API：先用 Contents API 打一个初始提交 ----
seed = base64.b64encode("seed commit\n".encode()).decode()
try:
    r = api("PUT", "/contents/seed.txt", {
        "message": "init", "content": seed, "branch": "main"})
    parent = r["commit"]["sha"]
    print(f"seed commit: {parent}")
except urllib.error.HTTPError as e:
    if e.code == 422:   # 已存在（断点续跑）：取 main 最新提交当 parent
        parent = api("GET", "/commits/main")["sha"]
        print(f"seed exists, parent: {parent}")
    else:
        raise

files = subprocess.check_output(["git", "ls-files"], text=True, encoding="utf-8").splitlines()
print(f"{len(files)} files")

entries = []
for i, path in enumerate(files):
    if path == "seed.txt":
        continue
    raw = open(path, "rb").read()
    try:
        text = raw.decode("utf-8")
        payload = {"content": text, "encoding": "utf-8"}
    except UnicodeDecodeError:
        payload = {"content": base64.b64encode(raw).decode("ascii"), "encoding": "base64"}
    sha = api("POST", "/git/blobs", payload)["sha"]
    entries.append({"path": path, "mode": "100644", "type": "blob", "sha": sha})
    print(f"[{i+1}/{len(files)}] {path} -> {sha[:10]}")

tree = api("POST", "/git/trees", {"tree": entries})
print(f"tree: {tree['sha']}")

commit = api("POST", "/git/commits", {"message": MESSAGE, "tree": tree["sha"], "parents": [parent]})
print(f"commit: {commit['sha']}")

ref = api("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": True})
print(f"ref: {ref['object']['sha']}")
print(f"DONE -> https://github.com/{REPO}/tree/main")
