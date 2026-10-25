import 'package:flutter/services.dart' show rootBundle;

import 'data/claim_repository.dart';
import 'data/http_transport.dart';
import 'data/imagination_repository.dart';
import 'data/local_api_client.dart';
import 'data/model_swap_repository.dart';
import 'data/root_shell.dart';
import 'data/skill_board_repository.dart';
import 'data/transport.dart';
import 'domain/result.dart';

export 'data/claim_repository.dart'
    show ClaimOutcome, ClaimPreview, ClaimRepository, MissionResetOutcome;
export 'data/imagination_repository.dart'
    show
        ImaginationFillPlan,
        ImaginationPreview,
        ImaginationRepository,
        planImaginationFill;
export 'data/local_api_client.dart' show LocalApiClient;
export 'data/model_swap_repository.dart'
    show
        ModelSwapApi,
        ModelSwapPaths,
        ModelSwapRepository,
        SwapAssets,
        SwapStatus;
export 'data/root_shell.dart' show RootShell, ShellResult;
export 'data/skill_board_repository.dart'
    show
        SkillBoardRepository,
        SkillFillPlan,
        SkillPreview,
        planSkillFill;
export 'data/transport.dart' show HttpReply, Transport;
export 'domain/claim_plan.dart';
export 'domain/model_enum.dart';
export 'domain/model_swap_rule.dart';
export 'domain/name_table.dart';
export 'domain/result.dart';
export 'domain/save_tables.dart';
export 'domain/season_convergence.dart';

/// 一份内置资产的加载器（默认 `rootBundle`）。测试里可以换成假实现。
typedef AssetLoader = Future<List<int>> Function(String asset);

/// YuiHelper next 的后端入口。
///
/// 三个功能各自独立：
/// - 领取奖励：`user/pull` + 四个 receive 动作，走游戏进程里的本地 HTTP 服务器；
/// - 装配想象力：同一套 HTTP 链路，`user/pull` + `user/push`（带版本栅栏）；
/// - 换模型：root shell 部署注入器 + `user/pull/push` 读写规则，另需内置资产。
///
/// UI 层只持有这个对象，不关心底下是真实实现还是测试替身。
final class YuiHelperBackend {
  YuiHelperBackend({
    Transport? transport,
    ModelSwapApi? modelSwapApi,
    AssetLoader? loadAsset,
    Future<ShellResult> Function(String cmd, {Duration timeout})? shell,
  }) : _transport = transport ?? HttpTransport() {
    final api = LocalApiClient(_transport);
    claims = ClaimRepository(api);
    imagination = ImaginationRepository(api: api, loadAsset: loadAsset);
    skills = SkillBoardRepository(api: api, loadAsset: loadAsset);
    modelSwap =
        modelSwapApi ??
        ModelSwapRepository(shell: shell ?? const RootShell().run);
  }

  final Transport _transport;

  /// 领取奖励（使命 / 礼物盒 / 赛季 / 活动角色）。
  late final ClaimRepository claims;

  /// 想象力一键装配（专属）。
  late final ImaginationRepository imagination;

  /// 解放所有角色（技能全满）：把每个角色的技能板换成 maximumSlots 并补材料。
  late final SkillBoardRepository skills;

  /// 换模型（部署注入器、启停、规则读写、枚举与日志）。
  late final ModelSwapApi modelSwap;

  /// 「游戏里的离线引擎活着吗」探针；UI 的「重新连接」用它。
  Future<Result<bool>> ping() => claims.ping();

  /// transport 的地址，方便诊断页展示。
  String get endpoint => switch (_transport) {
    final HttpTransport http => _endpointOf(http),
    _ => 'injected',
  };

  static String _endpointOf(HttpTransport transport) =>
      'http://${transport.host}:${transport.port}';
}

/// 默认的资产加载器（打进 SO 的 assets 目录）。
Future<List<int>> rootBundleAssetLoader(String asset) async {
  final data = await rootBundle.load(asset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
