import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/domain/model_enum.dart';

void main() {
  group('parseModelEnum', () {
    test('正常 JSON', () {
      final s = parseModelEnum(
        '{"characters":["alice","eugeo"],"counts":{"alice":3}}',
      );
      expect(s.characters, ['alice', 'eugeo']);
    });

    test('尾部空格（定长补齐文件）不影响解析', () {
      final s = parseModelEnum(
        '{"characters":["alice"]}\n${' ' * 100}',
      );
      expect(s.characters, ['alice']);
    });

    test('日志前缀混入时从第一个 { 截取', () {
      final s = parseModelEnum(
        '[saoub-model] ENUM written #1\n{"characters":["eugeo"]}',
      );
      expect(s.characters, ['eugeo']);
    });

    test('空串 → 空列表不抛', () {
      expect(parseModelEnum('').characters, isEmpty);
    });

    test('非 JSON → 空列表不抛', () {
      expect(parseModelEnum('not json at all').characters, isEmpty);
    });

    test('缺 characters 键 → 空列表', () {
      expect(parseModelEnum('{"counts":{}}').characters, isEmpty);
    });
  });
}
