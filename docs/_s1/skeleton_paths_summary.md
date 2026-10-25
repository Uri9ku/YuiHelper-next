# S1-B：628 个 Spine 骨架逻辑路径反推 — 结果汇总

> 判定标准：`SHA1("66VsXNegycgradYc" + 逻辑路径)` 必须等于骨架的 40 位 asset hash（逐条实跑验证，未命中一律记 `unresolved`，不做猜测写入）。
> 数据来源（只读）：`解包结果\资产库\Spine\Skeletons_JSON\*.json`（628）、`Spine\Bundles\**\bundle.json`、`Spine\Atlases\**\atlas.json`、`_manifests\asset_library.csv`、运行时 hook 日志 `_analysis\hook\*`、`_work\char_anchors.json`。
> 输出：`docs/_s1/skeleton_paths.csv`（628 行，162 exact + 466 unresolved）。

## 1. 命中概况

| 指标 | 数值 |
|---|---|
| 骨架总数 | 628 |
| hash 命中（exact） | **162（25.8%）** |
| 未命中（unresolved） | 466（74.2%） |

命中按 `kind`：

| kind | 命中 | 未命中 | 说明 |
|---|---|---|---|
| `base`（f_/a_ 通用素体） | **27** | 0 | 全部解出 |
| `enemy`（enemySpine） | **50** | 39 | 50 个 enemy_dir 的主骨架全部解出；额外变体未解 |
| `character`（服装 / 技能 cut-in / 交谈骨架） | **85** | 415 | 规律已找到，但 token 词表只覆盖一部分 |
| `other` | 0 | 12 | 无法归类（少量特效/残留骨架） |

按目录树分布（命中）：`characterSpine/f_chara_1..4` 共 88、`realCharacterSpine/a_chara_1..4` 共 24、`enemySpine/<50 个 enemy_dir>` 共 50。**未发现** `CharacterSpine`/`RealCharacterSpine`（首字母大写）真实存在的路径，大写形式只出现在与运行时日志的大小写混淆里。

## 2. 已确认的命名规律（每条都有 hash 实证）

前置：路径一律以 `files/spine/` 开头，不带前导 `/`，不含 `localization/tc` 段；扩展名在 hash 规则中**包含**。

### 2.1 通用素体 base（27 命中，100%）
```
files/spine/characterSpine/<f_chara_N>/<f_chara_N>_v<ver>_<weapon>.skelenc
files/spine/characterSpine/<f_chara_N>/<f_chara_N>_v<ver>.skelenc
files/spine/realCharacterSpine/<a_chara_N>/<a_chara_N>_v<ver>[_<variant>].skelenc
```
- `N ∈ 1..4`，`ver ∈ {0.4, 0.5}`（0.5 为主）。
- `weapon ∈ {sword, dualblade, finesword, dagger, mace, gun, bow, knuckle, whip, thsword, shield}`——正是骨架 skins 里的 `01_sword … 14_thsword`。
- 实例：`f_chara_2/f_chara_2_v0.5_sword.skelenc` → `dd66aa14…`；`f_chara_2_v0.5_dualblade` → `34661731…`；`a_chara_1/a_chara_1_v0.4.skelenc` → `11d33c12…`。
- **f_chara 在 `characterSpine/`，a_chara 在 `realCharacterSpine/`**（二者不通用，这是之前没解出的重要原因）。

### 2.2 敌人 enemy（50 命中 = 50/50 个 enemy_dir）
```
files/spine/enemySpine/<enemy_dir>/<enemy_dir>.skelenc
```
- `<enemy_dir> = enemy_<3位id>_<标签下划线化>`，如 `enemy_530_dragon`、`enemy_306_asterios_the_taurus_king`、`enemy_536_illfang_the_kobold_lord_prg`。**文件名 = 目录名，不是颜色变体名**（颜色变体只用于 atlas 页）。
- 来源：`Bundles/Enemies/<label (id)>/bundle.json` 的 label+id，或 `Atlases/Enemies/<id> <Name> [hash]/` 目录名，两条都能生成同一 dir。
- 50 个 dir 全部命中；其中 13 个是"没有配对 bundle / 标签解析失败"的，用 **所有 enemy_dir × 所有未命中骨架** 交叉跑 hash 找回来的（说明该规律对全部敌人成立）。
- 未命中 39 个 `kind=enemy` 的是**同一 enemy_dir 下的额外变体骨架**（如 Chudelkin 514 有 4 个），文件名不带 dir 名，规律未确定。

### 2.3 服装 outfit（19 命中）
```
files/spine/characterSpine/<set>/<set>_v<ver>_<variant>.skelenc
files/spine/realCharacterSpine/<set>/<set>_v<ver>_<variant>.skelenc
```
- `<variant>` = atlas 页 stem（即 `characterAtlas/chara_N/<variant>.pkmenc` / `faceAtlas` 的 stem），与 `Bundles/Characters/<角色>/<服装>` 的 `group_label` 下划线化一致。
- 实例：`f_chara_2_v0.4_administrator_cathedral.skelenc` → `4cfacbb5…`；`f_chara_2_v0.4_administrator_naked` → `0e6cdeba…`；`f_chara_2_v0.5_dil` → `5efcf326…`；`f_chara_1_v0.4_eldrie_naked_bath` → `261074ad…`；`f_chara_4_v0.4_bercouli_naked_bath` → `b2ff48b5…`；`a_chara_2_v0.4_yuna_white_hood` → `54e7724f…`；`a_chara_3_v0.4_mary_pajamas` → `61aed5e5…`。
- 注意：**同名 variant 会按 chara_set + 版本各存一份**（`administrator_cathedral` 就有 f_chara_2 v0.4 与 v0.5 等），所以必须把 `set × ver × variant` 叉乘。

### 2.4 技能 cut-in（56 命中，本轮最大增量）
```
files/spine/characterSpine/<set>/<set>_v<MAJOR>.<MINOR>.<BUILD>_<skill_anim_prefix>.skelenc
```
- 三段版本号来自骨架**首条动画** `##_v0.5.37` 这种标记；`<skill_anim_prefix>` 来自动画名前缀（`skill_inc_050010_cut01` → `skill_inc_050010`；`skill_dual_cyclone_008004_cut01` → `skill_dual_cyclone_008004`）。
- 实例：`f_chara_2_v0.5.37_skill_inc_050010.skelenc` → `5bc780f3…`（Administrator/Cathedral 那具 cut-in 骨架）；`f_chara_2_v0.4.42_skill_blooming_heart.skelenc` → `f18d9173…`。
- 这是"少动画（6~10 条） + 10 skins + 首条 `##_vA.B.C`"的骨架群的主要命名方式。

### 2.5 数字变体（10 命中）
`<set>_v<ver>_<6位数字>.skelenc`（如 `f_chara_2_v0.5_002031.skelenc` → `16986768…`），数字取自动画名里 `..._front_002031` / `..._enhance_mode_002031_cut01` 的 6 位动作/技能 id。

### 2.6 图集/图集页同一套规则（用于交叉验证，不计入 162）
`files/spine/characterAtlas/chara_2/alice_uw_2022_new_year_inc.atlas` → `00224dba…`，与 atlas.json 的 `pages[0]` 完全一致；这也是推 variant token 的入口。

## 3. 未命中分类（466）

| 类别 | 数量 | 说明 |
|---|---|---|
| `character: ##_v + skill cut-in`（首条 `##_v`，其余全是 `skill_*_cutNN`） | 67 | 命名同样应是 `_vA.B.C_<skill前缀>`，但很多骨架**首条动画里没有 `##_vA.B.C`** 或 set/版本组合不成立于我们枚举的集合（f_chara_1..4 / a_chara_1..4 × 0.4.00–0.5.199 × 4 个目录树，共 ~4.7e7 条候选已排除） |
| `character: 00_idle / #_test 交谈式` | 63 | 展示/交谈用骨架，variant token 不在 atlas 页 stem / bundle label / images / 动画后缀词表内（疑似 master 表 `spine` 里的私有 key） |
| `enemy: images 里没有 enemySpine 目录` | 38 | 同 enemy_dir 的额外变体，已用 50 个 dir × 8 种后缀（`_2/_3/2/3/_normal/_damaged/_boss/_enemy`）× 2 扩展名 = 97 万候选穷举，0 命中 |
| `character: ##_v 完整动画（展示/交谈）` | 15 | 同 2.3/2.4 的词表缺口 |
| `character: 首条动画就是 skill_*`（`skill_inc_cut01`、`common_skill_chant_*`、`##_activelink_*`、`skill_<名>_cut01` 等） | ~215 | 没有 `##_vA.B.C` 版本锚点，命名里的版本段未知；按 0.4.00–0.5.199 全量版本穷举仍未中 |
| `other` | 12 | skins≤3 且无敌人特征，疑为特效/武器残骸骨架（武器/特效骨架大多以 `died` magic 开头，不在本 628 集合内，但仍有个别混入） |

**已明确排除的目录树（负面结论，全部做过 hash 判定）**：
- `files/spine/characterSpine/chara_1..4/<variant>.skelenc`
- `files/spine/characterSpine/<variant>.skelenc`、`<variant>/<variant>.skelenc`
- `files/spine/realCharacterSpine/chara_N/...`（a_chara 只在 `a_chara_N` 目录）
- `files/spine/CharacterSpine|RealCharacterSpine`（大写开头）
- `files/spine/playerCharacterSpine`、`files/spine/spine`、`files/spine/uiSpine`、`files/spine/effectSpine`、`files/spine/other`、`files/spine/areaSpine`、`files/spine/skillSpine`、`files/spine/cutinSpine`、`files/spine/battleSpine`、`files/spine/<根>`
- 文件名后缀尝试过 `_spine/_skeleton/_skel/_face/_body/_cutin/_01/_2/_3/2/3`，扩展名 `.skelenc` 与 `.skel`——均无命中。

**结论：服装/cut-in 骨架确实在 `characterSpine/<f_chara_N>`、`realCharacterSpine/<a_chara_N>` 这两棵树里（已有 85 条 hash 实证），未解的部分不是"路径树没找对"，而是"文件名的 variant/版本 token 不在可离线推导的词表内"。**

## 4. 命名规律总结（可直接写入 App 路径表生成器）

```
逻辑路径 = "files/spine/" + 树 + "/" + 子目录 + "/" + 文件名
树/子目录：
  base/outfit/cut-in(f) : characterSpine/<f_chara_N>/
  base/outfit/cut-in(a) : realCharacterSpine/<a_chara_N>/
  enemy                 : enemySpine/<enemy_dir>/
文件名（<set> = 子目录名）：
  素体       <set>_v<0.4|0.5>[_<weapon>].skelenc
  服装       <set>_v<0.4|0.5>_<atlas页stem>.skelenc
  cut-in     <set>_v<A.B.C>_<skill动画前缀>.skelenc
  数字变体   <set>_v<0.4|0.5>_<6位动作id>.skelenc
  敌人       <enemy_dir>.skelenc
```
由此可**离线推导**：全部素体 + 全部敌人主骨架（约 77 条确定可生成）；服装/cut-in 需要 master 数据里的 variant/skill key 才能补齐。

## 5. 下一步建议（S2）

1. **不要在服务端穷举**：每具骨架候选空间已跑到 ~4.7e7 无增量，继续穷举 ROI 极低。
2. **推荐 pathlog hook 现场捕获**（最高性价比）：进入 `character/公会/剧情/编队` 等展示界面 + 战斗技能演出，用现有 `_analysis/hook/hook_pathlog.js` + `hook_dump_runtime.js` 把 `localization/tc/files/spine/characterSpine/**` 的 openPath 全量落盘（之前`battle3_out.txt`/`battle_dump_out.txt` 已证明能抓到 skelenc 路径），一次跑 3~5 个场景即可覆盖几百条。
3. **master 表 `spine.bin` 才是权威来源**（`files/spine/characterSpine/{}/{}` 模板 + `DomainPCSpineRepository`/`DomainEnemySpineRepository` 都指向它）。但 `master_dec/spine.bin` 是 flatbuffer 且**字符串段整体仍是密文/编码态**（全表仅 1.1k 段 3~8 字节不可读串），需要先破字符串编码（建议对 `spine.bin` 与 `localization.bin` 同一套编码做已知明文攻击，用已解出的 162 条路径做验证）。
4. 未解的 466 条可先用 oracle 现场探测批处理（`hook_oracle_v6.js` 已能按路径开文件并回 `f8` size，可用 size 匹配骨架大小来验证候选，不用解密）。
