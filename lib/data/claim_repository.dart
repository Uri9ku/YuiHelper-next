import '../domain/claim_plan.dart';
import '../domain/result.dart';
import '../domain/save_tables.dart';
import '../domain/season_convergence.dart';
import 'local_api_client.dart';

/// 一次领取的结果。
final class ClaimOutcome {
  const ClaimOutcome({
    required this.claimedCount,
    required this.summary,
    this.log = const [],
  });

  /// 本次真正到账的条数（以服务端的回应为准，不是「我发了多少 id」）。
  final int claimedCount;

  /// 显示在面板上的一句话（简体中文）。
  final String summary;

  /// 给日志面板看的逐轮明细。
  final List<String> log;
}

/// 一次只读预检：只拉表算数，**不写任何东西**。
///
/// F 领取所有奖励的「待领取」屏、C 任务领取的列表用它；
/// 失败原样透传，让 UI 能区分「游戏没开」和「真的没有可领的东西」。
final class ClaimPreview {
  const ClaimPreview({
    required this.missionRows,
    required this.missionClaimable,
    required this.missionInProgress,
    required this.missionClaimed,
    required this.giftCount,
    required this.seasonCount,
    required this.eventCount,
  });

  final List<Map<String, Object?>> missionRows;
  final int missionClaimable;
  final int missionInProgress;
  final int missionClaimed;
  final int giftCount;
  final int seasonCount;
  final int eventCount;
}

/// 一次「重置任务 / 撤销重置」的结果。
///
/// 只统计服务端 pull 回来的事实：本次改了几行、现在有多少条可领取/已领取。
final class MissionResetOutcome {
  const MissionResetOutcome({
    required this.updated,
    required this.claimableAfter,
    required this.claimedAfter,
    required this.total,
    required this.restored,
  });

  /// 本次 push 提交的行数（已经是目标状态的行不会重复写）。
  final int updated;

  /// push 完成后重新 pull 校验出来的可领取条数。
  final int claimableAfter;

  /// push 完成后重新 pull 校验出来的已领取条数。
  final int claimedAfter;

  /// 使命总条数。
  final int total;

  /// true = 撤销重置（恢复到「已领取」）；false = 重置为「可领取」。
  final bool restored;
}

/// 整批被业务拒绝之后，降级重试用的块大小。
const int kFallbackChunkSize = 256;

/// 一次批量提交的结果：真正到账几条、哪些 id 被服务端拒了、以及服务端给的原话。
final class _Batch {
  const _Batch({
    required this.claimed,
    required this.rejected,
    this.serverMessage,
  });

  final int claimed;
  final List<int> rejected;
  final String? serverMessage;
}

/// 四个领取动作。业务规则全部来自 domain 层的纯函数，这里只负责
/// 「拉表 → 算请求体 → 发请求 → 判 code → 数到账」这个循环。
final class ClaimRepository {
  ClaimRepository(this._api);

  final LocalApiClient _api;

  static const String _noContent = '本版本无内容';

  /// 「引擎活着吗」的探针，直接透传客户端。
  Future<Result<bool>> ping() => _api.ping();

  /// 使命：一般 / 每日 / 每週 / 活动 / 公会所有栏目共用一张表，
  /// 所以一次提交全部 `state==3` 的 id 就是「所有栏目一次领完」。
  Future<Result<ClaimOutcome>> claimMissions() async {
    final pull = await _pullOk('mission');
    if (pull case Err<Map<String, Object?>>(:final error)) return Err(error);

    final ids = claimableMissionIds(_value(pull));
    if (ids.isEmpty) {
      return const Ok(ClaimOutcome(claimedCount: 0, summary: '当前没有可领取的使命'));
    }

    final batch = await _receiveTolerant(
      ids: ids,
      action: 'mission/receive',
      bodyOf: missionReceiveBody,
      // 服务端在 table.put.mission 里精确回报哪些行变了，这就是到账条数。
      countOf: (response) => tablePutRows(response, 'mission').length,
    );
    if (batch case Err<_Batch>(:final error)) return Err(error);
    final result = (batch as Ok<_Batch>).value;

    // 一条都没领到 = 整体失败，不能包装成"已完成"。
    if (result.claimed == 0 && result.rejected.isNotEmpty) {
      return Err(
        AppError(
          kind: AppErrorKind.serverCode,
          userMessage: '游戏拒绝了这次领取：${result.rejected.length} 条被拒，一条都没领到',
          detail: 'code!=0 message=${result.serverMessage}',
        ),
      );
    }

    final summary = result.rejected.isEmpty
        ? '已领取 ${result.claimed} 项使命'
        : result.claimed == 0
        ? '领取失败：${result.rejected.length} 条被服务端拒绝，一条都没领到'
        : '已领取 ${result.claimed} 项使命（另有 ${result.rejected.length} 条被服务端拒绝，已跳过）';

    return Ok(
      ClaimOutcome(
        claimedCount: result.claimed,
        summary: summary,
        log: [
          '提交 ${ids.length} 个可领使命，服务端回报变动 ${result.claimed} 行'
              '${result.rejected.isEmpty ? '' : '，被拒 ${result.rejected.length} 条'}',
        ],
      ),
    );
  }

  Future<Result<ClaimOutcome>> claimGifts() async {
    final pull = await _pullOk('gift');
    if (pull case Err<Map<String, Object?>>(:final error)) return Err(error);

    final ids = giftIds(_value(pull));
    if (ids.isEmpty) {
      return const Ok(ClaimOutcome(claimedCount: 0, summary: _noContent));
    }

    final sent = await _api.call('gift/receive', giftReceiveBody(ids));
    if (sent case Err<Map<String, Object?>>(:final error)) return Err(error);

    final checked = _ensureOk(_value(sent));
    if (checked case Err(:final error)) return Err(error);

    // 礼物没有「已领」标记，服务端回的是领完之后**剩下的**表，
    // 所以到账条数 = 提交数 - 剩下的行数。
    final response = _value(checked as Ok<Map<String, Object?>>);
    final remaining = tableRows(response, 'gift').length;
    final claimed = ids.length - remaining;
    return Ok(
      ClaimOutcome(
        claimedCount: claimed < 0 ? 0 : claimed,
        summary: claimed <= 0 ? _noContent : '已领取 $claimed 项礼物',
        log: ['提交 ${ids.length} 个礼物 id，服务端剩下 $remaining 行'],
      ),
    );
  }

  /// 赛季 / 活动等级奖励。
  ///
  /// 服务端按 `min(请求次数, total - acquiredCount)` 封顶，而 `total` 对
  /// `loopLimit == -1` 的循环奖励没有上限，所以固定次数一定不够 —— 这里做多轮收敛：
  /// 每轮之后重新拉表比对 `acquiredCount`，只要某个 id 的增量恰好等于本轮请求次数，
  /// 说明它被截顶了，下一轮只带这些 id 并把次数翻倍，直到没有增长或到达轮数上限。
  Future<Result<ClaimOutcome>> claimSeasonRewards() async {
    final pull = await _pullOk('seasonReward');
    if (pull case Err<Map<String, Object?>>(:final error)) return Err(error);

    final candidates = seasonRewardIds(_value(pull));
    if (candidates.isEmpty) {
      return const Ok(ClaimOutcome(claimedCount: 0, summary: _noContent));
    }

    var before = acquiredCounts(_value(pull));
    var ids = candidates;
    var repeat = kSeasonRepeatInitial;
    var claimed = 0;
    final log = <String>[];

    for (var round = 1; round <= kSeasonMaxRounds && ids.isNotEmpty; round++) {
      final sent = await _api.call(
        'season-reward/receive',
        seasonReceiveBody(ids, repeat: repeat),
      );
      if (sent case Err<Map<String, Object?>>(:final error)) return Err(error);

      final checked = _ensureOk(_value(sent));
      if (checked case Err(:final error)) return Err(error);

      final afterPull = await _pullOk('seasonReward');
      if (afterPull case Err<Map<String, Object?>>(:final error))
        return Err(error);

      final after = acquiredCounts(_value(afterPull));
      var gained = 0;
      for (final id in ids) {
        final delta = (after[id] ?? 0) - (before[id] ?? 0);
        if (delta > 0) gained += delta;
      }
      claimed += gained;
      log.add('第 $round 轮：${ids.length} 个 id × $repeat 次 → 到账 $gained');

      ids = idsNeedingAnotherRound(
        sentIds: ids,
        repeat: repeat,
        before: before,
        after: after,
      );
      before = after;
      repeat = nextRepeat(repeat);
    }

    return Ok(
      ClaimOutcome(
        claimedCount: claimed,
        summary: claimed == 0 ? '当前没有可领取的赛季奖励（点数不够或已领满）' : '已领取 $claimed 项赛季奖励',
        log: log,
      ),
    );
  }

  /// 活动角色达成奖励。
  ///
  /// 服务端按 `{pcType, progress}` 判定，而这两个值只有客户端的活动界面知道 ——
  /// 外部拿不到。本 build 的 `catalog.characterRewards` 是空的，所以这里用
  /// 最保守的参数发一次、再把服务端前后的 `isReceived` 行数一减：
  /// 没有变化就如实报告「本版本无内容」，而不是假装领到了什么。
  Future<Result<ClaimOutcome>> claimEventCharacterRewards() async {
    final pull = await _pullOk('eventCharacterReward');
    if (pull case Err<Map<String, Object?>>(:final error)) return Err(error);

    final before = _receivedEventCharacterCount(_value(pull));

    final sent = await _api.call(
      'event/character/reward/receive',
      eventCharacterReceiveBody(pcType: 1, progress: 0),
    );
    if (sent case Err<Map<String, Object?>>(:final error)) return Err(error);

    final checked = _ensureOk(_value(sent));
    if (checked case Err(:final error)) return Err(error);

    final afterPull = await _pullOk('eventCharacterReward');
    if (afterPull case Err<Map<String, Object?>>(:final error))
      return Err(error);

    final after = _receivedEventCharacterCount(_value(afterPull));
    final claimed = after - before;
    return Ok(
      ClaimOutcome(
        claimedCount: claimed < 0 ? 0 : claimed,
        summary: claimed <= 0 ? _noContent : '已领取 $claimed 项活动角色奖励',
        log: ['活动角色奖励：服务端已领取行数 $before → $after'],
      ),
    );
  }

  /// 拉一张表并校验 `code`。
  ///
  /// `user/pull` 也会回 `code != 0`（例如 `Local runtime is not initialized`）。
  /// 如果把那种响应当成"表是空的"，用户会看到「本版本无内容」这种**假无事**，
  /// 然后直接放弃 —— 比报错更糟。
  Future<Result<Map<String, Object?>>> _pullOk(String alias) async {
    final pulled = await _api.pull(alias);
    switch (pulled) {
      case Err<Map<String, Object?>>(:final error):
        return Err(error);
      case Ok<Map<String, Object?>>(:final value):
        return _ensureOk(value);
    }
  }

  /// 提交一批 id，并且**不因为一个坏 id 就把整批赔进去**。
  ///
  /// 服务端对整批里任何一个不合格的 id 都会拒绝整批（`Unknown mission <id>`、
  /// `Mission <id> is incomplete`），而"这个 id 在 catalog 里存不存在"客户端查不到。
  /// 所以整批被业务拒绝时降级成按块重试：坏 id 只毁掉它所在的那一块，其余照领，
  /// 被拒的块如实报出来。
  Future<Result<_Batch>> _receiveTolerant({
    required List<int> ids,
    required String action,
    required Map<String, Object?> Function(List<int>) bodyOf,
    required int Function(Map<String, Object?>) countOf,
  }) async {
    final whole = await _api.call(action, bodyOf(ids));
    if (whole case Err<Map<String, Object?>>(:final error)) return Err(error);
    final wholeChecked = _ensureOk(_value(whole));
    if (wholeChecked case Ok<Map<String, Object?>>(:final value)) {
      return Ok(_Batch(claimed: countOf(value), rejected: const []));
    }

    var claimed = 0;
    final rejected = <int>[];
    String? serverMessage;
    for (var start = 0; start < ids.length; start += kFallbackChunkSize) {
      final end = start + kFallbackChunkSize > ids.length
          ? ids.length
          : start + kFallbackChunkSize;
      final chunk = ids.sublist(start, end);

      final one = await _api.call(action, bodyOf(chunk));
      if (one case Err<Map<String, Object?>>(:final error)) return Err(error);

      final raw = _value(one);
      final checked = _ensureOk(raw);
      if (checked case Ok<Map<String, Object?>>(:final value)) {
        claimed += countOf(value);
      } else {
        rejected.addAll(chunk);
        serverMessage ??= _messageOf(raw);
      }
    }
    return Ok(
      _Batch(
        claimed: claimed,
        rejected: rejected,
        serverMessage: serverMessage,
      ),
    );
  }

  String? _messageOf(Map<String, Object?> response) {
    final message = response['message'];
    return message is String ? message : null;
  }

  Map<String, Object?> _value(Result<Map<String, Object?>> result) =>
      (result as Ok<Map<String, Object?>>).value;

  /// 服务端 `code != 0` 时**绝不能**当成成功。
  Result<Map<String, Object?>> _ensureOk(Map<String, Object?> response) {
    final code = response['code'];
    if (code == 0) return Ok(response);

    final message = response['message'];
    final text = message is String && message.isNotEmpty ? '：$message' : '';
    return Err(
      AppError(
        kind: AppErrorKind.serverCode,
        userMessage: '游戏拒绝了这次领取$text',
        detail: 'code=$code message=$message',
      ),
    );
  }

  /// 一次只读预检：拉四张表，算出各渠道可领数量，**不写任何东西**。
  Future<Result<ClaimPreview>> preview() async {
    final pulls = <String, Map<String, Object?>>{};
    for (final alias in const [
      'mission',
      'gift',
      'seasonReward',
      'eventCharacterReward',
    ]) {
      final pulled = await _pullOk(alias);
      if (pulled case Err<Map<String, Object?>>(:final error)) return Err(error);
      pulls[alias] = _value(pulled);
    }

    final missionRows = tableRows(pulls['mission']!, 'mission');
    var claimable = 0;
    var claimed = 0;
    for (final row in missionRows) {
      final state = row['state'];
      if (state == kMissionStateClaimable) {
        claimable++;
      } else if (state == 4) {
        claimed++;
      }
    }
    return Ok(
      ClaimPreview(
        missionRows: missionRows,
        missionClaimable: claimable,
        missionInProgress: missionRows.length - claimable - claimed,
        missionClaimed: claimed,
        giftCount: tableRows(pulls['gift']!, 'gift').length,
        seasonCount: tableRows(pulls['seasonReward']!, 'seasonReward').length,
        eventCount: tableRows(
          pulls['eventCharacterReward']!,
          'eventCharacterReward',
        ).length,
      ),
    );
  }

  /// 把**全部使命**重置为「已完成可领取」（`state=3`），奖励可再次领取。
  ///
  /// 走离线引擎的通用写表入口 `user/push`：只提交 `{missionId, state}` 部分行，
  /// 引擎按 missionId merge，其余字段（progress/completedAt…）原样保留。
  /// mission 表没有 `stale_skill_push` 栅栏；仍把 pull 回来的 token 放进
  /// `hash.before.mission`，换了引擎实现也能用。
  ///
  /// 写完后**一定重新 pull 校验**并返回实测条数——不拿“我发了多少行”当成功。
  Future<Result<MissionResetOutcome>> resetMissions() =>
      _setMissionState(targetState: kMissionStateClaimable, restored: false);

  /// 撤销重置：把当前所有「可领取」（`state=3`）的使命改回「已领取」（`state=4`）。
  ///
  /// 这是重置的安全阀：实验证明同样的 push 能把 mission 表恢复成与重置前一致
  ///（内容版本 hash 也会复原）。它不会撤销已经领到手的奖励。
  Future<Result<MissionResetOutcome>> restoreMissions() =>
      _setMissionState(targetState: 4, restored: true);

  Future<Result<MissionResetOutcome>> _setMissionState({
    required int targetState,
    required bool restored,
  }) async {
    final pulled = await _pullOk('mission');
    if (pulled case Err<Map<String, Object?>>(:final error)) return Err(error);
    final pull = _value(pulled);
    final token = _missionTokenOf(pull);

    final updates = <Map<String, Object?>>[];
    var total = 0;
    for (final row in tableRows(pull, 'mission')) {
      total++;
      final id = row['missionId'];
      if (id is! int) continue;
      if (row['state'] == targetState) continue;
      updates.add({'missionId': id, 'state': targetState});
    }

    if (updates.isNotEmpty) {
      final pushed = await _pushMissionUpdates(updates, token);
      if (pushed case Err<void>(:final error)) return Err(error);
    }

    final verified = await _pullOk('mission');
    if (verified case Err<Map<String, Object?>>(:final error)) return Err(error);
    var claimableAfter = 0;
    var claimedAfter = 0;
    for (final row in tableRows(_value(verified), 'mission')) {
      final state = row['state'];
      if (state == kMissionStateClaimable) {
        claimableAfter++;
      } else if (state == 4) {
        claimedAfter++;
      }
    }
    return Ok(
      MissionResetOutcome(
        updated: updates.length,
        claimableAfter: claimableAfter,
        claimedAfter: claimedAfter,
        total: total,
        restored: restored,
      ),
    );
  }

  /// 提交 mission 部分行；失败时把 `userMessage` 透传给 UI。
  Future<Result<void>> _pushMissionUpdates(
    List<Map<String, Object?>> updates,
    String? token,
  ) async {
    final body = <String, Object?>{
      'table': [
        {
          'put': {'mission': updates},
        },
      ],
    };
    if (token != null && token.isNotEmpty) {
      body['hash'] = {
        'before': {'mission': token},
      };
    }
    final pushed = await _api.call('user/push', body);
    if (pushed case Err<Map<String, Object?>>(:final error)) return Err(error);
    final checked = _ensureOk(_value(pushed));
    if (checked case Err<Map<String, Object?>>(:final error)) {
      return Err(error);
    }
    return const Ok<void>(null);
  }

  String? _missionTokenOf(Map<String, Object?> pullJson) {
    final hash = pullJson['hash'];
    if (hash is! Map) return null;
    final token = hash['mission'];
    return token is String && token.isNotEmpty ? token : null;
  }

  int _receivedEventCharacterCount(Map<String, Object?> pullJson) {
    var count = 0;
    for (final row in tableRows(pullJson, 'eventCharacterReward')) {
      if (row['isReceived'] == true) count++;
    }
    return count;
  }
}
