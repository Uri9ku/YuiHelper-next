import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/domain/model_swap_rule.dart';
import 'package:yui_helper_next/domain/result.dart';

void main() {
  group('buildModelRulesJson', () {
    test('有规则时输出 models 表', () {
      final json = buildModelRulesJson(
        const ModelSwapRule(from: 'kirito_cathedral', to: 'alice_integrator'),
      );
      expect(json, '{"rules":{"models":{"kirito_cathedral":"alice_integrator"}}}');
    });

    test('null 规则 = 空 models 表（关闭替换）', () {
      expect(buildModelRulesJson(null), '{"rules":{"models":{}}}');
    });

    test('id 里的 JSON 特殊字符会被正确转义', () {
      final json = buildModelRulesJson(
        const ModelSwapRule(from: r'a$b', to: 'x.y'),
      );
      expect(json, '{"rules":{"models":{"a\$b":"x.y"}}}');
    });
  });

  group('validateModelIds', () {
    test('合法的一对通过', () {
      final r = validateModelIds('kirito_cathedral', 'alice_integrator');
      expect(r, isA<Ok<void>>());
    });

    test('空 id 拒绝', () {
      final r = validateModelIds('', 'alice_integrator');
      expect((r as Err<void>).error.userMessage, contains('角色'));
    });

    test('超长 id（>64）拒绝', () {
      final long = 'a' * 65;
      final r = validateModelIds(long, 'alice_integrator');
      expect(r, isA<Err<void>>());
    });

    test('非法字符拒绝', () {
      final r = validateModelIds('kirito cathedral', 'alice_integrator');
      expect(r, isA<Err<void>>());
    });

    test('A == B 拒绝且文案能看懂', () {
      final r = validateModelIds('alice_integrator', 'alice_integrator');
      final err = (r as Err<void>).error;
      expect(err.userMessage, contains('同一个'));
      expect(err.userMessage, isNot(contains('Exception')));
    });
  });
}
