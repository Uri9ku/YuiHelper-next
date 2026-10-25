#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""S1：重建 Spine 资源的「游戏内逻辑路径 → 内容 hash」表。

产出 `assets/spine/paths.json`，供 App 通过注入通道调引擎 `DataCache::read(path)`
按需取明文（方案 ①，见 docs/可行性分析_APP内实时渲染Spine动作.md §十四）。

核心事实（已实测验证，见 docs/_s1/README.md）：
    hash = SHA1("66VsXNegycgradYc" + 逻辑路径)
    逻辑路径不带前导 "/"、不带 "localization" 前缀，例如：
        files/spine/characterAtlas/chara_2/alice_uw_2022_new_year_inc.atlas
        files/spine/characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc

有效性校验：候选路径算出的 hash 若存在于离线 mod 的密文资源仓库
（`_extract/**/hashed/<xx>/<hash>`）中，即认为该路径真实存在（不需要解密）。

用法：
    py -3 tools/build_spine_paths.py \
        --unpack "C:/Users/Administrator/Desktop/解包" \
        --out assets/spine/paths.json
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict

KEY = b"66VsXNegycgradYc"
HASH_RE = re.compile(r"^[0-9a-f]{40}$")

# 角色骨架集（游戏里 body/face 图集按 chara_N 分目录）
CHARA_SETS = ["chara_1", "chara_2", "chara_3", "chara_4", "chara_other"]

# 图集目录类型 → 用于拼路径
ATLAS_KINDS = ["characterAtlas", "faceAtlas", "weaponAtlas", "enemySpine", "effectSpine"]


def logical_hash(path: str) -> str:
    return hashlib.sha1(KEY + path.encode("utf-8")).hexdigest()


def walk_hashed(root: str) -> set[str]:
    """收集密文资源仓库里出现过的所有内容 hash（文件名即 hash）。"""
    out: set[str] = set()
    if not os.path.isdir(root):
        return out
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if HASH_RE.match(name):
                out.add(name)
    return out


def parse_atlas(path: str) -> list[dict]:
    """解析 LibGDX .atlas：返回 [{page, w, h, regions}]。"""
    pages: list[dict] = []
    cur = None
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            line = raw.rstrip("\r\n")
            s = line.strip()
            if not s:
                cur = None
                continue
            if s.lower().endswith(".png"):
                cur = {"page": s, "w": 0, "h": 0, "regions": 0}
                pages.append(cur)
                continue
            if cur is None:
                continue
            if s.startswith("size:"):
                try:
                    w, h = s[5:].strip().split(",")
                    cur["w"], cur["h"] = int(w), int(h)
                except ValueError:
                    pass
            elif s.startswith("xy:"):
                cur["regions"] += 1
    return pages


EXTRA_KINDS = ["effectSpine", "others", "uiAtlas", "effect", "common", "weaponSpine", "characterSpine"]
WEAPON_NAMES = ["sword", "dualblade", "finesword", "dagger", "mace", "gun", "bow",
                "knuckle", "shield", "spear", "axe", "staff", "whip", "thsword"]


def page_variant(page: str) -> str:
    """`alice_uw_2022_new_year_inc2.png` → `alice_uw_2022_new_year_inc`。"""
    base = re.sub(r"\.png$", "", page, flags=re.I)
    return re.sub(r"\d+$", "", base)


def atlas_candidates(names, weapon_dirs, enemy_dirs, wide: bool = False) -> list[str]:
    """生成图集逻辑路径候选（wide=True 时做 01..20 × 武器名 的穷举兜底）。"""
    cands: list[str] = []
    exts = ["atlas", "atlasenc"] if not wide else ["atlas", "atlasenc", "atlas.txt", "txt"]
    for name in names:
        for kind in ATLAS_KINDS:
            if kind in ("characterAtlas", "faceAtlas"):
                for cs in CHARA_SETS:
                    for ext in exts:
                        cands.append(f"files/spine/{kind}/{cs}/{name}.{ext}")
            elif kind == "weaponAtlas":
                for wd in weapon_dirs:
                    for ext in exts:
                        cands.append(f"files/spine/weaponAtlas/{wd}/{name}.{ext}")
            elif kind == "enemySpine":
                for ed in enemy_dirs:
                    for ext in exts:
                        cands.append(f"files/spine/enemySpine/{ed}/{name}.{ext}")
            else:
                for ext in exts:
                    cands.append(f"files/spine/{kind}/{name}.{ext}")
        if wide:
            for kind in ("characterAtlas", "faceAtlas"):
                for cs in CHARA_SETS:
                    for ext in exts:
                        cands.append(f"files/spine/{kind}/{cs}/{name}.{ext}")
            for n in range(1, 21):
                for w in WEAPON_NAMES:
                    for ext in exts:
                        cands.append(f"files/spine/weaponAtlas/{n:02d}_{w}/{name}.{ext}")
            for kind in EXTRA_KINDS:
                for ext in exts:
                    cands.append(f"files/spine/{kind}/{name}.{ext}")
            for ext in exts:
                cands.append(f"files/spine/{name}.{ext}")
    seen = set()
    out = []
    for c in cands:
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def load_atlas_rows(asset_root: str) -> list[dict]:
    manifest = os.path.join(asset_root, "_manifests", "spine_atlases.csv")
    with open(manifest, "r", encoding="utf-8-sig") as fh:
        rows = []
        for r in csv.DictReader(fh):
            rows.append({(k or "").lstrip("\ufeff"): v for k, v in r.items()})
        return rows


def load_enemy_dirs(hook_dir: str, lib_root: str) -> list[str]:
    """敌人图集目录名：从 oracle 路径表（paths5/6/7）与资产库目录名收集。"""
    dirs: set[str] = set()
    if os.path.isdir(hook_dir):
        for name in os.listdir(hook_dir):
            if not (name.startswith("paths") and name.endswith("_data.js")):
                continue
            text = open(os.path.join(hook_dir, name), "r", encoding="utf-8", errors="ignore").read()
            dirs.update(re.findall(r"enemySpine/([^/\"']+)/", text))
    enemies = os.path.join(lib_root, "Atlases", "Enemies")
    if os.path.isdir(enemies):
        for group in os.listdir(enemies):
            for label in os.listdir(os.path.join(enemies, group)):
                m = re.match(r"^(enemy_[0-9]+_[A-Za-z0-9_]+)", group)
                if m:
                    dirs.add(m.group(1))
    return sorted(dirs)


def load_weapon_dirs(hook_dir: str, lib_root: str) -> list[str]:
    dirs: set[str] = set()
    p = os.path.join(hook_dir, "paths_data.js")
    if os.path.isfile(p):
        text = open(p, "r", encoding="utf-8", errors="ignore").read()
        dirs.update(re.findall(r"weaponAtlas/([^/\"']+)/", text))
    weapons = os.path.join(lib_root, "Atlases", "Weapons")
    if os.path.isdir(weapons):
        for group in os.listdir(weapons):
            dirs.add(group)
    # 常见武器目录兜底（目录名在游戏里是 01_sword 这类）
    dirs.update(
        [
            "01_sword", "02_dualblade", "03_finesword", "04_dagger", "05_mace",
            "06_gun", "07_bow", "08_knuckle", "09_shield", "10_spear",
            "11_axe", "12_staff", "13_whip", "14_thsword",
        ]
    )
    return sorted(d for d in dirs if re.match(r"^\d\d_", d))


def scan_skeleton_hints(skel_dir: str) -> dict[str, dict]:
    """从骨架 JSON 里抽命名线索：images 变体名、`##_vX.Y[.Z]` 版本、skill 动画前缀。

    技能 cut-in 骨架的命名规律（S1-B 实测）：
        <set>_v<A.B.C>_<skill动画前缀>.skelenc
    其中三段版本来自首条动画 `##_v0.5.37`，skill 前缀来自 `skill_inc_050010_cutNN` 去掉 cut 段。
    """
    hints: dict[str, dict] = {}
    if not os.path.isdir(skel_dir):
        return hints
    for name in os.listdir(skel_dir):
        if not name.endswith(".json"):
            continue
        hh = name[:-5]
        if not HASH_RE.match(hh):
            continue
        try:
            with open(os.path.join(skel_dir, name), "r", encoding="utf-8") as fh:
                j = json.load(fh)
        except Exception:
            continue
        anims = list((j.get("animations") or {}).keys())
        images = (j.get("skeleton") or {}).get("images") or ""
        segs = [x for x in images.replace("\\", "/").split("/") if x]
        variant = segs[-1] if segs else ""
        versions: set[str] = set()
        skills: set[str] = set()
        for a in anims:
            m = re.match(r"##_v(\d+\.\d+(?:\.\d+)?)", a)
            if m:
                versions.add(m.group(1))
            if "skill_" in a:
                t = re.sub(r"_cut\d+.*$", "", a)
                t = re.sub(r"^.*?skill_", "skill_", t)
                if 6 < len(t) < 70:
                    skills.add(t)
        hints[hh] = {"variant": variant, "versions": versions, "skills": skills}
    return hints


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--unpack", default=r"C:\Users\Administrator\Desktop\解包")
    ap.add_argument("--out", default=os.path.join("assets", "spine", "paths.json"))
    ap.add_argument("--skeletons-csv", default=os.path.join("docs", "_s1", "skeleton_paths.csv"))
    args = ap.parse_args()

    unpack = os.path.abspath(args.unpack)
    lib_root = os.path.join(unpack, "解包结果", "资产库", "Spine")
    hook_dir = os.path.join(unpack, "_analysis", "hook")
    hashed_roots = [
        os.path.join(unpack, "_extract", "assetpack", "assets", "hashed"),
        os.path.join(unpack, "_extract", "datadump", "data", "data",
                     "com.bandainamcoent.saoars", "files", "contents", "hashed"),
    ]

    print("[1/6] 扫描密文资源仓库（hash 存在性校验用）…", flush=True)
    known: set[str] = set()
    for root in hashed_roots:
        got = walk_hashed(root)
        print(f"      {root}\n        -> {len(got)} 个 hash")
        known |= got
    print(f"      合计 {len(known)} 个")

    print("[2/6] 读取图集清单…", flush=True)
    rows = load_atlas_rows(os.path.join(unpack, "解包结果", "资产库"))
    print(f"      {len(rows)} 个 atlas")

    enemy_dirs = load_enemy_dirs(hook_dir, lib_root)
    weapon_dirs = load_weapon_dirs(hook_dir, lib_root)
    print(f"      敌人目录 {len(enemy_dirs)} 个；武器目录 {len(weapon_dirs)} 个")

    print("[3/6] 反推图集逻辑路径（候选 hash 命中已知仓库）…", flush=True)
    atlases: dict[str, dict] = {}
    pages_out: dict[str, dict] = {}
    unresolved: list[dict] = []
    stats = Counter()

    for row in rows:
        ahash = row["atlas"]
        rel_dir = row["dir"].replace("\\", "/")
        abs_dir = os.path.join(unpack, "解包结果", "资产库", rel_dir)
        atlas_file = os.path.join(abs_dir, "atlas.atlas")
        if not os.path.isfile(atlas_file):
            stats["atlas_missing_file"] += 1
            continue
        pages = parse_atlas(atlas_file)
        if not pages:
            stats["atlas_no_page"] += 1
            continue
        # 该图集的候选目录/名字
        first = pages[0]["page"]
        names = {page_variant(first), re.sub(r"\.png$", "", first, flags=re.I)}
        for pg in pages[1:]:
            names.add(page_variant(pg["page"]))

        candidates = atlas_candidates(names, weapon_dirs, enemy_dirs)
        hit = next((c for c in candidates if logical_hash(c) == ahash), None)
        if hit is None:
            # 兜底：01..20 × 武器名 穷举 + 额外目录类型（只对未命中的少量图集做）
            wide = atlas_candidates(names, weapon_dirs, enemy_dirs, wide=True)
            hit = next((c for c in wide if logical_hash(c) == ahash), None)
        if hit is None:
            unresolved.append(
                {
                    "atlas": ahash,
                    "label": row.get("label", ""),
                    "category": row.get("category", ""),
                    "group": row.get("group", ""),
                    "page0": first,
                    "tried": len(candidates),
                }
            )
            stats["atlas_unresolved"] += 1
            continue

        stats["atlas_exact"] += 1
        kind = hit.split("/")[2]
        parts = hit.split("/")
        # files/spine/<kind>/<dirKey>/<name>.<ext>
        sub = parts[3] if len(parts) >= 5 else ""
        page_names = []
        for pg in pages:
            name = re.sub(r"\.png$", "", pg["page"], flags=re.I)
            page_path = f"{os.path.dirname(hit)}/{name}.pkmenc"
            if logical_hash(page_path) in known:
                stats["page_verified"] += 1
            else:
                stats["page_unverified"] += 1
            page_names.append(pg["page"])
        atlases[ahash] = {
            "path": hit,
            "kind": kind,
            "dir": sub,
            "category": row.get("category", ""),
            "group": row.get("group", ""),
            "label": row.get("label", ""),
            "pages": page_names,
        }

    print(f"      命中 {stats['atlas_exact']} / {len(rows)}；未命中 {stats['atlas_unresolved']}")

    print("[4/6] 归一页贴图表…", flush=True)
    # 页路径 = 图集目录 + 页名(.png→.pkmenc)，逐页去重后统计
    page_paths: dict[str, str] = {}
    for ahash, info in atlases.items():
        adir = os.path.dirname(info["path"])
        for page in info["pages"]:
            base = re.sub(r"\.png$", "", page, flags=re.I)
            p = f"{adir}/{base}.pkmenc"
            page_paths.setdefault(p, logical_hash(p))
    print(f"      唯一页路径 {len(page_paths)} 条（其中命中仓库 {sum(1 for h in page_paths.values() if h in known)}）")

    print("[5/6] 反推骨架逻辑路径（候选枚举 + hash 集合判定）…", flush=True)
    skeletons: dict[str, dict] = {}
    skel_hashes: list[str] = []
    skel_dir = os.path.join(lib_root, "Skeletons_JSON")
    if os.path.isdir(skel_dir):
        for name in os.listdir(skel_dir):
            if name.endswith(".json") and HASH_RE.match(name[:-5]):
                skel_hashes.append(name[:-5])
    skel_set = set(skel_hashes)
    print(f"      已知骨架 {len(skel_set)} 个")

    # 目录 / 名字池：全部来自已解出的图集变体与已知目录，避免手工猜
    variants = sorted({page_variant(v["pages"][0]) for v in atlases.values() if v["pages"]})
    base_rigs = ["f_chara_1", "f_chara_2", "a_chara_1", "a_chara_2"]
    char_sets = CHARA_SETS
    char_names = sorted({v.split("_")[0] for v in variants if v})
    dirs = list(dict.fromkeys(char_sets + base_rigs + enemy_dirs))
    prefixes = ["characterSpine", "CharacterSpine", "realCharacterSpine", "playerCharacterSpine"]

    cand_paths: set[str] = set()
    # 0) 服装/展示骨架（已由 S1-B 实测确认的规律）：
    #    characterSpine/<rig>/<rig>_v<ver>_<variant>.skelenc
    #    realCharacterSpine/<rig>/<rig>_v<ver>_<variant>.skelenc
    outfit_rigs = ["f_chara_1", "f_chara_2", "f_chara_3", "f_chara_4",
                   "a_chara_1", "a_chara_2", "a_chara_3", "a_chara_4"]
    versions = ["0.1", "0.2", "0.3", "0.4", "0.5", "0.6"]
    for rig in outfit_rigs:
        prefix = "realCharacterSpine" if rig.startswith("a_") else "characterSpine"
        for ver in versions:
            for var in variants:
                cand_paths.add(f"files/spine/{prefix}/{rig}/{rig}_v{ver}_{var}.skelenc")
    # 1) 基础骨架：<rig>_v<ver>_<weapon> / <rig>_v<ver>
    for rig in outfit_rigs:
        prefix = "realCharacterSpine" if rig.startswith("a_") else "characterSpine"
        for ver in versions:
            cand_paths.add(f"files/spine/{prefix}/{rig}/{rig}_v{ver}.skelenc")
            for w in WEAPON_NAMES + ["common"]:
                cand_paths.add(f"files/spine/{prefix}/{rig}/{rig}_v{ver}_{w}.skelenc")
    # 2) 敌人骨架：<enemy_dir>/<enemy_dir>.skelenc
    for ed in enemy_dirs:
        cand_paths.add(f"files/spine/enemySpine/{ed}/{ed}.skelenc")
    # 3) 骨架自身线索驱动的候选（变体名 / 三段版本 + skill 前缀），可复现、不依赖人工表
    hints = scan_skeleton_hints(skel_dir)
    print(f"      扫描骨架 JSON 线索 {len(hints)} 份", flush=True)
    for _h, info in hints.items():
        for ver in info["versions"]:
            suffixes = [s for s in [info["variant"], *info["skills"]] if s]
            for rig in outfit_rigs:
                prefix = "realCharacterSpine" if rig.startswith("a_") else "characterSpine"
                cand_paths.add(f"files/spine/{prefix}/{rig}/{rig}_v{ver}.skelenc")
                for suf in suffixes:
                    cand_paths.add(f"files/spine/{prefix}/{rig}/{rig}_v{ver}_{suf}.skelenc")

    # 4) 兜底：变体名直接作为目录/文件名（少量历史命名）
    for var in variants:
        for pre in prefixes:
            cand_paths.add(f"files/spine/{pre}/{var}.skelenc")
            cand_paths.add(f"files/spine/{pre}/{var}/{var}.skelenc")
        head = var.split("_")[0]
        for cs in char_sets:
            cand_paths.add(f"files/spine/characterSpine/{cs}/{head}/{var}.skelenc")
            cand_paths.add(f"files/spine/characterSpine/{head}/{var}.skelenc")

    weapon_set = set(WEAPON_NAMES + ["common"])
    for p in cand_paths:
        hh = logical_hash(p)
        if hh in skel_set and hh not in skeletons:
            fname = p.rsplit("/", 1)[-1].rsplit(".", 1)[0]  # <rig>_v<ver>[_<suffix>]
            if "/enemySpine/" in p:
                kind = "enemy"
            else:
                m = re.match(r"^[fa]_chara_\d_v[\d.]+(?:_(.+))?$", fname)
                suffix = (m.group(1) if m and m.group(1) else "") if m else ""
                kind = "base" if (m and suffix in weapon_set.union({""})) else "character"
            skeletons[hh] = {"path": p, "kind": kind}

    print(f"      命中骨架路径 {len(skeletons)} / {len(skel_set)}（候选 {len(cand_paths)} 条）")
    missing = skel_set - set(skeletons)
    print(f"      未命中 {len(missing)} 个（多为服装/展示骨架，留待 S2 用 pathlog 现场捕获）")

    # 若 S1-B 队友产出了 CSV，合并其 exact 行（不覆盖已命中项）
    sk_csv = os.path.abspath(args.skeletons_csv)
    if os.path.isfile(sk_csv):
        merged = 0
        with open(sk_csv, "r", encoding="utf-8-sig") as fh:
            for r in csv.DictReader(fh):
                if (r.get("confidence") or "").strip() != "exact":
                    continue
                h = (r.get("hash") or "").strip()
                path = (r.get("logical_path") or "").strip()
                if HASH_RE.match(h) and path and h not in skeletons:
                    skeletons[h] = {
                        "path": path,
                        "kind": (r.get("kind") or "").strip() or "other",
                    }
                    merged += 1
        print(f"      合并 S1-B CSV 追加 {merged} 条")

    print("[6/6] 组装 variants（图集变体 → 骨架/页）…", flush=True)
    variants: dict[str, dict] = {}
    for ahash, info in atlases.items():
        variant = page_variant(info["pages"][0]) if info["pages"] else ""
        if not variant:
            continue
        rec = variants.setdefault(variant, {"atlases": []})
        rec["atlases"].append({"hash": ahash, "kind": info["kind"]})
    # 骨架侧：用变体名（= 文件名去扩展名）把 skeleton 关联到同名 variant
    for h, info in skeletons.items():
        variant = os.path.basename(info["path"]).rsplit(".", 1)[0] if info.get("path") else ""
        if variant:
            variants.setdefault(variant, {"atlases": []}).setdefault("skeletons", []).append(h)

    payload = {
        "schema": 2,
        "gameVersion": "3.7.0",
        "client": "offline-mod (SAOUB-OFLINE)",
        "hashRule": "sha1(utf8('66VsXNegycgradYc' + logicalPath))",
        "pageRule": "pagePath = dirname(atlasPath) + '/' + pageName(no .png) + '.pkmenc'",
        "generatedFrom": "解包结果 / assetpack+datadump hashed stores",
        "stats": {
            "atlases": len(atlases),
            "pagePaths": len(page_paths),
            "pageVerified": sum(1 for h in page_paths.values() if h in known),
            "skeletons": len(skeletons),
            "variants": len(variants),
            "atlasUnresolved": len(unresolved),
            "assetHashes": len(known),
        },
        "atlases": atlases,
        "skeletons": skeletons,
        "variants": variants,
    }

    out_path = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
    size_kb = os.path.getsize(out_path) / 1024
    print(f"\n[OK] 写出 {out_path}  ({size_kb:.0f} KB)")
    print(f"     atlas {len(atlases)} / 页路径 {len(page_paths)} / skeleton {len(skeletons)} / variant {len(variants)}")
    print(f"     页命中 {sum(1 for h in page_paths.values() if h in known)}/{len(page_paths)}")
    if unresolved:
        rep = os.path.join("docs", "_s1", "atlas_unresolved.json")
        os.makedirs(os.path.dirname(os.path.abspath(rep)), exist_ok=True)
        with open(os.path.abspath(rep), "w", encoding="utf-8") as fh:
            json.dump(unresolved, fh, ensure_ascii=False, indent=1)
        print(f"     未命中清单 -> {os.path.abspath(rep)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
