import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/spine_path_table.dart';

const _sample = '''
{
  "schema": 2,
  "gameVersion": "3.7.0",
  "atlases": {
    "aaaa": {
      "path": "files/spine/characterAtlas/chara_2/edith_integrator.atlas",
      "kind": "characterAtlas", "dir": "chara_2",
      "category": "Characters", "group": "Edith", "label": "Integrator",
      "pages": ["edith_integrator.png", "edith_integrator2.png"]
    },
    "bbbb": {
      "path": "files/spine/faceAtlas/chara_2/edith_integrator.atlas",
      "kind": "faceAtlas", "dir": "chara_2",
      "category": "Characters", "group": "Edith", "label": "Integrator Face",
      "pages": ["edith_integrator.png"]
    },
    "cccc": {
      "path": "files/spine/weaponAtlas/01_sword/sword_r4_none_default.atlas",
      "kind": "weaponAtlas", "dir": "01_sword",
      "category": "Weapons", "group": "Sword", "label": "Sword R4 None Default",
      "pages": ["sword_r4_none_default.png"]
    }
  },
  "skeletons": {
    "dddd": {"path": "files/spine/characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc", "kind": "base"},
    "eeee": {"path": "files/spine/characterSpine/f_chara_2/f_chara_2_v0.4_edith_integrator.skelenc", "kind": "character"},
    "ffff": {"path": "files/spine/enemySpine/enemy_530_dragon/enemy_530_dragon.skelenc", "kind": "enemy"}
  },
  "variants": {
    "edith_integrator": {
      "atlases": [{"hash": "aaaa", "kind": "characterAtlas"}, {"hash": "bbbb", "kind": "faceAtlas"}],
      "skeletons": ["eeee"]
    },
    "sword_r4_none_default": {"atlases": [{"hash": "cccc", "kind": "weaponAtlas"}]}
  }
}
''';

void main() {
  late SpinePathTable table;

  setUp(() => table = SpinePathTable.parse(_sample));

  group('SpinePathTable 解析', () {
    test('读取基础统计与版本', () {
      expect(table.gameVersion, '3.7.0');
      expect(table.atlasCount, 3);
      expect(table.skeletonCount, 3);
      expect(table.variantCount, 2);
    });

    test('图集页路径按 pageRule 派生（同目录 + 页名 + .pkmenc）', () {
      final atlas = table.atlases['aaaa']!;
      expect(atlas.pagePaths, [
        'files/spine/characterAtlas/chara_2/edith_integrator.pkmenc',
        'files/spine/characterAtlas/chara_2/edith_integrator2.pkmenc',
      ]);
    });

    test('bodyAtlasOf 优先 characterAtlas，faceAtlasOf 取脸图集', () {
      expect(table.bodyAtlasOf('edith_integrator')!.hash, 'aaaa');
      expect(table.faceAtlasOf('edith_integrator')!.hash, 'bbbb');
      expect(table.bodyAtlasOf('not-exist'), isNull);
    });

    test('baseSkeleton 返回战斗素体（kind == base）', () {
      expect(table.baseSkeleton()!.hash, 'dddd');
      expect(table.baseSkeleton()!.path, contains('f_chara_2_v0.5_sword'));
    });

    test('skeletonOfVariant 取变体关联骨架', () {
      expect(table.skeletonOfVariant('edith_integrator')!.hash, 'eeee');
      expect(table.skeletonOfVariant('sword_r4_none_default'), isNull);
    });

    test('fetchListForVariant 合并 body/face 图集、页与骨架', () {
      final list = table.fetchListForVariant('edith_integrator');
      expect(list, [
        'files/spine/characterAtlas/chara_2/edith_integrator.atlas',
        'files/spine/characterAtlas/chara_2/edith_integrator.pkmenc',
        'files/spine/characterAtlas/chara_2/edith_integrator2.pkmenc',
        'files/spine/faceAtlas/chara_2/edith_integrator.atlas',
        'files/spine/faceAtlas/chara_2/edith_integrator.pkmenc',
        'files/spine/characterSpine/f_chara_2/f_chara_2_v0.4_edith_integrator.skelenc',
      ]);
    });

    test('allPaths 覆盖骨架 + 图集 + 页且不重复同一路径', () {
      final paths = table.allPaths().toList();
      expect(paths.length, 3 + 3 + 4);
      expect(paths.where((p) => p.endsWith('.skelenc')).length, 3);
      expect(paths.where((p) => p.endsWith('.pkmenc')).length, 4);
    });

    test('空表也能解析（容错）', () {
      final empty = SpinePathTable.parse('{}');
      expect(empty.atlasCount, 0);
      expect(empty.baseSkeleton(), isNull);
      expect(empty.fetchListForVariant('x'), isEmpty);
    });
  });

  group('真实 paths.json 形状抽样（若存在）', () {
    test('样例 JSON 与生成器字段名一致', () {
      // 生成器写的 stats 字段不影响解析；这里确认额外字段不会让解析失败
      final withStats = SpinePathTable.parse(
        const JsonEncoder.withIndent(' ').convert({
          'stats': {'atlases': 3, 'skeletons': 3},
          'atlases': <String, dynamic>{},
          'skeletons': <String, dynamic>{},
          'variants': <String, dynamic>{},
        }),
      );
      expect(withStats.atlasCount, 0);
    });
  });
}
