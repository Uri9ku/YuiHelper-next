import 'result.dart';

/// 一条换模型规则：把角色 [from] 的模型换成角色 [to] 的。
///
/// id 是游戏内部的英文变体名（如 `kirito_cathedral`），界面上的中文名
/// 由名称表负责翻译——规则里永远写 id。
final class ModelSwapRule {
  const ModelSwapRule({required this.from, required this.to});

  /// 被替换的角色（出现在哪，哪就变成 B 的样子）。
  final String from;

  /// 替换来源角色（A 的外观/模型将变成它）。
  final String to;
}

/// 规则文件 JSON 的形状（hook 脚本契约，见设计文档 §4.2-6）：
///
/// ```json
/// {"rules":{"models":{"<A>":"<B>"}}}
/// ```
///
/// [rule] 为 null 时输出空表 —— 就是「关闭替换」。
String buildModelRulesJson(ModelSwapRule? rule) {
  final models = rule == null
      ? ''
      : '"${_escape(rule.from)}":"${_escape(rule.to)}"';
  return '{"rules":{"models":{$models}}}';
}

String _escape(String id) => id.replaceAll('\\', r'\\').replaceAll('"', r'\"');

/// 校验一对角色 id。失败时 [Err.error.userMessage] 是能直接给用户看的一句话。
Result<void> validateModelIds(String a, String b) {
  final pattern = RegExp(r'^[A-Za-z0-9_$.\-]+$');

  if (a.isEmpty || b.isEmpty) {
    return const Err<void>(
      AppError(
        kind: AppErrorKind.invalidInput,
        userMessage: '请先选好两个角色：要替换的和替换成谁的。',
        detail: 'empty model id',
      ),
    );
  }
  if (a.length > 64 || b.length > 64) {
    return const Err<void>(
      AppError(
        kind: AppErrorKind.invalidInput,
        userMessage: '角色名太长，不像是游戏里的 id，请重新从下拉框里选。',
        detail: 'model id longer than 64',
      ),
    );
  }
  if (!pattern.hasMatch(a) || !pattern.hasMatch(b)) {
    return const Err<void>(
      AppError(
        kind: AppErrorKind.invalidInput,
        userMessage: '角色 id 里有不支持的字符，请直接用下拉框里的选项。',
        detail: 'model id contains invalid characters',
      ),
    );
  }
  if (a == b) {
    return const Err<void>(
      AppError(
        kind: AppErrorKind.invalidInput,
        userMessage: '两个角色是同一个，换不了。请选一个不同的角色 B。',
        detail: 'model id identical',
      ),
    );
  }
  return const Ok<void>(null);
}
