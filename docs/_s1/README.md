# S1 交付：Spine 资源路径表（游戏内逻辑路径 → 内容 hash）

> 目标（见主报告 §14.3 S1）：给 App 一张「按变体取资源」的路径表，使它能在运行时通过注入通道
> 调引擎 `DataCache::read(path)` 按需取明文——即方案 ①「运行时取数」的数据地基。
> 产出：`assets/spine/paths.json`（642 KB） + 本说明 + `tools/build_spine_paths.py`（可复跑）
> 生成时间：2026-10-25｜游戏版本：3.7.0｜客户端：offline mod（SAOUB-OFLINE）

---

## 0. 结论（数字都来自实跑）

| 资产 | 已解出路径 | 覆盖率 | 校验方式 |
|---|---:|---:|---|
| 图集 `.atlas` | **1,661 / 1,666** | **99.7%** | `hash ∈ 密文仓库 53,943 条` |
| 页贴图 `.pkmenc` | **3,420 / 3,425** | **99.85%** | 同上（3,420/3,420 命中） |
| **战斗基础骨架**（`f_chara_*` / `a_chara_*`，战斗/移动动作都在这里） | **28 / 28** | **100%** | path 的 hash **等于**已知骨架 hash |
| **敌人骨架** | **50 / 50** | **100%** | 同上 |
| 角色服装骨架（`<set>_v<ver>_<variant>`） | 85（含技能 cut-in、数字变体） | 部分 | 同上 |
| 技能 cut-in / 交谈 / 展示骨架 | 0 / 461 | 0% | 候选树已大量排除（≈960 万条），需 S2 现场捕获（见 §5） |
| 合计骨架 | **167 / 628** | **26.6%** | — |

**一句话**：**战斗/移动渲染需要的资源已 100% 有路径**（基础骨架 + 敌人骨架 + 角色身体/脸/武器图集与页图）；
剩下的 461 个骨架全是技能 cut-in / 交谈 / 展示类演出动画，文件名 token 依赖 master `spine.bin` 的私有 key，
留给 S2 的 pathlog hook 现场补。

---

## 1. 方法：为什么没有真机也能把路径反推出来

游戏资源是内容寻址的，hash 由逻辑路径决定（已实测验证）：

```
hash = SHA1(utf8("66VsXNegycgradYc" + logicalPath))
logicalPath 不带前导 "/"，不带 "localization/tc/" 前缀
例：files/spine/characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc
    files/spine/characterAtlas/chara_2/alice_uw_2022_new_year_inc.atlas
```

于是 S1 变成**离线可解的问题**：

1. 从离线 mod 的密文资源仓库拿到「存在的 hash 全集」
   （`_extract/assetpack/assets/hashed` 6,494 + `_extract/datadump/.../files/contents/hashed` 47,489 = **53,943 条**）；
2. 按已知命名规律**枚举候选逻辑路径** → 算 hash；
3. **hash 命中即有该路径**（不需要解密、不需要真机）；
4. 对 628 个已知骨架再加一重判定：候选 path 的 hash **恰好等于**某个骨架文件的 hash ⇒ 该骨架路径确定。

> 关键点：**不靠"我觉得路径应该这样"**，而是靠 hash 等值/存在性判定，错一位就 0 命中。
> 已验证的两条硬实例：`f_chara_2_v0.5_sword.skelenc → dd66aa14…`、`characterAtlas/chara_2/alice_uw_2022_new_year_inc.atlas → 00224dba…`。

---

## 2. 实测出来的路径规律（App 侧要按这个拼）

| 类别 | 路径模板 | 次数/命中 |
|---|---|---|
| 角色身体图集 | `files/spine/characterAtlas/chara_{1..4}/{variant}.atlas` | 534 个 |
| 角色脸部图集 | `files/spine/faceAtlas/chara_{1..4}/{variant}.atlas` | 416 个 |
| 武器图集 | `files/spine/weaponAtlas/<真实武器目录>/{name}.atlas` | 373 个 |
| 敌人图集 | `files/spine/enemySpine/{enemy_dir}/{variant}.atlas` | 338 个 |
| 页贴图 | `<图集目录>/{页名去掉 .png}.pkmenc` | **3,420/3,420** |
| 基础骨架 | `files/spine/characterSpine/{f_chara_1\|f_chara_2}/<rig>_v{0.4\|0.5}_{weapon}.skelenc` | 28 条 |
| 敌人骨架 | `files/spine/enemySpine/{enemy_dir}/{enemy_dir}.skelenc`（**文件名 = 目录名**，不是颜色变体名） | 50/50 |
| 角色服装骨架 | `files/spine/characterSpine/{f_chara_N}/<rig>_v<ver>_<variant>.skelenc`（`a_chara_N` 则在 `realCharacterSpine/`）；技能 cut-in 用三段版本 `<rig>_v<A.B.C>_<skill前缀>.skelenc` | 85 |
| 技能 cut-in / 交谈 / 展示骨架 | 未知（见 §5） | 0 |

**两个坑（都已在脚本里处理）**：

1. **武器目录不是顺序编号**：实际是 `01_sword / 02_dualblade / 03_finesword / 04_dagger / 06_gun / 10_shield / 12_knuckle …`
   （例如 knuckle 在 `12_knuckle`、shield 在 `10_shield`）——按 `01..14` 顺序猜会漏 8 个，必须用真实 id。
2. **图集文件名叫 `<variant>`，但库里目录名是"服装 label"**（如 `Alice/Uw 2022 New Year Inc Face [00224dba]`），
   两者不能靠目录名对齐；本工具用 `atlas.atlas` 里的页名反推变体名再 hash 校验。

---

## 3. `paths.json` 结构

```jsonc
{
  "schema": 2,
  "gameVersion": "3.7.0",
  "client": "offline-mod (SAOUB-OFLINE)",
  "hashRule": "sha1(utf8('66VsXNegycgradYc' + logicalPath))",
  "pageRule": "pagePath = dirname(atlasPath) + '/' + pageName(no .png) + '.pkmenc'",
  "stats": { "atlases": 1661, "pagePaths": 3420, "pageVerified": 3420,
             "skeletons": 69, "variants": 1390, "atlasUnresolved": 5 },
  "atlases": {
    "<atlasHash>": {
      "path": "files/spine/characterAtlas/chara_2/alice_uw_2022_new_year_inc.atlas",
      "kind": "characterAtlas",          // characterAtlas | faceAtlas | weaponAtlas | enemySpine
      "dir": "chara_2",                  // 目录键：chara_N / 12_knuckle / enemy_xxx
      "category": "Characters", "group": "Alice", "label": "Uw 2022 New Year Inc Face",
      "pages": ["alice_uw_2022_new_year_inc.png", "...inc2.png"]
    }
  },
  "skeletons": {
    "<skelHash>": { "path": "files/spine/characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc",
                    "kind": "base" }     // base | enemy | character
  },
  "variants": {
    "<variant>": { "atlases": [{ "hash": "...", "kind": "characterAtlas" }],
                   "skeletons": ["<skelHash>"] }
  }
}
```

- 页路径**不单独存**（可用 `pageRule` 现算，省一半体积）；
- `variants` 是给 UI 用的：一个变体 → 它的图集与骨架（同一变体名允许既有身体图集又有脸图集）。

---

## 4. App 侧怎么用（S2 取数时的调用顺序）

```dart
// 伪代码：按游戏内当前状态（pc 行 + 换模型规则）拿到 variant / charaSet
final v = paths.variants['edith_integrator'];
final atlas = paths.atlases[v.atlases.firstWhere((a) => a.kind == 'characterAtlas').hash];
final skel  = paths.skeletons[v.skeletons.first];            // 战斗用 base rig 时改查 kind == 'base'
final pages = atlas.pages.map((p) => '${dirname(atlas.path)}/${p.replaceAll('.png','')}.pkmenc');

// 逐个调引擎 oracle 取明文（S2 实现）
for (final path in [atlas.path, skel.path, ...pages]) {
  final bytes = await oracle.read(path);   // 注入通道，返回已解密+解压明文
}
```

> 战斗场景的权威组合来自游戏行为（实测日志）：**基础骨架 + 角色 characterAtlas/faceAtlas + 武器图集**；
> 因此 UI 取数时应优先用 `kind == 'base'` 的骨架，而不是服装骨架。

---

## 5. 未覆盖项（明确、可追踪）

| 项 | 数量 | 原因 / 下一步 |
|---|---:|---|
| 图集未解 | 5 | 全部是 `Others` 类的特效图集（`s0001_effect_sword` / `s0002_weapon` / `s0003_effect_phenix(±mask)` / `images`）。**它们在仓库里存在**（hash 可查），但路径前缀不在已知树里；非角色渲染必需，可留待 S2 pathlog 观察 |
| 技能 cut-in / 交谈 / 展示骨架 | **461** | 全部 hash 都在密文仓库里（路径真实存在）。已排除 ≈960 万条候选（8 类目录树 `characterSpine/chara_N`、大写 `CharacterSpine`、`playerCharacterSpine/uiSpine/effectSpine/other/根` 等 × 各种后缀 × 两代版本）。**已实证的命名规律**：基础体 `characterSpine/f_chara_N/...`、`a_chara` 在 `realCharacterSpine/a_chara_N/`、服装 `<set>_v<ver>_<atlas页stem>`、技能 cut-in `<set>_v<A.B.C>_<skill前缀>`（三段版本取自首条动画 `##_v0.5.37`）。**剩余 461 条的文件名 token 依赖 master `spine.bin` 私有 key（该表字符串段仍是密文）** → 建议 S2 用 `hook_pathlog.js` 现场记录 `openPath`（battle3_out 已证明能抓到 `skelenc` 路径） |
| 页贴图未解 | 5 | 即上面 5 个特效图集各自的页 |

> 注意：这 531 个骨架**不影响"战斗/移动动作实时渲染"**（战斗链只用基础骨架 + 敌人骨架，已 100% 覆盖），
> 只影响"技能演出/表情"这类展示动画；且它们的 hash 在仓库里，S2 一旦拿到路径即可直接取明文。

---

## 6. 复现

```powershell
# 需要：解包结果/ 与 _extract/ 两个目录（只读）
py -3 tools/build_spine_paths.py
# 可选参数：--unpack "C:/Users/Administrator/Desktop/解包" --out assets/spine/paths.json
#          --skeletons-csv docs/_s1/skeleton_paths.csv   （合并 S1-B 队友结果）
```

输出：

- `assets/spine/paths.json` —— 交付物
- `docs/_s1/atlas_unresolved.json` —— 5 个未解图集清单（含候选数与页名，便于后续补）
- 控制台统计（图集/页/骨架命中数）

---

## 7. 下一步（S2）

1. **注入取数**：把 oracle 从"离线跑批"改成"App 内单路径请求 → 明文落盘/回传"（复用 `hook_oracle_v6.js` 的
   `Interceptor.attach + DataCache::read` 思路；可与现有 `saoub-model-inject` 注入器合并，避免双注入）。
2. **补 461 个技能 cut-in / 交谈 / 展示骨架**：跑 `hook_pathlog.js`，在游戏里依次进主页/角色一览/编队/战斗/放技能演出，
   记录所有 `characterSpine/...skelenc` 的真实路径，回填本表（脚本支持从路径表重算）。
3. **App 内 Dart 版 `.skel → 3.6 JSON`**（或直接用旧版纯 Dart 解析器），与 paths.json 对接。
