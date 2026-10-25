import 'save_tables.dart';

/// 第一轮每个 id 重复几次。服务端按 `min(次数, total - acquiredCount)` 封顶，
/// 所以对一次性奖励（`total == 1`）来说，多发的部分会被丢掉，没有副作用。
const int kSeasonRepeatInitial = 30;

/// 单轮重复次数的上限，防止请求体失控。
const int kSeasonRepeatMax = 3840;

/// 最多跑几轮。真机上 `loopLimit == -1` 的循环奖励上限由玩家点数决定，
/// 理论上可能很高，所以必须有个安全上限而不是无限轮询。
const int kSeasonMaxRounds = 6;

/// 从 pull 响应里读出每个赛季奖励已经领了多少次。
Map<int, int> acquiredCounts(Map<String, Object?> pullJson) {
  final out = <int, int>{};
  for (final row in tableRows(pullJson, 'seasonReward')) {
    final id = row['seasonRewardId'];
    if (id is! int) continue;
    final acquired = row['acquiredCount'];
    out[id] = acquired is int ? acquired : 0;
  }
  return out;
}

/// 这一轮发出去之后，哪些 id 还有剩余、需要再来一轮。
///
/// 判据是「增量**恰好等于**本轮请求次数」：服务端领取量是
/// `min(请求次数, total - acquiredCount)`，所以只有被截顶的 id 才会涨满整数倍。
/// 增量更小说明已经领满；增量为 0 说明这轮什么都没发生 —— 两种都该停。
List<int> idsNeedingAnotherRound({
  required List<int> sentIds,
  required int repeat,
  required Map<int, int> before,
  required Map<int, int> after,
}) {
  final seen = <int>{};
  final out = <int>[];
  for (final id in sentIds) {
    if (!seen.add(id)) continue;
    final gained = (after[id] ?? 0) - (before[id] ?? 0);
    if (gained == repeat) out.add(id);
  }
  return out;
}

/// 下一轮的重复次数：翻倍，封顶在 [kSeasonRepeatMax]。
int nextRepeat(int repeat) {
  final doubled = repeat * 2;
  return doubled > kSeasonRepeatMax ? kSeasonRepeatMax : doubled;
}
