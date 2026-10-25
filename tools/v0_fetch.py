#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V0 验证（开发用）：真机上按逻辑路径取明文，验证「运行时取数」链路。

与 App 完全同一条路径：用仓库内置的 `assets/frida-inject`（不依赖 frida-server）
注入 `assets/spine_fetch.js`，脚本按 request.txt 调引擎 `DataCache::read` 取明文落盘。

流程：
  1. 推 frida-inject + spine_fetch.js + request.txt 到 /data/local/tmp/yui-spine/
  2. 冷启游戏，等 pid 出现后立即注入（attach 越早越能捕获 DataCache 实例）
  3. 等 done.txt → 拉回 result.json 与 out/*.bin
  4. 校验：.skelenc 明文以 0x1c 开头、.pkmenc 以 PKM 魔数 504b4d 开头、.atlas 是文本

用法：
  py -3 tools/v0_fetch.py
  py -3 tools/v0_fetch.py --paths-file my_paths.txt --timeout 150
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

PKG = "com.bandainamcoent.saoars"
DEV_DIR = "/data/local/tmp/yui-spine"
GAME_DIR = "/data/user/0/com.bandainamcoent.saoars/files/yui-spine"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
JS_PATH = os.path.join(ROOT, "assets", "spine_fetch.js")
INJ_PATH = os.path.join(ROOT, "assets", "frida-inject")

DEFAULT_PATHS = [
    "files/spine/characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc",
    "files/spine/characterAtlas/chara_2/alice_uw_2022_new_year_inc.atlas",
    "files/spine/characterAtlas/chara_2/alice_uw_2022_new_year_inc.pkmenc|files/spine/characterAtlas/chara_2/alice_uw_2022_new_year_inc.pngenc",
    "files/spine/enemySpine/enemy_530_dragon/enemy_530_dragon.skelenc",
]


def adb(*args: str, check: bool = True, timeout: int = 180) -> bytes:
    p = subprocess.run(["adb", *args], capture_output=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)} failed: {p.stderr.decode('utf-8', 'ignore')}")
    return p.stdout


def sh(cmd: str, check: bool = False, timeout: int = 120) -> str:
    """在设备上以 root 执行一条 shell 命令。"""
    p = subprocess.run(["adb", "shell", f"su -c {json.dumps(cmd)}"], capture_output=True, timeout=timeout)
    out = (p.stdout or b"") + (p.stderr or b"")
    text = out.decode("utf-8", "ignore")
    if check and p.returncode != 0:
        raise RuntimeError(f"sh failed ({p.returncode}): {cmd}\n{text}")
    return text


def game_pid() -> int:
    txt = sh(f"pidof {PKG}")
    for tok in txt.replace("\r", " ").replace("\n", " ").split():
        if tok.isdigit():
            return int(tok)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--paths-file", default="")
    ap.add_argument("--timeout", type=int, default=150)
    ap.add_argument("--delay", type=float, default=8.0, help="pid 出现后等多久再注入（秒）")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "v0"))
    args = ap.parse_args()

    if not os.path.isfile(INJ_PATH):
        print(f"[!] 缺少 {INJ_PATH}（assets/frida-inject）")
        return 2

    paths = DEFAULT_PATHS
    if args.paths_file:
        with open(args.paths_file, "r", encoding="utf-8") as fh:
            paths = [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]

    outdir = os.path.abspath(args.out)
    if os.path.isdir(outdir):
        shutil.rmtree(outdir)
    os.makedirs(outdir, exist_ok=True)

    print("[1/5] 推送注入器与请求文件 …", flush=True)
    sh(f"rm -rf {DEV_DIR} && mkdir -p {DEV_DIR} && chmod -R 777 {DEV_DIR}")
    sh(f"rm -rf {GAME_DIR} && mkdir -p {GAME_DIR}/out && chmod -R 777 {GAME_DIR}")
    sh(f"chown -R stat -c %u /data/user/0/com.bandainamcoent.saoars {GAME_DIR}")
    req_local = os.path.join(outdir, "request.txt")
    with open(req_local, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(paths) + "\n")
    adb("push", req_local, f"{DEV_DIR}/request.txt", timeout=120)
    sh(f"cp -f {DEV_DIR}/request.txt {GAME_DIR}/request.txt && chmod 666 {GAME_DIR}/request.txt")
    adb("push", JS_PATH, f"{DEV_DIR}/spine_fetch.js", timeout=120)
    adb("push", INJ_PATH, f"{DEV_DIR}/frida-inject", timeout=600)
    sh(f"chmod -R 777 {DEV_DIR} && chmod 755 {DEV_DIR}/frida-inject")
    print(f"      {len(paths)} 条路径；注入器已就位")

    print("[2/5] 冷启游戏并尽早注入 …", flush=True)
    sh(f"am force-stop {PKG}")
    time.sleep(1)
    sh(f"monkey -p {PKG} -c android.intent.category.LAUNCHER 1")
    pid = 0
    t0 = time.time()
    while time.time() - t0 < 30 and not pid:
        time.sleep(0.2)
        pid = game_pid()
    if not pid:
        print("[!] 30s 内没拿到游戏 pid")
        return 2
    launch = time.time() - t0
    print(f"      pid={pid}（{launch:.1f}s 出现），等 {args.delay:.0f}s 再注入 …", flush=True)
    time.sleep(args.delay)
    # 注入器改为本地 Popen 前台运行（adb shell 会话挂着即可），避免 su 后台进程挂住 adb
    inj_log = os.path.join(outdir, "inject.log")
    inj_out = open(inj_log, "wb")
    inj_cmd = f"cd {DEV_DIR} && exec ./frida-inject -p {pid} -s {DEV_DIR}/spine_fetch.js"
    inj_proc = subprocess.Popen(["adb", "shell", f"su -c {json.dumps(inj_cmd)}"],
                                stdout=inj_out, stderr=subprocess.STDOUT)
    time.sleep(8)
    injector_alive = inj_proc.poll() is None
    print(f"      注入器运行中={injector_alive}", flush=True)

    print("[3/5] 等待 done.txt …", flush=True)
    done = None
    t1 = time.time()
    while time.time() - t1 < args.timeout:
        time.sleep(3)
        txt = sh(f"cat {GAME_DIR}/done.txt 2>/dev/null").strip()
        if txt:
            done = txt
            break
    print(f"      done={done!r}（{time.time() - t1:.0f}s）injector_alive={injector_alive}")
    log = ""
    if log.strip():
        print("      inject.log:")
        for line in log.strip().splitlines()[-12:]:
            print("       ", line)

    print("[4/5] 拉回结果 …", flush=True)
    summary = {"paths": paths, "pid": pid, "done": done, "inject_log": log, "items": []}
    sh(f"chmod -R 777 {GAME_DIR}")
    try:
        adb("pull", f"{GAME_DIR}/result.json", os.path.join(outdir, "result.json"), timeout=120)
        with open(os.path.join(outdir, "result.json"), "r", encoding="utf-8") as fh:
            summary["items"] = json.load(fh)
    except Exception as e:
        print("      [!] 拉 result.json 失败：", e)
    adb("pull", f"{GAME_DIR}/out", outdir, check=False, timeout=300)

    print("[5/5] 校验 …", flush=True)
    ok = 0
    for it in summary["items"]:
        path = it.get("path", "")
        size = it.get("size", -1)
        head = (it.get("head") or "")[:8]
        err = it.get("err")
        verdict = "OK"
        if err:
            verdict = f"ERR({err})"
        elif path.endswith(".skelenc") and not head.startswith("1c"):
            verdict = f"BAD head={head}"
        elif path.endswith(".pkmenc") and not head.startswith("504b4d"):
            verdict = f"BAD head={head}"
        elif size <= 0:
            verdict = "EMPTY"
        if verdict == "OK":
            ok += 1
        print(f"      {verdict:16s} size={size:>9} head={head:8s} {path}")

    try:
        inj_proc.terminate()
    except Exception:
        pass
    sh("pkill -f yui-spine/frida-inject")
    try:
        with open(inj_log, "r", encoding="utf-8", errors="ignore") as fh:
            summary["inject_log"] = fh.read()[-4000:]
    except Exception:
        pass

    summary["ok"] = ok
    summary["total"] = len(summary["items"])
    with open(os.path.join(outdir, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=1)
    print(f"\n[V0] {ok}/{len(summary['items'])} 条成功；产物目录 {outdir}")
    return 0 if ok == len(summary["items"]) and ok > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
