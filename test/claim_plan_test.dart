import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/domain/claim_plan.dart';
import 'package:yui_helper_next/domain/save_tables.dart';

/// 造一份 `/api/user/pull` 形状的响应。
///
/// 真实形状来自 `state.js` 的 `response()`：
///   `{"code":0,"table":{"replace":{"<alias>": [<row>, ...]}},"hash":{...}}`
Map<String, Object?> pullFixture({
  List<int> missionStates = const [],
  List<Map<String, Object?>> extraMissionRows = const [],
  int giftRows = 0,
  List<int> seasonIds = const [],
}) {
  return {
    'code': 0,
    'table': {
      'replace': {
        'mission': [
          for (var i = 0; i < missionStates.length; i++)
            {
              'userId': 1,
              'missionId': 15000000001 + i,
              'state': missionStates[i],
              'progress': 1,
            },
          ...extraMissionRows,
        ],
        'gift': [
          for (var i = 0; i < giftRows; i++)
            {'id': 900 + i, 'rewardType': 1, 'itemId': 1, 'amount': 1},
        ],
        'seasonReward': [
          for (final id in seasonIds) {'seasonRewardId': id, 'acquiredCount': 0},
        ],
      },
    },
  };
}

void main() {
  group('可领项过滤', () {
    test('只挑 state==3 的任务，state 4/0/1/2 都不进请求体', () {
      final pull = pullFixture(missionStates: [3, 4, 0, 1, 2, 3]);
      expect(claimableMissionIds(pull), [15000000001, 15000000006]);
    });

    test('任务行缺 missionId 或不是整数时被跳过，不会构造出坏 id', () {
      final pull = pullFixture(extraMissionRows: [
        {'state': 3},
        {'missionId': 'x', 'state': 3},
      ]);
      // 两个坏行都必须被丢掉：任何一个漏进去都会让服务端整批 400 且一样都领不到。
      expect(claimableMissionIds(pull), isEmpty);
    });

    test('gift 表为空时返回空列表', () {
      expect(giftIds(pullFixture(giftRows: 0)), isEmpty);
    });

    test('gift 表有行时取出全部 id', () {
      expect(giftIds(pullFixture(giftRows: 2)), [900, 901]);
    });

    test('seasonRewardIds 取全部 id，不做 eligibility 过滤（引擎会自己跳过不合格项）', () {
      expect(seasonRewardIds(pullFixture(seasonIds: [11, 12])), [11, 12]);
    });
  });

  group('响应结构缺失时不炸', () {
    test('缺 table.replace 或表本身缺失时返回空列表，不抛异常', () {
      expect(claimableMissionIds(<String, Object?>{}), isEmpty);
      expect(tableRows(<String, Object?>{}, 'mission'), isEmpty);
    });

    test('table.replace 不是 map 时返回空列表', () {
      expect(tableRows({'table': {'replace': 'oops'}}, 'mission'), isEmpty);
    });

    test('replace 里该表不是 List 时返回空列表', () {
      expect(tableRows({'table': {'replace': {'mission': 'oops'}}}, 'mission'), isEmpty);
    });

    test('tablePutRows 取出 table.put 里该表的行', () {
      final response = {
        'code': 0,
        'table': {
          'put': {
            'mission': [
              {'missionId': 1, 'state': 4},
              {'missionId': 2, 'state': 4},
            ],
          },
        },
      };
      expect(tablePutRows(response, 'mission'), hasLength(2));
    });

    test('tablePutRows 在缺 put / put 不是 map / 表不是 List 时都返回空列表', () {
      expect(tablePutRows(<String, Object?>{}, 'mission'), isEmpty);
      expect(tablePutRows({'table': {'put': 'oops'}}, 'mission'), isEmpty);
      expect(tablePutRows({'table': {'put': {'mission': 'oops'}}}, 'mission'), isEmpty);
    });
  });

  group('请求体构造', () {
    test('mission 请求体的键就是 missionIds，且重复 id 去重', () {
      expect(missionReceiveBody([7, 7, 9]), {'missionIds': [7, 9]});
    });

    test('gift 请求体的键是 giftIds', () {
      expect(giftReceiveBody([900, 901]), {'giftIds': [900, 901]});
    });

    test('season 请求体把每个 id 连续重复 repeat 次', () {
      expect(seasonReceiveBody([11, 12], repeat: 3), {
        'seasonRewardIds': [11, 11, 11, 12, 12, 12],
      });
    });

    test('season 请求体 repeat 为 1 时每个 id 只出现一次', () {
      expect(seasonReceiveBody([11, 12], repeat: 1), {
        'seasonRewardIds': [11, 12],
      });
    });

    test('活动角色请求体只带 pcType 与 progress', () {
      expect(eventCharacterReceiveBody(pcType: 2, progress: 1500), {
        'pcType': 2,
        'progress': 1500,
      });
    });
  });
}
