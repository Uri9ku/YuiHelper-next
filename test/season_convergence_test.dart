import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/domain/season_convergence.dart';

/// 造一份只含 `seasonReward` 表的 pull 响应。
Map<String, Object?> seasonPull(List<Map<String, Object?>> rows) => {
      'code': 0,
      'table': {
        'replace': {'seasonReward': rows},
      },
    };

void main() {
  group('acquiredCounts', () {
    test('读出每个 seasonRewardId 的 acquiredCount', () {
      final pull = seasonPull([
        {'seasonRewardId': 11, 'acquiredCount': 3},
        {'seasonRewardId': 12, 'acquiredCount': 0},
      ]);
      expect(acquiredCounts(pull), {11: 3, 12: 0});
    });

    test('缺 acquiredCount 字段的行按 0 处理', () {
      expect(acquiredCounts(seasonPull([
        {'seasonRewardId': 11},
      ])), {11: 0});
    });

    test('读不出该表时返回空 map', () {
      expect(acquiredCounts(<String, Object?>{}), isEmpty);
    });
  });

  group('下一轮该带哪些 id', () {
    test('增量恰好等于本轮次数 → 被截顶，还需要下一轮', () {
      expect(
        idsNeedingAnotherRound(
          sentIds: [1, 2],
          repeat: 30,
          before: {1: 0, 2: 0},
          after: {1: 30, 2: 5},
        ),
        [1],
      );
    });

    test('增量小于本轮次数 → 已领满，不再重试', () {
      expect(
        idsNeedingAnotherRound(
          sentIds: [1],
          repeat: 30,
          before: {1: 10},
          after: {1: 17},
        ),
        isEmpty,
      );
    });

    test('某轮零增长 → 收敛，返回空列表（不空转到最大轮数）', () {
      expect(
        idsNeedingAnotherRound(
          sentIds: [1, 2],
          repeat: 30,
          before: {1: 30, 2: 30},
          after: {1: 30, 2: 30},
        ),
        isEmpty,
      );
    });

    test('本轮传空 id 列表时直接返回空', () {
      expect(
        idsNeedingAnotherRound(sentIds: [], repeat: 30, before: {}, after: {}),
        isEmpty,
      );
    });

    test('after 里缺键按 0 增量处理，不抛异常', () {
      expect(
        idsNeedingAnotherRound(
          sentIds: [1],
          repeat: 30,
          before: {1: 0},
          after: {},
        ),
        isEmpty,
      );
    });

    test('返回顺序与传来的一致，且不重复', () {
      expect(
        idsNeedingAnotherRound(
          sentIds: [5, 1, 5],
          repeat: 2,
          before: {5: 0, 1: 0},
          after: {5: 2, 1: 2},
        ),
        [5, 1],
      );
    });
  });

  group('nextRepeat', () {
    test('翻倍并封顶在 kSeasonRepeatMax', () {
      expect(nextRepeat(30), 60);
      expect(nextRepeat(kSeasonRepeatMax), kSeasonRepeatMax);
      expect(nextRepeat(kSeasonRepeatMax * 4), kSeasonRepeatMax);
    });
  });

  group('常量', () {
    test('初始次数小于等于上限，轮数上限为正', () {
      expect(kSeasonRepeatInitial, lessThanOrEqualTo(kSeasonRepeatMax));
      expect(kSeasonMaxRounds, greaterThan(0));
    });
  });
}
