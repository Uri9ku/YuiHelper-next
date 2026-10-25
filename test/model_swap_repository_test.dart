import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/model_swap_repository.dart';
import 'package:yui_helper_next/data/root_shell.dart';
import 'package:yui_helper_next/domain/model_enum.dart';
import 'package:yui_helper_next/domain/model_swap_rule.dart';
import 'package:yui_helper_next/domain/result.dart';

/// 可编程的假 su：记录命令串、按脚本回话。
class FakeShell {
  final List<String> commands = [];

  /// key → 回复。按"包含 key"匹配，**最长的 key 优先**，
  /// 避免 `id` 这种短 key 抢走 `pidof ...` 的命令。
  final Map<String, String Function(String cmd)> replies = {};

  /// 命中这些 key 的命令返回指定的非零退出码（用来测失败分支）。
  final Map<String, int> failCodes = {};

  Future<ShellResult> run(String cmd, {Duration timeout = const Duration(seconds: 8)}) async {
    commands.add(cmd);
    final keys = replies.keys.where(cmd.contains).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final failKey = failCodes.keys.where(cmd.contains).toList();
    final code = failKey.isEmpty ? 0 : failCodes[failKey.first]!;
    if (keys.isNotEmpty) return ShellResult(code, replies[keys.first]!(cmd));
    return ShellResult(code, '');
  }
}

void main() {
  late FakeShell shell;
  late ModelSwapRepository repo;

  setUp(() {
    shell = FakeShell();
    repo = ModelSwapRepository(shell: shell.run, assets: FakeAssets());
  });

  group('status', () {
    test('三种环境事实按 su 输出分类', () async {
      shell.replies['id'] = (_) => 'uid=0(root) gid=0(root)';
      shell.replies['pidof com.bandainamcoent.saoars'] = (_) => '4321';
      shell.replies['pidof saoub-model-inject'] = (_) => '';

      final s = await repo.status();
      expect(s.hasRoot, isTrue);
      expect(s.gameRunning, isTrue);
      expect(s.gamePid, '4321');
      expect(s.injectorRunning, isFalse);
    });

    test('无 root', () async {
      shell.replies['id'] = (_) => 'uid=10286(u0_a286)';
      final s = await repo.status();
      expect(s.hasRoot, isFalse);
    });
  });

  group('deploy', () {
    test('部署命令含二进制与脚本的目标路径和 chmod 755', () async {
      final r = await repo.deploy();
      final all = shell.commands.join('\n');
      expect(all, contains('/data/local/tmp/saoub-model-inject'));
      expect(all, contains('chmod 755'));
      expect(all, contains('/data/local/tmp/saoub-model.js'));
      expect(r, isA<Ok<List<String>>>());
    });

    test('部署静态配对表（身体 id → 脸 id）', () async {
      await repo.deploy();
      final all = shell.commands.join('\n');
      expect(all, contains('saoub-model-pairs.json'));
    });

    test('读取骨架集表（图集变体 → chara_N）', () async {
      final r = await repo.readVariantBones();
      expect(r, isA<Ok<Map<String, String>>>());
      final m = (r as Ok<Map<String, String>>).value;
      expect(m['kirito_cathedral'], 'chara_1');
      expect(m['alice_integrator'], 'chara_2');
    });
    test('部署骨架集表（图集变体 → chara_N）', () async {
      await repo.deploy();
      final all = shell.commands.join('\n');
      expect(all, contains('saoub-model-bones.json'));
    });

    test('脚本资产含非 UTF-8 字节时也能部署（原样写盘，不 decode）', () async {
      final repo2 = ModelSwapRepository(
        shell: shell.run,
        assets: RawScriptAssets(),
      );
      final r = await repo2.deploy();
      expect(r, isA<Ok<List<String>>>());
      expect(shell.commands.any((c) => c.contains('saoub-model.js')), isTrue);
    });

    test('预建规则/枚举文件为 666', () async {
      await repo.deploy();
      final all = shell.commands.join('\n');
      expect(all, contains('saoub-model-rules.json'));
      expect(all, contains('chmod 666'));
    });
  });

  group('start / stop', () {
    setUp(() {
      shell.replies['id'] = (_) => 'uid=0(root)';
      shell.replies['pidof com.bandainamcoent.saoars'] = (_) => '4321';
    });

    test('按 pid 注入而不是按名字', () async {
      shell.replies['pidof saoub-model-inject'] = (_) => '9999';
      final r = await repo.start();
      final startCmd = shell.commands.firstWhere((c) => c.contains('nohup'));
      expect(startCmd, contains('-p 4321'));
      expect(startCmd, isNot(contains('-n SAOUB')));
      expect(startCmd, contains('saoub-model.js'));
      expect((r as Ok<String>).value, contains('9999'));
    });

    test('游戏没开 → 明确的 Err', () async {
      shell.replies['pidof com.bandainamcoent.saoars'] = (_) => '';
      final r = await repo.start();
      expect((r as Err<String>).error.userMessage, contains('先打开游戏'));
    });

    test('没有 root 时给 root 文案，而不是误报「先打开游戏」', () async {
      shell.replies['id'] = (_) => 'uid=10286(u0_a286)';
      shell.replies['pidof com.bandainamcoent.saoars'] = (_) => '';
      final r = await repo.start();
      expect((r as Err<String>).error.userMessage, contains('root'));
    });

    test('停注入后 pid 仍在 → Err，不让界面假装已停', () async {
      // pkill 的退出码不可信（su 的 shell 自身可能被 -f 匹配到），
      // 判据是 pidof 复核：注入器还在跑才算失败。
      shell.failCodes['pkill -f saoub-model-inject'] = 2;
      shell.replies['pidof saoub-model-inject'] = (_) => '9999';
      final r = await repo.stop();
      expect(r, isA<Err<void>>());
      expect((r as Err<void>).error.userMessage, contains('停'));
    });

    test('停注入后 pid 消失 → Ok（即使 pkill 退出码是 143）', () async {
      shell.failCodes['pkill -f saoub-model-inject'] = 143;
      shell.replies['pidof saoub-model-inject'] = (_) => '';
      final r = await repo.stop();
      expect(r, isA<Ok<void>>());
    });

    test('启动失败时附上注入器日志', () async {
      shell.replies['pidof saoub-model-inject'] = (_) => '';
      shell.replies['tail -25'] = (_) => 'Segmentation fault';
      final r = await repo.start();
      final err = (r as Err<String>).error;
      expect(err.userMessage, contains('注入器没起来'));
      expect(err.detail, contains('Segmentation fault'));
    });

    test('stop 的 pkill 只针对自己的注入器', () async {
      await repo.stop();
      final pkills = shell.commands.where((c) => c.contains('pkill')).toList();
      expect(pkills, isNotEmpty);
      for (final cmd in pkills) {
        expect(cmd, contains('saoub-model-inject'));
        expect(cmd, isNot(contains(' saoub-inject')));
      }
    });
  });

  group('applyRule', () {
    test('写 models JSON 并 cp 到规则文件', () async {
      shell.replies['echo OK_RULES'] = (_) => 'OK_RULES';
      final r = await repo.applyRule(
        const ModelSwapRule(from: 'kirito_cathedral', to: 'alice_integrator'),
      );
      expect(r, isA<Ok<void>>());
      // JSON 在本地暂存文件里，su 只负责 cp —— 从暂存文件读回验证内容
      final staged = File(
        '${Directory.systemTemp.path}/saoub-model-rules.json',
      ).readAsStringSync();
      expect(staged, '{"rules":{"models":{"kirito_cathedral":"alice_integrator"}}}');
      final all = shell.commands.join('\n');
      expect(all, contains("cp -f "));
      expect(all, contains('saoub-model-rules.json'));
    });

    test('null 规则 = 关闭替换（空表）', () async {
      await repo.applyRule(null);
      final staged = File(
        '${Directory.systemTemp.path}/saoub-model-rules.json',
      ).readAsStringSync();
      expect(staged, '{"rules":{"models":{}}}');
    });
  });

  group('readEnum', () {
    test('正常解析', () async {
      shell.replies['cat /data/local/tmp/saoub-model-enum.json'] = (_) =>
          '{"characters":["alice_integrator"]}';
      final r = await repo.readEnum();
      expect((r as Ok<ModelEnumSnapshot>).value.characters, ['alice_integrator']);
    });

    test('脏数据容错', () async {
      shell.replies['cat /data/local/tmp/saoub-model-enum.json'] = (_) =>
          '[saoub-model] noise\n{"characters":["eugeo"]}   ';
      final r = await repo.readEnum();
      expect((r as Ok<ModelEnumSnapshot>).value.characters, ['eugeo']);
    });
  });

  group('readNames', () {
    test('内置表被设备覆盖文件优先', () async {
      shell.replies['cat /data/local/tmp/saoub-model-names.tsv'] = (_) =>
          'char\tkirito\t桐人（自訂）\n';
      final r = await repo.readNames();
      final t = (r as Ok<Map<String, String>>).value;
      expect(t['kirito'], '桐人（自訂）');
      // 内置表里的其它条目仍在
      expect(t, containsPair('alice_integrator', '史提西亞亞絲娜'));
    });
  });

  group('logSnapshot', () {
    test('tail + MODEL 计数 + MISMATCH 计数一起取回', () async {
      shell.replies['tail -25'] = (_) =>
          '[saoub-model] MODEL a -> b\n@@@COUNTS\n3\n0\n1024';
      final r = await repo.logSnapshot();
      expect((r as Ok<String>).value, contains('MODEL a -> b'));
      expect(shell.commands.single, contains("grep -c 'MODEL '"));
      expect(shell.commands.single, contains("grep -c 'OFFSET MISMATCH'"));
    });
  });
}

class FakeAssets implements SwapAssets {
  final bin = [1, 2, 3];
  final script = utf8.encode('console.log("x")');
  final names = utf8.encode(
    'char\talice_integrator\t史提西亞亞絲娜\nchar\tkirito\t桐人\n',
  );
  final pairs = utf8.encode(r'{"variants":{"kirito_cathedral":"kirito"}}');
  final seed = utf8.encode(r'{"skeletons":{"chara_2":"f_chara_2_v0.4_sword"}}');
  final bones = utf8.encode(
    r'{"variants":{"kirito_cathedral":"chara_1","alice_integrator":"chara_2"}}',
  );

  @override
  Future<List<int>> load(String asset) async {
    if (asset == 'assets/frida-inject') return bin;
    if (asset == 'assets/saoars_model.js') return script;
    if (asset == 'assets/names.tsv') return names;
    if (asset == 'assets/model_pairs.json') return pairs;
    if (asset == 'assets/model_bones.json') return bones;
    if (asset == 'assets/model_skeletons_seed.json') return seed;
    throw StateError('unexpected asset $asset');
  }
}

/// 脚本资产用非 UTF-8 字节：deploy 必须原样写盘，不能先 decode 再 encode。
class RawScriptAssets extends FakeAssets {
  final inValidUtf8 = [0xff, 0xfe, 0x00, 0x41, 0x80];

  @override
  Future<List<int>> load(String asset) async =>
      asset == 'assets/saoars_model.js' ? inValidUtf8 : super.load(asset);
}
