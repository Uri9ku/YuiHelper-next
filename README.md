# YuiHelper next

新版「离线游戏修改器」：**按 design/ 设计稿实现的 Flutter UI** + 从旧项目移植的后端。

- `design/` — 交互与视觉规范（HTML，自包含，无外部依赖）：`ui-system.html` + 页面稿 `claim-all.html`（F 领取所有奖励）、`equip.html`（B 装配装备）、`model-swap.html`（E 修改模型）。
- `lib/ui/` — 新版 UI：设计令牌 + 组件库 + 7 个页面（A–G），按 `design/` 的规范与页面稿实现。
- `lib/domain/`、`lib/data/`、`lib/backend.dart` — 后端：从旧项目 `YuiHelper`（saoub_claim）逐字节移植的领域层与数据层。
- `assets/` — 后端依赖的注入器、hook 脚本与数据表。

旧版 UI（88dp 悬浮球、320×420 面板）**没有**接入；新版 UI 全部按 `design/` 重画，只复用旧版的后端能力。

## 新版 UI（按 design/ 实现）

设计令牌来自 `design/ui-system.html` 的 `:root`：浅灰底 + 白卡 + `#2563EB` 主色，8 级字阶、18/16/12/9 圆角、4pt 间距步长。

| 页面 | 文件 | 说明 |
| --- | --- | --- |
| 一级导航 | `lib/ui/app.dart` | 胶囊 Tab 栏（数值 / 装备 / 任务 / 设置）+ IndexedStack |
| A 工作台 | `lib/ui/screens/home_screen.dart` | 四张功能卡 + 分段快速定位 + 快速跳转；领取/装备/换模型数据从后端读 |
| B 装配装备 | `lib/ui/screens/equip_screen.dart` | 想象力一键装配 + 「解放所有角色（技能全满）」卡（KPI/确认/倒计时/结果） |
| C 任务领取 | `lib/ui/screens/tasks_screen.dart` | 可领取/进行中/已完成三态使命列表 + 一键领取 + 危险操作：重置任务 / 撤销重置 |
| D 数值修改 | `lib/ui/screens/param_screen.dart` | 预设 + 4 滑杆 + diff 预览；数值写入后端未接入，主按钮禁用 |
| E 修改模型 | `lib/ui/screens/model_swap_screen.dart` | 环境体检 + A→B 映射 + 骨骼线稿预览 + 注入倒计时 + 日志 |
| F 领取所有奖励 | `lib/ui/screens/claim_all_screen.dart` | 四类渠道 + 分步进度 + 失败即停 + 汇总与日志 |
| G 设置 / 关于 | `lib/ui/screens/settings_screen.dart` | 引擎连接、设备环境、版本与权限说明 |
| 令牌 / 组件 | `lib/ui/tokens.dart`、`lib/ui/widgets/foundation.dart` | AppCard / 分段 / 胶囊 Tab / KPI / 槽位 / 任务卡 / 体检行 / 映射行 / 日志 / 提示条 |

页面严格组合 `foundation.dart` 的组件与 `tokens.dart` 的令牌，不写色值字面量；数据能取真就取真，取不到（游戏未连接/无 root）就如实写原因，不伪造数字与成功。

### 重置任务（危险操作，需游戏前台）

C 任务领取页底部有「重置任务」卡：

- 二次确认 → **5 秒倒计时**（提示切回游戏）→ 通过 `user/push` 把全部使命的 `state` 置为 3（可领取）→ 重新 pull 校验 → 回 App 显示「已重置 N 条（当前可领取 M 条）」。
- 反向「撤销重置」把当前所有可领取改回已领取（`state=4`），用于撤回；**不会**收回已经领到的奖励。
- 游戏内任务界面不会刷新（客户端只应用自己请求的回包）；重置后点「一键领取」即可再次拿奖励。
- 这是绕过业务校验的写表，务必先备份存档（root：`/data/data/com.bandainamcoent.saoars/files/offline-runtime/state.json`）；实测 4513 条约 0.5 s，可完整撤销。
- 危险卡在「游戏未连接」时也可见：发起后切回游戏，倒计时结束时由后台 pull+push 完成。

### 解放所有角色（技能全满，需游戏前台）

B 装配装备页的「解放所有角色」卡（旧版 YuiHelper 的「技能全满」移植）：

- `user/pull` pc/item → 按 `assets/skill_boards.json` 的 `maximumSlots` 替换每个已拥有角色的 `pc.slotSkills`，并按 `requiredItems` 补材料 → `user/push`（带 `hash.before.pc/item` 栅栏）→ 结果条。
- 二次确认 + 5 秒倒计时「切回游戏」；完成后提示重启游戏（客户端界面不会自动刷新）。
- 实测：253/253 个有技能板的角色全部满级（集合一致），6 个无板角色跳过，材料补足 0 种；再次执行返回「技能板已经都是满的」。
- 副作用：游戏客户端后续自行扣过 15 种技能材料共 2,332（不是本功能 push 的 item 行）；没有天然撤销，改前务必 root 备份 `state.json`。
- `SkillBoardRepository.preview()` 只读给出「待解放角色 / 槽位 / 补材料种类」；`_slotsKey` 对槽位数组与字段顺序做规范化，客户端重排后不会误判。

## 后端功能

| 功能 | 入口 | 依赖 | 关键语义 |
| --- | --- | --- | --- |
| 领取奖励 | `ClaimRepository`（`claims`） | 游戏内离线引擎 HTTP `127.0.0.1:18680` | 四类渠道：使命 / 礼物盒 / 赛季奖励 / 活动角色；顺序执行、失败即停、到账数只认游戏回应；`preview()` 只读预检 |
| 装配想象力 | `ImaginationRepository`（`imagination`） | 同一 HTTP 链路 + `assets/imagination_fill.json` | 只填空槽、只装已解锁槽位（≤4）、每角色一个专属、多槽用不同库存副本，写 `pc.imaginationSlots`（带 `hash.before.pc` 版本栅栏）；`preview()` 只读预检 |
| 解放所有角色（技能全满） | `SkillBoardRepository`（`skills`） | 同一 HTTP 链路 + `assets/skill_boards.json` | pc.slotSkills ← maximumSlots（253 角色 / 3503 槽）、按 requiredItems 补材料；带 `hash.before.pc/item` 栅栏；`preview()` 只读；比较时对槽位/字段顺序做规范化 |
| 换模型 | `ModelSwapRepository`（`modelSwap`） | root shell + `assets/` 里的注入器/hook/配对表/骨架表 | 角色 A→B 模型替换：部署注入器、启停、规则读写、枚举、日志；同一骨架集才能互换 |
| 重置任务（危险） | `ClaimRepository.resetMissions()` / `restoreMissions()` | 同上（`user/pull` + `user/push`） | 把全部使命 `state` 改成 3（可领取）或改回 4；只提交 `{missionId,state}` 部分行，写完重新 pull 校验；mission 表无 skill fence |

统一入口：

```dart
import 'package:yui_helper_next/backend.dart';

final backend = YuiHelperBackend();

final preview = await backend.claims.preview();             // ClaimPreview（UI 只读预检）
final claimed = await backend.claims.claimMissions();       // Result<ClaimOutcome>
final equipped = await backend.imagination.equipExclusive(); // Result<String>
final filled = await backend.skills.fillAll();               // Result<String>（技能全满）
final status = await backend.modelSwap.status();             // SwapStatus
```

`YuiHelperBackend` 的构造参数可以注入 `Transport` / `ModelSwapApi` / 资产加载器 / shell 执行器，测试与诊断页不用打真机。

## 目录

```
lib/
  backend.dart                 # 统一入口 + 具名导出
  ui/                          # 新版 UI（见上表）
    app.dart                   #   AppShell + 胶囊 Tab 导航
    tokens.dart                #   设计令牌（唯一来源 ui-system.html :root）
    widgets/foundation.dart    #   组件库
    screens/                   #   A–G 七个页面
  domain/                      # 纯函数与值对象（无 IO，可单测）
    result.dart                #   Result / AppError
    save_tables.dart           #   pull/push 响应取行
    claim_plan.dart            #   四类领取的请求体与可领过滤
    season_convergence.dart    #   赛季多轮收敛
    model_swap_rule.dart       #   规则 JSON 与 id 校验
    model_enum.dart            #   运行时角色枚举解析
    name_table.dart            #   名称表解析
  data/
    transport.dart             #   Transport / HttpReply 接口
    http_transport.dart        #   真实 HTTP 实现（127.0.0.1:18680）
    local_api_client.dart      #   /api/<action> 调用 + JSON 解码
    claim_repository.dart      #   四类领取 + 分块降级 + preview
    imagination_repository.dart#   想象力装配计划 + preview + user/push
    model_swap_repository.dart #   部署 / 启停注入 / 规则 / 枚举 / 日志
    root_shell.dart            #   su -c 执行封装
assets/                        # 后端依赖的内置资产（见下）
test/                          # 领域层与数据层单测（flutter_test）
```

## 构建 / 安装

```bash
flutter pub get
flutter analyze            # No issues found
flutter test               # 126 tests, All tests passed
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.yuihelper.next/.MainActivity
```

- 安装包已产出一份在 `dist/YuiHelperNext-v0.1.0-arm64.apk`（约 40 MB）。
- Android：`applicationId=com.yuihelper.next`、`minSdk 24`、`targetSdk 36`；清单里声明 `INTERNET` 与 `usesCleartextTraffic`（只为访问 `127.0.0.1:18680` 的本地引擎）。
- 真机验证（Xiaomi 24129PN74C / Android 16 / arm64）：已安装并启动，首页在游戏引擎在线时读到真实数据（如「可领取使命 2896 项」）；游戏没开时各页显示「游戏未连接 / 重新连接」，不伪造数字。

## 测试

测试不打真机、不联网：

- HTTP 用 `test/support/fake_transport.dart` 的 `ScriptedTransport` 按路径排队应答；
- 换模型用注入的假 shell（`Future<ShellResult> Function(String, {Duration timeout})`）与假资产加载器；
- 想象力装配同样注入假的 `imagination_fill.json` 内容。

### 迁移/实现验证

- `flutter test`：**126 个用例全绿**（共享层 16 + 领取奖励 45 + 想象力/换模型 47 + 重置任务 4 + 技能全满 8 + `backend_test` 装配 6）。
- `flutter analyze`：**No issues found**。
- 后端保真度：25 个代码/测试文件与旧项目**逐字节一致**（仅 `package:` 前缀与 CRLF→LF 行尾不同）；7 个资产 SHA-256 完全一致；`lib/data`、`lib/domain` 内无 presentation/UI 依赖残留。

## 资产

| 文件 | 用途 |
| --- | --- |
| `assets/frida-inject` | arm64 注入器二进制，部署到 `/data/local/tmp/saoub-model-inject`（59 MB） |
| `assets/saoars_model.js` | hook 脚本（模型替换规则在这里生效） |
| `assets/names.tsv` | 角色 id ↔ 中文名 |
| `assets/model_pairs.json` | 身体 id → 脸 id 配对 |
| `assets/model_bones.json` | 图集变体 → 骨架集（chara_1…） |
| `assets/model_skeletons_seed.json` | 跨骨架集互换的骨架名种子 |
| `assets/imagination_fill.json` | 210 条「角色 → 专属想象力」 |
| `assets/skill_boards.json` | 253 角色 / 3503 槽的「点满」技能板（maximumSlots + requiredItems，identity 与存档 policy 一致） |

## 平台约束

- **领取奖励 / 装配想象力**：游戏内的离线引擎在 `127.0.0.1:18680` 起本地 HTTP 服务器；请求必须带 `Content-Length`，读超时 30s（服务端要整份存档落盘后才回包）。
- **换模型**：需要 root（`su -c`）；注入必须游戏在前台；进程名统一 `saoub-model-*`，不与其他工具互相干扰；改规则不热重载，要重进场景/重启游戏。
- 桌面/CI：上述真机行为都由注入点替换，测试可在任意平台跑。

## 与设计稿的对应

| 设计稿 | 实现 |
| --- | --- |
| [design/ui-system.html](design/ui-system.html) | `lib/ui/tokens.dart` + `lib/ui/widgets/foundation.dart` |
| [design/claim-all.html](design/claim-all.html) | `lib/ui/screens/claim_all_screen.dart` |
| [design/equip.html](design/equip.html) | `lib/ui/screens/equip_screen.dart` |
| [design/model-swap.html](design/model-swap.html) | `lib/ui/screens/model_swap_screen.dart` |
| ui-system `#pages` 的 A/C/D 缩略图 | `home_screen.dart` / `tasks_screen.dart` / `param_screen.dart` |

## 未接入（有意保留）

- **数值写入后端**：D 页只实现设计稿的预设/滑杆/diff 交互，主按钮禁用并在页脚说明。
- 「技能全满」「更新检查」：本期需求只要领取/装配/换模型。
- 旧版 `lib/presentation/**`、Spine 模型预览渲染：属于旧 UI 能力，不接入新版。
