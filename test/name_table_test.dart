import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/domain/name_table.dart';

void main() {
  group('parseNameTable', () {
    test('char 行入表，中文映射正确', () {
      final t = parseNameTable(
        'char\talice_integrator\t史提西亞亞絲娜\n'
        'char\tkirito\t桐人\n',
      );
      expect(t['alice_integrator'], '史提西亞亞絲娜');
      expect(t['kirito'], '桐人');
    });

    test('anim/base/token 行忽略', () {
      final t = parseNameTable(
        'anim\tidle_front\t正面待機\n'
        'base\teugeo\t尤吉歐\n'
        'token\tintegrator\t整合騎士\tpre\n'
        'char\tkirito\t桐人\n',
      );
      expect(t, hasLength(1));
      expect(t['kirito'], '桐人');
    });

    test('注释行与空行忽略', () {
      final t = parseNameTable(
        '# SAOUB names\n'
        '\n'
        'char\tkirito\t桐人\n',
      );
      expect(t, hasLength(1));
    });

    test('重复 id 后行覆盖前行', () {
      final t = parseNameTable(
        'char\tkirito\t桐人（旧）\n'
        'char\tkirito\t桐人（自訂）\n',
      );
      expect(t['kirito'], '桐人（自訂）');
    });

    test('空文件 → 空 Map', () {
      expect(parseNameTable(''), isEmpty);
    });

    test('字段不足的行跳过不崩', () {
      final t = parseNameTable('char\tkirito\nchar\talice\t亞絲娜\n');
      expect(t, hasLength(1));
      expect(t['alice'], '亞絲娜');
    });
  });
}
