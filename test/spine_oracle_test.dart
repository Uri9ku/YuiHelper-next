import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/root_shell.dart';
import 'package:yui_helper_next/data/spine/spine_oracle.dart';

/// 可编排的假 shell：按命令前缀返回预设结果，并在 [calls] 里记录顺序。
final class FakeShell {
  FakeShell({
    this.root = true,
    this.gamePid = '4242',
    this.resultJson = '',
    this.resultBytes = const <int>[],
    this.statSizes = const <String, String>{},
  });

  final bool root;
  final String gamePid;
  final String resultJson;
  final List<int> resultBytes;
  final Map<String, String> statSizes;
  final List<String> calls = <String>[];

  Future<ShellResult> call(String cmd, {Duration timeout = const Duration(seconds: 8)}) async {
    calls.add(cmd);
    if (cmd == 'id') {
      return ShellResult(0, root ? 'uid=0(root) gid=0(root) groups=0(root)' : 'uid=10123(u0_a123)');
    }
    if (cmd.startsWith('pidof ')) return ShellResult(0, gamePid);
    if (cmd.startsWith('mkdir ')) return const ShellResult(0, '');
    if (cmd.startsWith('stat -c %s')) {
      for (final entry in statSizes.entries) {
        if (cmd.contains(entry.key)) return ShellResult(0, entry.value);
      }
      return const ShellResult(0, '-1');
    }
    if (cmd.startsWith('rm -rf ')) return const ShellResult(0, '');
    if (cmd.contains('spine-inject -p')) return const ShellResult(0, '');
    if (cmd.startsWith('base64 ')) return ShellResult(0, base64Encode(resultBytes));
    if (cmd.startsWith('cat ') && cmd.contains('result.json')) return ShellResult(0, resultJson);
    if (cmd.startsWith('cat ')) return const ShellResult(0, '');
    if (cmd.startsWith('cp ')) return const ShellResult(0, '');
    return const ShellResult(0, '');
  }
}

// 假资产：长度与 statSizes 匹配，避免触发 59MB 拷贝分支
final Uint8List _fakeInjector = Uint8List.fromList(List<int>.filled(3, 7));
final Uint8List _fakeScript = Uint8List.fromList(List<int>.filled(5, 9));

Future<Uint8List> _fakeAssets(String asset) async {
  if (asset.endsWith('frida-inject')) return _fakeInjector;
  return _fakeScript;
}

const _skelPath = 'files/spine/characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc';
const _pagePath = 'files/spine/characterAtlas/chara_2/edith_integrator.pkmenc';

void main() {
  group('SpineOracle.fetch', () {
    test('成功取回骨架明文，页贴图失败如实记录（不静默）', () async {
      final resultJson = jsonEncode([
        {
          'n': 1,
          'path': _skelPath,
          'file': 'out/1.bin',
          'size': 3,
          'head': '1c0001',
          'err': null,
        },
        {
          'n': 2,
          'path': _pagePath,
          'file': null,
          'size': -1,
          'head': null,
          'err': 'no data (f8=0)',
        },
      ]);
      final shell = FakeShell(
        resultJson: resultJson,
        resultBytes: const [0x1c, 0x00, 0x01],
        statSizes: const {
          'spine-inject': '3',
          'spine_fetch.js': '5',
        },
      );
      final stages = <String>[];
      final oracle = SpineOracle(shell: shell.call, assets: _fakeAssets);

      final result = await oracle.fetch([_skelPath, _pagePath], onProgress: stages.add);

      expect(result.assets.keys, [_skelPath]);
      final asset = result.assets[_skelPath]!;
      expect(asset.size, 3);
      expect(asset.looksLikeSkeleton, isTrue);
      expect(asset.head, startsWith('1c'));
      expect(result.failures[_pagePath], contains('no data'));
      expect(stages, isNotEmpty);
      // 注入命令用的是游戏 pid，且脚本/注入器都在 /data/local/tmp
      expect(shell.calls.any((c) => c.contains('pidof com.bandainamcoent.saoars')), isTrue);
      expect(shell.calls.any((c) => c.contains('spine-inject -p 4242 -s')), isTrue);
      expect(shell.calls.any((c) => c.contains('/data/local/tmp/yui-spine/spine_fetch.js')), isTrue);
    });

    test('没有 root 时抛 noRoot，不执行注入', () async {
      final shell = FakeShell(root: false);
      final oracle = SpineOracle(shell: shell.call, assets: _fakeAssets);
      await expectLater(
        oracle.fetch([_skelPath]),
        throwsA(isA<SpineOracleException>().having((e) => e.failure, 'failure', OracleFailure.noRoot)),
      );
      expect(shell.calls.any((c) => c.contains('spine-inject -p')), isFalse);
    });

    test('游戏没运行抛 gameNotRunning 并给出可操作文案', () async {
      final shell = FakeShell(gamePid: '');
      final oracle = SpineOracle(shell: shell.call, assets: _fakeAssets);
      await expectLater(
        oracle.fetch([_skelPath]),
        throwsA(isA<SpineOracleException>()
            .having((e) => e.failure, 'failure', OracleFailure.gameNotRunning)
            .having((e) => e.message, 'message', contains('先打开游戏'))),
      );
    });

    test('脚本没产出 result.json 时抛 badResult（带 done 状态）', () async {
      final shell = FakeShell(resultJson: '');
      final oracle = SpineOracle(shell: shell.call, assets: _fakeAssets);
      await expectLater(
        oracle.fetch([_skelPath]),
        throwsA(isA<SpineOracleException>().having((e) => e.failure, 'failure', OracleFailure.badResult)),
      );
    });

    test('空请求直接返回空结果，不做任何设备操作', () async {
      final shell = FakeShell();
      final oracle = SpineOracle(shell: shell.call, assets: _fakeAssets);
      final result = await oracle.fetch(const []);
      expect(result.isEmpty, isTrue);
      expect(shell.calls, isEmpty);
    });

    test('脚本未返回的路径记为"脚本未返回"', () async {
      final shell = FakeShell(
        resultJson: '[]',
        resultBytes: const [0x1c],
        statSizes: const {'spine-inject': '3', 'spine_fetch.js': '5'},
      );
      final oracle = SpineOracle(shell: shell.call, assets: _fakeAssets);
      final result = await oracle.fetch([_skelPath]);
      expect(result.failures[_skelPath], '脚本未返回');
    });
  });
}
