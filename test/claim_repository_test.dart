import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/claim_repository.dart';
import 'package:yui_helper_next/data/local_api_client.dart';
import 'package:yui_helper_next/domain/result.dart';
import 'package:yui_helper_next/domain/season_convergence.dart';

import 'support/fake_transport.dart';

void main() {
  late ScriptedTransport fake;
  late ClaimRepository repo;

  setUp(() {
    fake = ScriptedTransport();
    repo = ClaimRepository(LocalApiClient(fake));
  });

  group('失败绝不报告成功', () {
    test('服务端 code!=0 → Err(serverCode)，并带上服务端的 message', () async {
      fake.script(kPullPath, pullOf(mission: missionsOf([3])));
      fake.script(
        kMissionPath,
        jsonEncode({'code': 400, 'message': 'Mission 15000000001 is incomplete'}),
      );

      final result = await repo.claimMissions();

      expect(result, isA<Err<ClaimOutcome>>());
      final error = (result as Err<ClaimOutcome>).error;
      expect(error.kind, AppErrorKind.serverCode);
      expect(error.detail, contains('is incomplete'));
    });

    test('pull 本身失败时把错误原样返回，不吞成「0 项」', () async {
      // 没有任何脚本 → 假传输层返回 badJson
      final result = await repo.claimMissions();

      expect(result, isA<Err<ClaimOutcome>>());
      expect((result as Err<ClaimOutcome>).error.kind, AppErrorKind.badJson);
    });
  });

  group('连接自检', () {
    test('引擎有响应 → Ok(true)', () async {
      fake.script(kPingPath, '{"code":0}');

      expect(await repo.ping(), isA<Ok<bool>>());
    });

    test('引擎没响应 → 原样透传错误', () async {
      expect(await repo.ping(), isA<Err<bool>>());
    });
  });

  group('拉表失败不能伪装成「没有可领的东西」', () {
    // user/pull 也会回 code != 0（例如 Local runtime is not initialized）。
    // 当成"表是空的"，用户会看到「本版本无内容」这种假无事，直接放弃。
    const errorPull = '{"code":500,"message":"Local runtime is not initialized"}';

    test('使命', () async {
      fake.script(kPullPath, errorPull);
      final result = await repo.claimMissions();

      expect(result, isA<Err<ClaimOutcome>>());
      expect((result as Err<ClaimOutcome>).error.kind, AppErrorKind.serverCode);
    });

    test('礼物盒', () async {
      fake.script(kPullPath, errorPull);
      expect(await repo.claimGifts(), isA<Err<ClaimOutcome>>());
    });

    test('赛季', () async {
      fake.script(kPullPath, errorPull);
      expect(await repo.claimSeasonRewards(), isA<Err<ClaimOutcome>>());
    });

    test('活动角色', () async {
      fake.script(kPullPath, errorPull);
      expect(await repo.claimEventCharacterRewards(), isA<Err<ClaimOutcome>>());
    });
  });

  group('坏 id 不该让整批归零', () {
    test('整批被拒时降级按块重试，坏块之外的照领', () async {
      // 600 条 → 整批 + 3 块（256 / 256 / 88）
      final ids = List.generate(600, (i) => 15000000001 + i);
      fake.script(
        kPullPath,
        pullOf(mission: [
          for (final id in ids) {'missionId': id, 'state': 3},
        ]),
      );
      fake.scriptAll(kMissionPath, [
        jsonEncode({'code': 400, 'message': 'Unknown mission 15000000001'}),
        jsonEncode({'code': 400, 'message': 'Unknown mission 15000000001'}),
        okWith(put: {
          'mission': [
            for (var i = 0; i < 256; i++) {'missionId': 15000900000 + i, 'state': 4},
          ],
        }),
        okWith(put: {
          'mission': [
            for (var i = 0; i < 88; i++) {'missionId': 15000990000 + i, 'state': 4},
          ],
        }),
      ]);

      final outcome = (await repo.claimMissions()) as Ok<ClaimOutcome>;

      expect(outcome.value.claimedCount, 344);
      expect(outcome.value.summary, contains('344'));
      expect(outcome.value.summary, contains('256')); // 被拒条数
      expect(outcome.value.log.join(), contains('256'));
    });
  });

  group('使命', () {
    test('没有 state==3 的任务时不发 receive 请求，claimedCount=0', () async {
      fake.script(kPullPath, pullOf(mission: missionsOf([4, 4])));

      final result = await repo.claimMissions();

      expect(result, isA<Ok<ClaimOutcome>>());
      expect((result as Ok<ClaimOutcome>).value.claimedCount, 0);
      expect(fake.paths, [kPullPath]);
      expect(fake.countFor(kMissionPath), 0);
    });

    test('只把 state==3 的 id 提交上去', () async {
      fake.script(kPullPath, pullOf(mission: missionsOf([3, 4, 3, 1])));
      fake.script(kMissionPath, okWith());

      await repo.claimMissions();

      final body = jsonDecode(fake.bodiesFor(kMissionPath).single)
          as Map<String, Object?>;
      expect(body['missionIds'], [15000000001, 15000000003]);
    });

    test('claimedCount 等于服务端回报的变动行数', () async {
      fake.script(kPullPath, pullOf(mission: missionsOf([3, 3, 3])));
      fake.script(
        kMissionPath,
        okWith(put: {
          'mission': [
            {'missionId': 15000000001, 'state': 4},
            {'missionId': 15000000002, 'state': 4},
            {'missionId': 15000000003, 'state': 4},
          ],
        }),
      );

      final outcome = (await repo.claimMissions()) as Ok<ClaimOutcome>;

      expect(outcome.value.claimedCount, 3);
      expect(outcome.value.summary, contains('3'));
    });
  });

  group('礼物盒', () {
    test('表为空 → claimedCount=0，summary 说明本版本无内容', () async {
      fake.script(kPullPath, pullOf(gift: const []));

      final outcome = (await repo.claimGifts()) as Ok<ClaimOutcome>;

      expect(outcome.value.claimedCount, 0);
      expect(outcome.value.summary, contains('本版本无内容'));
      expect(fake.countFor(kGiftPath), 0);
    });

    test('按服务端实际移除的行数报领取条数（表里还有剩的就不算）', () async {
      fake.script(kPullPath, pullOf(gift: [
        {'id': 900},
        {'id': 901},
      ]));
      // 服务端回的是「领完之后剩下的礼物表」：两条都被领走了
      fake.script(
        kGiftPath,
        jsonEncode({
          'code': 0,
          'table': {
            'replace': {'gift': <Object?>[]},
          },
        }),
      );

      final outcome = (await repo.claimGifts()) as Ok<ClaimOutcome>;

      expect(outcome.value.claimedCount, 2);
      final body = jsonDecode(fake.bodiesFor(kGiftPath).single)
          as Map<String, Object?>;
      expect(body['giftIds'], [900, 901]);
    });
  });

  group('赛季奖励多轮收敛', () {
    test('某轮零增长即停，不多发一轮', () async {
      fake.script(kPullPath, pullOf(seasonReward: seasonOf({11: 0})));
      fake.script(kSeasonPath, okWith());

      final outcome = (await repo.claimSeasonRewards()) as Ok<ClaimOutcome>;

      expect(fake.countFor(kSeasonPath), 1);
      expect(outcome.value.claimedCount, 0);
    });

    test('被截顶的 id 会再来一轮，且下一轮重复次数翻倍', () async {
      fake.scriptAll(kPullPath, [
        pullOf(seasonReward: seasonOf({11: 0})), // 第 1 轮前
        pullOf(seasonReward: seasonOf({11: 30})), // 第 1 轮后：恰好等于 30 → 截顶
        pullOf(seasonReward: seasonOf({11: 40})), // 第 2 轮后：只涨了 10 → 收敛
      ]);
      fake.script(kSeasonPath, okWith());

      final outcome = (await repo.claimSeasonRewards()) as Ok<ClaimOutcome>;

      expect(fake.countFor(kSeasonPath), 2);
      final bodies = fake.bodiesFor(kSeasonPath);
      expect(
        (jsonDecode(bodies[0]) as Map<String, Object?>)['seasonRewardIds'],
        List<int>.filled(30, 11),
      );
      expect(
        (jsonDecode(bodies[1]) as Map<String, Object?>)['seasonRewardIds'],
        List<int>.filled(60, 11),
      );
      // 累计到账 = 30 + 10
      expect(outcome.value.claimedCount, 40);
    });

    test('永远被截顶也不会超过 kSeasonMaxRounds 轮', () async {
      // 构造一条「每一轮都刚好涨满」的曲线：repeat 依次是 30/60/120/240/480/960，
      // 于是每轮后的 acquiredCount 是 30/90/210/450/930/1890 —— 每轮都被截顶。
      fake.scriptAll(kPullPath, [
        pullOf(seasonReward: seasonOf({11: 0})), // 起手
        pullOf(seasonReward: seasonOf({11: 30})),
        pullOf(seasonReward: seasonOf({11: 90})),
        pullOf(seasonReward: seasonOf({11: 210})),
        pullOf(seasonReward: seasonOf({11: 450})),
        pullOf(seasonReward: seasonOf({11: 930})),
        pullOf(seasonReward: seasonOf({11: 1890})),
      ]);
      fake.script(kSeasonPath, okWith());

      final outcome = (await repo.claimSeasonRewards()) as Ok<ClaimOutcome>;

      // 六轮都判定为「还需要下一轮」，但必须被上限截住，而不是一直转下去。
      expect(fake.countFor(kSeasonPath), kSeasonMaxRounds);
      expect(outcome.value.claimedCount, 1890);
    });

    test('没有赛季奖励行 → 本版本无内容，不发请求', () async {
      fake.script(kPullPath, pullOf(seasonReward: const []));

      final outcome = (await repo.claimSeasonRewards()) as Ok<ClaimOutcome>;

      expect(outcome.value.summary, contains('本版本无内容'));
      expect(fake.countFor(kSeasonPath), 0);
    });
  });

  group('活动角色达成奖励', () {
    test('服务端无 table 变更 → 报告本版本无内容', () async {
      fake.script(kPullPath, pullOf(eventCharacterReward: const []));
      fake.script(kEventCharPath, okWith());

      final outcome =
          (await repo.claimEventCharacterRewards()) as Ok<ClaimOutcome>;

      expect(outcome.value.claimedCount, 0);
      expect(outcome.value.summary, contains('本版本无内容'));
    });
  });
}
