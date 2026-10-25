/// 角色中英文对照名称表（`assets/names.tsv`，繁體中文）。
///
/// 文件格式（由 `saoars_mod/build_names.py` 生成）：
/// ```text
/// # 注释行
/// <kind>\t<id>\t<中文>\t[token: pre|post]
/// ```
/// 本功能只消费 `kind == "char"` 的完整条目；`anim/base/token` 是组合素材，忽略。
Map<String, String> parseNameTable(String tsv) {
  final table = <String, String>{};
  for (final line in tsv.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final cols = trimmed.split('\t');
    if (cols.length < 3) continue; // 字段不足的残行直接跳过
    if (cols[0].trim() != 'char') continue;

    final id = cols[1].trim();
    final zh = cols[2].trim();
    if (id.isEmpty || zh.isEmpty) continue;
    table[id] = zh; // 重复 id：后行覆盖前行（可被设备覆盖文件修正）
  }
  return table;
}
