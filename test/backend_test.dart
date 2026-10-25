import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/backend.dart';

import 'support/fake_transport.dart';

/// 换模型的测试替身：不碰 root、不碰设备。
final class _FakeModelSwap implements ModelSwapApi {
  @override
  Future<SwapStatus> status() async => const SwapStatus(
    hasRoot: true,
    gameRunning: true,
    injectorRunning: false,
    gamePid: '4821',
  );

  @override
  Future<Result<List<String>>> deploy() async => const Ok(['注入器就绪']);

  @override
  Future<Result<String>> start() async => const Ok('注入器已启动');

  @override
  Future<Result<void>> stop() async => const Ok(null);

  @override
  Future<Result<void>> applyRule(ModelSwapRule? rule) async => const Ok(null);

  @override
  Future<Result<ModelEnumSnapshot>> readEnum() async =>
      const Ok(ModelEnumSnapshot(characters: ['kirito', 'eugeo']));

  @override
  Future<Result<Map<String, String>>> readNames() async =>
      const Ok({'kirito': '桐人'});

  @override
  Future<Result<Map<String, String>>> readVariantBones() async =>
      const Ok({'kirito_cathedral': 'chara_1'});

  @override
  Future<Result<String>> logSnapshot() async => const Ok('日志');
}

Future<List<int>> _fakeAssets(String asset) async => utf8.encode(
  jsonEncode({
    'characters': {
      '100': {'imaginationId': 9001, 'slots': 4},
    },
  }),
);

void main() {
  group('YuiHelperBackend 装配', () {
    test('ping 走 mission/refresh，成功返回 Ok(true)', () async {
      final transport = ScriptedTransport()
        ..script(kPingPath, jsonEncode({'code': 0}));
      final backend = YuiHelperBackend(
        transport: transport,
        modelSwapApi: _FakeModelSwap(),
      );

      final result = await backend.ping();
      expect(result, isA<Ok<bool>>());
      expect((result as Ok<bool>).value, isTrue);
      expect(transport.paths, [kPingPath]);
      expect(backend.endpoint, 'injected');
    });

    test('默认构造使用真实 HTTP transport，端点可展示', () {
      final backend = YuiHelperBackend(modelSwapApi: _FakeModelSwap());
      expect(backend.endpoint, 'http://127.0.0.1:18680');
    });

    test('领取使命：过滤 state!=3，按服务端 put 行数算到账', () async {
      final transport = ScriptedTransport()
        ..script(kPullPath, pullOf(mission: missionsOf([3, 3, 4])))
        ..script(
          kMissionPath,
          okWith(put: {
            'mission': [
              {'missionId': 1},
              {'missionId': 2},
            ],
          }),
        );
      final backend = YuiHelperBackend(transport: transport);

      final result = await backend.claims.claimMissions();
      final outcome = (result as Ok<ClaimOutcome>).value;
      expect(outcome.claimedCount, 2);
      expect(outcome.summary, '已领取 2 项使命');
      expect(transport.bodiesFor(kMissionPath).single, contains('15000000001'));
    });

    test('领取礼物盒：到账 = 提交数 − 服务端剩余行数', () async {
      final transport = ScriptedTransport()
        ..script(kPullPath, pullOf(gift: [{'id': 1}, {'id': 2}]))
        ..script(
          kGiftPath,
          jsonEncode({
            'code': 0,
            'table': {
              'replace': {'gift': <Object?>[]},
            },
          }),
        );
      final backend = YuiHelperBackend(transport: transport);

      final result = await backend.claims.claimGifts();
      expect((result as Ok<ClaimOutcome>).value.claimedCount, 2);
    });

    test('装配想象力：只填空槽并写 pc 行（带 hash.before.pc）', () async {
      final transport = ScriptedTransport()
        ..script(
          kPullPath,
          jsonEncode({
            'code': 0,
            'hash': {
              'pc': 'token-1',
            },
            'table': {
              'replace': {
                'pc': [
                  {
                    'pcId': 100,
                    'lastImaginationUnlockCount': 4,
                    'imaginationSlots': <Object?>[],
                  },
                ],
              },
            },
          }),
        )
        ..script(
          kPullPath,
          jsonEncode({
            'code': 0,
            'table': {
              'replace': {
                'imaginationStock': [
                  {'id': 1, 'imaginationId': 9001},
                  {'id': 2, 'imaginationId': 9001},
                ],
              },
            },
          }),
        )
        ..script(
          '/api/user/push',
          jsonEncode({'code': 0, 'table': <String, Object?>{}}),
        );
      final backend = YuiHelperBackend(
        transport: transport,
        modelSwapApi: _FakeModelSwap(),
        loadAsset: _fakeAssets,
      );

      final result = await backend.imagination.equipExclusive();
      expect(result, isA<Ok<String>>());
      expect((result as Ok<String>).value, contains('已给 1 个角色'));
      final pushBody = jsonDecode(transport.bodiesFor('/api/user/push').single)
          as Map<String, Object?>;
      expect((pushBody['hash'] as Map)['before'], {'pc': 'token-1'});
    });

    test('换模型：注入的 ModelSwapApi 原样生效', () async {
      final backend = YuiHelperBackend(
        transport: ScriptedTransport(),
        modelSwapApi: _FakeModelSwap(),
      );

      final status = await backend.modelSwap.status();
      expect(status.hasRoot, isTrue);
      expect(status.gamePid, '4821');
      final names = await backend.modelSwap.readNames();
      expect((names as Ok<Map<String, String>>).value['kirito'], '桐人');
    });
  });
}
