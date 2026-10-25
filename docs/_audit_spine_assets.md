# Spine 资产库审计报告（只读）

> 分工定位：本文件是 **task-1 / asset-auditor（资产审计员）** 的证据底稿。四个角色的分工、产出清单与交叉校正记录见主报告 [可行性分析_APP内实时渲染Spine动作.md](可行性分析_APP内实时渲染Spine动作.md) **§十二**。

- 审计对象：`C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine`
- 审计时间：2026-10-25 21:36–22:05（Asia/Shanghai）
- 审计方式：只读遍历（未修改/新增/删除任何资产）；PNG 仅读文件头 IHDR 33 字节取尺寸，不解码整图；`.atlas` 按文本块状格式解析（page 段：`name.png` + `size: W,H` + `format/filter/repeat`；region 段：名字 + `xy/size/orig/offset/rotate`）；`.json` 用 `json.load` 全量解析；重复性用 MD5。
- 证据落点：所有数字来自本次实际统计，脚本与中间结果在 `%TEMP%\spine_audit\`（stage1–stage16 的 `.py` + `.json`，可复跑）。机器可读摘要：同目录 `_audit_spine_assets.json`。

---

## 0. 结论摘要（先看这里）

**能内置吗？能，但"用户以为齐了"的地方有 4 处硬缺口，必须先修复/接受：**

| # | 事实 | 影响 |
|---|---|---|
| 1 | **1666 个 atlas 声明的 3425 个 page，PNG 一个不缺（3425/3425）**，但其中 **670 页（19.6%）的 PNG 实际尺寸与 atlas 声明不符**，regions 坐标超出图片边界 | 直接原样加载会有 337/1666 个 atlas（20.2%）**渲染破损**（贴错图/越界）。可自动修复 642 页，剩 28 页真缺 |
| 2 | **`Pages/` 的 658 张 PNG（411MB）是"孤儿"**：没有任何 `regions.json` 引用它们；它们正好是上述破损页的正确贴图（被同名 page 覆盖丢失） | 只按 basename 对齐会得出"缺 658 张"的错误结论；按 `regions.json.readable` 才能对齐 |
| 3 | **628 个骨架 JSON 里只有 138 个能与图集明确配对**（`bundle.json` 显式绑定）；1666 个 atlas 中仅 **413 个（24.8%）有确定骨架**（Characters 118 + Enemies 295，敌人一套骨架覆盖其全部元素/配色图集） | 不是"全角色齐备"：122 个角色目录中只有 **39 个**有至少一套"骨架+图集+贴图"；50 个敌人目录中 **38 个**有；**武器 0 个有骨架** |
| 4 | **体积怪兽是 `Skeletons_JSON/`：3.83GiB**（628 个 JSON，中位 4.02MB/个），是 Pages 贴图（1.48GiB）的 2.6 倍；纹理进显存后 RGBA8 共 **44.9GB**，单页最大 **64MB**、单套服装显存中位 **26.8MB** | 全量内置不现实；必须"按需 1–2 套 + 侧载"并做降采样/压缩 |

一句话：**"图集/贴图基本齐（99.2% 可修复后可用）、骨架只覆盖约 7% 图集"**。动作侧数据显示：全场 628 骨架中 123 个有 `idle_battle`、攻击类 123 个（lead 扫描口径）、移动类 170 个，但严格"战斗 6 件套"只有 19 个（lead 口径）/9 个（本报告严格口径），具备战斗体的角色只有 11 个角色组。

---

## 1. 目录结构与体积总览

| 目录 | 文件数 | 体积 | 说明 |
|---|---:|---:|---|
| `Pages/` | 3425 | **1517.7 MB** | 去重后的 page 贴图，按 `<分类>/<角色>/<服装label>.png` 命名 |
| `Atlases/` | 8423 | 1381.6 MB | 按 atlas 资产拆包：1666 个包，包含 atlas/atlas.json/regions.json/png 副本 |
| `Bundles/` | 6770 | 2196.8 MB | 原始 bundle 视角：1033 个包目录，含 138 个 `.skel` + 138 个 skeleton JSON |
| `Skeletons_JSON/` | 628 | **3922.1 MB** | 二进制 `.skel` 转换出的 JSON 骨架（扁平、按 sha1 命名） |
| `Renders/` | 274 | 19.6 MB | Frenzy Boar 逐帧渲染样例（266 png + 6 gif + index） |
| `_Stage0_ViewerReady/` | 7 | 3.5 MB | FrenzyBoar101 已验证可播放样例 |
| **合计** | **19527** | **9041.4 MB（8.83 GiB）** | — |

关键结构事实（复现：`stage1`/`stage3`/`stage4`）：

- `Atlases/` 有 **1666** 个 atlas 包（Characters 950 / Enemies 338 / Weapons 373 / Others 5），每个包**恰好 1 个** `atlas.atlas`，共 1666 个。
- 1666 个 atlas 共声明 **3425 个 page**、**203,096 个 region**（Characters 占绝大多数）。page 数分布：2 页 1598 包、4 页 41 包、3 页 17 包、1 页 9 包、5 页 1 包。
- 全部 3425 个 page 声明：`format: RGBA8888`、`filter: Linear,Linear`、`repeat: none`、无 `pma` 行（即**非预乘 alpha**）。与 `_Stage0_ViewerReady/FrenzyBoar101/README.txt` 记录一致。
- **`Pages/` 与 `Atlases/` 的 PNG 是同一份内容**：3425 个 Pages PNG 与对应 atlas 包内 PNG 逐字节相同（MD5 3425/3425 相等，尺寸 3425/3425 相等）。
- **命名陷阱（重要）**：`Pages/` 用"服装 label"（如 `Administrator/Cathedral.png`），atlas 包内用"page 名"（如 `administrator_cathedral.png`）。二者 **basename 直接匹配数为 0/3425**。正确对齐键是 `regions.json` 的 `readable` 字段（`"Spine\\Pages\\Characters\\Administrator\\Cathedral.png"`）。6845 条 readable 记录 **0 缺失**。

---

## 2. Q1 贴图完备性与质量

### 2.1 文件级完备（按 page 名核对）

| 指标 | 数值 |
|---|---:|
| 1666 个 atlas 声明的 page 总数 | **3425** |
| 同包目录内找到同名 PNG 数 | **3425（100%）** |
| 缺失 PNG 数 | **0** |
| 多余 PNG 数（未被任何 page 声明） | **0** |
| region 总数（Atlases 树） | **203,096** |

> 也就是说"文件个数"层面是齐的；**问题在"哪张图配哪一页"**（见 2.3/2.4）。

### 2.2 Pages/ 覆盖（按 regions.json 对齐）

| 指标 | 数值 |
|---|---:|
| Pages PNG 总数 | 3425 |
| 被 regions.json 引用的唯一 Pages 文件 | **2767（80.8%）** |
| 孤儿 Pages 文件（无任何 atlas 引用） | **658（19.2%），410.97 MB，全部在 Characters** |
| regions.json 条目 / 缺失 readable 目标 | 6845 / **0** |

孤儿示例：`Pages/Characters/Administrator/Christmas.png`、`Christmas (Variant 2).png`、`Naked.png`、`Nightwear.png`……（每个角色约 2–6 张）。
`Pages/` 中 3425 张里有 654 张与 `Atlases/` 内的任何 PNG 都不字节相同——它们不是重复文件，而是**被覆盖丢失的独立贴图**。

### 2.3 尺寸核对（声明 size vs PNG IHDR）

| 判定 | 页数 | 占比 |
|---|---:|---:|
| 一致：`声明 ≤ PNG ≤ 声明+4px`（PKM/ETC 解码常见 0–3px 补齐） | **2755** | 80.4% |
| 不一致（小于声明，或大于声明 4px 以上） | **670** | 19.6% |
| 其中：regions 的 `xy+size` 越出 PNG 实际边界 | **660** | 19.3% |
| 其中：宽高两个方向都越界（更严重） | 232 | 6.8% |
| 受影响 atlas 包数 | **337 / 1666** | 20.2% |

尺寸偏差分布 Top（PNG − 声明）：`(0,0):658`、`(+2,0):365`、`(0,+2):296`、`(0,+3):237`、`(0,+1):181`……即绝大多数"不一致"只是 0–3px 补齐；**真正错配的是 670 页**。

**错配示例（5 个，全部为 Characters，均为"两变体共用 page 文件名"导致）**：

| atlas 包 | page | 声明尺寸 | 实际 PNG | 正确贴图（Pages/） |
|---|---|---|---|---|
| `Administrator/Christmas Face [dcc17496]` | administrator_christmas.png | 4096×2310 | 3712×2312 | `Christmas.png`（4096×2312） |
| 同上 | administrator_christmas2.png | 4096×204 | 928×520 | `Christmas (Variant 2).png`（4096×204） |
| `Administrator/Naked Face [cce16da0]` | administrator_naked.png | 4096×1928 | 4064×3444 | `Naked.png`（4096×1928） |
| `Administrator/Nightwear Face [4933fa2c]` | administrator_nightwear.png | 4096×1368 | 1992×1536 | `Nightwear.png`（4096×1368） |
| `Agil/Alo Face [517b4a96]` | agil_alo.png | 4096×2674 | 1896×2056 | `Alo.png`（4096×2676） |

**根因（已定位）**：一个 bundle 里常含 **2 个 atlas 变体**（同一 label，不同 hash，page 文件名相同但布局不同，例：`Christmas Face` 包里 `36fcbc4d` 与 `dcc17496` 各声明 2 页，共 4 个 page 槽，但目录里只有 2 个同名 PNG）。抽取脚本按**文件名**拷页 → 后写覆盖先写，另一变体的贴图被赶到 `Pages/` 并以 `(Variant N)` 命名，包目录里则留下错图。

### 2.4 可修复性（好消息）

| 修复规则 | 页数 |
|---|---:|
| 规则 A：破损包 label 为 `X Face` → 取 `Pages/<角色>/X.png`（+ `(Variant N)` 对应页序） | **640** |
| 规则 B：同角色目录内"孤儿 Pages 文件尺寸唯一命中声明尺寸" | 2 |
| 合计可自动修复 | **642 / 670（95.8%）** |
| 无法修复（尺寸在 Pages 里也找不到匹配） | **28**（多为小尺寸第 2 页，如 `dampa2.png` 声明 4096×206 实为 376×220） |

修复后可用 page = **3397 / 3425 = 99.2%**；剩余 28 页集中在第 2 页（条状小页），可接受（多为 mask/描边页）。
> 结论：**贴图层"可修复到基本齐"，但"开箱即用"只有 80.4%。**

### 2.5 抽样目视与像素级质量（25 张统计 + 5 张目视）

- 抽样 25 张（Characters 10 / Enemies 8 / Weapons 5 / Effects 2）：**25/25 均为真实有效贴图**——全部 RGBA 有 alpha、alpha 最大 255、无全透明图、64×64 缩略色彩数 214–1999、非透明像素包围盒平均占页面 **81%**（最小 34.6%）。
- 5 张目视确认（`read_image`）：
  1. `Pages/Characters/Asuna/Ggo Face.png`（4048×1832）：**脸部件图集**（多套眼睛/嘴/发型/脸型），透明背景，真实美术部件 ✅
  2. `Pages/Characters/Npc/Sadore.png`（4096×1092）：**角色服装身体部件**（上衣/围裙/腿/靴/手），真实部件 ✅
  3. `Pages/Enemies/530 Dragon/530201 Normal2.png`（1404×468）：**敌人第 2 页遮罩/描边图**（白形黑底，属于 atlas 第 2 页的 mask/发光页），非占位 ✅
  4. `Pages/Weapons/Sword/Sword R4 None Leafa Os 3d2.png`（432×4096）：**武器发光/遮罩第 2 页**（白色渐变形状），非占位 ✅
  5. `Pages/Effects/S0003 Effect Phenix/S0003 Effect Phenix.png`（4096×2048）：**凤凰火焰特效图**，真实彩色美术 ✅
- 占位图扫描（全 3425 张，字节/像素 bpp）：中位 **0.139 bpp**；156 张 <0.05 bpp、24 张 <0.02 bpp——最小值是 `Weapons/Sword/Sword R1 None Invisible.png`（16×4096，363 字节），这是**游戏刻意保留的"隐形武器"空贴图**，属正常设计，不是抽取损坏。Pages 层未发现整图空白占位。

---

## 3. Q2 骨架 ↔ 图集 ↔ 贴图 配对

### 3.1 显式配对（可信）

配对依据是 `Bundles/` 下的 `bundle.json`：字段 `skeletons: [<40位sha1>]`、`atlases: [<40位sha1>]`、`label/category/group/pages/pairing`。

- `Bundles/` 共 **1033** 个包目录；其中 **107 个包带骨架**（Characters **69** / Enemies **38**，Weapons **0**），`bundle.json` 共引用 **138 个骨架**。
- 138 个骨架 **全部**能在 `Skeletons_JSON/<sha1>.json` 找到，且有对应 `skeleton_<8位>.skel` 二进制；**0 缺失**。
- 这 138 个骨架覆盖 **413 个 atlas 包**（1666 中的 24.8%；Characters 118 + Enemies 295——敌人 bundle 的一套骨架覆盖该敌人的全部元素/配色图集）、**39 个角色组**（122 中的 32.0%）、**38 个敌人组**（50 中的 76.0%）；按"只算 label 精确对应"的口径则是 118 个包（Characters）。
- 配对标记：`pairing: "skeleton-by-embedded-path"`（69 个，角色）/ `"skeleton-by-numeric-id"`（38 个，敌人）/ `"pages-only"`（926 个，无骨架）。

### 3.2 628 个骨架 JSON 的全貌

| 项 | 数值 |
|---|---:|
| 骨架 JSON 总数 | 628 |
| 有 `skeleton.images` 路径的 | 556（88.5%），其中相对路径 432、Windows 绝对路径 102（`C:/Users/z.rurika.nakashima/saoal/...`、`D:/ALICE_git/...`）、72 个无 images |
| 能被 `bundle.json` 显式归属 | **138（22.0%）** |
| `images` 路径末段 == 某 atlas page 名（可推断配对） | **443（70.5%）** → 覆盖 **236 个 atlas 包**、**68 个角色组 + 37 个敌人组**（中置信，见下） |
| 其余 490 个（多出的 JSON） | 无 `bundle.json` 归属；images 指向开发机/其他资产树路径（`saoal/asset/source/spine/...`、`characterAtlas/chara_1|chara_2/...`、日文工程目录 `素体シート`/`キャラシート`/`シートチェック` 等）。其对应图集**不在本资产库的 1666 个 atlas 内**（低置信：可能属其他解包目录或未抽取的 bundle） |

> **配对可信度说明**：不能靠"region 名字字面覆盖率"判配对。抽样 6 个骨架：其 skin 有 **9–11 个**（`default` + `01_sword`/`02_dualblade`/`03_finesword`… 每武器一个 skin），附件名（196–598 个）跨多张图集，与单一图集的 region 名覆盖率仅 **3%–58%**。因此：
> - **确定配对**：138（bundle.json 显式）；
> - **中高置信推断**：443（images 路径末段 = page 名，如 `./chara_2/administrator_cathedral/` ↔ `administrator_cathedral.png`）；
> - 最终正确性仍需渲染验证（本库已有 `_Stage0_ViewerReady/FrenzyBoar101` 用官方 spine-ts 3.6 渲染通过的先例）。

### 3.3 完整三元组（骨架+图集+可用贴图）能拼多少

| 口径 | 数量 |
|---|---:|
| 有确定骨架的 atlas 包（bundle 级覆盖） | **413**（Characters 118 + Enemies 295） |
| 其中贴图"开箱一致"的包 | **361** |
| 其中贴图破损但可修复的包 | 46 |
| 修复后仍不可用的包（28 页真缺） | **6** |
| 修复后可用（骨架+图集+贴图） | **407 / 413** |
| 服装套数 | **107 套**（Characters 69 / Enemies 38） |
| 涉及角色 | **39 / 122 个角色目录**；敌人 **38 / 50** |
| 完全无骨架的图集 | **1253 / 1666（75.2%）** |

---

## 4. Q3 体积预算

### 4.1 Pages/ 分布（3425 页 / 1517.7 MB）

| 分类 | 页数 | MB | 页均 MB | 最大页 |
|---|---:|---:|---:|---|
| Characters | 1980 | 966.48 | 0.488 | `Subtilizer/Death Angel.png` 6.074MB（4096×2808） |
| Enemies | 695 | 443.85 | 0.639 | `516 Fire Demon/516100 Water.png` 5.51MB（3964×3324） |
| Weapons | 745 | 104.94 | 0.141 | `Bow R4 Light Sinon Solus Enhance.png` 0.93MB（1568×4096） |
| Effects | 5 | 2.43 | 0.486 | `S0003 Effect Phenix.png` 2.376MB（4096×2048） |

纹理分辨率：1016 种不同尺寸；最大边 4096（无 >4096）；`4096×N` 竖/横条页大量存在（Top：84×4096 共 304 页、648×4096 共 234 页、4096×204 共 154 页）。**全库像素总量 11.78 Gpx**。

### 4.2 单套服装体积（Bundles/Characters/*/*，排除 *.json）

| 指标 | 数值 |
|---|---:|
| 套数 | **614** |
| 中位数 | **0.943 MB** |
| P90 | **2.167 MB** |
| 最大 | **13.236 MB**（Asuna / `After Mc`） |
| 合计 | 740.9 MB |

单角色（122 个角色、全部服装合计，非 json）：中位 **2.26MB**、P90 **15.17MB**、最大 **64.09MB**（Asuna）。
备查：按 `Atlases/` 包（png+atlas）算 Characters 950 包：中位 0.811MB / P90 1.55MB / 最大 3.33MB。

### 4.3 骨架体积

| 项 | 数值 |
|---|---:|
| `Skeletons_JSON` 628 个 | **3922.1 MB（3.83 GiB）**；中位 **4.02MB**、P90 **15.56MB**、最大 41.63MB |
| 二进制 `.skel`（Bundles 138 + 样例 1） | 139 个，**209.26 MB**；中位 0.934MB、最大 10.12MB |
| JSON gzip 压缩比（抽 5 个实测） | **≈0.10**（3.83GiB → 约 390MB） |

> 结论：**骨架 JSON 是最大单项**，直接内置会撑爆 APK；要么用 `.skel` 二进制（只有 138 个），要么在打包期把 JSON 转二进制/压缩。

### 4.4 Bundles/ 分布（1033 个包 / 2196.8 MB，含与 Atlases 重复的 png/atlas）

| 分类 | 文件数 | MB | 构成 |
|---|---:|---:|---|
| Characters | 3662 | 1425.4 | png 1322 / atlas 950 / json 1309 / skel 81 |
| Enemies | 1252 | 663.0 | png 696 / atlas 338 / json 159 / skel 57 |
| Weapons | 1856 | 108.4 | atlas 373 / png 745 / json 738 / skel 0 |

### 4.5 三档预算数字

| 档 | 数字 | 估算方法 |
|---|---:|---|
| **内置 1 套角色服装** | **约 1–2.5 MB**（中位 0.94MB 贴图+atlas；加 1 个骨架二进制中位 0.93MB ≈ **1.9MB**；P90 ≈ 3.2MB） | 实测 614 套非 json 体积分位 + skel 中位 |
| **内置 20 套服装** | **≈18.9 MB**（中位口径）；20 个角色（每人全部服装）≈**45.3 MB** | 614 套中位 0.943×20；122 角色中位 2.26×20 |
| **内置全部 122 角色（全部服装）** | 贴图+atlas **≈741–793 MB**；若每套配 1 个骨架（中位 0.93MB×950 套）再 +≈884MB → **≈1.6–1.7 GB**；若仍用 JSON 骨架则 **+3.83GiB** | 实测分类汇总 + 分位估算 |
| **WebP q80 压缩后** | 实测压缩比：**中位 0.261×**、总量 **0.247×**（25 页实测，PIL 编码）→ Pages 1517.7MB → **≈375MB**；Characters 966.5MB → **≈239MB** | 25 张实编 WebP q80/q90（q90 中位 0.343×） |
| **ETC2/ASTC（GPU 压缩格式）** | ETC2 RGBA8 = 8bpp → **11.2 GB**；ASTC 6×6 → **5.0 GB**；ASTC 8×8 → **2.8 GB**；PVRTC4 → 5.6GB | 11.78Gpx × 位宽推算（**注意：对这些大量透明的页，ETC2 比 PNG 存储大 7 倍**） |
| **显存（RGBA8，未压缩）** | 全 Pages **44.9 GB**（含 mipmap +33% → 59.9GB）；单页中位 **6.31MB**、P90 35.9MB、最大 **64MB**（4096×4096×4）；单套服装中位 **26.8MB**、P90 46.6MB、最大 93.2MB；Characters 全量 24.9GB | IHDR 尺寸×4B 计算 |

**预算建议（资产侧）**：内置演示只放 1–2 套（<5MB）；其余侧载；进 GPU 前按 0.5–0.75 降采样并可复测（4096 页 → 2048 页显存降为 1/4）。ETC2 只适合"必须 GPU 压缩纹理"的场景，且应配合裁剪透明边（否则体积反升）。

---

## 5. Q4 动作覆盖

### 5.1 动作命名空间（important：不是简单的 idle/attack/run）

- 战斗动作多为**武器前缀**：`common_*`、`sword_*`、`finesword_*`、`dagger_*`、`dualblade_*`、`gun_*`、`knuckle_*`、`mace_*`、`shield_*`、`bow_*`、`thsword_*`、`whip_*`（例：`sword_idle_battle_front`、`common_damage_back`、`knuckle_victory`、`*_dash`）。
- **技能动画在独立骨架里**：383/628 个骨架**只有** `skill_*_cutNN`（如 `skill_lightning_strike_administrator_naked_cut01…08`），战斗体骨架（idle/attack/damage）与技能骨架是不同资产。
- **移动**：战斗侧只有 `*_dash`/`*_ready`/`*_encount`；**场地/剧情移动是 `fadv_run_front|back|side`、`fadv_walk_side`**（fadv = Field ADV），纯 `run`/`walk` 全库仅 2 个（`run_side`、`_test_side_run`）。
- **胜利**：`*_victory` / `*_victory_02` / `*_victory_loop`（武器前缀），另有 `common_victory`。
- 剧情/表情：`fadv_*`（70 种：`fadv_idle_*`、`fadv_run_*`、`fadv_01_fun_*`…`fadv_11_boast_*`、`fadv_sitdown/standup/pray`）。

### 5.2 覆盖数字

**本报告全量统计（628 个骨架，按"去武器前缀后"的归一化分类）**：

| 动作类 | 有该类动作的骨架数 | 占 628 |
|---|---:|---:|
| `idle_battle*`（含 idle） | 123 | 19.6% |
| `attack*` | 119 | 18.9% |
| `damage*` | 119 | 18.9% |
| `victory*` | 47 | 7.5% |
| `dash*` | 55 | 8.8% |
| `skill*`（任意） | 405 | 64.5% |
| `skill*_cutNN`（技能分镜） | 394 | 62.7% |
| `fadv_*`（剧情/表情） | 101 | 16.1% |
| `fadv_run/walk_*`（场地移动） | 94 | 15.0% |
| `00_idle`/`fadv_idle_*`（ADV 待机） | 195 | 31.0% |

**lead 的独立全量扫描（`docs/_scan_skeletons.json`，引用）：**有 `attack` 骨架 **123**、`move` 骨架 **170**、`idle_battle` **123**、`skill` **455**、**完整战斗 6 件套 19**；动作实例计数：skill 4647、attack 802、damage 603、move 1218、idle_battle 1233、idle 1641、fadv 3541、guard 215、victory 390。

**组合口径（本报告，628 骨架）**：

| 组合 | 骨架数 |
|---|---:|
| idle+attack+damage（"有战斗体"） | **110**（其中 54 有 bundle 归属） |
| +victory | **45**（bundle 内 9） |
| +dash | **45**（bundle 内 9） |
| 严格 6 件套 idle+attack+damage+victory+dash+skill | **9**（bundle 内 4） |
| 只有 skill、无战斗体 | 383（61.0%） |
| 无任何可识别动作标签 | 112（17.8%） |

**角色/包级（用 bundle 归属 + 图集页可用性联合）**：

- 有确定骨架的 413 个 atlas 包中：**8 个包**的骨架含"严格 6 件套"，其中 **7 个包贴图可用**（Dil/Default Face、Kirito/Tales Face、Leafa/Tales Face、Mob/Assassin Fa Hood Boss Face 等）。
- 有"战斗体（idle+attack+damage）"的 **角色组 11 个 + 敌人组 32 个**（共 43 组）；严格 6 件套角色组 **4 个**（Dil、Kirito、Leafa、Mob），敌人 0。
- 与 lead 的 19 差异来自口径：lead 按"任意 attack+move+idle_battle+skill 组合"计 19；本报告严格要求"同一骨架内 idle_battle+attack+damage+victory+dash+skill"故为 9。**两口径都不改变结论：完整战斗动作的可播放角色只有个位数～十几个，不是全角色。**

---

## 6. Q5 骨架 JSON 格式与附件类型

| 项 | 结论 | 证据 |
|---|---|---|
| Spine 版本 | **628/628 全部 `"skeleton.spine" = "3.6.53"`** | 全量解析 `stage11`/`stage13` |
| 是否有 `version` 字段 | **无**（628/628 无 `skeleton.version`） | 同上 |
| 顶层结构 | 628/628 完全一致：`skeleton, bones, slots, ik, transform, path, animations, skins, events` | `stage11.top_keys` |
| `skeleton.hash` | 存在（base64，如 `l4/N/VRUZv7gSWjDkJynTUOcYuQ`），与文件名 sha1 不同 | 抽样 |
| 附件类型总分布（全 628 骨架） | **mesh 314,464 / linkedmesh 110,407 / region 16,297 / clipping 433 / path 1,400**；bbox=0、point=0、weightedmesh=0 | 引用 lead `_scan_skeletons.json`；本报告独立全量解析**数值完全一致** |
| 含 clipping 的骨架 | **432 / 628 = 68.8%**（与 README 的"约 69%"吻合） | `stage5` |
| mesh / linkedmesh | 628/628 含 mesh；606/628 含 linkedmesh | `stage5` |
| **权重网格** | JSON 中 **0 个 `"weights"` 键、0 个 weightedmesh** → 全部为**刚性网格**（靠骨骼变换 + deform，无顶点权重） | `stage11` 原始字节计数 |
| 规模 | 骨骼中位 **189**、P90 259；附件中位 **876**、P90 1021；动画中位 **11**、最多 136 | `stage5` |
| `3.6.53 定制后缀 D/E` | 磁盘 `.skel` 头是 `3.6.53 (custom suffix D/E)`（见 `_Stage0_ViewerReady/FrenzyBoar101/FrenzyBoar101.info.json`），而 JSON 头只写 `3.6.53`。骨架/附件布局与官方 3.6.53 一致，但**二进制解析必须走厂商定制分支**（用户已有 `_analysis/spine_skel_to_json.py` 转换先例） | info.json + README |
| 附件的可渲染性影响 | 68.8% 骨架含 clipping → 需要 runtime 支持 `clipping` 附件（Spine 3.6 已支持；若选 4.x runtime 需确认兼容）；100% 含 mesh → 需要 mesh 渲染；无权重网格 → 实现难度降低（不需要 full weighted-mesh 支持） | 上述统计 |

---

## 7. 对"内置到 Flutter 实时渲染"的资产侧结论

1. **可行，但只建议以"样例角色"内置**：单套 1–2.5MB 存储、25MB 级显存；全量 122 角色 ≈0.8–1.7GB 且显存 45GB，不可能打进 APK。
2. **必须先做一次贴图重配**：按 2.4 的规则把 658 张孤儿 Pages 贴图补回 642 个错配 page（可用脚本自动完成），否则 20.2% 的 atlas 会花屏/错位。
3. **骨架是瓶颈**：1666 个 atlas 只有 413 个（24.8%）在 bundle 级有骨架（角色仅 118 个包 / 39 个角色组）；若要"全角色"，还缺 490 个孤立骨架的图集（不在本资产库）或 1253 个 atlas 的骨架（缺）。**"全角色骨骼+动作+贴图齐备"这个前提不成立**。
4. **动作侧**：idle/attack/damage 覆盖尚可（123/119/119 骨架），victory/dash 少（47/55），技能靠独立骨架（405 个）；严格 6 件套个位数。做 Demo 建议选 `FrenzyBoar101`（已验证）+ 一个角色完整服装包（如 Dil/Kirito/Leafa 的 Tales Face）。

---

## 8. 证据、复现与未验证项

### 8.1 关键证据路径（供抽查）

- 样例（已验证可播放）：`_Stage0_ViewerReady/FrenzyBoar101/`（含 `README.txt`、`.info.json`、`.skel`、`.json`、`.atlas`、2 张 page）
- 破损页实例：`Atlases/Characters/Administrator/Christmas Face [dcc17496]/atlas.atlas`（声明 4096×2310） vs 同目录 `administrator_christmas.png`（3712×2312）
- 孤儿贴图实例：`Pages/Characters/Administrator/Christmas.png`（4096×2312，无任何 regions.json 引用）
- 配对实例：`Bundles/Characters/Administrator/Cathedral/bundle.json`（`skeletons:["5bc780f3…"]`, `pairing:"skeleton-by-embedded-path"`）
- 图集↔Pages 映射：任意 `Atlases/**/regions.json` 的 `readable` 字段
- 骨架路径来源：`Skeletons_JSON/0495dde0….json` → `"images":"D:/ALICE_git/saoal/asset/source/spine/characterAtlas/chara_1/subtilizer_burn_enemy/"`

### 8.2 复现脚本（在 `%TEMP%\spine_audit\`，只读）

| 脚本 | 作用 |
|---|---|
| `stage1.py` | 目录清单、PNG IHDR、atlas 解析、体积 |
| `stage2/3.py` | 逐包 page↔PNG、region 越界、树间比对 |
| `stage4/6/7/8.py` | regions.json 映射、孤儿贴图、错配修复匹配 |
| `stage5/11/13.py` | 628 骨架全量解析（动画、附件类型、images 配对） |
| `stage9/16.py` | 25 张像素级抽样、bpp 扫描、WebP 实测、显存估算 |
| `stage10/12/14/15.py` | 动作分类、体积分位、配对归组 |

### 8.3 未验证 / 低置信项（如实标注）

| 项 | 状态 |
|---|---|
| 443 个"images 路径 ↔ atlas page 名"配对是否 100% 正确 | **中置信**：命名规则强，但抽样附件名覆盖率仅 3%–58%（多 skin 跨图集），最终需渲染验证 |
| 490 个无 bundle 归属骨架的来源 | **低置信**：images 指向开发机/其他工程目录，判断其图集不在本资产库，但未在其他解包目录查证 |
| 28 个不可修复 page 是否为"真缺失" | **低置信**：Pages 中也无尺寸匹配文件，可能是该变体从未导出；未做像素级对比 |
| region 越界是否一定导致可见花屏 | **未渲染验证**：坐标越界是事实，实际视觉影响取决于 UV 采样（部分仅边缘 1–2px） |
| Renders/ 的 266 帧是否与当前 skel 一致 | 未逐帧比对（仅确认存在 gif/png/index） |
| 图片是否"官方美术"版权 | 资产侧不做版权判断（见另一任务） |

---

## 9. 一页速查（给用户/lead）

| 问题 | 答案 |
|---|---|
| 贴图齐不齐？ | **文件齐（3425/3425）**，但 **19.6% 页错配**；修复后 99.2% 可用；658 张孤儿贴图（411MB）是修复关键 |
| 角色齐不齐？ | **不齐**：122 角色中只有 **39 个**有至少一套完整"骨架+图集+贴图"；50 敌人中 38 个；武器 0 个有骨架 |
| 动作齐不齐？ | idle/attack/damage 约 120 个骨架有；victory 47、dash 55；技能 405 个独立骨架；**严格战斗 6 件套仅 9 个骨架** |
| 体积？ | 单套 **≈0.94MB**（中位，含骨架约 1.9MB）；20 套 **≈18.9MB**；全部角色 **≈0.8–1.7GB**；骨架 JSON **3.83GiB**；WebP 后全 Pages **≈375MB** |
| 格式？ | 全部 Spine **3.6.53**（JSON 头，无 version）；含 clipping 68.8%、mesh 100%、**无权重网格**；二进制头带 `custom suffix D/E` |
| 能不能内置 Flutter？ | **资产侧：可做 1–2 个样例角色**；全量实时渲染需要侧载 + 修复脚本 + 降采样，显存是最大约束（单页最大 64MB，单套中位 26.8MB） |
