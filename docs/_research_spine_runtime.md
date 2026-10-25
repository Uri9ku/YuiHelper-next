# Flutter Android 内嵌 Spine 实时渲染方案调研（任务 task-2）

> 分工定位：本文件是 **task-2 / runtime-researcher（运行时调研员）** 的证据底稿。四个角色的分工、产出清单与交叉校正记录见主报告 [可行性分析_APP内实时渲染Spine动作.md](可行性分析_APP内实时渲染Spine动作.md) **§十二**。

> 调研对象：`C:\Users\Administrator\Desktop\YuiHelper-next`（Flutter Android，minSdk 24、arm64、pubspec 仅 flutter、APK ≈40MB）
> 数据对象：解包资产库里的 Spine 骨骼（`C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine`），628 个 3.6.53 二进制 `.skel`（版本头带定制后缀）、1666 个 `.atlas`、3425 张 PNG 图集页。
> 本机环境（实测）：Flutter **3.47.5 stable** / Dart **3.13.4**（`E:\env\flutter\version`、`E:\env\flutter\bin\cache\dart-sdk\version`）；pub 缓存中**没有** spine_flutter / flame_spine / flutter_inappwebview（`%LOCALAPPDATA%\Pub\Cache` 实测为空匹配），即任何方案都要联网 `pub get`。
> 本文不修改工程代码，只做调研结论。

---

## 0. 结论速览（先看这段）

**能不能做：能做，且不需要等官方支持 3.6。** 关键是"不要把 `.skel` 直接丢给官方运行时"，而是**沿用工程里已经跑通的"3.6 二进制 → 3.6 JSON"转换**（本地 `_analysis\spine_skel_to_json.py`，628/628 EOF 对齐），再喂给一个 3.6 世代的运行时。

| 路线 | 可行性 | 首版代价 | 产品级代价 | 保真度 | 主要风险 |
|---|---|---|---|---|---|
| **B. WebView + 官方 spine-ts 3.6**（推荐先做） | ✅ 高（运行时源码级已确认支持 clipping） | **3–5 人日** | **10–15 人日** | ★★★★★（官方运行时，clipping/皮肤/网格/混合模式全支持） | WebView 内存/冷启动；WebGL 兼容性；跨端通讯 |
| A. 纯 Dart 自研（**不是从零**：fork `spine_core`+`spine_flutter_dart`） | ✅ 中（有 3.8 版 Dart 移植可复用） | 8–15 人日 | 15–25 人日 | ★★★★（自己补 clipping 渲染/调优） | 包 3 年未维护、Dart 3 迁移、60fps 打不满、自维护 |
| A′. 纯 Dart 真·从零写渲染器 | ⚠️ 低（仅理论可行） | 25–40 人日 | 40+ 人日 | ★★★ | 工作量被严重低估，不建议 |
| C. 构建期烘焙（WebP/精灵表/视频） | ✅ 简单，但**不是实时** | 2–3 人日 | 3–5 人日 | ★★（锁死分辨率/镜头/皮肤） | 体积暴涨、不能换装/任意动作组合 |

**推荐：先 B 打通"能看"，把 A 作为第二阶段可选的"原生化"升级；C 只用于列表缩略图/低端机兜底。**
理由：B 用的 spine-ts 3.6 运行时**源码里已经有 `SkeletonClipping` 和 `ClippingAttachment` 的 JSON 加载**（见 §2 证据），和我们的 JSON 数据是同一代格式，属于"零格式改造"；而 A 虽然有现成 Dart 移植（`spine_core 0.3.5`，3.8 世代、含 clipping 类），但要自己扛 Dart 3 迁移 + 渲染器 + 性能，收益是省掉 WebView 的 ~1MB APK 和 ~50–100MB 进程内存。

**clipping 结论（重要更正）**：clipping **不是 3.8 引入的，而是 Spine 3.6 引入的**（官方博客 2017-06-19 明确写 "We've added support for clipping and point attachments to all runtimes"）。真正的分界是**二进制格式**：3.6/3.7 的 `AttachmentType` 枚举只有 0–5（Region/BoundingBox/Mesh/LinkedMesh/Path/Point），**3.8 才把 `Clipping` 加进枚举成为 type 6**。所以：3.6/3.7 运行时能**从 JSON** 读 clipping 并渲染；而我们的 `.skel` 头写 `3.6.53E` 却含 type 6——说明厂商改了 3.6.53 的二进制导出器（后缀 `E` 就是他们自己的版本标记）。**结论：`.skel` 必须转换后才能给任何官方运行时；转成 3.6 JSON 后，3.6 运行时能完整处理 clipping。**

**定制后缀结论（实锤）**：`FrenzyBoar101.skel` 头 28 字节 hash 后跟变长字符串 `3.6.53E`（hexdump 实测：`... 07 33 2e 36 2e 35 33 45 ...`），转换后的 JSON 里 `"spine":"3.6.53"`（后缀已剥离）。官方 3.6 解析器不校验版本字符串（本地转换器是按 spine-libgdx 3.6 `SkeletonBinary.java` 逐字段移植的，转换后 628/628 精确 EOF），但**官方 3.6 的二进制读取器不认识 type 6**，所以 Q2 的"3.8 运行时能否读 3.6 数据"这条对我们是**否**——3.8 运行时连 3.6 的版本都对不上。

---

## 1. pub.dev 可用包（Q1）——真实版本号/日期/维护者

### 1.1 `spine_flutter`（官方，Esoteric Software LLC）
- 最新版 **4.3.6**，**2026-07-09** 发布（pub API `published` 字段）；主页 <https://pub.dev/packages/spine_flutter>，文档 <https://esotericsoftware.com/spine-flutter>，仓库 `github.com/esotericsoftware/spine-runtimes`。
- 性质：**Flutter FFI 插件**，底层是 **spine-cpp**（`ffiPlugin: true`，Android/iOS/desktop/web）。pubspec 依赖 `universal_ffi ^1.1.3`、`inject_js`、`js`、`crypto` 等；Flutter `>=3.16.0`、Dart `>=3.0.0 <4.0.0`。
- 版本谱系：`0.1.0`–`0.1.3`（2022-01~07，**jtakakura** 的纯 Dart 版）→ 2023-03-08 起改为官方，从 **4.1.1** 起步，之后 4.2.x/4.3.x 跟随编辑器版本发布（4.3.0 2025-10-29，4.3.6 2026-07-09）。
- **支持的数据版本：只支持与包 `major.minor` 完全一致的导出数据。** 官方文档原文：*"Ensure that the `major.minor` version of spine-flutter matches the `major.minor` Spine Editor version you are exporting from… If you change the major.minor version, you have to re-export your Spine skeletons with the same Spine Editor major.minor version."* → 4.3.6 **不能**加载 3.6 数据（见 §2）。
- 功能面：支持除 **tint black** 和 **screen 混合模式** 外的全部 Spine 特性；**不支持预乘 alpha（pma）图集**（原文："does not support atlases exported using pre-multiplied alpha"）。我们的图集 `pma` 为空（非 PMA）→ 这一条不阻塞。
- Android 已知问题（真实 issue，均来自官方仓库）：
  - `#2719`（2024-12-25，Flutter 3.27 + Impeller 下 Spine 画面质量下降，badlogic 修复/关闭）<https://github.com/EsotericSoftware/spine-runtimes/issues/2719>；
  - `#3038`（2026-03-06，`SpineWidget.fromAsset` 异步加载完成时 widget 已 dispose 触发 `setState() called after dispose()`，Android，已修）<https://github.com/EsotericSoftware/spine-runtimes/issues/3038>；
  - `#2849`（Android 16K page size 适配告警）<https://github.com/EsotericSoftware/spine-runtimes/issues/2849>。
- License：Spine Runtimes License（见 §5）。
- **对本项目：不可直接用**（数据版本差 3.6 vs 4.3）。除非走"重新导出"路径（§2.3），而那需要 Spine 编辑器 + 原始 `.spine` 工程。

### 1.2 `flame_spine`（Flame 引擎官方社区包）
- 最新 **0.3.1+6**，**2026-07-19**；依赖 `flame ^1.38.0` + `spine_flutter ^4.3.0`，Flutter `>=3.41.0`、Dart `>=3.11.0`。另有 `0.4.0-dev.1`（2026-10-06，flame 2.0 dev）。
- 定位：**只是 spine_flutter 的 Flame 组件包装**（`SpineComponent`），不解决版本问题；**数据版本约束同 spine_flutter（4.3）**。
- 对本项目：不适用（我们不是游戏引擎场景，且版本不匹配）。

### 1.3 `spine_core`（jtakakura，纯 Dart 运行时移植）
- 最新 **0.3.5**，**2022-11-28**（此后停更，pub 上 "Published 3 years ago"）；SDK `>=2.17.0 <3.0.0` → **Dart 3.13 的 pub 解析会直接拒绝**（需 fork 改 SDK 约束）。
- 内容：**spine-ts 的纯 Dart 移植**，API 级别证据（pub 文档类列表）：含 `ClippingAttachment`、`SkeletonClipping`、`MixPose`/`MixDirection`、`TwoColorTimeline`、`PathConstraintMixTimeline`、`Triangulator`；**不含 `SkeletonBinary`**（只能读 JSON）。
- 版本推断：有 clipping 类 + MixPose/MixDirection + 无 Physics/Sequence（4.0 特性）→ **移植目标为 3.8 世代**（可信度高，源码可复核：<https://github.com/jtakakura/spine_core/blob/main/lib/src/skeleton_json.dart>）。
- **关键发现**：其 `SkeletonJson.readSkeletonData()` **没有任何版本校验**——只把 `skeleton.spine` 读进 `skeletonData.version` 就继续解析；且 `skins` 同时兼容 object（3.6/3.7 写法）和 list，附件 `switch(type)` 认 `"clipping"` 并读 `end` 槽名。**这意味着我们转换出来的 3.6 JSON（含 clipping）大概率能被它直接加载**（未实测，见 §7 验证清单）。
- License：仓库 `LICENSE` 是 **Spine Runtimes Software License v2.5**（"solely for personal or internal use… may not modify/create derivative works"）→ 比现行协议更严（见 §5）。

### 1.4 `spine_flutter_dart`（jtakakura，纯 Dart Flutter 渲染器）
- 最新 **0.2.0**，**2022-12-04**；依赖 `spine_core ^0.3.5`，Flutter `>=3.0.2`、SDK `>=2.17 <3.0`。
- API（pub 文档实测）：`SkeletonAnimation`、`SkeletonRenderObject`、`SkeletonRenderObjectWidget`、`AssetLoader`、`PlayState` → **是一个真·Flutter RenderObject 渲染器**（非 FFI、非 WebView）。
- 状态：3 年未更新、无 clipping 渲染的书面证据（渲染层是否调用 `SkeletonClipping` **未验证**）、无废弃 API 说明。
- 对本项目：**这是路线 A 的最佳起点**（比从零写渲染器省 60–70% 工作量）。

### 1.5 其它（查过，不建议）
- `spine`：2014 年 Dart 1 时代包，已死。
- `bonfire_spine` 0.0.1（2022-10-28）：Bonfire 引擎插件，包 `spine_core ^0.3.4`，无维护。
- `flutter_spine` 0.2.6（2026-08-19）：**名字撞车**，实际是某 MVVM 基础设施包，与 Spine 无关。
- 结论：**pub 上不存在"官方维护 + 支持 3.6/3.8"的包**。3.6/3.8 世代只有 jtakakura 的两个纯 Dart 包（停更、Dart 2 约束），这是路线 A 能"便宜"的唯一原因，也是它必须 fork 的原因。

---

## 2. 官方版本兼容策略（Q2）

### 2.1 硬规则：major.minor 必须一致
官方《Versioning》原文（<https://esotericsoftware.com/spine-versioning>）：

> **"The major and minor version for the Spine editor used to export JSON or binary data must always match the Spine Runtimes version. If not, the Spine Runtimes will not be able to read the data."**
> "After updating the Spine Runtimes to the branch for the new version, the Spine Runtimes will no longer be able to read any of the exports from the older Spine editor version."

- 同 major.minor 内 patch 安全：3.6.44 的数据可被 3.6 运行时读，编辑器可升到 3.6.53。
- **跨版本（3.6→3.8/4.x）不存在"向下兼容加载"开关**。所以"用 spine_flutter 4.3.6 直接加载 3.6.53E"= 不行；"用 3.8 运行时加载 3.6 的 skel"= 也不行。
- 3.8/4.x 运行时的源码对版本只做"弱校验"，但**字段布局差异（timeline/约束/附件表）会造成静默错位**，即便不抛异常也不可用——工程上按"不能读"处理。

### 2.2 3.6 → 4.x 的官方迁移路径（需要 Spine 编辑器）
官方唯一正规路径（Versioning 文档 "Recovering work from a newer version"/"File storage" 一节）：
1. 用**导出时同版本的编辑器**（3.6.x）导入 JSON：`Spine -u 3.6.51 -i input.json -o project.spine --import`；
2. 保存为 `.spine` 工程；
3. 用新版编辑器（4.x）打开工程（工程文件向后兼容），再导出 4.x JSON/binary：`Spine -u 4.0.10 -i project.spine -o out --export json`。
- 前置条件：**必须持有对应版本的 Spine 编辑器授权**；本机只装了 **Spine Launcher 3.8.75**（`C:\Users\Administrator\Spine\spine.log` 报错路径 + `_work\spine_help.txt` 实测），且 3.8 编辑器**不能**直接导入 3.6 JSON（导出数据只能被同版本编辑器导入）。要拿 3.6.x 需 launcher `-u 3.6.53` 在线拉取对应版本（授权/联网前提）。
- 风险：本批数据是**厂商魔改的 3.6.53E**（含 type 6 clipping），官方 3.6.53 编辑器能否导入这种"非法版本字符串"的 JSON 未知；就算能，往返一次再导出 4.x 会引入曲线/约束语义差异（3.8 之前没有 clipping 二进制、4.0 又改了 JSON 结构），失败概率高。**因此"A 方案：迁移到 4.x"应作为高风险备选，不作为首选。**

### 2.3 clipping 与"定制后缀"到底意味着什么（源码级证据）
| 事实 | 证据 | 等级 |
|---|---|---|
| clipping 是 **3.6** 引入的特性（不是 3.8） | 官方博客 2017-06-19《Spine 3.6 - Tint black, clipping, weight painting, and more!》："We've added support for clipping and point attachments to all runtimes" | B（官方一手） |
| 3.6/3.7 的**二进制** `AttachmentType` 只有 0–5，**没有 Clipping** | 分支源码 `spine-ts/core/src/attachments/AttachmentType.ts`：3.6/3.7 都是 `Region, BoundingBox, Mesh, LinkedMesh, Path, Point` | A（源码） |
| **3.8** 才把 `Clipping` 变成 type **6** | 3.8 分支同名文件：`Region, BoundingBox, Mesh, LinkedMesh, Path, Point, Clipping` | A（源码） |
| 3.6 运行时**能读 JSON 形式的 clipping 并做 CPU 裁剪** | 2017-04-11 commit `778055a`："[ts] Added ClippingAttachment and loading in SkeletonJson"；3.6 分支含完整 `SkeletonClipping.ts`（多项式裁剪+三角化实现） | A（源码） |
| 我们的数据是"3.6 布局 + 3.8 风格 type 6"的混合体 | `_analysis\spine_skel_to_json.py`：按 spine-libgdx **3.6** `SkeletonBinary.java` 移植（IK timeline 只读 mix+bend），但 `ATT_CLIPPING = 6` 且按 3.8 布局读 `endSlotIndex(int)+vertices+color`；628/628 EOF 精确对齐 | A（本地实测） |
| `.skel` 版本头确实是 `3.6.53E`（厂商自定义后缀） | `FrenzyBoar101.skel` 前 80 字节 hexdump：28 字节 hash + `07 "3.6.53E"` | A（本地实测） |

**推论**：厂商把 3.8 的"二进制 type 6 clipping"回填进了自改的 3.6.53 导出器，并把编辑器版本串改成 `3.6.53E`（E = 他们的定制版标记，另一批数据可能是 D）。因此：
- 官方 **3.6 二进制读取器**遇到 type 6 → 未知类型报错（本地 `spine.md` 亦记录 "3.6 spine-c 只认 0–4"，该结论对**二进制**成立；但其"clipping 3.8 才引入"的表述不准确，以本文为准）；
- 官方 **3.8 二进制读取器**认 type 6，但版本串是 `3.6.53E`、且 3.6→3.8 的 timeline 布局有差异 → 不能直接读；
- **唯一稳的路径 = 自己解析 → 产出 3.6 世代 JSON（保留 clipping 附件）→ 交给 3.6 世代运行时**。本地转换器已把这个解析做完了（628/628），这就是我们最大的既有资产。

---

## 3. 三条备选路线评估（Q3，重点）

### 路线 B（推荐）：WebView + 官方 spine-ts 3.6
**技术事实（源码级）**
- 官方 `spine-runtimes` 仓库 **3.6 分支的 `spine-ts/build/` 里有预编译产物**（不需要 Node/TS 工具链）：
  - `spine-core.js` 299,442 B；`spine-webgl.js` 343,374 B（3.6 分支实测存在）<https://github.com/EsotericSoftware/spine-runtimes/tree/3.6/spine-ts/build>
- 3.6 的 `SkeletonJson` 认 `"type":"clipping"`（commit `778055a`），渲染端有完整 `SkeletonClipping`（CPU 裁剪，支持凹多边形分解）→ **我们的 JSON 里的 clipping 会被正确解析并裁剪**。
- 我们的 JSON 是**按 3.6 JSON 语义生成**的（`skins` 为 object、动画 timeline 用 3.6 键名、`"spine":"3.6.53"`），与 3.6 运行时 schema 对齐；本地已验证"官方 spine-ts 3.6 能逐帧算出骨骼"（`_Stage0_ViewerReady\FrenzyBoar101\README.txt` 原文："converted from binary, verified with official spine-ts 3.6"）。
- 注意：3.6 运行时**不能**直接吃 `.skel`（type 6 不在枚举里），**必须走 JSON**；JSON 体积约为 skel 的 4 倍（实测 FrenzyBoar：skel 491,776 B → JSON 2,048,589 B），但 JSON 可以 gzip（文本压缩率通常 5–8×）或构建期预压缩，实际网络/磁盘开销可接受（单角色约 0.3–1.5MB gzip）。

**Flutter 侧接入**
- 插件二选一：
  - `flutter_inappwebview` **6.1.5**（2024-10-08；SDK `^3.5.0`、Flutter `>=3.24.0`）<https://pub.dev/packages/flutter_inappwebview>；
  - `webview_flutter` **4.14.1**（2026-07-07；Dart `^3.10.0`、Flutter `>=3.38.0`）<https://pub.dev/packages/webview_flutter>。本机 Flutter 3.47.5 两者都可解析。
- 本地资源加载两条成熟方案：
  1. **InAppWebView 资产模式**：`initialFile`/`WebViewAssetLoader` 直接加载 Flutter asset 里的 `index.html` + JS + 角色数据；
  2. **内置 `dart:io HttpServer`（推荐）**：App 内起 `127.0.0.1:<随机端口>`，从 app 私有目录/侧载目录 serve `index.html`、`spine-core.js`、`spine-webgl.js`、`.json`、`.atlas`、`.png`，WebView 加载 `http://127.0.0.1:port/`。好处：绕开 `file://` 的跨域/纹理加载限制；天然支持"用户侧载 1.48GB 资产库"按需读取；支持 HTTP Range/缓存；端口随机 + 只监听 loopback 保证安全。
- 增量与性能：
  - APK 增量约 **+0.6–1.2MB**（spine-core.js + spine-webgl.js + 自写 viewer/loader + Flutter 插件 native 代码；WebView 渲染器本身用系统 WebView，不占 APK）；
  - WebGL 渲染 900 附件/帧对 arm64 中端机无压力（单个 `drawArrays`/多次 batch，和原作手游同代技术栈）；clipping 是 CPU 裁剪，官方博客明确警告"clipping 可能非常昂贵，尤其配密集网格" → 需要按角色实测，必要时"低端机降到 30fps/关闭部分特效/预裁剪可疑页"；
  - 内存：WebView 渲染进程约 50–100MB + WebGL 纹理（见 §4）。
- 坑（要提前设计）：
  1. **WebView 是独立进程/合成层**：Flutter widget 不能叠在 WebView 内部（只能盖在外面）；触摸/手势需转发；截图需 `takeScreenshot`；
  2. 部分 ROM 的 WebView 版本过旧/被禁用（Android 7+ 系统 WebView 必有，但 GL 能力差异大），需启动自检 + 降级提示；
  3. WebGL context lost 恢复：spine-ts 3.6 已内置恢复逻辑（官方博客提到 WebGL/Widget 后端默认支持 context loss recovery），但要处理好重载；
  4. 字体/DPI/背景透明：WebView 透明背景需 `setBackgroundColor(Colors.transparent)` + HTML `body{background:transparent}`；
  5. 首帧冷启动 300–800ms（WebView 初始化 + JS 解析 2MB JSON），用"进度条 + 预加载上一角色"掩盖。

**工作量（估算，1 名熟 Flutter 的工程师）**
- MVP（单角色、3 个动作切换、侧载目录扫描、进度/错误提示）：**3–5 人日**；
- 产品级（多角色缓存、动作列表/循环/混合、缩放旋转、性能分级、异常兜底、截图导出）：**10–15 人日**。

### 路线 A（纯 Dart，不推荐"从零"，推荐 fork）
**已有基础（关键，别从零写）**
- `spine_core 0.3.5`：3.8 世代纯 Dart 运行时，含 `SkeletonClipping`/`ClippingAttachment`/`Triangulator`，**SkeletonJson 无版本校验**，能读我们的 3.6 JSON（推断，待实测）；
- `spine_flutter_dart 0.2.0`：基于 RenderObject 的 Flutter 渲染器（`SkeletonRenderObjectWidget`），可直接接 `spine_core` 的骨架数据 → 用 `Canvas.drawVertices` + 图集纹理绘制。
**必须做的工作**
1. fork 两个包，把 SDK 约束从 `<3.0.0` 改为 `>=3.0.0 <4.0.0`（Dart 3 语言版本兼容，2.17 空安全代码基本可直接编译，预计 0.5–1 人日修 analyzer 报错）；
2. 渲染器补/验 clipping：`SkeletonClipping.clipTriangles()` 输出裁剪后的顶点/三角形，逐批次 `drawVertices`（期望 2–4 人日；若 `spine_flutter_dart` 已实现则只需验证）；
3. 性能：合并绘制批次（按纹理页 + blend mode 分组）、避免每帧分配、`PictureRecorder` 缓存静态部件；目标 60fps@中端 arm64（**未验证**，风险最高项）；
4. 资产管线：`.skel→JSON` 放到构建期/首启（Dart 版二进制解析器需另写，或复用 Python 脚本离线转好——推荐"离线转 + App 只读 JSON"）；
5. 纹理管理：见 §4（4096 页降采样）。
**代价**：首版 **8–15 人日**；产品级 **15–25 人日**；若真从零写解析器+渲染器则 **25–40 人日**（不推荐）。
**收益**：无 WebView、无额外进程、可深度定制（做"骨骼线稿/换装/动作混合"更自然）、APK 增量几乎为 0；
**代价/风险**：两个包 3 年无维护（无社区兜底）、性能全靠自己调、Dart 版没有二进制解析器、clipping 密集网格在全 CPU 路径上可能掉帧（官方警告 clipping 昂贵）。

### 路线 C：构建期烘焙（只适合缩略图/兜底）
**已有雏形（本地实测）**：`_work\render_test\idle.gif` 401,594 B + `idle_0000..0039.png`（40 帧 × ≈55KB）；`_work\render_tmp\idle_battle_front_frames.json` 等 6 个动作的逐帧数据 → 说明"渲染成帧序列/动图"的管线在本机已跑通过。
**体积估算（按 512×512 画布、RGBA）**
| 形式 | 60 帧/动作 | 10 动作/角色 | 说明 |
|---|---|---|---|
| PNG 序列 | ≈3.3MB | ≈33MB | 无损但太大 |
| 动画 WebP（q80） | ≈1.5–2.4MB | ≈15–24MB | 支持 alpha，推荐 |
| 精灵表 PNG + `drawAtlas` | ≈2–4MB | ≈20–40MB | 播放最省 CPU，需按动作打包 |
| HEVC/H.264 视频 | 0.5–1.5MB | 5–15MB | H.264 无 alpha（需 HEVC+alpha/VP9），seek/循环麻烦 |
- 单角色 15–25MB × 4 角色 = 60–100MB，**APK 会从 40MB 涨到 100–140MB**；且动作时长 p90 3s、max 42.67s，长动作帧数爆炸。
**保真度**：锁死分辨率/镜头/皮肤/武器；无法运行时换装、无法任意动作叠加、无法骨骼交互；帧率受烘焙帧率限制（30fps 才能压体积）。
**结论**：只用于**列表缩略图**（每角色 1 张 512px WebP，几十 KB）或**低端机兜底播放**；不作为主方案。

---

## 4. Android 大图集纹理内存（Q4）

**算账（问题核心）**
- Flutter 把图片解码成 RGBA8888：**4096×4096 = 64 MiB/页**（还没算上传 GPU 时的临时拷贝，峰值可能 2×）。
- 我们数据：单角色 1–3 页、最大页 4096×4096；`spine.md` 统计 3425 页中 2578 页有一边 ≥2048，其中含 4096×2048 与 4096×4096。
- 极端情况：3 页全 4096² → **192 MiB 解码内存 + ~192 MiB 显存**，低端 3GB/4GB 机（单应用堆 256–512MB、GPU 共享内存）直接 OOM/掉帧。
- 结论：**在 App 内必须降采样**。建议 viewer 用 **≤2048 边长**（2048² = 16 MiB/页，3 页 ≈ 48 MiB，可接受）；显示尺寸一般 <1080p 宽，2048 页足够清晰（图集页是"sprite sheet"，缩到一半仍 ≥1x 显示）。实现：`ui.instantiateImageCodec(bytes, targetWidth: 2048)` 或 `ResizeImage`，并配合 `imageCache.maximumSizeBytes`（默认 100MB 也要调小）、切角色时 `imageCache.clear()`。

**设备/引擎上限**
- OpenGL ES 2.0 规范只保证 `GL_MAX_TEXTURE_SIZE ≥ 2048`（GLES3 同样下限 2048；Vulkan 才保证 4096）。minSdk 24 覆盖的老 GPU（尤其 GLES2 机型）**可能只有 2048 上限**，4096 页会上传失败（表现为贴图空白/黑块，Flutter 层不报错，很难查）。→ 4096 页在低端机上属于"不可靠"，必须降采样或按页拆图。
- 引擎差异：本机 Flutter **3.47.5**，Android 上 **Impeller 已是默认渲染器**（官方文档 <https://docs.flutter.dev/perf/impeller>；Impeller 在 Android 走 Vulkan，设备/驱动不支持时按 Flutter 版本回退，具体回退策略随版本变化——**本机 3.47.5 需实测确认**）。Impeller 下大图集的纹理分配/采样行为与 Skia(GLES) 不同，已知 3.27 时代有"Impeller 下 spine 画面质量下降"的官方 issue（`#2719`，已修复）；若遇到花屏/模糊，优先试：`FilterQuality.medium`、关闭 mipmap、`--no-enable-impeller` 对比。
- 另一条现实约束：**Flutter 没有"按需部分上传"**，`ui.Image` 一次性全解；图集页不能像原生游戏那样做 streaming，所以"只加载当前角色 + 降采样 + 及时释放"是唯一稳的策略。
- 若走路线 B（WebView）：WebGL 纹理同样吃显存（4096² RGBA ≈ 64MiB/页），但 WebView 进程独立、OOM 时是"渲染进程被杀"而不是主 App 崩溃；仍需在 HTML 侧检查 `gl.getParameter(gl.MAX_TEXTURE_SIZE)` 并降采样。

---

## 5. 许可证（Q5）

**现行 Spine Runtimes License Agreement（2025-04-05 版）** <https://esotericsoftware.com/spine-runtimes-license> 原文要点：
> "Integration of the Spine Runtimes into software or otherwise creating derivative works … is permitted under the terms and conditions of **Section 2 of the Spine Editor License Agreement**; Otherwise, it is permitted … provided that **each user of the Products must obtain their own Spine Editor license** and redistribution of the Products in any form must include this license and copyright notice."

- 用 **spine_flutter / flame_spine / spine-ts / spine_core / spine-flutter-dart** 都受这份（或其历史版本）协议约束；**加载 3.6 数据不需要"3.6 版运行时授权"，但"把运行时集成进 App"这件事本身需要 Spine 编辑器授权（分发场景下还要求每个用户各自持有授权）。**
- 现状定性：
  - **纯个人自用、不发布**：属于协议里的 personal/internal use 范畴，风险最低（历史上 v2.5 明确允许 personal/internal，现行版本通过 Section 2 也覆盖）。**结论：可以自用。**
  - **任何形式分发（含发群、发网盘、上第三方商店）**：需要解决 ①Spine Editor 授权（每个用户各持一份，实操上意味着"你自己得有、且不能替用户获得"）、②**游戏美术资源版权**（这是 SAO 手游的资产，与 Spine 授权无关，分发即侵权）。本项目 APK 里已内置 Frida 注入器 59MB，明显不走商店、属灰色自用工具——但"自用"和"分发"必须区分，建议**只做本机使用，不公开分发含资产/运行时的 APK**。
  - 若坚持分发：更干净的做法是**用户自备资产 + 用户自备/自行拉取运行时**（App 只当播放器，运行时从本地或用户可替换的 bundle 加载），但这会显著增加工程复杂度，不建议现在做。
- 额外注意：`spine_core`/`spine_flutter_dart` 的 LICENSE 是**旧版 v2.5**（"may not modify, translate, adapt… create derivative works… solely for personal or internal use"）。fork 修改这两个包**在 v2.5 下是明确禁止的**——这给路线 A 增加了法务不确定性（个人自用、不分发时实践风险低，但不等于"合规"）。路线 B 用官方 3.6 分支代码（同属 v2.5 时代，但发行协议已更新到 2025 版），且在不开源、不分发的情况下同为 personal use。
- 一句话结论：**能做，个人自用风险低；分发型产品在 Spine 授权 + 游戏美术版权两条线上都过不了，别做。**

---

## 6. 推荐方案（明确到"能不能做、代价多少"）

### 6.1 推荐：路线 B（WebView + 官方 spine-ts 3.6），A 作为二期
**为什么是 B**
1. 数据是"3.6 布局 + 3.8 风格 clipping"的混合体，**只有 3.6 世代运行时能同时吃下"3.6 JSON schema"和"clipping 材质"**（3.6 源码实锤：SkeletonJson 认 clipping、SkeletonClipping 完整）；4.x 版本对不上，3.8 二进制对不上。
2. 工作量最小、保真度最高：官方运行时 + 官方 CPU clipping，不用自己实现裁剪/网格/皮肤。
3. APK 增量 ~1MB，可接受（现有 40MB）；WebView 是系统组件，不引入 20–30MB 的 spine-cpp 原生库（spine_flutter 的 FFI 方案在 arm64 上会给每个 ABI 加几 MB native 库，且要重新编译 spine-cpp）。
4. 与现有工程解耦：新增 `assets/spine_viewer/`（HTML+JS）+ 一个 `dart:io HttpServer` 服务 + 一个页面，不动现有代码结构。

**MVP 落地步骤（3–5 人日）**
1. **数据打包脚本**（离线，Python 复用现有 `spine_skel_to_json.py`）：选 1–2 个演示角色 → `.skel → .json`（保留 clipping `end` 槽名）→ 拷贝 `.atlas` + PNG 页 → 生成 `manifest.json`（角色/动作/页清单）→ 输出到 `assets/spine_preview/<char>/`。
2. **viewer 页面**：`index.html` + `viewer.js`，引入 3.6 的 `spine-core.js` + `spine-webgl.js`（从官方 3.6 分支 `spine-ts/build/` 取），实现：加载 manifest → 选角色/动作 → requestAnimationFrame 播放 → 缩放/拖拽 → 通过 JS bridge 回报状态。
3. **Flutter 接入**：`dart:io HttpServer`（loopback、随机端口、路径白名单）serve 私有目录 + assets；`flutter_inappwebview 6.1.5` 或 `webview_flutter 4.14.1` 加载 `http://127.0.0.1:<port>/index.html`；页面里放动作下拉/播放控制（或 Flutter 外层控制 + JS bridge）。
4. **资产策略**：APK 只内置 1–2 个演示角色（≈1–3MB）；其余 1.48GB 资产库由用户侧载到 app 私有目录（`/data/data/<pkg>/files/spine_assets/` 或 `Android/data/...`），App 启动时扫描 manifest 按需加载、LRU 缓存、离开页面释放。
5. **性能/内存**：4096 页降采样到 2048（或在 HTML 侧 `gl.MAX_TEXTURE_SIZE` 检测后降采样）；WebGL 纹理显存按角色计；低端机降 30fps。

**二期（可选）：路线 A 的"原生化"**
- 当出现以下任一情况时再上 A：WebView 内存在低端机不可接受 / 需要 Flutter 内嵌交互（骨骼叠加、换装 UI 直接在画面上）/ 需要离屏截图批量导出。
- 起点：fork `spine_core 0.3.5` + `spine_flutter_dart 0.2.0`，改 SDK 约束，补 clipping 渲染，8–15 人日。

### 6.2 验收标准（可直接当 checklist）
- [ ] 单角色（≥189 骨、≥1 页 4096）idle_battle/attack/victory 三个动作实时播放 ≥30fps（中端 arm64 真机，Flutter profile 模式）
- [ ] 含 clipping 的骨架（从 432/628 里抽 3 个）画面无"该裁未裁"的穿插
- [ ] 冷启动到首帧 ≤2s；切角色 ≤1s；返回/退出后内存回落（无泄漏）
- [ ] 4096 页设备兼容：GLES2 仅 2048 上限的机型上不黑屏（降采样生效）
- [ ] APK 增量 ≤2MB；内置演示角色 ≤3MB
- [ ] 无网络权限也能播放（全本地）

---

## 7. 未验证清单（如实标注）
| # | 待验证项 | 影响 | 建议验证方式 |
|---|---|---|---|
| 1 | spine-ts **3.6** 运行时加载我们转换后**含 clipping** 的 JSON 能否完整渲染 | 路线 B 核心假设 | 抽 3 个含 type 6 的骨架转 JSON，在 Node/Chrome 里用 3.6 `spine-webgl.js` 跑一帧截图比对 |
| 2 | `spine_core 0.3.5` 的 SkeletonJson 是否 100% 接受我们的 JSON（无版本校验是源码事实，但字段兼容性未实测） | 路线 A 可行性 | fork 后写个 `dart run` 加载 10 个 JSON，对比骨矩阵/时长 |
| 3 | `spine_flutter_dart 0.2.0` 是否实现 clipping 渲染 | 路线 A 工作量 | 读 `SkeletonRenderObject.paint()` 源码 |
| 4 | 纯 Dart 路线在 200 骨/900 附件下的 60fps 能力 | 路线 A 风险 | 真机 profile 跑帧率 |
| 5 | 本机 Flutter 3.47.5 + Impeller 下大图集（4096）表现 | 纹理策略 | 真机分别测 Impeller `--no-enable-impeller` |
| 6 | 厂商 `3.6.53E` 的 clipping 是否严格等于 3.8 布局（我们已按 3.8 布局解析并对齐 EOF，但"语义"层面未比对官方 3.8 实现） | 渲染正确性 | 用 3.8 运行时读同结构 JSON 对比裁剪形状 |
| 7 | 本地渲染管线（`render_test/idle.gif`）用的具体渲染器 | 路线 C 复用性 | 查 `_work` 下相关脚本/日志（本次未追） |

---

## 8. 引用与证据索引
**官方文档/源码**
- pub `spine_flutter`（4.3.6，2026-07-09）：<https://pub.dev/packages/spine_flutter>；API 元数据：<https://pub.dev/api/packages/spine_flutter>
- 官方 spine-flutter 文档（版本必须对齐、pma 不支持、支持的平台/特性）：<https://esotericsoftware.com/spine-flutter>
- pub `flame_spine`（0.3.1+6，2026-07-19）：<https://pub.dev/packages/flame_spine>
- pub `spine_core`（0.3.5，2022-11-28）+ 文档（ClippingAttachment/SkeletonClipping 等类）：<https://pub.dev/packages/spine_core>、<https://pub.dev/documentation/spine_core/0.3.5/spine_core/>
- spine_core `SkeletonJson` 源码（无版本校验、认 `clipping`/`end`、兼容 skins object/list）：<https://github.com/jtakakura/spine_core/blob/main/lib/src/skeleton_json.dart>
- pub `spine_flutter_dart`（0.2.0，2022-12-04；SkeletonRenderObjectWidget）：<https://pub.dev/packages/spine_flutter_dart>
- 官方《Versioning》"major.minor 必须一致"：<https://esotericsoftware.com/spine-versioning>
- 官方《Spine Runtimes License Agreement》（2025-04-05）：<https://esotericsoftware.com/spine-runtimes-license>
- 官方 Changelog（含 clipping 相关条目、4.3.27 未发布/4.3.26 2026-09-07）：<https://esotericsoftware.com/spine-changelog>
- 官方博客《Spine 3.6 - Tint black, clipping, weight painting, and more!》（2017-06-19，"clipping 引入 + 所有运行时支持"）：<https://esotericsoftware.com/blog/Spine-3.6-tint-black-clipping-weight-painting-and-more>
- 3.6 分支 `spine-ts/build/`（预编译 spine-core.js 299KB / spine-webgl.js 343KB）：<https://github.com/EsotericSoftware/spine-runtimes/tree/3.6/spine-ts/build>
- 3.6 分支 `SkeletonClipping.ts`（完整 CPU 裁剪）：<https://github.com/EsotericSoftware/spine-runtimes/blob/3.6/spine-ts/core/src/SkeletonClipping.ts>
- commit `778055a`（3.6 加入 ClippingAttachment + SkeletonJson 加载，2017-04-11）：<https://github.com/EsotericSoftware/spine-runtimes/commit/778055ae5bda29305652b0956bd3ae5d410a6a78>
- 3.6 的 `AttachmentType`（无 Clipping）：<https://github.com/EsotericSoftware/spine-runtimes/blob/3.6/spine-ts/core/src/attachments/AttachmentType.ts>；3.8 的（有 Clipping）：<https://github.com/EsotericSoftware/spine-runtimes/blob/3.8/spine-ts/core/src/attachments/AttachmentType.ts>
- WebView 插件：`flutter_inappwebview 6.1.5` <https://pub.dev/packages/flutter_inappwebview>；`webview_flutter 4.14.1` <https://pub.dev/packages/webview_flutter>
- Flutter Impeller 文档：<https://docs.flutter.dev/perf/impeller>
- spine_flutter Android/Impeller 相关 issue：<https://github.com/EsotericSoftware/spine-runtimes/issues/2719>、<https://github.com/EsotericSoftware/spine-runtimes/issues/3038>、<https://github.com/EsotericSoftware/spine-runtimes/issues/2849>
- GLES2 纹理上限（2048 下限，二手资料）：<https://stackoverflow.com/questions/9072764/minimum-required-texture-size-for-compliance-with-opengl-es-2-0-on-android>

**本地证据（只读）**
- `C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine\_Stage0_ViewerReady\FrenzyBoar101\README.txt`（"verified with official spine-ts 3.6"；atlas pma 空、Linear）
- 同目录 `FrenzyBoar101.skel` 头 80 字节（hash + `3.6.53E`）、`FrenzyBoar101.json`（`"spine":"3.6.53"`，skel 491,776 B → JSON 2,048,589 B）
- `C:\Users\Administrator\Desktop\解包\_analysis\spine_skel_to_json.py`（3.6 `SkeletonBinary.java` 移植；`ATT_CLIPPING=6` 按 3.8 布局读 `endSlotIndex+vertices+color`；剥离版本后缀；628/628 EOF）
- `C:\Users\Administrator\Desktop\解包\_analysis\spine.md`（432/628=69% 含 type 6；骨骼中位 189、动画中位 11、时长 p90 3.0s/max 42.67s）
- `C:\Users\Administrator\Desktop\解包\_work\render_test\idle.gif`（401,594 B）+ `idle_0000..0039.png`（40 帧 × ≈55KB）；`_work\render_tmp\*_frames.json`（6 个动作）
- `C:\Users\Administrator\Desktop\解包\_work\spine_help.txt`（本机 Spine Launcher 3.8.75，支持 `-u <version>` 拉取指定版本）
- 本机 Flutter `3.47.5` / Dart `3.13.4`（`E:\env\flutter\version`、`E:\env\flutter\bin\cache\dart-sdk\version`）；pub 缓存无相关包

---
*调研人：runtime-researcher（task-2）；时间：2026-10-25；未修改任何代码/资产。*
