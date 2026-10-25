import 'save_tables.dart';

/// 使命行的 `state` 语义（`rewards.js` 的 `mission` 分支）：
/// `3` = 已完成可领，`4` = 已领取，其它 = 未完成。
///
/// 服务端要求 `missionIds` 里**每一个** id 的 state 都恰好是 3：
/// `state == 4` 会被静默跳过，其它任何值都会抛 `Mission <id> is incomplete`，
/// 让**整批** 400 且完全不落盘。所以过滤必须做在客户端。
const int kMissionStateClaimable = 3;

/// 使命：一般 / 每日 / 每週 / 活动 / 公会 —— **所有栏目共用这一张表**，
/// 所以一次提交全部可领 id 就等于「所有栏目一次领完」，不需要切画面。
List<int> claimableMissionIds(Map<String, Object?> pullJson) {
  final ids = <int>[];
  for (final row in tableRows(pullJson, 'mission')) {
    if (row['state'] != kMissionStateClaimable) continue;
    final id = row['missionId'];
    if (id is int) ids.add(id);
  }
  return ids;
}

/// 礼物盒。服务端不做任何状态校验，表里每一行都是可领的。
List<int> giftIds(Map<String, Object?> pullJson) {
  final ids = <int>[];
  for (final row in tableRows(pullJson, 'gift')) {
    final id = row['id'];
    if (id is int) ids.add(id);
  }
  return ids;
}

/// 赛季 / 活动等级奖励。
///
/// **故意不做 eligibility 过滤**：点不点得动由服务端判定
/// （点数不够、未购高级轨、已领满都会静默 continue，不报错）。
/// 客户端只需要把候选 id 全部交上去。
List<int> seasonRewardIds(Map<String, Object?> pullJson) {
  final ids = <int>[];
  for (final row in tableRows(pullJson, 'seasonReward')) {
    final id = row['seasonRewardId'];
    if (id is int) ids.add(id);
  }
  return ids;
}

/// 保持顺序地去掉重复 id。
List<int> _dedup(Iterable<int> ids) {
  final seen = <int>{};
  return [
    for (final id in ids)
      if (seen.add(id)) id,
  ];
}

Map<String, Object?> missionReceiveBody(List<int> ids) => {
  'missionIds': _dedup(ids),
};

Map<String, Object?> giftReceiveBody(List<int> ids) => {'giftIds': _dedup(ids)};

/// 赛季奖励的请求体。
///
/// 同一个 id 可以重复出现，**重复 N 次 = 尝试领 N 次**
/// （对应客户端自己的「Receive-all repeats IDs once per claim」）。
/// 服务端按 `min(次数, total - acquiredCount)` 封顶，所以过量重复是安全的。
Map<String, Object?> seasonReceiveBody(List<int> ids, {required int repeat}) {
  final out = <int>[];
  for (final id in _dedup(ids)) {
    for (var i = 0; i < repeat; i++) {
      out.add(id);
    }
  }
  return {'seasonRewardIds': out};
}

/// 活动角色达成奖励。服务端按 `pcType` 匹配定义、按 `progress` 判定达标。
Map<String, Object?> eventCharacterReceiveBody({
  required int pcType,
  required int progress,
}) => {'pcType': pcType, 'progress': progress};
