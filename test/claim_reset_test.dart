import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/claim_repository.dart';
import 'package:yui_helper_next/data/local_api_client.dart';
import 'package:yui_helper_next/domain/result.dart';

import 'support/fake_transport.dart';

/// 一条使命行（字段与线上一致；只关心 missionId/state）。
Map<String, Object?> mission(int id, int state) => {
  'userId': 1,
  'missionId': id,
  'state': state,
  'progress': 1,
  'readState': 1,
  'completedAt': 1673840594,
  'isNotifiable': false,
  'progressUpdatedAt': 1673840594,
};

String pullOfMission(List<Map<String, Object?>> rows, {String token = 'tok-1'}) =>
    jsonEncode({
      'code': 0,
      'table': {
        'replace': {'mission': rows},
      },
      'hash': {'mission': token},
    });

String pushOk() => jsonEncode({'code': 0, 'hash': {'mission': 'tok-2'}});

void main() {
  group('resetMissions', () {
    test('只把非可领取行改成 state=3，并带 hash.before.mission', () async {
      final transport = ScriptedTransport()
        ..scriptAll(kPullPath, [
          pullOfMission([
            mission(1, 3),
            mission(2, 4),
            mission(3, 4),
          ]),
          pullOfMission([
            mission(1, 3),
            mission(2, 3),
            mission(3, 3),
          ], token: 'tok-2'),
        ])
        ..script('/api/user/push', pushOk());
      final repository = ClaimRepository(LocalApiClient(transport));

      final result = await repository.resetMissions();
      expect(result, isA<Ok<MissionResetOutcome>>());
      final outcome = (result as Ok<MissionResetOutcome>).value;
      expect(outcome.updated, 2);
      expect(outcome.claimableAfter, 3);
      expect(outcome.claimedAfter, 0);
      expect(outcome.total, 3);
      expect(outcome.restored, isFalse);

      final body =
          jsonDecode(transport.bodiesFor('/api/user/push').single)
              as Map<String, Object?>;
      expect((body['hash'] as Map)['before'], {'mission': 'tok-1'});
      final table = (body['table'] as List).single as Map;
      final rows = ((table['put'] as Map)['mission'] as List)
          .cast<Map<String, Object?>>();
      expect(rows, [
        {'missionId': 2, 'state': 3},
        {'missionId': 3, 'state': 3},
      ]);
    });

    test('已经全部可领取时不写表，只回验结果', () async {
      final transport = ScriptedTransport()
        ..scriptAll(kPullPath, [
          pullOfMission([mission(1, 3), mission(2, 3)]),
          pullOfMission([mission(1, 3), mission(2, 3)]),
        ]);
      final repository = ClaimRepository(LocalApiClient(transport));

      final result = await repository.resetMissions();
      final outcome = (result as Ok<MissionResetOutcome>).value;
      expect(outcome.updated, 0);
      expect(outcome.claimableAfter, 2);
      expect(transport.countFor('/api/user/push'), 0);
    });
  });

  group('restoreMissions', () {
    test('把 state=3 改回 4，并返回撤销结果', () async {
      final transport = ScriptedTransport()
        ..scriptAll(kPullPath, [
          pullOfMission([mission(1, 3), mission(2, 3), mission(3, 4)]),
          pullOfMission([mission(1, 4), mission(2, 4), mission(3, 4)]),
        ])
        ..script('/api/user/push', pushOk());
      final repository = ClaimRepository(LocalApiClient(transport));

      final result = await repository.restoreMissions();
      final outcome = (result as Ok<MissionResetOutcome>).value;
      expect(outcome.updated, 2);
      expect(outcome.claimableAfter, 0);
      expect(outcome.claimedAfter, 3);
      expect(outcome.restored, isTrue);

      final body =
          jsonDecode(transport.bodiesFor('/api/user/push').single)
              as Map<String, Object?>;
      final table = (body['table'] as List).single as Map;
      final rows = ((table['put'] as Map)['mission'] as List)
          .cast<Map<String, Object?>>();
      expect(rows, [
        {'missionId': 1, 'state': 4},
        {'missionId': 2, 'state': 4},
      ]);
    });
  });

  test('push 被游戏拒绝时返回 Err，不谎报成功', () async {
    final transport = ScriptedTransport()
      ..scriptAll(kPullPath, [
        pullOfMission([mission(1, 4)]),
      ])
      ..script('/api/user/push', jsonEncode({'code': 400, 'message': 'bad rows'}));
    final repository = ClaimRepository(LocalApiClient(transport));

    final result = await repository.resetMissions();
    expect(result, isA<Err<MissionResetOutcome>>());
    final error = (result as Err<MissionResetOutcome>).error;
    expect(error.userMessage, contains('游戏拒绝了这次领取'));
    expect(error.detail, contains('code=400'));
  });
}
