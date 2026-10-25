/// `/api/user/pull` 响应的形状（来自离线引擎 `state.js` 的 `response()`）：
///
/// ```json
/// {"code":0,"table":{"replace":{"mission":[{...}, ...], "gift":[...]}},"hash":{...}}
/// ```
///
/// 注意 `mission` 表只会在**全量拉取**时出现：`mission/refresh` 与 `event`
/// 走的是「只回本次变动行」的分支，会把 `table.replace.mission` 整个删掉。
/// 所以想拿到可领任务，必须用 `user/pull`（见 design §4.1）。
library;

/// 从 pull 响应里取出某张表的全部行。
///
/// 任何一层缺失或类型不对都返回空列表 —— 服务端少给一张表是正常现象，
/// 不该让调用方崩掉。
List<Map<String, Object?>> tableRows(
  Map<String, Object?> pullJson,
  String alias,
) {
  final table = pullJson['table'];
  if (table is! Map) return const [];

  final replace = table['replace'];
  if (replace is! Map) return const [];

  final rows = replace[alias];
  if (rows is! List) return const [];

  final out = <Map<String, Object?>>[];
  for (final row in rows) {
    if (row is Map && row.keys.every((key) => key is String)) {
      out.add(row.cast<String, Object?>());
    }
  }
  return out;
}

/// 取出 `table.put[alias]` 里的行。
///
/// 写操作的**增量**走这里而不是 `replace`：`mission/receive` 会在
/// `table.put.mission` 里只回本次真正变动的那些行（`state.js` 的 `response()`
/// 在 `current !== previousMissions` 时把 `replace.mission` 删掉、改走 put）。
/// 所以「到底领到了几项」只能从 put 里数。
List<Map<String, Object?>> tablePutRows(
  Map<String, Object?> responseJson,
  String alias,
) {
  final table = responseJson['table'];
  if (table is! Map) return const [];

  final put = table['put'];
  if (put is! Map) return const [];

  final rows = put[alias];
  if (rows is! List) return const [];

  final out = <Map<String, Object?>>[];
  for (final row in rows) {
    if (row is Map && row.keys.every((key) => key is String)) {
      out.add(row.cast<String, Object?>());
    }
  }
  return out;
}
