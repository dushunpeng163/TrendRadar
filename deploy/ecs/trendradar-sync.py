#!/usr/bin/env python3
"""把 TrendRadar 前端同步到本机 nginx 目录，并维护一份尽可能新的 snapshot.json。

由 cron 每 5 分钟调用一次（见 setup_cn_web.sh）：
  1. git pull 仓库（index.html / assets）
  2. 拉 ntfy 最新消息，与本地 snapshot.json 合并（按消息 id 去重，保留 3 天）
  3. 复制到 WEB_ROOT

消息通道的主题名是私密的，只放在本机 /etc/trendradar/private.env（仅 root 可读，由 setup_cn_private.sh 生成），
不写进这份公开的代码。没有这个文件时沿用旧的公开主题，保证升级前后页面不断数据。

任一步失败只记录日志，不影响已上线的页面。
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

SRC = os.environ.get("TR_SRC", "/opt/trendradar-src")
WEB_ROOT = os.environ.get("TR_WEB_ROOT", "/var/www/trendradar")
PRIVATE_ENV = os.environ.get("TR_PRIVATE_ENV", "/etc/trendradar/private.env")
LEGACY_TOPIC = "trendradar-mac-511"   # 旧的公开主题；配置了私密主题后不再读取


def _private(key: str) -> str:
    """读 PRIVATE_ENV 里的 KEY=VALUE；文件不存在或没有这个键返回空串。"""
    try:
        with open(PRIVATE_ENV, encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and k.strip() == key:
                    return v.strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


TOPIC = os.environ.get("TR_NTFY_TOPIC") or _private("TR_NTFY_TOPIC") or LEGACY_TOPIC
NTFY_BASE = (os.environ.get("TR_NTFY_BASE") or _private("TR_NTFY_BASE") or "https://ntfy.sh").rstrip("/")
KEEP_DAYS = 3


def log(msg: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def git_pull() -> None:
    try:
        r = subprocess.run(
            ["git", "-C", SRC, "pull", "-q", "--ff-only"],
            timeout=180, capture_output=True, text=True,
        )
        if r.returncode != 0:
            log(f"git pull 失败: {r.stderr.strip()[:300]}")
    except subprocess.TimeoutExpired:
        log("git pull 超时（180s），沿用上次代码")


def load_json(path: str) -> list:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:  # noqa: BLE001
        return []


def fetch_ntfy() -> list:
    url = f"{NTFY_BASE}/{TOPIC}/json?poll=1&since=all"
    try:
        raw = urllib.request.urlopen(url, timeout=25).read().decode("utf-8")
    except Exception as exc:  # noqa: BLE001
        log(f"ntfy 不可达，跳过: {exc}")
        return []
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        if m.get("event") == "message":
            out.append({k: m.get(k) for k in ("id", "time", "event", "title", "message")})
    return out


def merge_snapshot() -> int:
    merged = {}
    for src in (
        load_json(os.path.join(SRC, "snapshot.json")),
        load_json(os.path.join(WEB_ROOT, "snapshot.json")),
        fetch_ntfy(),
    ):
        for m in src:
            if m.get("id"):
                merged[m["id"]] = m
    cutoff = time.time() - KEEP_DAYS * 86400
    out = sorted((m for m in merged.values() if (m.get("time") or 0) >= cutoff), key=lambda m: m["time"])
    os.makedirs(WEB_ROOT, exist_ok=True)
    tmp = os.path.join(WEB_ROOT, "snapshot.json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, os.path.join(WEB_ROOT, "snapshot.json"))
    return len(out)


def copy_site() -> None:
    os.makedirs(WEB_ROOT, exist_ok=True)
    index = os.path.join(SRC, "index.html")
    if os.path.exists(index):
        shutil.copy2(index, os.path.join(WEB_ROOT, "index.html"))
    assets_src = os.path.join(SRC, "assets")
    if os.path.isdir(assets_src):
        shutil.copytree(assets_src, os.path.join(WEB_ROOT, "assets"), dirs_exist_ok=True)


def main() -> int:
    git_pull()
    copy_site()
    n = merge_snapshot()
    log(f"同步完成：snapshot {n} 条（主题：{'私密' if TOPIC != LEGACY_TOPIC else '旧的公开主题'}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
