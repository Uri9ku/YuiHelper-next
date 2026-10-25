# 把 Spine 骨骼动作实时渲染内置进 App —— 集成架构与工期方案

> 分工定位：本文件是 **task-3 / app-integrator（集成架构分析员）** 的证据底稿。四个角色的分工、产出清单与交叉校正记录见主报告 [可行性分析_APP内实时渲染Spine动作.md](可行性分析_APP内实时渲染Spine动作.md) **§十二**。

> 任务：task-3（集成架构分析员）｜只读分析 `C:\Users\Administrator\Desktop\YuiHelper`（旧版）与
> `C:\Users\Administrator\Desktop\YuiHelper-next`（新版）｜产出：本文件
> 分析时间：2026-10-25｜本文件是本次唯一写入的文件，两个工程与资产库均未改动（未 pub get / 未 build / 未跑 flutter 命令）

---

## 0. 结论先行（TL;DR）

| 问题 | 结论 | 一句话依据 |
|---|---|---|
| 旧版有没有现成 Spine 渲染？ | **有，而且是纯 Dart 自研**（不是 spine_flutter / 不是 flame / 不是 WebView） | `YuiHelper/lib/data/spine/spine_binary.dart`（830 行二进制解析器）+ `lib/presentation/model_swap/preview/spine_painter.dart`（`drawVertices` 蒙皮渲染），真机截图 `docs/spine-render/device-wireframe.png` |
| 能复用吗？ | **能，复用度很高（约 80% 的"渲染前半程"已经写完并验证过）** | 旧版 11 个文件 2433 行；`pubspec.yaml` 只有 1 个第三方依赖（`flutter_overlay_window`），Spine 部分零依赖；解析器 300/300 份真实骨骼"恰好读完"，真机一次画出 215 个部件 |
| 缺的是什么？ | **只缺"动画"**：时间轴当前是 `skip` 不是 `read`；约束（IK/transform/path）也只 skip | `spine_binary.dart:640-649`（`_skipAnimations`）、`:651-770`（`_skipAnimationBody`）、`:411-466`（三类约束 skip）；`docs/spine-render/README.md:18` 明写"动画回放 ❌ 未实现" |
| 新版接在哪？ | E 修改模型页的"模型预览卡"（现在是**假线稿**）→ 换成真渲染；再加一个全屏动作预览页 + 一个素材库页 | `lib/ui/screens/model_swap_screen.dart:763-860`（预览卡）、`:1117-1210`（`_BonePainter` 硬编码火柴人，`:857-859` 自述"示意占位"） |
| 推荐哪条路线？ | **两条都成立，按"先能看、再干净"排序**：B（WebView + 官方 spine-ts 3.6，3~5 人日首版）先打通；A（纯 Dart，复用旧版二进制解析器）二期原生化。**不建议从零写渲染器，也不建议走 4.x 迁移**。详见 §5.4 与 §12（与 task-2 调研的交叉核对） | 见 §5 |
| 1.48GB 能打进 APK 吗？ | **不能，也不该**。只内置 1-2 套演示（1.7~8MB）+ 清单；其余走**分级侧载**（用户放 `/sdcard`，root 复制/按需解包到私有目录） | 614 套角色服装合计 740.8MB（中位 0.95MB/套）；APK 已 39.95MB，其中 59MB 注入器压到 23.92MB |
| 最大风险 | ①"全角色动作"不成立：628 份离线骨架里**只有 19 份**具备完整战斗 6 件套、123 份有 `idle_battle`；②69% 骨架含二进制 clipping(type 6)，官方 3.6/3.8 的**二进制**读取器都不认 → 必须先转 3.6 JSON（JSON 路径保真，见 §4.3）；③4096×2680 贴图全分辨率 RGBA = 43.9MB/页，minSdk 24 低端机必爆；④B 路线要把 JSON 交给 WebView，而 JSON 比 `.skel` 大 4~20 倍（最大 43.6MB） | §4.2、§4.3、§4.4、§5.2 |

**一句话**：这不是"从零做一个 Spine 渲染器"，而是"把旧版已经跑通的解析+蒙皮渲染搬过来，补上动画时间轴与播放层，再把素材做成可侧载的分级资产"。真正的工程量在**动画运行时**和**资产工程**，不在渲染本身。

---

## 1. 任务边界与证据等级

- 只读：两个 Flutter 工程 + `C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine` + `C:\Users\Administrator\Desktop\解包\_analysis`（离线渲染脚本）。
- 未执行任何会改状态的命令：无 `pub get`、无 `build`、无 `flutter` 命令、无写资产。
- 证据等级标注：
  - **[实测]** = 本次亲自读文件/量体积/读字节得出；
  - **[转引]** = 引用工程内已有文档/脚本的结论（给路径行号）；
  - **[推断]** = 由数据推导、未实测。
- 并行的 task-1（资产审计）与 task-2（运行时调研）产出的数字如与本文件有出入，以那两份的一手审计为准；本文件的数字均可复现（命令见 §10）。

---

## 2. 第 1 问：旧版 YuiHelper 的 Spine 预览实现（考古，最关键）

### 2.1 结论表

| 维度 | 结论 | 证据（文件:行） |
|---|---|---|
| 有没有 Spine 预览 | **有，已真机验证** | `YuiHelper/README.md:102-129`；截图 `docs/spine-render/device-wireframe.png`（215 部件 / 226 骨 / 351 网格） |
| 实现方式 | **纯 Dart 自研**：自写 `.skel` 二进制解析器 + 自写 bind pose 蒙皮 + `Canvas.drawVertices` | `lib/data/spine/spine_binary.dart:6-21`、`lib/data/spine/skeleton_pose.dart:74-183`、`lib/presentation/model_swap/preview/spine_painter.dart:191-291` |
| 是不是 spine_flutter / flame / WebView | **都不是**。`.dart_tool/package_config.json` 的包列表里没有 spine/flame/webview；`pubspec.yaml` 只有 `flutter` + 1 个 `flutter_overlay_window` | `YuiHelper/pubspec.yaml:30-39`；`YuiHelper/.dart_tool/package_config.json`（25 个包，全部 Flutter SDK 自带 + overlay） |
| 入口 | 换模型页 `_previewSection()` → `SpinePreviewCard` → `CustomPaint(SpinePainter)` | `lib/presentation/model_swap/model_swap_screen.dart:781-836`；`preview/spine_preview_card.dart:88-116` |
| 帧率 / 动画 | **没有动画，也没有帧率概念**：只画 bind pose（静止姿势），`CustomPainter` 按需重绘一次，没有 `Ticker`/`AnimationController` | `docs/spine-render/README.md:18`；`spine_preview_card.dart:35-117`（State 里只有 `_skin`、`_showWireframe` 两个状态） |
| 支持的动作 | **0 个**。动画段只统计数量与名字，内容整体跳过 | `spine_binary.dart:640-649`、`:225-228`、`:269-271` |
| 用了哪些资产 | `.skel` + `.atlas`（LibGDX 文本）+ 纹理（`.pkm` ETC1/ETC2 或 `.png`） | `spine_preview.dart:1-16`、`spine_asset_library.dart:12-38` |
| 是否已内嵌 skel/atlas/png | **没有**。APK 内 `assets/` 只有注入器/JSON/JS/TSV；Spine 素材由用户放 `/sdcard/YuiHelper/spine/`，首次进页面时借 root 复制到私有目录 | `YuiHelper/pubspec.yaml:72-80`；`spine_asset_library.dart:50-54`、`:66-84` |
| fallback | 有，且是"诚实型"：缺纹理 → 写"骨骼已解析，但缺纹理"并列出缺的文件名；没素材 → "还没有模型素材"；解析失败 → 写原因。**不画假模型** | `spine_preview_card.dart:57-71`；`docs/spine-render/README.md:142` |
| 渲染能力边界 | 单皮肤、bind pose；线框模式；**不画** linked mesh / path / point / bbox / clipping；不做 blend mode 分组、不做 drawOrder 动画 | `spine_painter.dart:83-121`（只处理 mesh 与 region）、`spine_binary.dart:518-527`（linked mesh 只记名字）、`:529-552` |

### 2.2 关键文件清单（这就是要搬的东西）

| 文件 | 行数 | 职责 | 移植难度 |
|---|---:|---|---|
| `lib/data/spine/spine_binary.dart` | 830 | Spine 3.6.53 二进制解析（头/骨骼/插槽/约束/皮肤/附件/动画跳过） | ★★☆ 直接搬；动画段要"skip → read" |
| `lib/data/spine/skeleton_pose.dart` | 176 | bind pose 世界变换 + 骨骼权重蒙皮 + 区域四角 | ★★☆ 要扩展成"可施加动画姿态" |
| `lib/data/spine/spine_preview.dart` | 149 | 骨骼+图集+纹理 → 可渲染对象 | ★☆☆ 直接搬 |
| `lib/data/spine/spine_asset_library.dart` | 175 | 目录批量加载、缓存、PKM 解码、root 同步 | ★★☆ 要改成新的资产存储层 |
| `lib/data/spine/atlas_variant.dart` | 46 | 从 `imagesPath` 推图集变体名 | ★☆☆ 直接搬 |
| `lib/data/assets/texture_atlas.dart` | 233 | LibGDX `.atlas` 文本解析（多页/rotate） | ★☆☆ 直接搬 |
| `lib/data/assets/etc2.dart` | 219 | ETC2 RGBA8 → RGBA8（纯 Dart） | ★☆☆ 直接搬（贴图已是 PNG 时非必需） |
| `lib/presentation/model_swap/preview/spine_painter.dart` | 235 | `SpineBinder` + `SpinePainter`（`drawVertices` + `ImageShader`） | ★★☆ 要改：按图集页合批、每帧重绘、blend 分组 |
| `lib/presentation/model_swap/preview/spine_preview_card.dart` | 264 | 预览卡 UI（皮肤下拉 / 线框 / 缺纹理说明） | ★★☆ 要加播放控制 |
| `lib/presentation/model_swap/preview/atlas_painter.dart` | 71 | `rgbaToImage` + 区域绘制 | ★☆☆ |
| `lib/presentation/model_swap/preview/atlas_sprite_view.dart` | 35 | 单区域显示 | ★☆☆ |
| **合计** | **2433** | | |

配套验证资产（可直接复用为新工程的验收工具）：

- `tool/spine_verify.dart:1-82`：批量解析 + `consumedBytes == 文件长度` 判据（旧版跑出 300/300）。
- `tool/spine_pose_check.dart` / `tool/spine_variant_check.dart`：包围盒 / 变体名推断校验。
- `test/spine_binary_test.dart`：**19 个合成样本用例**（手工拼 `.skel` 字节，不依赖游戏资源，任何机器能跑）。
- `test/spine_render_e2e_test.dart`、`test/spine_wireframe_test.dart`、`test/spine_render_png_test.dart`：真实资源端到端（缺资源自动 skip）。
- 真机截图证据：`docs/spine-render/device-wireframe.png`（本次已目视确认：226 骨 / 351 网格 / 215 部件，人形三角网格清晰）、`device-textured.png`、`device-missing-texture.png`。

### 2.3 旧版已踩过、新工程可以直接跳过的坑（价值最高的一段）

来自 `docs/spine-render/README.md:26-113` 与 `docs/PROGRESS.md:42-54`，均为 [转引] + 代码可对照：

1. **每个附件有两个名字**（skin 层 placeholder + 附件自身 name，后者可为 null）。少读一个，skin 区第一个附件就错位。`spine_binary.dart:476-482`。
2. **事件段没有 audio/volume/balance**（3.8+ 才有）。多读 8 字节后面整段动画错位——旧版修之前只过 239/300。`spine_binary.dart:625-638`。
3. **命名皮肤没有 bones/ik/transform/path 计数段**（3.8 才加）。`spine_binary.dart:332-337`。
4. **头部可能没有 audio 字段**，用"读完 audio 后骨骼区是否合法"回退判定。`spine_binary.dart:306-321`、`:798-817`。
5. **世界变换是行主序**（`a,b` 是 x 行，`c,d` 是 y 行）。按教科书列主序写会让所有顶点 Y=0、角色被拍扁成一条线，**且不报错**。`skeleton_pose.dart:39-52`、`:107-123`。
6. **UV 必须按解码后图像真实尺寸换算**，不能信 atlas 声明尺寸（ETC 按 4 对齐，声明 4096×2310、实际 4096×2312）。`spine_painter.dart:33-43`。
7. **clipping(type 6) 的字段顺序**是 `endSlotIndex → vertexCount → vertices → color`，反了就错位。`spine_binary.dart:547-552`。
8. **分区存储**：App 读不到 `/sdcard`，且 `cp -a` 会把别人的属主/权限搬进私有目录导致"自己读不了自己的文件"，必须 `chown -R`。`spine_asset_library.dart:56-84`。

### 2.4 旧版"没有"的部分（= 本次要新写的）

| 缺口 | 现状 | 影响 |
|---|---|---|
| 动画时间轴读取 | `_skipAnimationBody` 只跳过（布局已完全摸清） | 没有动画可播 |
| 曲线求值（linear/stepped/bezier） | `_skipCurve` 只跳过 | 动画会变成跳帧 |
| IK / transform / path 约束 | 数据被 skip，无求解器 | 脚踩地、手部对齐会错；部分动作明显失真 |
| deform 时间轴 | skip | 网格形变（布料/肌肉）不生效 |
| drawOrder 时间轴 | skip | 换武器/特效遮挡顺序会错 |
| slot 颜色/附件切换时间轴 | skip | 换装、表情、武器切换不生效 |
| linked mesh 解析 | 只记名字，不画 | 命名皮肤里只有 linked mesh 的部件会缺（旧版用"只列 meshCount>0 的皮肤"绕开，`spine_preview_card.dart:169-171`） |
| clipping 遮罩 | 解析但丢弃 | 头发/眼睛等遮罩区域会露出来（433 个附件 / 628 骨架中 432 份含 ≥1 个） |
| blend mode | slot 里读了 `blendMode`（`spine_binary.dart:397`）但渲染只用 `srcOver` | 发光/加色特效会变成普通混合 |
| 连续帧渲染 | 无 Ticker、无帧率数据 | **"能不能 60fps 连续渲染"是全新风险，旧版没有测过** |

> 这一点很重要：旧版证明了"**一帧**能画对"，没有证明"**每秒 60 帧**能画得动"。M1 的第一件事就是补这个测量。

---

## 3. 第 2 问：新版工程现状

### 3.1 构建参数（[实测]）

| 项 | 值 | 证据 |
|---|---|---|
| applicationId / namespace | `com.yuihelper.next` | `android/app/build.gradle.kts:8,19`；`build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`（`package="com.yuihelper.next"`） |
| minSdk | **24** | 同上 merged manifest `android:minSdkVersion="24"`（`build.gradle.kts:22` 用的是 `flutter.minSdkVersion`） |
| targetSdk | **36** | 同上 merged manifest `android:targetSdkVersion="36"` |
| ABI | **仅 arm64-v8a** | APK 内只有 `lib/arm64-v8a/`（`libflutter.so` 11.2MB、`libapp.so` 4.38MB） |
| 权限 | 只有 `INTERNET` + `usesCleartextTraffic`（访问 `127.0.0.1:18680`） | `android/app/src/main/AndroidManifest.xml:1-9` |
| 第三方依赖 | **0 个**（`pubspec.yaml` 只有 `flutter`；dev 只有 `flutter_test`） | `pubspec.yaml:9-17`；`.dart_tool/package_config.json` |
| 资源加载方式 | 只有 `rootBundle.load()`；落盘用 `Directory.systemTemp`（Android 上 = app cache）+ `su cp` 到 `/data/local/tmp` | `lib/data/model_swap_repository.dart:34-40`、`:127-204` |
| 有没有 WebView / 本地 HTTP 服务 / 图片缓存 | **都没有**。只有 HTTP 客户端（连游戏的 18680），没有 server、没有 webview 插件、没有 path_provider、没有磁盘缓存层 | `.dart_tool/package_config.json`；`lib/data/http_transport.dart` |

### 3.2 当前 APK 体积构成（[实测]，`dist/YuiHelperNext-v0.1.0-arm64.apk`）

| 组成 | 未压缩 | 压缩后 | 占比说明 |
|---|---:|---:|---|
| `assets/flutter_assets/assets/frida-inject` | 56.19 MB | **23.92 MB** | 占 APK 一半以上（60%） |
| `lib/arm64-v8a/libflutter.so` | 11.20 MB | 11.20 MB | 引擎 |
| `lib/arm64-v8a/libapp.so` | 4.38 MB | 4.38 MB | Dart AOT（当前全部业务代码） |
| `assets/skill_boards.json` | 0.28 MB | 0.02 MB | |
| `assets/model_bones.json` | 0.14 MB | 0.01 MB | |
| 其余（JSON/JS/TSV/shaders/fonts） | <0.1 MB | <0.05 MB | |
| **合计** | **72.98 MB** | **APK 文件 39.95 MB** | |

**结论**：APK 的绝对大头是注入器（不可压），业务代码只有 4.38MB。给 Spine 留的预算很宽裕——但要**克制**：内置 1 套演示角色（1.7~8MB）+ 清单（<0.5MB），APK 约 42~48MB，仍远小于"再塞一个 40MB 贴图包"。

### 3.3 E 修改模型页的"骨骼线稿"是假的（重要）

- `lib/ui/screens/model_swap_screen.dart:763-860`：预览卡（150dp 高）里 `CustomPaint(painter: _BonePainter())`，右上角 chip 写死 `'12 网格'`、底部写死 `'37 骨'`。
- `:1117-1210`：`_BonePainter` 是按 `design/model-swap.html` 的 120×168 比例**硬编码的火柴人**（头一个圆、脊柱一条线、四肢 6 条折线），与真实骨骼数据无关。
- `:857-859` 自己写明：**"线稿只画骨架结构（12 网格 / 37 骨），是示意占位，不是游戏内真实渲染。"**
- 设计稿本身要的是真预览：`design/model-swap.html:303-309`（"导入骨骼、图集与纹理后显示角色静止姿势"）、`:690-711`（预览卡的三种非正常态：缺纹理/解析失败/线框）、`:833`（`SpinePreviewCard` 画布 150、皮肤下拉 28、线框钮 28、mono 37 骨）。
- 新版 README 把这件事归到"旧 UI 能力，不接入"：`README.md:168`。

> **架构判断（本报告最重要的一条纠正）**：旧版 README 的目录树里，Spine 解析/渲染的**数据层在 `lib/data/spine/**`**（`YuiHelper/README.md:265-270`），`lib/presentation/**` 里只有"卡片 + painter"两个 UI 文件。新版 README 说"`lib/presentation/**` 与 Spine 模型预览渲染不接入"，**只否掉了 UI 层，没有否掉数据层**。数据层零依赖、无 UI 依赖，是可以整体搬过来的。所以"接入 Spine 预览"并不违反新版的迁移纪律。

### 3.4 `model_bones.json` / `model_skeletons_seed.json` 的真实用途

| 资产 | 结构 | 用途 | 对预览的价值 |
|---|---|---|---|
| `assets/model_bones.json`（150KB） | `{"variants": {"<图集变体名>": "chara_N", ...}}`，覆盖 `chara_1/2/3/4/chara_other`，键同时含 `xxx` 与 `xxx.pvrenc` 两种写法 | **换模型的"同骨架集"校验**（跨集互换会缺骨架/比例错乱）；UI 用它把 B 的候选限制在 A 的同一骨架集（`model_swap_screen.dart:275-278,383,408-436`） | **可直接复用为预览分组**：预览库按 `chara_N` 分组、按变体名索引素材目录，不用另建索引 |
| `assets/model_skeletons_seed.json`（329B） | `{"skeletons": {"chara_1": "f_chara_1_v0.4_sword"}}`，只有 1 条真机验证过的种子 | 跨骨架集互换时需要目标骨架集的**骨架文件名**；清单里没有，只能运行时学，这里先放种子 | 与预览基本无关；但提醒：**"骨架文件名"不在离线资产库里**，离线打包时要自己造名字（用 `imagesPath`/`atlas` 页名派生） |

其它相关资产：`names.tsv` 528 行（角色 id ↔ 中文名）、`model_pairs.json`（身体 id → 脸 id）。

### 3.5 新版集成落点（结论）

```
lib/
  data/spine/                    ← 【新增】从旧版整体移植（纯 Dart，零依赖，无 UI 依赖）
    spine_binary.dart            （830 行，type 0..6 全覆盖；动画段 skip→read）
    skeleton_pose.dart           （176 行；扩展为可施加动画姿态）
    atlas_variant.dart / spine_preview.dart / spine_asset_library.dart
    animation/                   ← 【新增】动画运行时
      timeline.dart               （时间轴数据 + 曲线采样）
      animation_state.dart        （播放/循环/混合/队列）
      constraints.dart            （IK / transform / path 求解）
    spine_asset_store.dart       ← 【新增】L0/L1 分级资产：扫描/侧载同步/解包/LRU
  data/assets/                   ← 【新增】texture_atlas.dart（233 行）、etc2.dart（219 行，可选）
  ui/spine/                      ← 【新增】
    spine_painter.dart           （移植 + 改：按图集页合批、blend 分组、每帧重绘）
    spine_preview_card.dart      （移植 + 改：动作下拉、播放/暂停/速度/循环）
    spine_animation_page.dart    （新增：全屏动作预览，横屏/双指缩放）
  ui/screens/
    model_swap_screen.dart       ← 【改】:763-860 把 `_BonePainter` 换成真实 `SpinePreviewCard`
    spine_library_screen.dart    ← 【新增】素材库/导入/存储统计（从设置页或工作台进入）
  backend.dart                   ← 【改】装配 `SpineAssetStore` + 注入 `AssetLoader`（测试可替身）
assets/spine/                    ← 【新增】L0 内置素材
  manifest.json                  （变体 → 骨架集/文件/页/动作/体积）
  demo/<variant>/                （1-2 套完整素材，1.7~8MB）
```

- **不需要新增 pub 依赖**（路线 A）。这保住了新版"零第三方依赖"的纪律，也保住了 `flutter analyze` / 126 个测试的现状。
- 预览卡保留设计稿的"三态不撒谎"（缺纹理/解析失败/线框），只是把占位线稿换成真几何。

---

## 4. 数据侧的硬事实（决定方案可行性的前提）

> 用户的前提是"已经拿到全角色 Spine 骨骼动作 + 贴图"。审计下来**骨骼和贴图基本成立，但"全角色都有战斗/移动动作"不成立**。

### 4.1 资产库体量与物理占用（[实测]）

`C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine\`：

| 目录 | 文件数 | 逻辑体积 | 物理占用 | 说明 |
|---|---:|---:|---|---|
| `Pages/` | 3,425 | **1,517.7 MB** | **≈1.48 GB（唯一真身）** | 角色 1,091 / 脸 889 / 武器 745 / 敌人 695 页；用户说的 1.48GB 就是它 |
| `Atlases/` | 8,423（1,666 图集） | 1,381.6 MB | 0（**硬链接**） | 每目录 = 一个 atlas 的全部页 + `atlas.atlas` + `regions.json` + `atlas.json` |
| `Bundles/` | 6,770（1,033 套装） | 2,196.8 MB | 部分（PNG 硬链接；skel/atlas/regions 是新文件） | 614 角色服装 / 50 敌人 / 369 武器 |
| `Skeletons_JSON/` | 628 | **3,922.1 MB** | 3.92 GB | 由二进制转出的官方 3.6 JSON（单文件最大 43.6MB）——**不要用它做运行时** |
| `Renders/` | 274 | 19.6 MB | 19.6 MB | 离线烘焙产物（GIF + 逐帧 PNG），见 §5.3 |
| `_Stage0_ViewerReady/` | 7 | 3.5 MB | 3.5 MB | **一套可直接看的完整演示包**（Frenzy Boar 101） |

**硬链接已实测确认**：`fsutil hardlink list` 显示同一个 PNG 同时存在于 `Pages/`、`Atlases/`、`Bundles/` 三处（例如 `administrator_cathedral2.png`）。所以贴图的物理占用就是 ~1.48GB，不是三份。

**单套素材体积（[实测]，`Bundles/Characters/**` 去掉 JSON 后）**：

| 指标 | 值 |
|---|---|
| 角色服装套装数 | 614 |
| 中位数 | **0.95 MB** |
| P90 | 2.17 MB |
| 最大 | 13.24 MB（Edith / After Mc） |
| 全部合计 | **740.8 MB** |

**`.skel` 体积（[实测]，Bundles 内 138 份已配对骨架）**：中位 0.96MB、P90 4.35MB、最大 10.12MB、合计 208.8MB。

**页图尺寸（[实测] 抽样）**：最大 4096×2680（PNG 1.6MB）、4096×2024、4096×1800；脸页 1768×1408；敌人页 4084×1228 / 3936×1752。atlas 声明格式 `RGBA8888`、`filter: Linear`、`pma` 为空（`_Stage0_ViewerReady/FrenzyBoar101/README.txt:24-27`）。

### 4.2 动作覆盖：全角色 ≠ 全动作（[实测] 基于 `docs/_scan_skeletons.json`）

工作区已有的全量扫描结果（628 份骨架，0 错误，全部 `spine 3.6.53`、`fps 30.0`）：

| 动作类别 | 拥有该类动画的骨架数 | 说明 |
|---|---:|---|
| `idle`（看板/待机） | 258 | 覆盖最广 |
| `skill_*_cutNN`（技能分镜） | 455 | 数量最多（4,477 条动画实例） |
| `move`（run/walk/dash/fadv_*） | 170 | 移动动作 |
| `damage`（受击） | 133 | |
| `victory`（胜利） | 133 | |
| `idle_battle`（战斗待机） | **123** | 战斗核心 |
| `attack`（普攻） | **123** | 战斗核心 |
| `fadv`（表情） | 101 | |
| `guard`（格挡） | 45 | |
| **完整战斗 6 件套**（idle_battle+attack+damage+victory+move+skill） | **19** | **只有 19 个骨架** |

其它事实：附件类型总计 `mesh 314,464 / linkedmesh 110,407 / region 16,297 / path 1,400 / clipping 433`；骨骼数中位 189（2~326）；88 个骨架动画数 ≥50（最多 136）。

> **对产品的直接含义**：如果需求是"任意角色都能看战斗/移动动作"，**现在做不到**——628 份离线骨架里能凑齐战斗 6 件套的只有 19 个。可交付的说法应是"**支持有该动作的角色**，UI 里按动作过滤角色列表"，而不是"全角色"。
> 另一层：离线只解出 628 份骨架，而图集有 1,666 份——**骨架-图集配对也是数据工程问题**（旧版只覆盖 300 份 / 116 个变体，见 `docs/spine-render/README.md:205-206`）。

### 4.3 版本兼容：3.6.53 + clipping(type 6)（本节已按 task-2 的源码级结论**更正**）

- 所有骨架头写 `3.6.53`，但这个构建是**带定制后缀（D/E）的厂商版本**（`_Stage0_ViewerReady/FrenzyBoar101/FrenzyBoar101.info.json:5`：`"spine_version": "3.6.53 (custom suffix D/E)"`；hexdump 实测头串为 `3.6.53E`）。
- 432/628（69%）骨架含 `clipping` 附件（type 6）。
- **关键更正**：clipping **不是 3.8 才引入的特性**，而是 Spine **3.6** 引入的（官方博客 2017-06-19："We've added support for clipping and point attachments to all runtimes"）。分界线在**二进制格式**：3.6/3.7 的 `AttachmentType` 枚举只有 0–5，**3.8 才把 `Clipping` 加进枚举成为 type 6**。所以：
  - 官方 **3.6 的二进制读取器**（`SkeletonBinary`）读到 type 6 → 未知类型报错（我们这批 `.skel` 就是这种情况）；
  - 官方 **3.6 的 JSON 读取器**（`SkeletonJson`）**认 `"type":"clipping"` 并做 CPU 裁剪**（3.6 分支含完整 `SkeletonClipping`）；
  - 官方 **3.8/4.x** 二进制读取器认 type 6，但版本串是 `3.6.53E`、且 3.6→3.8 的 timeline/约束布局有差异 → **不能直接读**。
- 因此**唯一稳的官方运行时路径 = 先用工程里已有的转换器把 `.skel` 转成 3.6 JSON（保留 clipping 附件），再交给 3.6 世代运行时**。转换器已存在且 628/628 EOF 对齐（`_analysis/spine_skel_to_json.py`，按 spine-libgdx 3.6 `SkeletonBinary.java` 移植，`ATT_CLIPPING=6` 按 3.8 布局读 `endSlotIndex+vertices+color`，并剥离版本后缀）。
- 旧版 Dart 解析器直接读**二进制**并处理 type 6（`spine_binary.dart:547-552`），只是不渲染遮罩 → 这是路线 A 的现成优势（省掉转换、体积只有 JSON 的 1/4~1/20）。
- 本机已有官方 3.6 运行时源码：`D:\spine-runtimes-3.6\spine-ts\build\{spine-core,spine-webgl,spine-canvas}.js`（[实测] 存在）——**这是 B 路线最关键的既有资产**。
- 详见 `docs/_research_spine_runtime.md` §2.3（含官方 commit / 分支源码链接）；本节的"二进制 vs JSON"区分以那份为准。

### 4.4 内存账（决定"能不能在手机上跑"）

| 项 | 计算 | 结果 |
|---|---|---|
| 4096×2024 页全分辨率 RGBA | 4096×2024×4 | **33.2 MB** |
| 4096×2680 页 | 4096×2680×4 | **43.9 MB** |
| 1768×1408 脸页 | 1768×1408×4 | 9.96 MB |
| 一套角色服装（body 1-2 页 + face 1 页）全分辨率 | ≈33~44 + 10 | **45~55 MB 常驻** |
| 同上，`targetWidth: 2048` 解码 | ÷4 | **11~14 MB** |
| 同上，`targetWidth: 1536` | ÷7 | **6~8 MB** |

- Flutter 的 `ui.instantiateImageCodec(bytes, targetWidth: ...)` 支持**解码期降采样**，不是先解全图再缩——这是省内存的关键手段。
- minSdk 24 的低端机（Mali-T7xx / Adreno 3xx 时代）GL 最大纹理常见 2048–4096；4096 页处在边界上。**全分辨率在低端机上不是"慢"，是"OOM / 贴图创建失败"**。
- 结论：**默认按 2048 解码**（预览窗口 150dp 根本看不出差别），提供"高清"开关；同时常驻页数硬上限 3 页。

### 4.5 帧预算（[推断]，需真机实测）

| 项 | 估算 |
|---|---|
| 单套服装可绘制附件 | 350~900（扫描值 mesh 314k/628 ≈ 500 均值） |
| 顶点数 | 1~3 万 / 角色 |
| CPU 蒙皮 | 顶点数 × 影响骨骼数（2~3）≈ 3~9 万次乘加 → Dart AOT **<1ms**，不是瓶颈 |
| Draw call（朴素） | 每附件一次 `drawVertices` = **350~900 次/帧** → 太多 |
| Draw call（按图集页合批） | 每页一次 = **1~3 次/帧** → 合理 |
| 结论 | 60fps 可行，但**必须合批 + 复用 Float32List**（避免每帧分配导致 GC 抖动）。这是阶段 1 必须先验证的头号指标（WebView 路线则由官方 runtime 的批处理负责，主要看 WebGL 掉帧）。 |

---

## 5. 第 3 问：三条候选架构

### 5.0 总览对比

| 维度 | **A 纯 Dart 自研**（二期原生化） | **B WebView + spine-ts**（先做） | C 构建期烘焙 |
|---|---|---|---|
| 复用旧版代码 | **高（2433 行直接搬）** | 低（只复用素材） | 中（复用离线渲染脚本） |
| 新增 pub 依赖 | **0** | 1~2（`webview_flutter` 或 `flutter_inappwebview`） | 0 |
| 运行方式 | 进程内 `Canvas.drawVertices` | 独立 WebView 进程内嵌 WebGL/Canvas | 播放图片/视频 |
| 任意动作切换 | ✅ | ✅ | ❌（只能播预烘焙的） |
| 换皮肤/换武器 | ✅（命名皮肤） | ✅ | ❌ |
| 实时调参（速度/单帧/暂停） | ✅ | ✅ | 有限 |
| 首次打开延迟 | 解析 0.5~10MB `.skel`，几十~几百 ms | WebView 冷启 300~800ms + JS 加载 | 解码首帧 <100ms |
| 60fps 风险 | 中（需合批/降采样，可控） | 中高（WebGL 碎片化、低端机掉帧） | 低 |
| 3.6 clipping 兼容 | ✅ 二进制直接读 type 6（不渲染遮罩，仅 433 个附件） | ✅ **官方 3.6 的 JSON 读取器 + `SkeletonClipping`（源码级确认）**；⚠ 但必须先 `.skel→JSON`，JSON 体积是 `.skel` 的 4~20 倍 | ✅ 离线烘焙时用官方 runtime 算，天然正确 |
| 许可风险 | 低（自研，仅依据公开格式文档，不复制 runtime 代码） | 中（Spine Runtimes License：个人自用风险低，**分发需 Spine 编辑器授权**，见 §8） | 中（同一批 runtime） |
| 与新版"零依赖/可测"纪律 | ✅ 完全一致 | ❌ 破坏（+1~2 插件） | ✅ |
| 工期 | **31~45 人日**（旧版 2433 行可直接搬，但动画运行时是从零写） | **18~27 人日**（task-2 口径：渲染 10~15；本报告另加资产/UI/侧载 8~12） | 2~5 人日（缩略图/兜底）；若全角色批量烘焙 + 索引打包 **10~16 人日** |
| 能否满足"实时渲染战斗/移动动作" | ✅ | ✅ | ⚠ 只能"播放"，不是渲染器 |

### 5.1 路线 A：纯 Dart 自研（二期原生化；旧版代码的直接继承者）

#### 5.1.1 架构图

```
┌──────────────────────────── Flutter UI (lib/ui) ────────────────────────────┐
│  model_swap_screen (E 修改模型)          spine_animation_page (全屏动作预览)   │
│    └─ SpinePreviewCard ◄── 150dp 卡片        ├─ 动作列表（按类别分组）         │
│        ├─ 动作下拉（idle_battle/attack/…）    ├─ 播放/暂停/进度/速度/循环       │
│        ├─ 皮肤下拉（命名皮肤）               ├─ 皮肤 / 线框 / 背景 / 缩放        │
│        ├─ 线框开关                          └─ 帧率/内存 HUD（debug）          │
│        └─ "缺纹理/解析失败"三态提示                                            │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ 只读数据对象
┌───────────────────────────────▼──── lib/data/spine ──────────────────────────┐
│ SpineAssetStore          素材清单/同步/解包/LRU 缓存（L0 内置 + L1 侧载）      │
│ SpinePreviewLoader       装配：skel + atlas + textures → SpinePreview         │
│ SpineBinaryParser        .skel → SkeletonData（骨骼/插槽/皮肤/附件/动画/约束）  │
│ AnimationState           时间轴采样 → 骨骼局部变换 / 附件 / 颜色 / deform      │
│ ConstraintSolver         IK / transform / path                                │
│ SkeletonPose             世界变换 + 骨骼权重蒙皮（每帧重算顶点）                │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ Float32List 顶点 + Uint16 索引 + UV
┌───────────────────────────────▼──── lib/ui/spine/spine_painter ──────────────┐
│ SpineBinder   → 按图集页合批（1~3 个 Vertices）                               │
│ SpinePainter  → CustomPaint + drawVertices + ImageShader（Y 翻转、自适应缩放） │
│ Ticker(60Hz)  → 时间驱动采样 → 重算顶点 → repaint                             │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### 5.1.2 落点与依赖

- 新增目录/文件：见 §3.5 目录树。
- 新增 pub 依赖：**无**。
- 改动现有文件：`lib/ui/screens/model_swap_screen.dart`（预览卡）、`lib/backend.dart`（装配注入）、`assets/`（新增 `assets/spine/`）、`pubspec.yaml`（登记新资产）。
- 测试：把旧版 `test/spine_binary_test.dart` 19 个合成用例搬过来；新增动画时间轴合成用例、约束求解用例；渲染层用"合成纹理 + `CustomPaint` 不抛异常 + 像素抽样非空"验收。

#### 5.1.3 关键实现要点（按优先级）

1. **动画段 skip → read**：`_skipAnimationBody` 的布局已经完整（`spine_binary.dart:651-770`），把每个 `r.float()/r.varint()` 换成写入数组即可。**风险最低、收益最大的一步**（读出来就等于拿到了全部动作数据）。
2. **曲线求值**：`_skipCurve` 已经知道 `int8()==2` 是 bezier（4 个控制点），补齐 linear/stepped/bezier 三种采样。
3. **姿态施加**：把 `SkeletonPose.bindPose`（只读 setup 值）扩展成 `apply(animationState)`——骨骼 rotate/translate/scale/shear 时间轴按顺序叠加。
4. **约束求解**：`_skipIkConstraints/_skipTransformConstraints/_skipPathConstraints`（`:411-466`）字段顺序已知，改成 read + 求解器。**这是 M2 里最硬的一块**（spine-c 的 IK 求解有细节：bendDirection、compress/stretch、mix）。
5. **deform / drawOrder / slot 时间轴**：deform 影响网格顶点偏移；drawOrder 影响绘制顺序；slot 时间轴负责换装/表情/武器。
6. **合批**：`SpineBinder.bind` 现在"每附件一批"，改成"按图集页 + blend mode 分组"，一个 `Vertices` 塞多个附件（UV 已是页内归一化坐标，天然可合）。
7. **每帧重算**：`skinMeshVertices`（`skeleton_pose.dart:150-183`）复用输出 `Float32List`，别每帧 new。
8. **降采样解码**：`instantiateImageCodec(bytes, targetWidth: 2048)`；常驻页数上限 3。
9. **解析放 isolate**：`.skel` 最大 10MB，主 isolate 解析可能卡 200~500ms；用 `Isolate.run` 或 `compute`。
10. **linked mesh 解析**：按 `(skin, slot, parent)` 找父网格，继承几何 + deform。
11. **clipping**：`Canvas.clipPath` 或 `saveLayer`；433 个附件，优先级最低（先不渲染，视觉上只影响遮罩区域）。

#### 5.1.4 风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| IK/约束求解与官方语义有偏差，动作"看起来不对" | 高 | 用 `_analysis/render/` 的 spine-ts 3.6 逐帧 dump 做**对照基准**（同一骨架同一动画，逐帧比世界坐标）；先支持无约束动画（多数 idle/attack 可能不依赖 IK） |
| 60fps 达不到 | 中 | 先做合批 + 降采样 + 复用缓冲；HUD 显示 ms/帧；低端机降到 30fps 播放（动作是 30fps 制作的，不损失信息） |
| 骨架-图集配对不全（628 skel vs 1666 atlas） | 中 | 打包工具按 `imagesPath` + 页名主干 + region 重叠率三重匹配，输出"已配对/仅页图"两级；UI 只列已配对 |
| 动作覆盖不全（19 个完整战斗） | 高（产品层） | UI 按动作过滤；文案不说"全角色" |
| 4096 贴图在低端机 OOM | 中 | 默认 2048 解码 + 高清开关 + 失败降级到 1024 |
| 新版零依赖纪律被破坏 | 低 | 路线 A 不新增依赖，纪律保持 |

### 5.2 路线 B：WebView + spine-ts

#### 5.2.1 架构图

```
Flutter App ──webview_flutter/flutter_inappwebview──► WebView
     │                                                   ├─ index.html + spine-core/webgl.js
     │  Dart HttpServer.bind(127.0.0.1, 0)               ├─ 请求 /assets/<variant>/...
     └────────────── serve /sdcard 或私有目录 ───────────►└─ WebGL 渲染 + 自带 UI 控件
     ▲                                                   │
     └────── JS Bridge（选角色/选动作/播放控制/回传状态）───┘
```

- 素材服务两种方式：① `file://` 直读（现代 WebView 默认禁止 `file://` XHR，需要 `allowFileAccessFromFileURLs`，兼容性差）；② **App 内起 `HttpServer` 绑 127.0.0.1**（推荐；已有 `INTERNET` 权限，零额外权限；还天然支持侧载目录按需读取与缓存）。
- spine-ts 版本：**必须用 3.6**。官方 3.6 的 `SkeletonJson` 认 `"type":"clipping"` 并有完整 `SkeletonClipping`（task-2 源码级确认，见 `_research_spine_runtime.md` §2.3），所以我们的 3.6 JSON 是"零格式改造"；而 **4.x 读不了 3.6 数据、3.8 的二进制读不了 `3.6.53E`**，都不能用。本机已有 3.6 全量源码 `D:\spine-runtimes-3.6\spine-ts\build\`。
- 数据格式（**这是 B 路线最大的工程细节**）：
  - 官方 3.6 二进制读取器不认 type 6 → **不能直接喂 `.skel`**，必须先用 `_analysis/spine_skel_to_json.py` 转成 3.6 JSON；
  - 但 JSON 体积是 `.skel` 的 **4~20 倍**（实测：FrenzyBoar101 的 `.skel` 491KB ↔ JSON 2.05MB；`Skeletons_JSON` 最大 43.6MB、平均 6.2MB）→ **WebView 里 `JSON.parse(43MB)` 会卡 1~3s 并吃掉数百 MB 内存**；
  - 缓解手段（按优先级）：① 只允许"可演示规模"的角色进 B 路线（JSON ≤ 5MB，如小怪/中型角色）；② 打包阶段**裁剪用不到的动画**（只留要演示的 5~8 个动作，JSON 可缩到 1/3~1/5）；③ 把 JSON 再 gzip（HTTP `Content-Encoding` 或打包时压缩，WebView 侧 `DecompressionStream`/pako 解压）；④ 大型角色干脆不进 B，留给 A。
  - 这条"JSON 体积税"是本报告对 task-2 推荐 B 的**主要补充意见**：B 的 3~5 人日首版成立，但"任意角色都能进 B"不成立，需要按角色筛选或做动画裁剪。

#### 5.2.2 优缺点

| 优点 | 缺点 |
|---|---|
| 官方 runtime，渲染语义正确（clipping/blend/约束/皮肤全支持） | **破坏新版零依赖纪律**（+1~2 个插件） |
| 工期短（渲染 10~15 人日；含资产/UI/侧载 18~27） | WebView 冷启动 300~800ms，首屏体验差 |
| 调试方便（Chrome DevTools 远程调试） | 低端机 WebGL 碎片化、掉帧、白屏 |
| 可直接复用 `Renders/` 的验证思路 | **JSON 体积税**：`.skel` 必须转 JSON 才能被 3.6 读，最大 43.6MB，需按角色筛选/裁动画/gzip（见 §5.2.1） |
| 不引入 spine-cpp 原生库（WebView 是系统组件） | 许可：Spine Runtimes License（个人自用风险低，**分发需编辑器授权**） |
|  | 与 Flutter UI 融合差（下拉框/手势/主题两套）；APK +1~3MB |

### 5.3 路线 C：构建期烘焙（离线渲成帧序列/GIF/WebP）

**这条路已经有现成管线**（[实测]）：

- `_analysis/render/spine_dump_frames.js:1-111`：用**官方 spine-ts 3.6**（`D:/spine-runtimes-3.6/spine-ts/build/spine-canvas.js`）逐帧 dump 顶点/UV/三角形/颜色；
- `_analysis/render/rasterize_spine.py`：Python 三角形光栅化（支持 alpha/加色混合）；
- 产物：`资产库/Spine/Renders/Enemies/Frenzy Boar (101)/`，6 个动画（attack_1/attack_2/damage_front/damage_side/idle_battle_front/idle_battle_side），GIF 747KB/61 帧等，共 274 个文件 19.6MB。
- 说明文档：`Renders/Enemies/Frenzy Boar (101)/README.md:1-19`。

| 维度 | 评估 |
|---|---|
| 工期 | 10~16 人日（管线泛化 3~5 + 编码打包 2~3 + 索引 2~3 + UI 1~2 + 调优 2~3） |
| 体积 | 512px 宽 WebP ≈ 15~25KB/帧；6 动作 × 45 帧 ≈ **5~7MB/角色**；100 角色 = 500~700MB（同样不能全内置） |
| 保真度 | 高（离线用官方 runtime 算的），但**丢交互**：不能换皮肤/武器、不能任意混合动作、不能实时调参 |
| 适用 | ① 作为 M1 之前的"演示/兜底"；② 角色列表的**动作缩略图/封面**；③ 低端机降级路径 |
| 不适用 | 作为"实时渲染战斗/移动动作"的主实现 |

### 5.4 推荐与降级路径（已与 task-2 的运行时调研对齐）

```
 阶段 1（1~2 周）：用 B 打通"能看"
 ┌──────────────────────────────────────────────────────────────┐
 │ .skel → 3.6 JSON（复用 _analysis/spine_skel_to_json.py）        │
 │ + spine-ts 3.6（本机 D:\spine-runtimes-3.6\spine-ts\build\）   │
 │ + App 内 HttpServer 供素材 + WebView 播放                      │
 │ 交付：E 页真模型 + 动作切换 + 侧载素材可用（1~2 个角色）          │
 │ 验收：含 clipping 的骨架画面无"该裁未裁"穿插；60fps/30fps 可接受  │
 └───────────────────────────┬──────────────────────────────────┘
                             │ 决策门（拿真机数据后）
             ┌───────────────┴────────────────┐
             ▼                                ▼
 体验/体积/依赖可接受 → 继续 B     不可接受（WebView 冷启慢、
 （产品级 18~27 人日）            低端机掉帧、想离线零依赖、
                                  大角色 JSON 太大）
             │                                │
             │                                ▼
             │                 阶段 2：A 原生化（15~25 人日渲染 +
             │                 8~12 人日资产/UI），保留旧版
             │                 二进制解析器（.skel 直读，无 JSON 税）
             ▼                                ▼
        ┌─────────────────────────────────────────────┐
        │ 两条路线共用同一套：SpineAssetStore（L0/L1/L2）、 │
        │ 预览卡三态 UI、动作分组、manifest 清单           │
        └─────────────────────────────────────────────┘
```

**为什么不是"一上来就 A"**：A 的渲染部分要从零补动画运行时（时间轴/曲线/约束/deform/drawOrder/blend/linked mesh/clipping），周期 15~25 人日，而 B 用官方 runtime 只要 3~5 人日就能验证"这批数据在手机上到底长什么样"。**先用 B 拿到真机画面和帧率，再决定要不要为"零依赖 + 大角色"投入 A 的原生化**，是信息量最大、返工最少的顺序。

**为什么不是"只做 B"**：B 的 JSON 体积税决定了它**天然不适合大角色**（43.6MB JSON），而角色主体恰恰是大角色；且 WebView 与 Flutter UI 的融合、低端机 WebGL 都是长期债。所以 A 作为二期不是"可选项"，而是"覆盖 B 覆盖不到的那部分角色"的必然补位。

**为什么不是 C 主方案**：C 只能"播放"不能"渲染"，无法换装/任意动作组合，且全角色烘焙同样几 GB 不可内置——只适合做列表缩略图与低端机兜底。

---

## 6. 资产组织：1.48GB 不可能全内置，分级方案

### 6.1 分级模型

```
┌─ L0 内置（APK 内，assets/spine/）────────────────────────────────────────┐
│  manifest.json（全量索引：变体→骨架集/文件/页/动作类别/字节数，<0.5MB）      │
│  demo/<variant>/ 1~2 套完整素材                                          │
│    · 推荐①：Frenzy Boar 101（现成 _Stage0_ViewerReady，skel+atlas+2页=1.67MB）│
│    · 推荐②：1 套主角（如 kirito_cathedral，约 3~5MB）                     │
│  预算：+2~6MB → APK 42~46MB                                             │
└──────────────────────────────────────────────────────────────────────────┘
┌─ L1 侧载（用户提供，不进 APK、不进 git）──────────────────────────────────┐
│  目录：/sdcard/YuiHelper/spine/<variant>/                                │
│        <variant>.skel  +  <variant>.atlas  +  *.png  +  meta.json        │
│  （沿用旧版约定，旧用户素材可直接复用，见 YuiHelper/README.md:112-118）      │
│  可选：整库打成 <name>.spinetar.gz（tar+gzip；gzip 用 dart:io 内置，       │
│        tar 解析 ~120 行纯 Dart → 零第三方依赖），App 按需解出单角色         │
│  全量体积：614 角色服装 ≈ 741MB（+ 已配对 skel 209MB）≈ 0.95GB            │
└──────────────────────────────────────────────────────────────────────────┘
┌─ L2 运行时缓存（App 私有目录，LRU）──────────────────────────────────────┐
│  /data/data/com.yuihelper.next/files/spine/                             │
│  只放"当前选中 + 最近用过的 N 个角色"；上限 500MB（可配 200MB~2GB）        │
│  选中角色时按需 cp/解包单角色（中位 0.95MB、P90 2.17MB）→ 秒级             │
└──────────────────────────────────────────────────────────────────────────┘
```

### 6.2 侧载通道对比（决定要不要新依赖）

| 通道 | 需要 root | 需要存储权限 | 新依赖 | 用户体验 | 建议 |
|---|---|---|---|---|---|
| `su cp -a` 从 `/sdcard/YuiHelper/spine/` → 私有目录 | ✅（App 换模型本来就要求 root） | ❌ | 0 | 旧版已跑通（含 `chown` 修权限坑） | **首选**（`spine_asset_library.dart:66-84` 直接复用） |
| `/sdcard/Android/data/com.yuihelper.next/files/spine/`（app-specific 外部目录） | ❌ | ❌ | 0 | App 能直接读写；但 Android 11+ 文件管理器写入受限，用户要会用 adb/MTP | 备选（无 root 用户） |
| SAF（`ACTION_OPEN_DOCUMENT_TREE`） | ❌ | ❌ | +1（file_picker 等） | 最好，但要插件 | 不建议（破坏零依赖） |
| 首启全量解压 1.48GB | — | — | — | 不可接受（存储 + 时长） | **否决** |

### 6.3 存储与内存上限（写进验收）

| 项 | 上限 | 处理 |
|---|---|---|
| APK | ≤ 50MB | L0 只放 1~2 套演示 + 清单 |
| 私有目录缓存 | 500MB（可配） | LRU 淘汰；页面显示"已用/上限" |
| 单角色常驻纹理 | ≤ 3 页 × 2048 宽 | 超出先淘汰其它角色；同一角色多页按需解码 |
| 解析内存峰值 | ≤ 64MB | `.skel` 最大 10MB，解析后对象 ~2-3×；放 isolate，解析完释放字节 |
| 首帧时间 | ≤ 800ms（中端机） | isolate 解析 + 2048 解码 + 缓存命中直出 |

### 6.4 首次使用流程（不撒谎版）

1. 进 E 修改模型页 → 预览卡先出 **L0 演示角色**（保证永远有东西看）。
2. 首次点"选择角色"时：读 L1 目录索引（列目录 + 读 `meta.json`，毫秒级）；没有 → 卡片写"还没有模型素材"+ 一行"素材放 `/sdcard/YuiHelper/spine/<变体名>/`"（沿用旧版文案风格，`YuiHelper/README.md:120-126`）。
3. 选中角色 → 按需同步单角色 → 出真渲染。
4. 素材库页显示：已安装 N 套 / 占用 X MB / 上限 Y MB / "刷新索引" / "清理缓存"。

---

## 7. 第 4 问：工期估算（人日）

> 口径：1 人日 = 6 小时有效编码；估算含自测，不含真机联调排期（真机按阶段各留 0.5~1 天）。
> 下表是**路线 A（纯 Dart 原生化）**的分解：单人串行总量 **31~45 人日**；2 人并行（数据工程 / 渲染运行时）日历约 **4~6 周**。
> **路线 B（先做，见 §5.4）的分解在里程碑表之后**：渲染 10~15 人日 + 资产/UI/侧载 8~12 人日 ≈ **18~27 人日**。

| 阶段 | 内容 | 人日 | 阻塞点 | 验收标准 |
|---|---|---:|---|---|
| **P0 资产打包工具链** | 从 `Pages/Atlases/Bundles/Skeletons_JSON` 生成按角色分包（`<variant>/skel+atlas+png+meta.json`）；生成 manifest；配对（imagesPath→atlas 页名→region 重叠率三重）；校验（skel EOF、atlas region 覆盖率、PNG 尺寸 vs atlas 声明、缺页报告） | 4~6 | **骨架-图集配对只有 88 组精确（14%）**；其余靠启发式，需人工抽检 | 628 份 skel 全部 `consumedBytes==长度`；至少 100 套"骨架+图集+页图"可渲染；输出缺页清单 |
| **P1 渲染接入（M1 核心）** | 移植 `lib/data/spine/**` + `lib/data/assets/**`（2433 行）到新版；`SpinePreviewCard` 替换 `_BonePainter`；bind pose 真渲染 + 线框 + 缺纹理三态 | 3~4 | 旧代码 `presentation` 与 `data` 分层要理顺（painter 依赖 `dart:ui` 无妨） | E 页选中角色后 300ms 内出真模型；缺素材/缺纹理文案与设计稿 `design/model-swap.html:690-711` 一致 |
| **P2 动画数据解析** | `_skipAnimations/_skipAnimationBody` → 读；曲线三种；约束数据读取；deform/drawOrder/slot 时间轴读取 | 4~6 | 时间轴类型多（9 类），字段错一位就整段崩 → 靠 `consumedBytes==长度` 兜底 | 628 份 skel 仍 100% EOF 对齐；随机 20 个动画能取出关键帧且时长与 JSON 版一致（对照 `Skeletons_JSON`） |
| **P3 动画运行时（M2 核心）** | `AnimationState`（采样/循环/混合/队列）；姿态施加；IK/transform/path 求解；blend 分组；linked mesh | 6~9 | **IK/约束求解语义**（最高风险）；blend mode 分组影响合批 | 逐帧对照 `spine-ts 3.6` 的 dump（同一骨架同一动画，世界坐标误差 <1 单位或可解释）；`idle_battle/attack/damage/victory/run` 各 1 个动作目视正确 |
| **P4 播放与切换 UI** | 动作下拉（按类别分组：待机/攻击/受击/胜利/移动/技能/表情）；播放/暂停/进度/速度/循环；皮肤切换；全屏页（缩放/平移）；HUD（fps/ms/内存，debug 隐藏） | 3~4 | 150dp 卡片放不下完整控制 → 卡片只放 idle 循环 + "查看动作"入口 | 全屏页 60fps（或降级 30fps）连续播放 60s 无掉帧告警、无内存增长 |
| **P5 资产侧载与缓存** | L0 内置 + manifest；L1 扫描；root `cp -a` 同步（复用旧版 + `chown` 坑）；可选 `spinetar.gz` 按需解包；LRU + 存储统计；导入引导文案 | 4~6 | Android 分区存储（旧版已踩过，直接复用结论）；tar+gzip 纯 Dart 实现 | 放 3 套素材到 `/sdcard/YuiHelper/spine/` → App 内 3 套全部可播；缓存超上限自动淘汰；无 root 时给明确文案 |
| **P6 性能与内存** | 按图集页合批（350~900 draw call → 1~3）；`Float32List` 复用；`instantiateImageCodec(targetWidth)`；解析放 isolate；页缓存上限；低端降级（30fps / 1024 贴图） | 4~6 | 真机（尤其低端）数据只能真机拿 | 中端机 60fps 稳定；低端机不 OOM；单角色常驻内存 ≤ 目标值；帧时间 P95 < 20ms |
| **P7 异常与测试** | 缺纹理/缺骨架/版本不符/内存不足/解码失败的降级与文案；搬旧版 19 个合成单测；新增动画/约束/资产层单测；真机验收清单 | 3~4 | 无资源环境下测试要能 skip（旧版已示范） | `flutter analyze` 无 issue；`flutter test` 全绿（现有 126 + 新增）；真机 3 套素材 × 5 个动作通过 |
| **合计** | | **31~45** | | |

**里程碑切分（建议按此排期）**

| 里程碑 | 包含 | 人日 | 交付物（可演示） |
|---|---|---:|---|
| **M1 能看** | P1 + P2 + P4 精简版 + P0 精简版 | 10~13 | E 页真模型 + 1 个动作循环播放 + 1 套内置演示 |
| **M2 能信** | P3 + P5 + P6 + P7 | 14~20 | 5 类动作可切、侧载资产库、帧率/内存达标、测试全绿 |
| **M3 能扩展** | 全量打包 + 素材库页 + 文档 | 5~8 | 全库打包产物 + 使用说明 + 性能报告 |

**路线 B（WebView + spine-ts 3.6）的工期分解（先做的那条）**

| 阶段 | 内容 | 人日 | 阻塞点 | 验收标准 |
|---|---|---:|---|---|
| **B0 数据转换与筛选** | 复用 `_analysis/spine_skel_to_json.py` 把演示角色 `.skel→3.6 JSON`；**按 JSON 体积筛选可进 B 的角色**；可选裁动画/gzip | 2~3 | JSON 体积税（最大 43.6MB）；clipping 保留 `end` 槽名 | 选出的角色 JSON ≤ 5MB；3.6 运行时能完整加载 |
| **B1 WebView 接入** | `webview_flutter`/`flutter_inappwebview`；App 内 `HttpServer` 供素材；WebView 生命周期与 Flutter 页面绑定 | 2~3 | 新依赖（破坏零依赖）；`pub get` 需联网；WebView 版本碎片 | 冷启 ≤ 800ms；退出页面不泄漏 WebView 进程 |
| **B2 Viewer 页面** | `index.html` + spine-ts 3.6（core/webgl）；动作下拉、播放/暂停/速度/循环、皮肤切换、线框、背景 | 3~5 | 3.6 API 与文档；WebGL 上下文丢失恢复 | 5 类动作可切；含 clipping 骨架无"该裁未裁"穿插 |
| **B3 Flutter↔JS 桥** | 选角色/选动作/播放控制/回传状态（fps、错误） | 1~2 | 双向消息时序 | 切换角色 ≤ 1s；错误能回传到 Flutter 侧显示 |
| **B4 资产/UI/侧载** | 与路线 A 共用 `SpineAssetStore`（L0/L1/L2）+ 预览卡三态 + 素材库页 | 5~7 | 与 A 共用同一套设计，需先定接口 | 放 3 套素材到 `/sdcard` 全部可播；缓存上限生效 |
| **B5 性能与兼容** | 低端机 WebGL 降级；内存/进程监控；JSON 解析耗时优化 | 3~4 | 只能真机拿数据 | 中端机 60fps / 低端 30fps；单页面内存增量 ≤ 150MB |
| **B6 异常与测试** | WebView 不可用/JS 报错/素材缺失/许可提示；widget 测试用假 WebView | 2~3 | 测试环境没有 WebView | `flutter analyze` 无 issue；测试全绿；真机 3 角色 × 5 动作通过 |
| **合计** | | **18~27** | | |

---

## 8. 第 5 问：合规与风险

### 8.1 现状事实（先摆事实，再谈判断）

- 新版 APK 里已经内置 **59MB 的 frida 注入器**（`assets/frida-inject`）与针对特定游戏 build 的 hook 脚本（`assets/saoars_model.js`）——`README.md:139-140`、`android/app/build.gradle.kts`（debug 签名）。
- 因此这个 App **本来就不是商店分发物**：它需要 root、需要注入、签名是 debug key。**Google Play / 国内商店的政策不是本功能的主要约束**。
- 真正的约束是：**不要把第三方版权美术资源打进分发包**。旧版 README 已写明免责声明（`YuiHelper/README.md:314-318`："仅供本地归档、互操作与个人学习研究……请勿分发、商用"），且旧版 `.gitignore` 把解出来的游戏素材排除在仓库外（`YuiHelper/.gitignore` 末两行 `docs/asset-render/*.pkm`、`eugeo_cathedral_*.png`）。
- **新版 README 目前没有免责声明段落**（`README.md` 全文 168 行无"免责/版权"节）——建议在集成时补上，与旧版对齐。

### 8.2 风险矩阵

| 风险 | 等级 | 说明 | 建议 |
|---|---|---|---|
| 内置游戏美术资源 = 再分发 | **高**（法律）/低（实际，自用） | 角色/武器/敌人贴图版权属 Bandai Namco / Wright Flyer Studios（资产库 `README.md:169-173` 已声明） | **APK 只放 1~2 套演示**（满足"打开就有东西看"），其余全部侧载；侧载包不进 git、不进发行物；README 写清"素材由用户自备" |
| 素材进仓库 | 中 | 1.48GB 进 git 会炸 | 沿用旧版做法：`.gitignore` 排除 `assets/spine/**`（只提交 `manifest.json` 与极小演示包）；`docs/_integration_plan.md` 这类文档才入库 |
| Spine Runtime 许可（路线 B/C） | 中 | 官方 spine-ts/spine-c 适用 Spine Runtimes License；商用/分发通常需 Spine 编辑器授权；个人自用处于灰色地带（**以 task-2 `_research_spine_runtime.md` 的一手结论为准**） | 路线 A 自研不依赖 runtime 代码，规避该风险；若走 B/C，先在 README 注明 runtime 来源与许可 |
| 换模型/注入本身违反游戏 ToS | 中 | 现状已存在（旧版与新版都做了） | 与本功能无关，但集成时不要在 UI 上把"预览"包装成官方能力；保持现有免责口径 |
| 版权素材被二次传播 | 中 | 用户可能把侧载包/截图发出去 | README 明示；素材库页显示"仅限个人本地使用" |
| 数据来源合规（解包/解密） | 中 | 资产来自已解包/解密的游戏文件 | 不在报告/代码里附带解密密钥与脚本；仅引用路径 |

### 8.3 一个可执行的"合规友好"设计

```
APK（可分发，体积 ~42MB）        侧载包（不随 APK 分发，用户自备）
├─ 渲染器（自研 Dart）            ├─ 角色素材（skel+atlas+png）
├─ 1~2 套演示素材（1.7~6MB）      └─ 由用户从自己的游戏文件导出/整理
└─ manifest.json（只含索引元数据）
```
这样"代码可分发、素材不随包"，既解决体积问题，也把版权风险压到最低——**这是分级方案的第二重收益**。

---

## 9. 实施检查清单（DoD）

**阶段 1（路线 B，先做）验收**

- [ ] `.skel → 3.6 JSON` 转换跑通，含 clipping 的骨架在 3.6 运行时里**裁剪正确**（抽 3 个含 type 6 的骨架）
- [ ] 进 E 页 → WebView 出真模型，冷启 ≤ 800ms，退出不泄漏 WebView
- [ ] 5 类动作（idle_battle/attack/damage/victory/run）可切；播放/暂停/速度/循环可用
- [ ] 皮肤切换、线框模式可用
- [ ] 预览卡三态文案与 `design/model-swap.html:690-711` 一致（缺纹理/解析失败/线框）
- [ ] 帧率与内存实测记录在案（中端机 / 低端机各一份）

**阶段 2（路线 A，原生化；若启动）验收**

- [ ] `lib/data/spine/**` 在新工程编译通过，`flutter analyze` 无 issue
- [ ] 628 份 `.skel` 解析 `consumedBytes == 文件长度`（用 `tool/spine_verify` 移植版）
- [ ] E 页选中角色 → 300ms 内出真模型（贴图正确、Y 不倒置、比例正常）
- [ ] 线框模式可用（分辨"模型错"vs"贴图错"）
- [ ] 1 个动作（`idle_battle_*`）循环播放，帧时间 P95 记录在案
- [ ] 动画与官方 spine-ts 3.6 逐帧 dump 对照：世界坐标误差可解释（记录方法）
- [ ] 中端机 60fps、低端机不 OOM（降级策略生效）

**两条路线共用验收**

- [ ] 侧载：`/sdcard/YuiHelper/spine/` 放 3 套 → 全部可播；无 root 时有明确文案
- [ ] 缓存上限与 LRU 生效；存储统计显示正确
- [ ] `flutter test` 全绿（现有 126 + 新增），无资源环境自动 skip
- [ ] README 补：功能说明、素材放置说明、免责声明、不支持项（"不是全角色全动作"）

---

## 10. 证据索引与复现命令

### 10.1 旧版（`C:\Users\Administrator\Desktop\YuiHelper`）

| 结论 | 证据 |
|---|---|
| 纯 Dart 解析器 + 判据 | `lib/data/spine/spine_binary.dart:6-21`、`:286-357` |
| 动画只 skip | `:225-228`、`:269-271`、`:640-649`、`:651-770` |
| 约束 skip | `:411-466` |
| clipping type 6 处理 | `:547-552` |
| slot blend mode 已读 | `:388-409` |
| 蒙皮/世界变换 | `lib/data/spine/skeleton_pose.dart:74-127`、`:150-183`、`:189-220` |
| `drawVertices` 渲染 | `lib/presentation/model_swap/preview/spine_painter.dart:191-291`（关键 `:274-283`） |
| 合批前的"每附件一批" | `spine_painter.dart:76-123` |
| 预览卡三态 | `preview/spine_preview_card.dart:57-71`、`:88-116`、`:169-171` |
| 素材目录 + root 同步 + chown | `lib/data/spine/spine_asset_library.dart:50-54`、`:56-84`、`:112-146`、`:217-231` |
| 页面接线 | `lib/presentation/model_swap/model_swap_screen.dart:96-189`、`:781-836` |
| 唯一第三方依赖 | `pubspec.yaml:30-39`；`.dart_tool/package_config.json` |
| 未内嵌 Spine 素材 | `pubspec.yaml:72-80` |
| 真机验证 + 截图 | `docs/spine-render/README.md:10-18`、`:128-186`；`docs/spine-render/device-wireframe.png`（本次目视：215 部件 / 226 骨 / 351 网格） |
| 已知未做 | `docs/spine-render/README.md:189-208`；`docs/PROGRESS.md:66-74` |
| 免责声明 | `README.md:314-318` |

### 10.2 新版（`C:\Users\Administrator\Desktop\YuiHelper-next`）

| 结论 | 证据 |
|---|---|
| appId / minSdk 24 / targetSdk 36 | `android/app/build.gradle.kts:8,19,22-23`；`build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml` |
| 零第三方依赖 | `pubspec.yaml:9-17`；`.dart_tool/package_config.json` |
| 资产列表 | `pubspec.yaml:19-28` |
| APK 体积构成 | `dist/YuiHelperNext-v0.1.0-arm64.apk`（zip 条目：frida-inject 56.19MB→23.92MB、libflutter 11.2MB、libapp 4.38MB；合计未压缩 72.98MB、APK 39.95MB） |
| 资产加载/落盘机制 | `lib/data/model_swap_repository.dart:14-27`、`:34-40`、`:127-204` |
| AssetLoader 注入点 | `lib/backend.dart:45-46`、`:56-70`、`:100-103` |
| 假线稿 | `lib/ui/screens/model_swap_screen.dart:763-860`、`:1117-1210`、`:857-859` |
| 设计稿要求真预览 | `design/model-swap.html:303-309`、`:690-711`、`:833` |
| "不接入"声明 | `README.md:164-168` |
| 全量骨架扫描数据 | `docs/_scan_skeletons.json`（628 / 0 错误 / 动作类别计数 / has_battle6=19） |
| 骨架集映射表 | `assets/model_bones.json`（`variants`）；`assets/model_skeletons_seed.json`（1 条种子） |

### 10.3 资产库与离线管线（`C:\Users\Administrator\Desktop\解包`）

| 结论 | 证据 |
|---|---|
| 体量 | `资产库/Spine/{Pages 1517.7MB/3425, Atlases 1381.6MB/1666, Bundles 2196.8MB/1033, Skeletons_JSON 3922.1MB/628, Renders 19.6MB, _Stage0_ViewerReady 3.5MB}` |
| 硬链接（物理只算一份） | `fsutil hardlink list`：同一 PNG 同时出现在 Pages/Atlases/Bundles |
| 单套体积 | 614 角色服装（去 JSON）中位 0.95MB / P90 2.17MB / max 13.24MB / 合计 740.8MB；138 skel 中位 0.96MB / max 10.12MB |
| 演示包 | `资产库/Spine/_Stage0_ViewerReady/FrenzyBoar101/`（skel 491,776B + atlas 9,884B + 2 PNG 1.16MB；不含 2MB JSON 时 **1.67MB**） |
| atlas 文本格式 | `资产库/Spine/Atlases/Characters/Administrator/Cathedral [04ff8db2]/atlas.atlas`（RGBA8888 / Linear / 4096×2024） |
| 3.6.53 定制后缀 | `_Stage0_ViewerReady/FrenzyBoar101/FrenzyBoar101.info.json:5` |
| 69% 含 clipping | `_analysis/spine.md:12,140-141` |
| JSON 由二进制转换 + spine-ts 3.6 验证 | `资产库/README.md:255-262`；`_Stage0_ViewerReady/FrenzyBoar101/README.txt:4,27` |
| 离线烘焙管线 | `_analysis/render/spine_dump_frames.js:1-13,66-101`；`_analysis/render/rasterize_spine.py`；`资产库/Spine/Renders/Enemies/Frenzy Boar (101)/README.md:1-19` |
| 官方 3.6 runtime 本机存在 | `D:\spine-runtimes-3.6\spine-ts\build\spine-core.js|spine-webgl.js|spine-canvas.js` |

### 10.4 复现命令（只读）

```powershell
# 旧版：确认零第三方依赖
Get-Content 'C:\Users\Administrator\Desktop\YuiHelper\.dart_tool\package_config.json' -Raw

# 新版：APK 构成
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z=[System.IO.Compression.ZipFile]::OpenRead('C:\Users\Administrator\Desktop\YuiHelper-next\dist\YuiHelperNext-v0.1.0-arm64.apk')
$z.Entries | Sort-Object Length -Descending | Select-Object -First 12 Length,FullName
$z.Dispose()

# 资产库：各目录体积
Get-ChildItem 'C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine' -Directory |
  ForEach-Object { $s=(Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum);
                   [pscustomobject]@{Name=$_.Name; Files=$s.Count; MB=[math]::Round($s.Sum/1MB,1)} }

# 硬链接验证
fsutil hardlink list 'C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine\Pages\Characters\Administrator\Cathedral (Variant 2).png'
```

---

## 11. 未验证项（诚实清单）

1. **60fps 连续渲染**：旧版只验证了"一帧画对"，没有任何帧率数据；§4.5 的预算是推算，**必须实测**（B 路线在 WebView 里测，A 路线在 CustomPaint 里测）。
2. **IK/transform/path 约束的求解语义**：字段布局已知，但求解结果与官方是否一致未验证；这是 A 路线 M2 的最大不确定性（B 路线由官方 runtime 负责，无此风险）。
3. **clipping 的实际视觉影响**：433 个附件分布在 432 份骨架里（平均 1 个/骨架）；**B 路线能正确裁剪（源码级确认）**，A 路线需要自己补 `Canvas.clipPath`/`saveLayer`，效果未验证。
4. **骨架-图集配对覆盖率**：已知 88/628 精确、626/628 有候选；批量配对的实际可用率要 P0 跑完才知道。
5. **4096 页在 minSdk 24 真机上的表现**：未实测（本机是 Android 16 的小米 24129PN74C，不是低端机）。
6. **Spine Runtime 许可的准确边界**：本报告只做风险标注，**结论以 task-2 `_research_spine_runtime.md` §5 为准**（个人自用风险低；分发需每个用户各持 Spine 编辑器授权 + 美术资源版权双重门槛）。
7. **`.spinetar.gz` 纯 Dart 解包**：tar 解析 ~120 行可行，但未实现验证；若不做，退化为"目录直拷"（功能等价，只是用户要多放几个文件）。
8. **动作"看起来对"的判据**：目前只能靠"逐帧坐标对照 + 目视"；没有像素级 golden 测试（可后续加）。
9. **B 路线的 JSON 体积税到底多大**：需要按"裁剪动画后"的 JSON 体积重新统计（现有 `Skeletons_JSON` 是**全动画**导出，平均 6.2MB、最大 43.6MB）；裁剪后大概率能压到 1/3~1/5，未实测。
10. **WebView 在低端 minSdk 24 设备上的 WebGL 可用性**：未实测（碎片化严重，可能直接白屏）。

---

## 12. 与并行调研的交叉核对（task-1 / task-2）

| 事项 | 本报告（task-3） | task-2 `_research_spine_runtime.md` | 核对结果 |
|---|---|---|---|
| clipping 归属版本 | 初稿按 `_analysis/spine.md` 写成"3.8 才引入、3.6 运行时不认识" | 源码级更正：clipping 是 **3.6 特性**；3.8 只是把它加进**二进制**枚举成为 type 6；**3.6 的 JSON 读取器认识它** | **以 task-2 为准，本报告 §4.3 已更正**。这条直接影响 B 路线可行性（结论：B 可行） |
| 官方 runtime 能否直接吃 `.skel` | 初稿认为"3.6 读不了 type 6，B 不可行" | 3.6 二进制确实读不了 type 6 → **必须转 JSON**；转成 3.6 JSON 后 3.6 运行时完整支持 | 一致。补充：**JSON 体积税**是本报告新提的约束（§5.2.1） |
| 4.x / 3.8 迁移 | 列为高风险备选 | 明确"版本串对不上 + 布局差异 → 不能读"，**不建议** | 一致 |
| 纯 Dart 路线起点 | 建议**复用旧版 `YuiHelper` 的二进制解析器**（2433 行，628/300 份 EOF 验证过，直接读 `.skel`，无 JSON 税） | 建议 **fork `spine_core 0.3.5` + `spine_flutter_dart 0.2.0`**（3.8 世代 JSON 解析器，含 clipping 类；但包 3 年未维护、需读 JSON） | **两条子路线互补**：旧版解析器强在"二进制直读 + 已验证"，弱在"动画运行时从零写"；`spine_core` 强在"已有动画/约束实现"，弱在"只读 JSON + 停更 + v2.5 许可禁止改" |
| 工期 | A 31~45（含资产/UI/测试全流程）；B 18~27（渲染 10~15 + 资产/UI 8~12） | A 8~15 首版 / 15~25 产品级；B 3~5 首版 / 10~15 产品级 | **口径差在"是否含资产侧载/UI/测试"**。把本报告 P0/P5/P6/P7（约 15~21 人日）加上后两者对齐 |
| 许可 | 路线 A 自研可规避 runtime 许可；B/C 受 Spine Runtimes License | 现行协议 2025-04-05 版：集成需 Section 2 授权；个人自用风险低；分发需每用户各持授权 + 美术版权 | 一致；本报告 §8 按此收口 |
| 资产体量 | Pages 1.48GB（物理唯一）、614 套角色服装 740.8MB、单套中位 0.95MB | 未展开（task-1 负责） | 本报告独立实测，供 task-1 交叉校验 |
| 动作覆盖 | **只有 19 个骨架有完整战斗 6 件套**、123 个有 `idle_battle` | 未展开 | **本报告独有发现**（数据源 `docs/_scan_skeletons.json`），建议产品文案据此调整 |

**收敛后的建议（两份报告合起来看）**：

1. **先做 B**（1~2 周）：把"这批数据在手机上长什么样"这个问题一次性回答掉；同时产出 `.skel→JSON` 管线、viewer、素材服务。
2. **同时做 P0 资产打包 + L0/L1/L2 资产层**（B/A 共用，不浪费）。
3. **拿到真机数据后再决定 A**：若 B 的冷启动/掉帧/JSON 体积不可接受，或要覆盖大角色与"零依赖离线"，再投入 A 的原生化（优先复用旧版二进制解析器，而不是从零）。
4. **无论走哪条，都先落 `SpineAssetStore` + 预览卡三态 UI + 动作分组**——这三块是两条路线 100% 共用的，早做不返工。
