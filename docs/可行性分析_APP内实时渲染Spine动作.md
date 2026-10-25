# 可行性分析：把角色骨骼 / 动作 / 贴图内置进 App 做实时渲染

> 分析日期：2026-10-25　｜　性质：**只做可行性与证据核查，没有修改任何代码与游戏资产**
> 输入：`C:\Users\Administrator\Desktop\解包\可行性分析_角色战斗移动动作骨骼复原.md`、`角色动作渲染_可行性分析.md`、
> `解包结果\资产库\Spine\`（Pages / Atlases / Bundles / Skeletons_JSON / Renders / _Stage0_ViewerReady）、
> 目标 App：`C:\Users\Administrator\Desktop\YuiHelper-next`（Flutter / Android / minSdk 24 / 仅 arm64）、
> 旧版 App：`C:\Users\Administrator\Desktop\YuiHelper`（已有 Spine 预览实现）
> 证据等级：**实测**=本次亲自统计/读字节；**源码级**=本机官方运行时源码可查；**推断**=由数据推导未实测。
> 三份并行取证报告：`docs/_audit_spine_assets.md`（资产审计）、`docs/_research_spine_runtime.md`（运行时调研）、`docs/_integration_plan.md`（集成架构/工期）。
> **任务分工、产出清单与交叉校正记录见 §十二。**
> **数据源口径以游戏实时为准：预览 = 游戏当前状态 + 运行时从游戏取的资源；APK 内置/侧载只是兜底，见 §十三。**
> **已定方案 ①（运行时取数）：依据见 §十三，实施计划 / 模块拆分 / 22~33 人日排期见 §十四（含 1~2 天 V0 前置验证）。**

---

## 一、结论（先看这里）

| 目标 | 判定 | 一句话依据 |
|---|---|---|
| **单个角色**实时播放 `idle_battle / attack / damage / victory / dash` | ✅ **可行，高置信** | 骨架解析 628/628 通过；官方 spine-ts 3.6 已在本机跑通逐帧计算 + 带贴图渲染；现成一套可播样例（FrenzyBoar101，1.67 MB） |
| **多角色切换浏览**（列表选角色 → 换装 → 换武器 → 换动作） | ✅ 架构可行，⚠ 数据覆盖需补齐 | 数据机制齐全，但**确定配对**的完整三元组（骨架+图集+贴图）只覆盖 **39/122 个角色组**、38/50 敌人组 |
| **"全角色 × 任意战斗动作"** | ⚠️ **不成立，必须按动作能力过滤 UI** | 动作是分层的：110 个骨架有战斗体（idle+attack+damage）、45 个再加胜利、**严格 6 件套只有 9 个**；383 个骨架只有技能分镜 |
| 复刻**游戏内的完整战斗表现**（刀光、粒子、受击闪白、镜头、UI、音效） | ❌ **不可行** | 属引擎层（shader/相机/粒子/UI），**不在 Spine 数据内**；能还原的只有角色本体 + 图集内的特效 region |
| **全量资产打进 APK** | ❌ **不可行** | 原始合计 ≈ 9.0 GB（其中骨架 JSON 3.83 GB、页图 1.48 GB）；现 APK 才 39.95 MB |
| **内置 1~2 套演示角色** | ✅ 可行（但**只作兜底**） | 单套完整角色 = 贴图+atlas（中位 0.94 MB）+ skel 二进制（中位 0.93 MB）≈ **1.9 MB**（P90 ≈ 3.2 MB） |
| **预览的数据源：状态 + 美术资源从哪来** | ✅ **已定 ①：运行时从游戏取**（§十三 / §十四） | 状态实时读；资源走注入通道调引擎 `DataCache::read` 拿明文（解包期已用它取到 100% 页图与 628 骨架）；**APK 零美术资源**，内置/侧载只作离线兜底；**硬前提：root + 注入 + 游戏前台** |

**一句话**：**能做，但要做三件事才成立**——① 先跑一遍"贴图重配 + 骨架配对"的打包工具链（贴图文件一个不缺，但有 19.6% 的页装上了同名变体的错图，且只有 39/122 个角色组能确定配对）；② 运行时选"官方 3.6 读 JSON"或"复用旧版纯 Dart 解析器"（官方二进制读不了这批厂商魔改格式）；③ **资源优先在运行时从游戏进程里取明文**（§十三），APK 内置与 `/sdcard` 侧载只作兜底。**"实时渲染战斗/移动动作"本身没有技术障碍，障碍全在数据装配、取数链路与包体策略。**

---

## 二、数据核实：用户的"已经拿到全部"到底成立多少（本次实测）

### 2.1 贴图：**文件一个不缺，但 19.6% 的页"装错了图"——这是最需要先修的一条**

| 检查项 | 结果 |
|---|---|
| atlas 声明的页（page）数 | **3,425 个**（1,666 个 atlas，203,096 个 region） |
| 同目录找到同名 PNG | **3,425 / 3,425，缺失 0** |
| 格式 | 全部 `RGBA8888`、`filter: Linear,Linear`、`repeat: none`、**无 pma**（非预乘 alpha） |
| 尺寸一致（`声明 ≤ PNG ≤ 声明+4px`） | **2,755 页（80.4%）** |
| **尺寸不一致 / regions 越出图片边界** | **670 页（19.6%）**，影响 **337 / 1,666 个 atlas（20.2%）** |
| 其中"宽高双向越界"（严重） | 232 页（6.8%） |
| 可自动修复 | **642 / 670（95.8%）** → 修复后可用 **3,397 / 3,425 = 99.2%** |
| 剩下 28 页 | 多是第 2 页的条状小页（mask/描边），可接受 |
| 目视抽检 25 张 | 25/25 真实有效美术（脸部件 / 服装身体 / 敌人遮罩 / 武器发光 / 凤凰特效），全部带 alpha、无空白占位 |

**根因（已定位，可修）**：一个 bundle 里常含 **2 个 atlas 变体**（同一服装 label、不同 hash、**page 文件名相同但布局不同**），抽取脚本按**文件名**拷页 → 后写覆盖先写。结果：包目录里留下的是另一个变体的图（尺寸对不上、regions 越界），而正确的那张被挤到 `Pages/` 下并以 `(Variant 2)` 命名。

**修复方式（打包期一次性，不需要重新解包）**：
- **对齐键必须用 `regions.json` 的 `readable` 字段**（如 `"Spine\\Pages\\Characters\\Administrator\\Cathedral.png"`），**不能用 basename**——`Pages/` 用服装 label 命名（`Cathedral.png`）、atlas 包内用 page 名（`administrator_cathedral.png`），两者 basename 直接匹配 **0 / 3,425**；
- 破损包 label 为 `X Face` → 取 `Pages/<角色>/X.png`（+ `(Variant N)` 对应页序），覆盖 640 页；同角色目录内"孤儿 Pages 文件尺寸唯一命中"再修 2 页；
- `Pages/` 里另有 **658 张"孤儿"PNG（411 MB，全在 Characters）** 没有任何 `regions.json` 引用——它们正好是被覆盖丢失的那批正确贴图，别当垃圾删掉。

> 结论修订：**"贴图缺失"确实已翻篇（文件 100% 齐），但"开箱即用"只有 80.4%**；跑一遍上述重配即可到 99.2%。UV 必须按 **PNG 真实宽高** 计算（差 1~3 px 就整体错位，旧版踩过：`YuiHelper/docs/spine-render/README.md:172-178`）。

### 2.2 骨架：628/628 可解析，但二进制是**厂商魔改格式**，且**大部分骨架的图集不在本库**

| 项 | 数值 |
|---|---|
| `.skel` 数量 / JSON 导出版 | **628**（JSON 合计 **3.83 GB**，中位 4.02 MB、最大 41.63 MB） |
| 版本串 | JSON 写 `3.6.53`；**二进制头实测 `3.6.53D`**（hexdump：`1c <28B hash> 07 "3.6.53D"`） |
| fps / 规模 | fps 恒 30；骨骼中位 189（2~326），插槽中位 ≈96 |
| 附件类型（全库） | **mesh 314,464 / linkedmesh 110,407 / region 16,297 / path 1,400 / clipping 433** |
| 含 clipping 的骨架 | **432 / 628（68.8%）** |
| 网格是否带骨骼权重 | **全刚性、无权重**：随机 8 个骨架共 4,239 个 mesh，`weights` 键 **0** 个、`uvs` 全有（全库同结论）→ 每个顶点只绑一根骨骼，**不需要多骨骼影响混合**（大幅简化自研渲染器、也降低 CPU 蒙皮成本） |
| `skeleton.images` 路径 | **556 / 628（88.5%）** 有；其中 102 个是开发者机器的 Windows 绝对路径，72 个没有 |
| 能被 `bundle.json` 显式归属 | **138（22.0%）** |
| `images` 末段能对上图集 page 名（中高置信推断） | **443（70.5%）** |
| 其余 490 个 | `images` 指向开发机/其他资产树（`saoal/asset/source/spine/...`、日文工程目录等），**对应图集不在本库 1,666 个 atlas 内** |

**关键结论（决定运行时选型）**：
- 官方 3.6 的**二进制枚举只有 `Region,BoundingBox,Mesh,LinkedMesh,Path,Point`（0–5）**，没有 Clipping=6（本机 `D:\spine-runtimes-3.6\spine-ts\core\src\attachments\AttachmentType.ts` 实测）；
- 这批数据是 **"3.6 布局 + 3.8 风格 type 6 clipping" 的厂商魔改导出器**产物 → **任何官方运行时都不能直接读 `.skel`**；
- 但 **3.6 的 JSON 读取器认 `"type":"clipping"` 并带完整 `SkeletonClipping`**（本机 `spine-canvas.js` 实测 21 处 `ClippingAttachment`/`SkeletonClipping`）→ **`.skel → 3.6 JSON` 是"归一到官方格式"的关键一步，工具已存在且 628/628 EOF 对齐**；
- 链路已实证：`Renders/Enemies/Frenzy Boar (101)/` 有 `idle_battle_side`(40 帧)、`attack_1`(61)、`attack_2`(77)、`damage_*`(21) 的 GIF + 逐帧 PNG，**带贴图、动作正确**（本次目视复核：体型/獠牙/红眼/尾巴/突进都正确）。

### 2.3 动作：**"全角色都有战斗动作"不成立，而且"移动"分两种**

动作命名空间不是简单的 `idle/attack/run`：战斗动作带**武器前缀**（`sword_* / dualblade_* / dagger_* / bow_* / thsword_* / mace_* / shield_* / gun_* / whip_* / knuckle_* / finesword_* / common_*`），技能分镜 `skill_*_cutNN` **在独立骨架里**，场地移动是 `fadv_run/walk_*`。

| 动作类 | 有该类动作的骨架数（/628） |
|---|---:|
| `skill*_cutNN`（技能分镜） | **394（62.7%）** |
| `idle_battle*`（含 idle） | 123 |
| `attack*` | 119 |
| `damage*` | 119 |
| `dash*`（战斗内位移） | 55 |
| `victory*` | 47 |
| `fadv_run/walk_*`（场地移动） | 94 |
| `fadv_*`（剧情/表情） | 101 |

组合口径：

| 口径 | 骨架数 |
|---|---:|
| 战斗体：`idle + attack + damage` | **110** |
| 再加 `victory` | **45** |
| 再加 `dash` | **45** |
| **严格 6 件套**（idle+attack+damage+victory+dash+skill） | **9** |
| 只有技能分镜、没有战斗体 | **383（61%）** |
| 无任何可识别动作标签 | 112（17.8%） |

> 补充口径（本次独立扫描，分类更宽）：含 `attack` 123、含 `move`（含 `fadv_run/walk`）170、六类全含 19。
> **重要事实**：**战斗里的"移动"只有 `*_dash / *_backstep / *_ready / *_encount`**；真正的 `run/walk` 是**场地 ADV 动画**（`fadv_run_front/back/side`、`fadv_walk_side`），全库纯 `run/walk` 仅 2 条。所以产品上要区分"战斗位移（dash）"和"场地移动（fadv run/walk）"。

**骨架分三类（解释上面的数字）**：

1. **战斗体骨架**（110 个含 idle+attack+damage）：220~258 骨、60~136 动画、**10 个武器 skin**（`01_sword … 14_thsword`），动画名如 `dualblade_attack_front_cut01/02/03`、`dualblade_dash`、`dualblade_damage_{front,side,back}`、`dualblade_idle_battle_*`、`dualblade_victory`。**→ 战斗/战斗内移动动作本体。**
2. **角色/服装骨架**（如 `kirito_cathedral`：159 骨 / 88 插槽 / 94 动画）：同一套 `sword_*` 战斗动作 + 35 条 `fadv_*`，`images` 指向该服装的图集。**→ 带贴图的可渲染素材。**
3. **展示/技能分镜骨架**（383 个）：只有 `skill_*_cutNN`、`bust_*`、`goto`、`fadv_*`。**→ 只能看技能分镜/表情，不能看战斗动作。**

### 2.4 体积、显存与压缩

| 项 | 实测/计算 |
|---|---|
| `Pages/` | **3,425 页 / 1,517.7 MB**（Characters 1,980 页 966 MB；Enemies 695 页 444 MB；Weapons 745 页 105 MB；Effects 5 页 2.4 MB）；最大页 4096×2808 |
| 硬链接 | `Atlases/`、`Bundles/` 里的 PNG 与 `Pages/` 是**硬链接**（`fsutil hardlink list` 已验证）→ 物理占用就是 1.48 GB，不是三份 |
| 单套服装（`Bundles/Characters/*/*`，不含 JSON） | 614 套，中位 **0.943 MB**、P90 2.167 MB、最大 13.24 MB，合计 740.9 MB |
| 单角色（全部服装合计） | 中位 **2.26 MB**、P90 15.17 MB、最大 64.09 MB（Asuna） |
| `.skel` 二进制 | 138 份合计 209 MB，中位 0.93 MB、最大 10.12 MB；**JSON 是二进制的 ~3.7~20 倍** |
| `Skeletons_JSON` | 3.83 GB（中位 4.02 MB）；**gzip 压缩比 ≈0.10 → 约 390 MB** |
| 全库像素 | **11.78 Gpx** → 显存 RGBA8 合计 **44.9 GB**（含 mipmap 59.9 GB） |
| 单页显存 | 中位 6.31 MB、P90 35.9 MB、最大 **64 MB**（4096×4096） |
| 单套服装显存 | 中位 **26.8 MB**、P90 46.6 MB、最大 93.2 MB |
| WebP q80（实测 25 页） | **0.247×** → Pages 1,518 MB ≈ **375 MB**（q90 约 0.34×） |
| ETC2 / ASTC（GPU 压缩） | ETC2 RGBA8 = 11.2 GB、ASTC 6×6 = 5.0 GB —— **对这些大量透明的页，ETC2 比 PNG 存储还大 7 倍，不划算** |

**结论**：一套可渲染角色 ≈ **1.9 MB（中位）/ 3.2 MB（P90）**；20 套 ≈ 19 MB（同角色多套 ≈ 45 MB）；全量 122 角色（全部服装）+ 骨架 ≈ **1.6~1.7 GB**。**必须按 2048 解码**（`ui.instantiateImageCodec(targetWidth: 2048)` 是解码期降采样，显存直接 ÷4）——低端 minSdk 24 设备上 4096 原图不是"慢"，是**贴图创建失败/OOM**。

---

## 三、运行时选型

### 3.1 现成 Flutter Spine 包为什么都不行

| 包 | 版本 | 能否读这批数据 | 原因 |
|---|---|---|---|
| `spine_flutter` | 4.3.6（官方，FFI/spine-cpp） | ❌ | 官方策略：运行时必须与数据**同 major.minor**，4.x 只吃 4.x |
| `flame_spine` | 0.3.1+6 | ❌ | 只是 `spine_flutter ^4.3` 的 Flame 包装 |
| `spine_core`（jtakakura） | 0.3.5（2022-11，3.8 移植） | ⚠ JSON 路径理论可行 | 3 年停更、Dart 2 约束需迁移、许可 v2.5 禁改 |
| `spine_flutter_dart` | 0.2.0（2022-12） | ⚠ | 同上，且 60fps 未验证 |

→ **不存在"官方支持本批数据"的现成包**，只剩两条真路径：**官方 3.6 JS 运行时 + JSON**（B）或**旧版纯 Dart 二进制解析器 + 补动画运行时**（A）。

### 3.2 三条候选路线

| 维度 | **A 纯 Dart 自研**（旧版继承者） | **B WebView + 官方 spine-ts 3.6** | C 构建期烘焙（WebP/帧序列/GIF） |
|---|---|---|---|
| 可复用资产 | **极高**：旧版 `lib/data/spine/**` 等 11 文件 2,433 行（解析器 300/300 EOF 通过、真机 215 部件渲染成功） | 只复用素材 + `_analysis/spine_skel_to_json.py` | 复用 `_analysis/render/*` |
| 新增依赖 | **0**（保持新版"零第三方依赖"） | 1~2 个 WebView 插件 | 0 |
| 数据路径 | 直读 `.skel`（无 JSON 税） | 必须 `.skel→3.6 JSON`（体积 ×3.7~20） | 离线 |
| 任意动作/换装/换武器 | ✅ | ✅ | ❌ 只能播预烘焙固定镜头 |
| 保真度 | 需自己实现时间轴/曲线/约束/deform/drawOrder/blend/clipping，**有语义风险** | **官方 3.6 运行时，零语义风险** | 官方运行时离线算，正确 |
| 首帧 | 解析几十~几百 ms | WebView 冷启 300~800 ms + JS | <100 ms |
| 内存 | 进程内可控（合批+降采样） | 额外 50~100 MB WebView 进程 | 最小 |
| 60fps 风险 | 中（需按页合批 + 复用 `Float32List`） | 中高（WebGL 碎片化、低端机可能白屏） | 低 |
| 许可 | 低（自研） | 中（Spine Runtimes License：自用风险低，**分发需授权**） | 中 |
| 工期（含资产/UI/测试） | **31~45 人日** | **18~27 人日**（渲染 10~15 + 资产/UI 8~12） | 2~5 人日（缩略图/兜底） |

### 3.3 推荐：**先 B 打通"能看"，再用 A 原生化**

```
第 1~2 周（M0/M1）：B 路线最小闭环
  .skel → 3.6 JSON（工具已有） + spine-ts 3.6（本机 build/spine-canvas.js 241KB / spine-webgl.js 335KB）
  + App 内本地 HttpServer 供素材 + WebView 播放
  → 交付：真机上 1 个角色 × 6 类动作可切、换装、暂停/调速
  → 验收：含 clipping 的骨架无"该裁未裁"穿插；记录 30/60fps；冷启首帧 ≤ 2s

第 3 周起：拿真机数据决策
  ├─ WebView 体验/内存可接受 → 继续 B 做产品级（侧载资产库 + UI + 测试）
  └─ 冷启慢 / 低端掉帧 / 大角色 JSON 太大 → 二期 A 原生化
       （复用旧版 830 行二进制解析器，把"动画时间轴 skip → read"补齐；它已能直读含 type 6 的 .skel）
```

**为什么不一上来就 A**：A 的动画运行时（9 类时间轴 + 曲线 + IK/transform/path 约束 + deform + drawOrder + blend + linkedMesh + clipping）要从零写，语义正确性没有现成对照，15~25 人日风险远高于先花 3~5 人日拿到真机画面。
**为什么不只做 B**：B 的 JSON 体积税让大角色进不来（最大 41.63 MB JSON），而角色主体恰恰是大角色；WebView 与 Flutter UI 融合也是长期债。
**为什么不做 C 主方案**：C 只能"播放"不能"渲染"，无法换装/任意动作组合，全量烘焙同样几 GB。

---

## 四、四个必须解决的工程问题（真正的成本在这里）

### 4.1 贴图重配（**先做，1~2 人日**）
按 `regions.json.readable` 而不是 basename 把 page 对齐到 `Pages/` 的正确变体；输出"修复 642 页 / 剩 28 页不可修"清单。**不做这一步，20% 的图集会贴错图**。

### 4.2 骨架 ↔ 图集 ↔ 贴图配对（**3~5 人日**，决定能上多少角色）

| 层级 | 数量 |
|---|---|
| `bundle.json` **显式配对** | 138 骨架 / 107 套 / 413 个 atlas / **39 个角色组 + 38 个敌人组** |
| `images` 路径末段可推断（中高置信） | 443 骨架 → 236 atlas / 68 角色组 + 37 敌人组 |
| 完全无骨架的图集 | **1,548 / 1,666（92.9%）** |
| 修复贴图后"骨架+图集+贴图"三元组可用 | **118 个 atlas 包 / 107 套服装**，约 30+ 个独立角色名 |

→ 需要一条打包工具链：按 `imagesPath` + 图集页名 + region 覆盖率打分，产出 `variant → {skel, atlas[], pages[], animations[]}` 的 `manifest.json`，并列出"无图集/低置信"清单人工抽检。**这是"能上多少角色"的真正天花板**，也是 A/B 共用资产层。

### 4.3 多图集合成（body + face + weapon，1~2 人日）
游戏里一个角色 = **身体图集 + 脸部图集 + 武器图集**（运行时 `toybox::SpineCharacter` 有 `updateBodyAtlas / updateFaceAtlas` 两个入口）；而 **Spine 3.6 的 `AtlasAttachmentLoader` 一次只绑一个 atlas**。解决方式：合并 atlas（页名唯一化 + region 去重/重命名并同步改骨架引用），或自己写**多图集 attachment loader**（按 region 名跨 atlas 查，改动最小，推荐）。

### 4.4 性能：**60fps 从未被验证过**
单角色可绘制附件 350~900、顶点 1~3 万，且**网格全是刚性顶点（无骨骼权重混合，见 §2.2）**；CPU 蒙皮 Dart AOT <1 ms，**不是瓶颈**；瓶颈是 draw call——朴素"每附件一次 `drawVertices`" = 350~900 次/帧，**必须按图集页合批到 1~3 次/帧**，并复用 `Float32List` 避免 GC 抖动。旧版只验证了"一帧画对"（`device-wireframe.png`：226 骨 / 351 网格 / 215 部件），**没有任何帧率数据**，M1 第一件事就是测这个。

---

## 五、资产组织（兜底方案）：APK 只放演示，其余侧载

> ⚠ **本节是兜底方案**。主线已由 **§十三** 修正为"**运行时从游戏进程实时取明文**（复用 App 已有注入器 + 解包期的 oracle）"，并已在 **§十四 定为唯一主线（方案 ①）**；内置与侧载只在"游戏没开 / 无 root / 注入失败 / 首启演示"时接管。

```
L0 内置（APK）：manifest.json（全量索引 <0.5MB）+ demo 1~2 套
                （现成 FrenzyBoar101 = 1.67MB；1 套主角 ≈ 3~5MB）→ APK 39.95MB → 约 42~46MB
L1 侧载（用户）：/sdcard/YuiHelper/spine/<variant>/{*.skel,*.atlas,*.png,meta.json}（沿用旧版约定，旧用户素材可复用）
                全量 614 套角色服装 ≈ 741MB（+ skel 209MB）；可打 <name>.spinetar.gz 按需解单角色
L2 缓存（私有）：/data/data/com.yuihelper.next/files/spine/，LRU 上限 500MB（可配 200MB~2GB）
```

侧载首选 **root `su cp -a` + `chown -R`**（App 换模型本来就要求 root；旧版已踩过"`cp -a` 把别人属主搬进来导致自己读不了自己文件"的坑）。无 root 退化为 `/sdcard/Android/data/<pkg>/files/spine/`。

---

## 六、集成落点（新版 App 具体改哪里）

| 位置 | 现状 | 要做的事 |
|---|---|---|
| `lib/ui/screens/model_swap_screen.dart:763-860` | 预览卡是 `_BonePainter` **硬编码火柴人**，`:857-859` 自述"示意占位" | 换成真渲染卡，保留设计稿"缺纹理/解析失败/线框"三态 |
| `lib/data/spine/**`（新增） | 无 | 从旧版整体移植（纯 Dart、零 UI 依赖、零第三方依赖）。**新版 README 说的"旧版 Spine 预览不接入"只否掉了 `lib/presentation/**`，没否掉数据层** |
| `lib/ui/spine/spine_animation_page.dart`（新增） | — | 全屏动作预览：动作按类别分组（待机/攻击/受击/胜利/位移/技能分镜/表情）+ 播放/暂停/进度/速度/循环 + 缩放 + fps/内存 HUD |
| `lib/ui/screens/spine_library_screen.dart`（新增） | — | 素材库：已装 N 套 / 占用 / 上限 / 刷新索引 / 清理缓存 / 缺素材引导 |
| `assets/spine/`（新增） | — | L0 演示角色 + `manifest.json` |
| `pubspec.yaml` | 仅 `flutter` | A 路线**不加依赖**；B 路线加 1 个 WebView 插件（会打破"零第三方依赖"纪律） |

旧版可直接复用 2,433 行（11 文件）：`spine_binary.dart`(830)、`skeleton_pose.dart`(176)、`spine_preview.dart`(149)、`spine_asset_library.dart`(175)、`atlas_variant.dart`(46)、`texture_atlas.dart`(233)、`etc2.dart`(219)、`spine_painter.dart`(235)、`spine_preview_card.dart`(264)、`atlas_painter.dart`(71)、`atlas_sprite_view.dart`(35)；配套 `tool/spine_verify.dart` 等可直接变成新工程验收脚本。

---

## 七、工期与里程碑

| 路线 | 首版可演示 | 产品级（含资产层/UI/测试/性能） |
|---|---|---|
| **B（推荐先做）** | **3~5 人日** | **18~27 人日** |
| A（二期原生化） | 8~15 人日 | 31~45 人日 |
| C（缩略图/兜底） | 2~3 人日 | 5~16 人日（全角色批量烘焙） |

> **已定方案 ①（运行时取数，§十四）后的口径**：B 路线里的"资产侧载/打包"被"注入取数模块"替代，总工作量约 **22~33 人日**（其中首版"取数闭环"5~7 天、能看 6~9 天）；APK 不再需要美术资源。详见 §14.3/§14.4。

| 里程碑 | 内容 | 工期 | 验收 |
|---|---|---|---|
| **M0 打通** | 贴图重配 + `.skel→JSON` + spine-ts 3.6 + 播放 + 一套内置素材 | 3~5 天 | 真机 1 角色播放 `idle_battle→attack→dash` 不错位、不黑屏、贴图正确 |
| **M1 能看** | 动作下拉 + 播放控制 + 换皮肤 + 缺素材三态 + 帧率 HUD | +5~8 天 | ≥6 类动作可切；含 clipping 骨架无"该裁未裁"；30fps 起 |
| **M2 能信** | 打包工具链 + manifest + 侧载同步 + LRU + 合批/降采样 | +8~12 天 | 3 套侧载素材可播；单角色显存 ≤ 目标值；无 OOM |
| **M3 能扩** | 全量打包 + 素材库页 + 文档 + 免责声明 | +3~5 天 | 全库清单可用；`flutter analyze`/`flutter test` 全绿 |

---

## 八、风险与边界（必须对用户讲清楚）

| 风险 | 等级 | 处置 |
|---|---|---|
| **"全角色战斗动作"是伪命题**：110 有战斗体、45 有胜利、**9 个严格 6 件套**；383 个只有技能分镜；112 个无可识别动作 | **高（产品文案级）** | UI 按动作能力过滤/分组；文案写"支持有该动作的角色" |
| **确定配对只有 39/122 角色组**（92.9% 图集无骨架） | **高** | 先上线 30~40 个确定可渲染角色；其余靠推断配对（443 个骨架）逐步补，或重新抓取缺的 bundle |
| **19.6% 页装错图**（同名变体覆盖） | 高 | 按 `regions.json.readable` 重配（642/670 可自动修）→ 99.2% |
| 二进制定制格式（3.6 布局 + type 6 clipping + 后缀 D/E） | 高 | 走 JSON 归一（B）或复用旧版直读解析器（A）；**不要迁移 4.x**（需 Spine 编辑器重导出） |
| 4096 页低端机 OOM | 高 | 默认 2048（`targetWidth`）、常驻 ≤3 页、低端降 1536/1024 |
| 60fps 未验证 | 中高 | M1 先测；不达标就 30fps + 合批 + 复用缓冲 |
| JSON 体积税（B 路线，最大 41.63 MB） | 中高 | 按体积筛选角色进 B；裁剪动画后预计 1/3~1/5（未实测） |
| 多图集合成（脸/武器） | 中 | 自写多 atlas loader（1~2 人日） |
| WebView 低端机 WebGL 白屏/上下文丢失 | 中 | 降级 Canvas2D（spine-canvas）或退回 A |
| **许可/版权** | 中 | Spine Runtimes License：个人自用风险低，**分发需集成方与用户各持 Spine 编辑器授权**；游戏美术版权归 Bandai Namco / Wright Flyer，**不要把含资产的分发包公开**。新版 README 无免责声明，建议补（旧版有） |

**明确做不到**：游戏内全屏后期（bloom/热浪）、粒子、伤害数字、UI、音效、镜头推拉、受击闪白 —— 来自引擎层（`posteffect` 贴图 + 自定义 shader + 逻辑层），Spine 数据里没有。

---

## 九、建议的下一步（成本从低到高）

1. **0.5 天**：用现成 `_Stage0_ViewerReady/FrenzyBoar101` 在桌面跑一遍 spine-ts 3.6（`_analysis/render/spine_dump_frames.js` 已在做这件事），确认本机能出画面。
2. **1 天**：跑贴图重配（`regions.json.readable` 对齐），产出"修复 642 页 / 剩 28 页"清单——**这是所有后续工作的前提**。
3. **1~2 天**：挑 3 个确定配对角色（如 `kirito_cathedral` + 1 个敌人）跑 `.skel→JSON` + 多图集合成 + spine-ts 3.6 播放，**量出每帧 draw call 与耗时**。
4. **2~3 天**：把一个角色塞进 App（WebView 或旧版 painter 移植），真机录屏 + 帧率 + 内存。
5. **拿数据后决策**：B 产品化 or A 原生化；同时启动打包工具链（两条路线共用）。
6. **文案先改**：把"全角色战斗动作"改成"按角色/按动作过滤"，避免后面踩空。

---

## 十、对既有报告的四处理修正

| 既有结论 | 修正（本次实测） |
|---|---|
| `可行性分析_角色战斗移动动作骨骼复原.md` §一②"贴图缺失 ≈99.9%" | 该文 §十 已自我修正；本次复核：**文件 3,425/3,425 齐备**，但 **670 页（19.6%）装的是同名变体的错图** → 需要按 `regions.json.readable` 重配（642 页可修 → 99.2%）。"齐"和"对"是两件事。 |
| 同文 §六"69% 骨架含 clipping，官方 3.6 运行时不认 → 需 3.8+/打补丁" | **clipping 是 3.6 引入的特性**；3.8 只是把它加进**二进制**枚举（type 6）。官方 **3.6 的 JSON 读取器原生支持 clipping**（本机 `spine-canvas.js` 实测有 `SkeletonClipping`）→ **不需要 3.8、不需要打补丁**，只需"二进制 → 3.6 JSON"。 |
| `角色动作渲染_可行性分析.md` "角色服装 69/614、敌人 38/50 有骨架" | 复核为 **107/1,033 套带骨架（138 个 skel）**，覆盖 **39/122 角色组、38/50 敌人组**、413/1,666 atlas；另有 443 个骨架可按 `images` 末段推断配对（中高置信）。 |
| 本文初稿"贴图完备率 100%""全角色可渲染" | 已按审计结果修正为 §2.1 / §二 结论：**文件 100%、内容 80.4%、修复后 99.2%**；**确定可渲染角色 39/122**。 |

---

## 十一、证据索引

| 内容 | 位置 |
|---|---|
| 资产审计（贴图完备性/错配根因/体积/动作） | `YuiHelper-next/docs/_audit_spine_assets.md` + `_audit_spine_assets.json` |
| 628 骨架全量动作/附件类型扫描 | `YuiHelper-next/docs/_scan_skeletons.json` |
| 运行时调研（pub 包/版本墙/许可/WebView） | `YuiHelper-next/docs/_research_spine_runtime.md` |
| 集成架构/工期/资产分级/旧版考古 | `YuiHelper-next/docs/_integration_plan.md` |
| 旧版纯 Dart 解析 + 真机渲染 | `YuiHelper/lib/data/spine/**`、`lib/presentation/model_swap/preview/**`、`docs/spine-render/device-*.png` |
| 官方 3.6 运行时（本机） | `D:\spine-runtimes-3.6\spine-ts\build\{spine-core,spine-webgl,spine-canvas}.js` |
| 官方 3.6 JSON 支持 clipping | `spine-ts/core/src/SkeletonJson.ts:345`、`SkeletonClipping.ts`、`build/spine-canvas.js`（21 处） |
| 二进制 `AttachmentType` 无 Clipping(6) | `spine-ts/core/src/attachments/AttachmentType.ts` |
| `.skel→3.6 JSON` 转换器（628/628 EOF） | `解包/_analysis/spine_skel_to_json.py` |
| 带贴图动作渲染已验证 | `资产库/Spine/Renders/Enemies/Frenzy Boar (101)/**`、`_analysis/render/spine_dump_frames.js` |
| Viewer 就绪包（1.67MB 完整一套） | `资产库/Spine/_Stage0_ViewerReady/FrenzyBoar101/` |

---

## 十二、任务分工与产出（本次分析是怎么做完的）

### 12.1 分工与产出

| 角色 | 共享任务 | 职责范围 | 产出文件 | 该角色定下的关键结论 |
|---|---|---|---|---|
| **Lead（主控）** | — | 定范围与判定标准、拆任务、独立复核、合稿；另做 628 骨架全量扫描作为公共数据 | `docs/_scan_skeletons.json`、**本报告** | 628/628 骨架可解析、附件类型分布、动作分层（110 有战斗体 / 45 有胜利 / 9 严格 6 件套）；发起并收敛 4 处结论校正（见 12.3） |
| **asset-auditor**（资产审计员） | `task-1` | 贴图完备性与质量、骨架↔图集↔贴图配对、体积/显存预算、动作覆盖、JSON 格式 | `docs/_audit_spine_assets.md`（341 行）+ `_audit_spine_assets.json` | 页文件 3,425/3,425 齐但 **670 页（19.6%）装错同名变体**（可修 642 → 99.2%）；`Pages` 按 `regions.json.readable` 对齐（basename 匹配 0/3,425）；**确定可渲染 39/122 角色组、38/50 敌人组**；显存 44.9 GB、单页最大 64 MB |
| **runtime-researcher**（运行时调研员） | `task-2` | pub 包与版本墙、官方运行时兼容策略、三条渲染路线、纹理内存、许可证 | `docs/_research_spine_runtime.md` | `spine_flutter` 4.3.6 / `flame_spine` 只吃 4.x，读不了 3.6；**clipping 是 3.6 特性、3.8 才进二进制枚举**；本机 `spine-canvas.js` 已含 `SkeletonClipping`；推荐 B 路线 3~5 天 MVP / 18~27 人日产品级 |
| **app-integrator**（集成架构员） | `task-3` | 旧版 `YuiHelper` 考古、新版 `YuiHelper-next` 现状、集成落点、资产分级、工期、合规 | `docs/_integration_plan.md` | 旧版已有**纯 Dart 自研**解析+蒙皮渲染 **2,433 行 / 11 文件**（300/300 EOF、真机 215 部件），但**只有 bind pose、无动画**；新版 E 页“骨骼线稿”是硬编码火柴人；APK 只放 1~2 套演示（+2~6 MB），其余侧载；B 18~27 人日 / A 31~45 人日 |

### 12.2 协作规则（为了不互相踩）

- **共享任务板**：`task-1/2/3` 各自 `claim → 执行 → complete`，任务描述里写死了验收项，避免“做完了但不是要的”。
- **写权限隔离**：三个执行角色**只读**两个 Flutter 工程与 `资产库/Spine`，写权限只给各自的 `docs/` 文件（`_audit_*` / `_research_*` / `_integration_*`），**文件名互不重叠**；主报告只有 Lead 写。
- **证据纪律**：数字必须来自实际统计或本机源码，查不到就标“未验证/低置信”，禁止拿推测当结论（各报告的“未验证清单”章节即此产物）。
- **公共数据复用**：Lead 的 628 骨架扫描（`_scan_skeletons.json`）作为公共输入分发给另两个角色，避免重复跑 3.83 GB JSON。

### 12.3 交叉校正记录（4 处结论被推翻/收紧，这是并行取证的主要收益）

| # | 初稿结论 | 最终结论 | 谁纠正了谁 |
|---|---|---|---|
| 1 | “贴图 3,425/3,425 齐全 → 完备率 100%” | 文件齐，但**内容只有 80.4% 正确**（19.6% 页被同名变体覆盖），修复后 99.2% | Lead 初稿被 **asset-auditor** 用 `regions.json.readable` 复核推翻 |
| 2 | “69% 骨架含 clipping，官方 3.6 不认，需升 3.8 或打补丁” | **clipping 是 3.6 特性**；3.8 只是把它加进**二进制**枚举；3.6 的 **JSON 读取器原生支持** → 不需 3.8、不需补丁 | **runtime-researcher** 源码级更正（旧报告与 integrator 初稿均采信旧说法） |
| 3 | “贴上贴图就能全角色渲染” | **确定配对只有 39/122 角色组**（92.9% 图集无骨架），443 骨架可按 `images` 末段推断（中高置信），490 骨架图集不在本库 | **asset-auditor** 收紧 Lead 的乐观表述 |
| 4 | “战斗 6 件套 19 个” | 口径不同：宽口径 19、**严格同骨架 6 件套 9 个**；战斗体（idle+attack+damage）110 个 | Lead 与 auditor 相互对齐口径后写清“两种口径” |

### 12.4 时间线（2026-10-25，Asia/Shanghai）

| 时间 | 事件 |
|---|---|
| 21:34 | 任务下发，拆成 3 个并行取证任务（`task-1/2/3`） |
| 21:41 | Lead 完成 628 骨架全量扫描 → `_scan_skeletons.json`（公共数据） |
| 21:50 | 运行时调研报告完成（`_research_spine_runtime.md`） |
| 21:56 | 集成架构方案完成（`_integration_plan.md`） |
| 22:00–22:05 | 资产审计报告完成（`_audit_spine_assets.md`，含贴图重配根因） |
| 22:08 | 主报告初稿合稿；随后按资产审计结果修订「贴图/配对/动作」三节 |
| 22:12 | 补「§十二 任务分工与产出」，并把分工定位回写到三份底稿抬头 |

### 12.5 后续工作归属（谁该接着干什么）

| 后续步骤 | 归属 | 前置条件 |
|---|---|---|
| 贴图重配脚本（`regions.json.readable` 对齐、输出 642 修复 / 28 缺失清单） | 资产侧 | 无（第一步） |
| 打包工具链 + `manifest.json`（variant → skel/atlas/pages/动作） | 资产侧 | 贴图重配完成 |
| `.skel→JSON` 批处理 + 按体积筛选可进 B 路线的角色 | 资产侧 | 同上 |
| WebView 播放页 + Flutter↔JS 桥 + 侧载资产库 | 客户端侧 | M0 素材就绪 |
| **注入取数模块**（oracle 移植进 App、路径表裁剪、按需取明文、LRU、失败降级） | 客户端侧 | 换模型注入链路可用（已具备），见 §十三 |
| 真机 60fps / 内存 / 低端机降级实测 | 客户端侧 | 播放页可跑 |
| 动画运行时（A 路线：时间轴 skip→read、约束、clipping、合批） | 客户端侧（二期，决策门之后） | B 路线真机数据 |

## 十三、重要修正：数据源应"读游戏内实时"，内置/侧载只是兜底

> 本节修正 §一 的③与 §五：**预览用的不是"软件里预先装好的模型"，而是"游戏此刻的状态 + 游戏自己加载的资源"**。前文的"内置演示/侧载资产库"降级为 fallback，不是主线。

### 13.1 先把两件事拆开：**状态**是实时的，**美术资源**是文件

| 层 | 内容 | 能否实时从游戏拿 | 现状 |
|---|---|---|---|
| **状态层** | 当前角色 / 服装变体（`characterAtlas`）/ 脸变体（`faceAtlas`）/ 武器（`weaponAtlas`）/ 骨架集（`chara_1..4`）/ 换模型规则 / 正在哪套模型被加载 | ✅ **能，成本低** | App 已有：`user/pull`（pc/item 存档行）+ 换模型 hook 规则 + 注入器日志；换模型命中的正是 `files/spine/characterAtlas\|faceAtlas/{chara_N}/{variant}.pkmenc` 的 x1/x2 槽（旧版 README:73-99） |
| **资源层** | `.skelenc` 几何 / `.atlas` 文本 / `.png` 页图（解密+解压后的明文） | ✅ **能，但要走注入** | 游戏内是 `AES(KEY1,IV)+XZ` 的加密容器；App 默认读不到；**但本项目解包时用的 oracle 已经证明可以运行时拿到明文** |

**所以"实时状态"本身不含几何与贴图**：状态告诉你"该画 `kirito_cathedral` + `kirito` 脸 + `01_sword` 武器"，但要把它们画出来，仍必须拿到那三个变体的 skel/atlas/页——区别只在"这几份文件是内置的，还是运行时从游戏里取"。

### 13.2 "运行时从游戏取明文"在本项目里已经是**现成能力**

- App 里已经内置 `assets/frida-inject`（59 MB）与 `assets/saoars_model.js`（换模型 hook）——**注入通道已经在跑**；
- 解包 3,425 页贴图 / 628 骨架的最终手段就是 **oracle**：注入后把 trampoline 写进 `.text` 代码洞，调用引擎自己的 `DataCache::read(instance, path, &Data)`，返回的就是**已解密+解压的明文**（`_analysis/hook/hook_oracle_v4.js`、`hook_oracle_v6.js`、`hook_oracle_batch*.js`，8 批跑完）；
- 逻辑路径表已从 KeyStore dump 拿到（`_analysis/hook/paths_data.js` 719 KB / `paths3_data.js` 515 KB），批量结果：**1,581 页命中 → 后续补齐 → 3,425/3,425 页、唯一页名 2,767/2,767 = 100%**，骨架 628 个（`可行性分析_B类codec逆向路线.md` §18、§25）；
- 把"离线跑批"改成"App 内按需"= **同一套注入 + 取路径表里的单角色条目**，不需要重新逆向。

### 13.3 三种资源来源对比（新版报告的主线应换成 ①）

| 来源 | 覆盖范围 | 前置条件 | 首次耗时 | 版本风险 | APK 增量 |
|---|---|---|---|---|---|
| **① 运行时 oracle 取明文**（推荐主线） | 路径表覆盖的全量（当前页 100% / 骨架 628） | root + 注入 + **游戏前台** + build 偏移匹配（3.7.0 已验） | 单角色估计 0.3~1 s（取 + 解析，需实测） | 换版本要重新定位偏移（复用 KeyStore/路径表方法） | **0**（只带路径表与脚本，约 1~2 MB） |
| ② 设备本地游戏数据 / 解码缓存 | 解码缓存只覆盖开机预热过的资源（实测仅 ~4%）；若用户把解包库推到 `/sdcard` 则 100% | root 读目录 / 用户推文件 | 快 | 低 | 0 |
| ③ APK 内置演示 | 只有内置的那几套 | 无 | 最快 | 无 | +2~6 MB/套 |

> ① 还有个额外好处：**预览与游戏天然同一个 build**，彻底消除"App 里的资源版本和游戏不一致 → 动作/皮肤错位"的风险（这是 ②③ 的最大隐患）。

### 13.4 建议的最终形态（"所见即所得"预览）

```
打开 E 修改模型页
  ├─ ① 实时读状态：pc 行 + 换模型规则 + 注入器日志 → 得到 {骨架集 chara_N, 身体变体, 脸变体, 武器}
  ├─ ② 按状态推导资源路径（与换模型 hook 命中的路径同一套）
  ├─ ③ 通过注入通道调 DataCache::read 取该角色的 skel + atlas + 页明文（按需、单角色、LRU 缓存）
  ├─ ④ 归一化（.skel → 3.6 JSON，或复用旧版纯 Dart 解析器）→ 实时渲染动作
  └─ 降级链：取不到 → 侧载库 → 内置 1 套演示 / 骨骼线稿 → 明确文案（不画假模型）
```

### 13.5 代价与风险（写进验收）

- **注入与 build 绑定**：oracle 依赖 `libapp.so` 偏移（`.text` 代码洞、`DataCache::read`、AES 入口）。3.7.0 已验；换版本需重定位（已有 KeyStore/路径表复用方法，但**这是长期维护成本**）。
- **必须游戏前台 + root**：与现有换模型功能同一约束；App 内"打开预览"若游戏没在跑，只能走降级链。
- **不要预取全量**：全量明文 4.9 GB，必须"当前角色按需"；单角色 skel 0.9~10 MB、页 1~6 MB，要流式 + LRU。
- **时序**：注入要在模型加载前（换模型已知约束）；取数要与游戏加载错开，避免卡帧。
- **首帧预算**：状态 <100 ms；取数 + 解析 0.3~1 s（中端机估值，需 M1 实测）。
- **合规**：性质与现有"换模型"一致（注入 + 读游戏资源）；仍然**不要把美术资源打进分发包**。

### 13.6 对前文的影响

| 前文 | 修正 |
|---|---|
| §五"L0 内置 / L1 侧载 / L2 缓存" | 改为**三级来源**：① 运行时 oracle（主线）→ ② 本地侧载（兜底）→ ③ APK 演示（首启/离线兜底）；容量数字不变，只是优先级倒过来 |
| §七 工期 | **+5~8 人日**：注入取数模块（oracle 移植到 App、路径表裁剪、传输/落盘、缓存、失败降级、真机验证） |
| §八 风险 | 新增：注入偏移与 build 绑定、游戏前台依赖、按需取数的首帧延迟 |
| §一 结论 | 已加一行"预览的数据源"；"内置 1~2 套"降级为兜底 |

---

## 十四、已定方案 ①：「运行时从游戏取数」实施计划

> 决策（2026-10-25）：**预览 = 游戏当前状态 + 运行时从游戏进程取到的资源**。APK 内**不放游戏美术资源**；② 侧载 / ③ 内置只保留在降级链里。

### 14.1 决策与硬前提

- **主线**：状态实时读 → 路径从本地路径表推 → 明文用注入通道从游戏进程取 → 归一化 → 实时渲染 → 用完即清。
- **硬前提**：**root（KernelSU 等）+ 注入可用 + 游戏进程在前台且已初始化**。也就是：**游戏没开就不能预览真模型**（只能走降级链）——这是产品口径，必须写进 UI 文案。
- **收益**：版本永远与游戏对齐（不会出现"App 内资源与游戏 build 不一致"导致的动作/皮肤错位）；APK 不膨胀；覆盖全量（路径表 2,767 页名 / 628 骨架）。

### 14.2 数据流

```
E 修改模型页 / 动作预览页
  ① 状态：user/pull(pc 行) + 换模型规则 + 注入器日志
        → { 骨架集 chara_N, 身体变体 bodyVariant, 脸变体 faceVariant, 武器 weapon }
  ② 路径：App 内 paths.json（KeyStore 路径表裁剪 + 骨架↔图集配对结果）
        → { skelPath, atlasPath[], pagePaths[] }
  ③ 取数：su → frida-inject -p <游戏 pid> oracle.js  →  引擎 DataCache::read(path) 拿明文
        → 落盘 /data/local/tmp/yui-spine/<随机>/（skel / atlas / page）
  ④ 读取：App 读该目录（注意 chown/权限，旧版踩过）→ 解析 → 渲染 → 立即清理
  ⑤ 缓存：命中过就放 App 私有目录 LRU（避免重复注入；上限可配）
```

### 14.3 模块拆分与人日

| 模块 | 内容 | 人日 |
|---|---|---:|
| **S1 路径表与配对** | 页表**已有**（`paths_data.js` 11,691 条 `.pkmenc`）；**骨架路径表需新建**（该表 0 条 `characterSpine`/`.skelenc`，但运行时 log 已见到真实路径，见 §14.7）；与骨架↔图集配对（§4.2）合并，产出 `assets/spine/paths.json`（预计 <1 MB） | 3~5 |
| **S2 注入取数** | 把 `hook_oracle_v4/v6` 改写成"单路径请求 → 明文落盘"；App 侧 `su` 调用、超时/重试、权限修正、清理 | 4~6 |
| **S3 明文解析** | 优先：Dart 版 `.skel → 3.6 JSON`（从 `_analysis/spine_skel_to_json.py` 移植，Python 侧 628/628 已验证）；备选：直接用旧版纯 Dart 二进制解析器（已支持 type 6） | 3~5 |
| **S4 渲染接入** | WebView + spine-ts 3.6（或旧版 painter）+ **多图集 loader**（body/face/weapon）+ 按页合批 + 2048 降采样 | 4~6 |
| **S5 播放与状态联动** | 动作分组/播放控制/皮肤切换；换模型规则变更 → 预览自动刷新 | 3~4 |
| **S6 缓存与降级** | LRU、降级链（取不到 → 侧载 → 内置演示/线稿）、失败文案 | 2~3 |
| **S7 性能与真机** | 首帧/帧率/内存；注入对游戏帧率影响；低端降级 | 3~4 |
| **合计** | | **22~33** |

### 14.4 里程碑（含一个"先验证再承诺"的 V0）

| 里程碑 | 内容 | 工期 | 验收 |
|---|---|---|---|
| **V0 前置验证（建议立刻做）** | ① 现有 `frida-inject` 能否在 App 内**常驻执行脚本并写文件**（还是只能一次性）；② `paths_data.js` 里是否含 `characterSpine/...skelenc` 骨架路径；③ 用户设备上装的是**官方客户端还是 offline mod**（偏移是否一致）；④ 单角色取数耗时与明文体积 | 1~2 天 | 4 个问题都有实测答案；否则先改架构（改"注入+落盘+轮询文件"或改渲染路线） |
| **M0 取数闭环** | S1 + S2 精简：选 1 个角色，App 内取到 skel+atlas+页并落盘 | 5~7 天 | 取到的明文与解包库同变体文件**字节/尺寸一致**；重复 10 次成功率 ≥95% |
| **M1 能看** | S3 + S4 精简：真机播放 1 角色 × `idle_battle / attack / dash` | 6~9 天 | 贴图正确、无错位；首帧 ≤2 s；30fps 起 |
| **M2 能用** | S5 + S6：动作/皮肤切换、状态联动、缓存与降级链 | 5~7 天 | 换模型规则改动后预览跟随；断游戏/断 root 有明确文案 |
| **M3 能交付** | S7：性能、低端降级、素材库页、文档与免责声明 | 3~4 天 | 中端 60fps / 低端 30fps；注入后游戏掉帧 ≤10%；`flutter analyze`/`test` 全绿 |

### 14.5 追加验收指标（写进 DoD）

- 取数成功率 ≥95%（已配对角色）；单角色首帧 ≤2 s（注入 + 取数 + 解析 + 首绘）；
- 注入后游戏帧率下降 ≤10%；明文缓存 ≤200 MB 且用后清理干净；
- **全程不写游戏目录**：只读游戏数据，写只落在 `/data/local/tmp` 与本 App 私有目录；
- 无 root / 游戏未前台时，必须走降级链并**如实说明原因**（延续旧版"不画假模型"的纪律）。

### 14.6 风险（相比 §八 的增量）

| 风险 | 说明 | 对策 |
|---|---|---|
| 偏移与 build 绑定 | oracle / `DataCache::read` / AES 入口地址随版本变化 | 版本探测 + 偏移表；不支持则明确降级，不硬试 |
| **脚本常驻能力** | ⚠ 需实测，但**风险已降低**：App 现有注入器是**常驻进程**（`saoub-model-inject`，可启停 + 写日志），oracle 脚本也用 `Interceptor.attach + setInterval` 常驻 → 取数可**并入同一注入脚本**，避免双注入 | V0 先验证；不行就改"一次性注入 + 落盘 + App 轮询" |
| 明文落盘安全 | `/data/local/tmp` 可被其他 root 应用读到 | 随机目录 + 用后立即删；不落存档/账号数据 |
| 取数卡顿 | 4096 页明文几十 MB，读盘/落盘要时间 | 只取当前角色真正用到的页；异步 + 进度提示 |
| 注入被游戏检测/冲突 | 与换模型注入器同时跑可能互相影响 | 复用同一注入进程/规则通道；避免双注入 |

### 14.7 V0 预答（本次只读核查已能回答 2/4，剩下 2 条要真机）

| V0 问题 | 预答（证据） | 结论 |
|---|---|---|
| ① 注入能否常驻 / 取数能否并入现有注入器 | App 的换模型注入器是**常驻进程**（`saoub-model-inject`，`model_swap_repository.dart` 有 `injectorRunning`/`injectorPid`/启停 + 日志文件）；oracle 脚本本身也是 `Interceptor.attach` + `setInterval` + 延时执行，天然常驻 | ✅ **大概率可行**，建议把"按路径取明文"做成现有 hook 脚本的一个新指令；仍要真机确认"取数时游戏不卡死" |
| ② 路径表里有骨架路径吗 | `paths_data.js`：`.pkmenc` **11,691 条**、`characterSpine` **0 条**、`.skelenc` **0 条**；但运行时 path log（`lp_out.txt`/`pathlog_out.txt`）里已实测到 `characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc`、`CharacterSpine/a_chara_1/a_chara_1_v0.4.skelenc` | ⚠ **页表可用、骨架表需新建**（pathlog 采样 + mod APK 条目枚举 + 骨架 `images` 字段推断），S1 工时已按其调整 |
| ③ 设备上是官方客户端还是 offline mod | 解包与 oracle 全部基于 offline mod（`SAOUB-OFLINE-final9`）build；App 连的 `127.0.0.1:18680` 也是离线引擎 | ❓ **需你确认实际安装的是哪个包**（偏移按 build 绑定，两者可能不一致） |
| ④ 单角色取数耗时 / 明文体积 | 骨架明文 0.9~10 MB、单页明文 1~6 MB（4096 页 ≈ 36~64 MB RGBA，但落盘的是 ETC2/PKM 密文解出的原始块，比 RGBA 小） | ❓ 需真机实测（预计首次取数 0.3~1 s，未验证） |

> 另两个实测细节：oracle v6 把明文写在 `/data/user/0/com.bandainamcoent.saoars/files/dump2/`（注入进程以游戏 uid 写，App 借 root 读）；正式版建议改写到 `/data/local/tmp/yui-spine/<随机>/` 并在读完立即删除。

### 14.8 结论与下一步

**结论**：方案 ① **技术上可行、产品语义正确**，且"取数"这一环不是从零开始——注入器、oracle、页路径表都已存在；真正的新增工作是 **骨架路径表（S1）**、**把 oracle 从"离线跑批"改成"App 内单角色按需调用"（S2）**、以及**明文解析与多图集渲染（S3/S4）**。主要风险从"包体与配对"转移到"**注入稳定性 + build 版本维护**"。

**下一步（按顺序）**：
1. 你确认 V0 第③项：手机上装的是**官方客户端**还是 **offline mod**（决定偏移是否对得上）；
2. 花 1~2 天做 V0：把"按路径取一个骨架 + 一页贴图"在真机上跑通，并记录耗时/体积/游戏卡顿；
3. V0 通过后按 §14.4 的 M0→M3 排期（首版 5~7 天出"取数闭环"，13~16 天出"能看"）；
4. 渲染路线仍按 §三：**先 B（WebView + spine-ts 3.6）**验画面，若 App 内 Dart 版 skel→JSON 转换（S3）顺利，则长期可换 A（纯 Dart）去掉 WebView。

---

### 14.9 S1 已完成（2026-10-25）：路径表已产出

> 产物：`assets/spine/paths.json`（648 KB）+ `tools/build_spine_paths.py`（可复跑）+ `docs/_s1/README.md`（方法/规律/schema）。

| 资产 | 已解路径 | 覆盖率 | 校验方式 |
|---|---:|---:|---|
| 图集 `.atlas` | **1,661 / 1,666** | 99.7% | hash 命中离线 mod 密文仓库（53,943 条） |
| 页贴图 `.pkmenc` | **3,420 / 3,425** | 99.85% | 同上（3,420/3,420 命中） |
| 战斗基础骨架（`f_chara_*` / `a_chara_*`） | **28 / 28** | 100% | path hash == 已知骨架 hash |
| 敌人骨架 | **50 / 50** | 100% | 同上 |
| 角色服装 / 技能 cut-in 骨架 | **89**（含三段版本 `v0.5.37` 规律） | 部分 | 同上 |
| 技能 cut-in / 交谈 / 展示骨架（剩余） | 0 / 461 | 0%（留待 S2） | 文件名 token 依赖 master `spine.bin` 私有 key |
| 合计骨架 | **167 / 628** | 26.6% | — |

**方法要点**（无需真机、无需解密）：`hash = SHA1("66VsXNegycgradYc"+logicalPath)`，用"候选路径枚举 + hash 成员判定"反推；
实测规律：武器目录是真实 id（`10_shield`/`12_knuckle` 而非顺序编号）、敌人骨架**文件名 = 目录名**、页路径 = 图集目录 + 页名 + `.pkmenc`、
`a_chara_*` 在 `realCharacterSpine/`（不是 `characterSpine/`）、技能 cut-in 用**三段版本** `<set>_v<A.B.C>_<skill前缀>`。

**结论**：**战斗/移动实时渲染所需的资源路径已 100% 就绪**（基础骨架 + 敌人骨架 + 身体/脸/武器图集与页）。
唯一缺口是 461 个技能 cut-in / 交谈 / 展示骨架——不影响战斗/移动，**S2 跑一次 pathlog hook 即可补齐**。

### 14.10 S2 进展（2026-10-25）：真机取数链路已打通，页贴图有明确边界

**V0 真机验证**（Xiaomi 24129PN74C / Android 16 / offline mod；用 App 同款 `frida-inject` + `assets/spine_fetch.js`）：

| 取数对象 | 结果 | 证据 |
|---|---|---|
| `characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc` | ✅ **8,339,008 字节**、头部 `1c…` | 与本地解包明文**大小一致**（同路径 hash `dd66aa14…`） |
| `characterAtlas/chara_2/alice_uw_2022_new_year_inc.atlas` | ✅ **21,068 字节**、文本头 `\nali…` | 与本地 `atlas.atlas` **逐字节等长** |
| `enemySpine/enemy_530_dragon/enemy_530_dragon.skelenc` | ✅ 158,759 字节、`1c…` | 敌人骨架可按时取 |
| `.pkmenc` / `.pngenc` 页贴图 | ❌ `DataCache::read` 返回空（`f8=0` / null） | 连运行时日志里的**真实路径** `characterAtlas/chara_2/edith_integrator.pkmenc` 也失败 → 页贴图不走该接口 |

**结论**：
1. **A 类资源（`.skelenc` / `.atlas`，AES+XZ）可以按时取明文** —— S2 的"骨架/图集按逻辑路径取数"已打通，注入一次约 40~60s（脚本内固定等 40s 让游戏加载完成以捕获 `DataCache` 实例）。
2. **B 类资源（`.pkmenc` 页贴图）不能走 `DataCache::read`** —— 这是已确认的硬边界。页贴图有两条可行来源：
   - **mod 的解码缓存** `files/saoub_all/`（设备实测 1,404 文件 / 563 MB，文件名里编码了逻辑路径与尺寸/格式，可直接解码）——覆盖"玩过/预热过"的页，缺的页提示用户"在游戏里打开该角色一次"即可补齐；
   - 或重做 **B 类 codec**（`可行性分析_B类codec逆向路线.md` 的 oracle 路线，成本高）。
3. 附带发现：`DataCache::read` 对**未加载**资源也可能返回空，因此注入后固定等待 40s 再取数（脚本已实现）。

**S2 已交付代码**：

| 文件 | 作用 |
|---|---|
| `assets/spine_fetch.js` | 注入脚本：读 `request.txt` → 逐条调 `DataCache::read` → 明文落盘到游戏私有目录 `files/yui-spine/out/`，支持一行多候选（`a\|b`） |
| `assets/frida-inject`（已有） | App 内置注入器，S2 直接复用 |
| `lib/data/spine/spine_path_table.dart` | 解析 `paths.json`：变体 → 身体/脸图集、页路径派生、素体骨架选择、取数清单 |
| `lib/data/spine/spine_oracle.dart` | 取数编排：root/进程检查 → 部署注入器与脚本 → 准备 IO（游戏私有目录，规避 SELinux）→ 注入 → 读 `result.json` + base64 取明文 → 分类失败（noRoot/gameNotRunning/badResult…） |
| `tools/v0_fetch.py` | 真机 V0 复跑脚本（同上流程，命令行版） |
| `test/spine_path_table_test.dart`、`test/spine_oracle_test.dart` | **15 个单测全绿**（`dart analyze` 0 issue） |

**下一步（S3）**：
1. 页贴图取数：实现 `SpineTextureCache`（读 `files/saoub_all/` + ETC2/RGBA 解码）；缺页时给"去游戏里打开该角色一次"的引导；
2. 渲染接入：Dart 版 `.skel → 3.6 JSON`（或旧版纯 Dart 解析器）+ 多图集 loader，先在预览卡跑通 1 个角色 × `idle_battle/attack/dash`；
3. 把 `SpineOracle`/`SpinePathTable` 接到 E 修改模型页（替换现在那张硬编码火柴人）。

### 14.11 S3 进展（2026-10-25）：页贴图解码链路打通（离线实测）

**结论**：页贴图走 **mod 解码缓存 + ETC2 解码**这条路已验证可用（用真实缓存数据、并与我们解包出的 PNG 对照）。

| 项 | 结果 |
|---|---|
| 缓存规模 | 本地 `saoub_all` 1,404 文件 / 558 MB → **702 个条目**（raw+json 成对）；其中 **spine 相关 81 条** |
| 页名 → 缓存匹配 | 按「逻辑路径下划线化后作为后缀」匹配（如 `files/spine/characterAtlas/chara_2/test.pkmenc` → `..._files_spine_characterAtlas_chara_2_test.pkmenc`），不会跨目录误配 |
| ETC2 解码 | `fmt=37496 (ETC2_RGBA8_EAC)` 可解；**该 build 的块顺序是 alpha 块在前**（`etc2AlphaFirst=true`）——用本地 PNG 对照确认：`4096×204` 页 avgRGB `(53,51,52)` vs 本地 `(51,51,51)`、alpha 覆盖率 `62.9%` vs `62.5%`；`3668×2568` 页覆盖率 `13.0%` vs 本地 `13%` |
| 性能 | 4096×204 约 70 ms、3668×2568 约 471 ms（纯 Dart，未优化） |
| 覆盖边界 | 缓存只含**预热/加载过**的资源（81 条 spine ≈ 3,425 页的 2.4%）→ 缺页时提示"在游戏里打开该角色一次" |

**S3 已交付**：

| 文件 | 作用 |
|---|---|
| `lib/data/spine/spine_binary.dart`（830 行，从旧版移植） | Spine 3.6 二进制骨架解析（300/300 EOF 已验证过；含 clipping/path 等附件） |
| `lib/data/spine/skeleton_pose.dart` | bind pose 世界变换 + 网格顶点（后续动画运行时在此扩展） |
| `lib/data/spine/atlas_variant.dart` | 从 `images` 路径推断图集变体名 |
| `lib/data/assets/texture_atlas.dart` | LibGDX `.atlas` 文本解析（多页 / rotate） |
| `lib/data/assets/etc2.dart` | ETC2 RGBA8（EAC）纯 Dart 解码 |
| `lib/data/spine/spine_texture_cache.dart`（新增） | 读 `saoub_all`：索引、逻辑路径匹配、tex/ctex 解码、alpha 覆盖率诊断；支持设备源与本地目录源 |
| `tools/s3_texture_probe.dart`（新增） | 离线解码探针（`dart run tools/s3_texture_probe.dart <缓存目录> --filter spine --limit 5`） |
| 测试 | **46 个用例全绿**（含移植的 19 个骨架解析用例 + 图集用例 + S2/S3 新用例）；`dart analyze` **No issues found** |

**下一步（S4：渲染接入）**：
1. `SpineVariantAssembler`：variant → 取骨架（Oracle）+ 图集文本（Oracle）+ 页贴图（TextureCache）→ 校验完整性 → 产出可渲染对象；
2. 渲染器：先按旧版 `drawVertices` 方案画出 bind pose（验证数据闭环），再补动画时间轴（S5）；
3. 接到 E 修改模型页，替换硬编码火柴人；缺页/缺骨架按旧版"三态"如实提示。

### 14.12 S4 已完成（2026-10-25）：渲染闭环打通，E 页已接真渲染

**离线端到端验证（真实素材，已出图）**：用 _Stage0_ViewerReady/FrenzyBoar101（skel + atlas + 2 页 PNG）
走完整链路 → **渲染出带贴图的野猪 bind pose**（uild/spine_offline_render.png，线框图 uild/spine_offline_wireframe.png）：
骨骼、几何、UV、纹理、颜色全部正确（蓝身/红眼/獠牙/尾珠）。

| S4 交付 | 说明 |
|---|---|
| lib/ui/spine/spine_painter.dart | SpineBinder（网格/区域 → 世界顶点 + 图集 UV）+ SpinePainter（drawVertices + ImageShader，含线框模式） |
| lib/data/spine/spine_assembler.dart | 装配器：.skelenc → 解析；多图集（身体/脸/武器）→ 合并纹理池；	ex 像素 → ui.Image；产出 SpineRenderBundle（骨架/图集/皮肤/批次/缺页清单） |
| lib/data/spine/spine_preview_loader.dart | 变体 → 装配入口（骨架优先服装骨架，回退 kind==base 素体；页贴图走缓存） |
| lib/ui/spine/spine_preview_view.dart | 预览卡：加载/成功/缺件/错误四态 + 皮肤切换 + 线框开关（不画假模型） |
| lib/ui/spine/spine_preview_page.dart | 「全部变体」真渲染页：搜索 1,488 个变体 → 选中 → 运行时取数 → 渲染 |
| E 修改模型页 | 原硬编码火柴人（_BonePainter）**已删除**，预览卡改为真渲染 + 缺件提示 + 「浏览全部变体」入口 |
| 测试 | spine_render_offline_test.dart（装配/出图/三态）+ 全量 **175 个用例全绿**；dart analyze **No issues found** |

**已解决的关键坑**：
1. 解析器把 default 皮肤单独放在 data.defaultSkin（命名皮肤才在 data.skins）——不合并会导致批次为空；
2. 	estWidgets 里图片解码/	oImage/	oByteData 必须包在 	ester.runAsync 里，否则假时钟卡死（曾 10 分钟超时）；
3. 多图集：3.6 运行时单图集限制，装配器合并纹理池、按 region 名跨套查找。

**下一步（S5：动画）**：
1. 在解析器里把动画时间轴从 skip 改成 read（旧版已摸清布局），或在 App 内做 .skel → 3.6 JSON + WebView 播放；
2. AnimationState（采样/循环/混合/队列）+ 约束（IK/transform/path）→ 播放 idle_battle / attack / dash；
3. 预览卡加动作下拉与播放控制；随后做 saoub_all 缺页引导与 LRU 缓存。

### 14.13 S5 已完成（2026-10-26）：动作播放打通（FK 时间轴）

**关键改动**：解析器的动画段从「只统计名字/跳过内容」改成**真正读取时间轴**（字节布局与 skip 完全一致，
判据仍是「读到 EOF 恰好对齐」——移植的 19 个合成用例 + 真实骨架 e2e 全部通过，证明没读错位）。

| S5 交付 | 说明 |
|---|---|
| `lib/data/spine/spine_animation_data.dart` | 时间轴数据模型：`SpineCurve`（linear/stepped/bezier 反解）、`SpineBoneTimeline`（rotate/translate/scale/shear）、`SpineAnimation` |
| `lib/data/spine/spine_animation_player.dart` | 播放器 v1：时间推进/循环 + 姿态采样（setup 值加时间轴偏移；scale 为乘）+ `SkeletonPose.fromLocals` 世界变换 |
| `spine_binary.dart` | 动画段改为读入：骨骼时间轴保留；slot 颜色/附件、IK/transform/path、deform、drawOrder、event 读掉不应用（字段全读，保证对齐） |
| `skeleton_pose.dart` | 新增 `BoneLocals` + `SkeletonPose.fromLocals`（与 bind pose 共用同一套世界变换公式） |
| `lib/ui/spine/spine_preview_view.dart` | 动画下拉 + 播放/暂停 + 循环 + 进度显示；每帧重算姿态与批次后重绘；皮肤/线框保持不变 |
| 测试 | `spine_animation_offline_test.dart`：时间轴解析自洽（times 递增、values=frames×stride、curves=frames-1）、半周期骨骼位移 >1 单位、**3 帧渲染出 PNG 且互不相同**（`build/spine_anim_0..2.png`）；全量 **178 个用例全绿**，`dart analyze` No issues found |

**真机素材验证**：`FrenzyBoar101` 的 `idle_battle_front`（40 帧 / 1.30s）逐帧渲染出图，与 bind pose 明显不同
（低头、抬尾、重心前移），说明时间轴采样正确。

**v1 的诚实边界**（写进 UI 文案/文档，不假装完整）：
- ✅ 已应用：rotate / translate / scale / shear（含三种曲线）；
- ❌ 未应用：IK / transform / path 约束求解、deform 网格形变（布料/肌肉）、drawOrder、slot 颜色与附件切换；
- ❌ 不做多动画混合（mix/队列），一次只播一条；
- 性能：预览每帧重算批次（数百个 drawVertices），150dp 卡片够用；全屏 60fps 需后续合批优化。

**下一步（S6 候选）**：
1. 约束求解（IK/transform/path）+ deform，让动作更完整；
2. 每帧合批（按图集页合并顶点缓冲）以支撑全屏 60fps；
3. 缺页引导与 LRU 缓存的产品化；真机回归（设备重连后跑一次 E 页全链路）。

### 14.14 S6 已完成（2026-10-26）：按图集页合批 + 帧预算

**做了什么**：`SpinePainter` 增加按图集页合批（只合并**相邻同页**批次，保证叠加顺序不变），
默认开启；`SpineBinder.pageRunCount()` 暴露绘制次数用于诊断；预览卡状态条加 FPS（EMA）。

**实测（FrenzyBoar101，animate 后单帧）**：

| 指标 | 逐附件绘制 | 合批后 |
|---|---:|---:|
| drawVertices 次数 | **68** | **1** |
| 绘制指令构建耗时 | 0.698 ms/帧 | **0.229 ms/帧（−67%）** |
| 画面像素一致性 | 基准 | **差异像素 < 0.1%（实测 0）** |

> 注意：该耗时为 Flutter 测试环境下的「指令构建」时间，不含 GPU 光栅；真机帧率需设备回归
> （USB 断开后未跑）。合批的主要收益是把数百次 draw call 压到 1~3 次，这是移动端 60fps 的前提。

**踩坑**：合批不能简单"按页分组"，否则跨页插槽的绘制顺序会被打乱导致遮挡错误；
必须**按相邻同页切分成 run**，每个 run 一次 `drawVertices` —— 这样像素与逐附件绘制完全一致（测试断言）。

**S6 交付**：
- `lib/ui/spine/spine_painter.dart`：`batching` 开关 + `_paintBatched`（run 合并顶点/UV/索引）；
- `lib/ui/spine/spine_preview_view.dart`：FPS 显示（播放时）；
- `test/spine_render_batching_test.dart`：像素一致性断言 + 绘制次数断言 + 帧耗时打印；
- 全量 **180 个用例通过**，`dart analyze` No issues found。

**下一步（S7 候选）**：
1. **约束求解（IK/transform/path）+ deform**：让动作更接近游戏内（布料/裙摆/足部贴地）；
2. **多动画混合（mix）**：动作切换过渡、待机→普攻更自然；
3. **产品化**：缺页"去游戏里打开一次"引导 + LRU 缓存 + 真机全链路回归 + 全屏页合批压测。

### 14.15 S7 已完成（2026-10-26）：约束数据读入 + deform 网格形变应用

**这轮做了什么**：

| 能力 | 之前 | 现在 |
|---|---|---|
| IK / transform / path 约束（setup） | 整段 **skip**（数据被丢掉） | **读入** `SpineSkeletonData.ikConstraints / transformConstraints / pathConstraints`（含骨骼链、目标、mix、bend） |
| 动画里的 IK 时间轴 | 读掉 | 读入 `SpineAnimation.ikTimelines`（逐帧 mix / bend，供 S8 求解） |
| deform 网格形变 | 读掉 | **读入并应用**：`SpineBoneTimeline` 之外新增 `SpineDeformTimeline`（官方 3.6 的 start+values 区间语义），装配时按附件叠加到顶点 |
| 渲染契约 | — | `SpineBinder.bind(..., skinIndex, deformLookup)`；`skinMeshVertices(..., deform:)`（加权/未加权都支持） |

**实测（`Administrator / Cathedral` 真实角色骨架 + 图集 + 页贴图）**：
- IK 约束 6 个被正确读入（JSON 侧同为 6）；
- deform 时间轴跨全部动画扫描：帧数/时间轴自洽，采样出**非零偏移**；
- 同一姿态下「带 deform / 不带 deform」顶点最大差 > 0.5 单位，渲染图不同
  （对照图：`build/spine_deform_off.png` / `build/spine_deform_on.png`）。

**顺带修正的两个 3.6 格式坑**（都是先踩后修，写进文档避免再犯）：
1. **transform 约束的 mix 是 4 个**（rotate/translate/scale/shear），不是 3.8 的 6 个逐分量 mix；
2. **path 约束的 mix 是 2 个**（rotate/translate），不是 3 个。
   读多/读少都会让后续段整体错位（表现为"读取越界"或 EOF 对不上）。

**S7 交付**：
- `lib/data/spine/spine_constraint_data.dart`：三类约束的 setup 数据模型；
- `spine_binary.dart`：约束读入 + IK 时间轴保留 + deform 帧读入（`start`/`values` 区间）；
- `spine_animation_data.dart`：`SpineDeformFrame/Timeline`、`SpineIkTimeline`；
- `skeleton_pose.dart`：`skinMeshVertices(..., deform:)`；
- `spine_painter.dart`：`bind(..., skinIndex, deformLookup)`；
- `spine_animation_player.dart`：`deformAt(time)`；
- 检查全绿：**183 个用例通过**，`dart analyze` No issues found（含新增 3 个 S7 用例）。

**仍未做（S8）**：
- **IK/transform/path 约束求解**（数据已就位）：足部贴地、手部对齐、路径摆放；
- 多动画混合（mix）、drawOrder、slot 颜色/附件切换；
- 真机全链路回归（设备重连后）。

---

> 声明：本分析仅用于个人学习、研究与存档；游戏素材版权归 ©Bandai Namco Entertainment / ©Wright Flyer Studios 及相关权利方所有，请勿用于商业用途或再分发。
