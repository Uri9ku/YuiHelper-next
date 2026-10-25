import 'dart:convert';

/// hook 脚本写出的枚举数据（`/data/local/tmp/saoub-model-enum.json`）。
///
/// 形状（见 hook 脚本头部注释）：
/// ```json
/// {"characters": ["alice_integrator", ...], "counts": {...}}
/// ```
final class ModelEnumSnapshot {
  const ModelEnumSnapshot({required this.characters});

  /// 运行时实际见到过的角色变体名（已排序去重）。
  final List<String> characters;
}

/// 解析枚举文件内容。**任何解析失败都回落到空快照**：
/// 文件还没写出来、被日志前缀污染、长度补齐的尾部空格——这些都不是错误，
/// 只是「还没收集到」，绝不能让下拉框页面崩掉。
ModelEnumSnapshot parseModelEnum(String raw) {
  if (raw.isEmpty) return const ModelEnumSnapshot(characters: []);

  // 容忍日志前缀混入：从第一个 `{` 开始截取。
  final start = raw.indexOf('{');
  if (start < 0) return const ModelEnumSnapshot(characters: []);

  try {
    final decoded = jsonDecode(raw.substring(start));
    if (decoded is! Map<String, dynamic>) {
      return const ModelEnumSnapshot(characters: []);
    }
    final list = decoded['characters'];
    if (list is! List) return const ModelEnumSnapshot(characters: []);
    return ModelEnumSnapshot(
      characters: list.whereType<String>().toList(growable: false),
    );
  } on FormatException {
    return const ModelEnumSnapshot(characters: []);
  }
}
