import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../domain/result.dart';
import 'local_api_client.dart';

/// 角色技能板「点满」：把每个角色的 `pc.slotSkills` 换成 catalog 里的
/// `manualSkillsPolicy.maximumSlots`（含每槽等级上限），并按 `requiredItems` 补足材料。
///
/// 数据来源与生成脚本：`tool/make_skill_boards.py` -> `assets/skill_boards.json`。
/// 走的是离线 mod 的通用表同步接口（`user/pull` + `user/push`），和「领取奖励」同一条链路。
final class SkillBoardRepository {
  SkillBoardRepository({
    required this.api,
    Future<List<int>> Function(String asset)? loadAsset,
  }) : _loadAsset = loadAsset ?? _bundleAsset;

  final LocalApiClient api;
  final Future<List<int>> Function(String asset) _loadAsset;

  static Future<List<int>> _bundleAsset(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// 点满所有**已拥有**角色。返回一句给用户看的结果。
  Future<Result<String>> fillAll() async {
    final boardsResult = await _loadBoards();
    if (boardsResult is Err<Map<String, Map<String, Object?>>>) {
      return Err(boardsResult.error);
    }
    final boards =
        (boardsResult as Ok<Map<String, Map<String, Object?>>>).value;

    final pcResult = await api.pull('pc');
    if (pcResult is Err<Map<String, Object?>>) return Err(pcResult.error);
    final itemResult = await api.pull('item');
    if (itemResult is Err<Map<String, Object?>>) return Err(itemResult.error);

    final pcOk = pcResult as Ok<Map<String, Object?>>;
    final itemOk = itemResult as Ok<Map<String, Object?>>;
    final pcRows = _rowsOf(pcOk.value, 'pc');
    final itemRows = _rowsOf(itemOk.value, 'item');

    final plan = planSkillFill(
      pcRows: pcRows,
      itemRows: itemRows,
      boards: boards,
    );
    if (plan.pcUpdates.isEmpty && plan.itemUpdates.isEmpty) {
      return Ok('技能板已经都是满的（${plan.total} 个角色，无需改动）。');
    }

    final deltas = <Map<String, Object?>>[];
    if (plan.pcUpdates.isNotEmpty) {
      deltas.add({
        'put': {'pc': plan.pcUpdates},
      });
    }
    if (plan.itemUpdates.isNotEmpty) {
      deltas.add({
        'put': {'item': plan.itemUpdates},
      });
    }

    // ★ 离线 mod 对 pc/item 的推送有「版本栅栏」（skill_reset.js 的 checkFence）：
    //   改了 pc/item 就必须带 `hash.before.{pc,item}` = 当前 epoch 的 token，
    //   否则回 400 stale_skill_push（資料已更新，請重新確認）。
    //   token 直接来自 `user/pull` 响应里的 `hash`。
    final body = <String, Object?>{'table': deltas};
    final before = <String, Object?>{};
    final pcToken = _tokenOf(pcOk.value, 'pc');
    final itemToken = _tokenOf(itemOk.value, 'item');
    if (pcToken != null) before['pc'] = pcToken;
    if (itemToken != null) before['item'] = itemToken;
    if (before.isNotEmpty) {
      body['hash'] = {'before': before};
    }

    final push = await api.call('user/push', body);
    if (push is Err<Map<String, Object?>>) return Err(push.error);
    final response = (push as Ok<Map<String, Object?>>).value;
    final code = response['code'];
    if (code is int && code != 0) {
      final errorCode = '${response['errorCode'] ?? ''}';
      final friendly = errorCode == 'stale_skill_push'
          ? '游戏端数据已更新，请重启游戏后再试一次。'
          : '游戏拒绝了这次修改（code=$code${errorCode.isEmpty ? '' : ' / $errorCode'}）。';
      return Err(
        AppError(
          kind: AppErrorKind.serverCode,
          userMessage: friendly,
          detail: jsonEncode(response),
        ),
      );
    }

    final parts = <String>[
      '已点满 ${plan.changed} 个角色（共 ${plan.total} 个）',
      '补足材料 ${plan.itemUpdates.length} 种',
    ];
    if (plan.skippedNoBoard > 0) {
      parts.add('${plan.skippedNoBoard} 个角色没有技能板数据，已跳过');
    }
    parts.add('请重启游戏让客户端重新拉取存档');
    return Ok(parts.join('；'));
  }

  /// 只读预检：拉 pc/item 算出「将解放多少角色 / 槽位 / 要补多少种材料」，不写表。
  Future<Result<SkillPreview>> preview() async {
    final boardsResult = await _loadBoards();
    if (boardsResult is Err<Map<String, Map<String, Object?>>>) {
      return Err(boardsResult.error);
    }
    final boards =
        (boardsResult as Ok<Map<String, Map<String, Object?>>>).value;
    final pcResult = await api.pull('pc');
    if (pcResult is Err<Map<String, Object?>>) return Err(pcResult.error);
    final itemResult = await api.pull('item');
    if (itemResult is Err<Map<String, Object?>>) return Err(itemResult.error);

    final pcRows = _rowsOf(
      (pcResult as Ok<Map<String, Object?>>).value,
      'pc',
    );
    final itemRows = _rowsOf(
      (itemResult as Ok<Map<String, Object?>>).value,
      'item',
    );
    final plan = planSkillFill(
      pcRows: pcRows,
      itemRows: itemRows,
      boards: boards,
    );
    var slots = 0;
    for (final row in plan.pcUpdates) {
      final maxSlots = row['slotSkills'];
      if (maxSlots is List) slots += maxSlots.length;
    }
    return Ok(
      SkillPreview(
        total: plan.total,
        changed: plan.changed,
        skippedNoBoard: plan.skippedNoBoard,
        materialTypes: plan.itemUpdates.length,
        slots: slots,
      ),
    );
  }

  Future<Result<Map<String, Map<String, Object?>>>> _loadBoards() async {
    try {
      final raw = await _loadAsset('assets/skill_boards.json');
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map) {
        return const Err(
          AppError(
            kind: AppErrorKind.badJson,
            userMessage: '内置技能板数据格式不对。',
            detail: 'not a map',
          ),
        );
      }
      final chars = decoded['characters'];
      if (chars is! Map) {
        return const Err(
          AppError(
            kind: AppErrorKind.badJson,
            userMessage: '内置技能板数据缺少 characters。',
            detail: 'no characters',
          ),
        );
      }
      final out = <String, Map<String, Object?>>{};
      chars.forEach((k, v) {
        if (k is String && v is Map) out[k] = v.cast<String, Object?>();
      });
      return Ok(out);
    } catch (e) {
      return Err(
        AppError(
          kind: AppErrorKind.invalidInput,
          userMessage: '读取内置技能板数据失败。',
          detail: e.toString(),
        ),
      );
    }
  }

  /// 从 `user/pull` 响应里取该表的版本 token（也就是 skill_reset 的 fence token）。
  static String? _tokenOf(Map<String, Object?> body, String alias) {
    final hash = body['hash'];
    if (hash is! Map) return null;
    final v = hash[alias];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 从 `{table:{replace:{alias:[...]}}}` 里取行。
  static List<Map<String, Object?>> _rowsOf(
    Map<String, Object?> body,
    String alias,
  ) {
    final table = body['table'];
    if (table is! Map) return const [];
    final replace = table['replace'];
    if (replace is! Map) return const [];
    final rows = replace[alias];
    if (rows is! List) return const [];
    return [
      for (final r in rows)
        if (r is Map) r.cast<String, Object?>(),
    ];
  }
}

/// 只读预检的结果：将解放多少角色/槽位，以及材料补足种类。
final class SkillPreview {
  const SkillPreview({
    required this.total,
    required this.changed,
    required this.skippedNoBoard,
    required this.materialTypes,
    required this.slots,
  });

  final int total;
  final int changed;
  final int skippedNoBoard;
  final int materialTypes;
  final int slots;
}

/// 一次「点满」要推送的改动。
final class SkillFillPlan {
  const SkillFillPlan({
    required this.pcUpdates,
    required this.itemUpdates,
    required this.total,
    required this.changed,
    required this.skippedNoBoard,
  });

  final List<Map<String, Object?>> pcUpdates;
  final List<Map<String, Object?>> itemUpdates;
  final int total;
  final int changed;
  final int skippedNoBoard;
}

/// 技能槽的比较键：按 slot 排序，并把每条槽的 map key 也排序后序列化。
///
/// 游戏客户端会在不改变内容的情况下重排 `slotSkills` 数组顺序 **以及 JSON key 顺序**
///（实测满级后 2 个角色的数组顺序/字段顺序被客户端改过）。如果直接比 JSON 字符串，
/// 会把「内容已满级、只是顺序不同」误判成需要再写一次，所以这里做双重规范化。
Object? _canonSlot(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _canonSlot(value[k])};
  }
  if (value is List) return [for (final item in value) _canonSlot(item)];
  return value;
}

String _slotsKey(Object? slots) {
  if (slots is! List) return jsonEncode(slots);
  final list = [...slots];
  list.sort((a, b) {
    final am = a is Map ? a : const <String, Object?>{};
    final bm = b is Map ? b : const <String, Object?>{};
    final slotA = am['slot'] is num ? (am['slot'] as num).toInt() : -1;
    final slotB = bm['slot'] is num ? (bm['slot'] as num).toInt() : -1;
    if (slotA != slotB) return slotA.compareTo(slotB);
    final extraA = am['isExtraSlot'] == true ? 1 : 0;
    final extraB = bm['isExtraSlot'] == true ? 1 : 0;
    return extraA.compareTo(extraB);
  });
  return jsonEncode(_canonSlot(list));
}

/// 纯函数：算出要把哪些行推上去（便于单测，不碰网络）。
///
/// - `boards`：pcId -> {maximumSlots, requiredItems}
/// - 材料按**所有已拥有角色**的 requiredItems 取并集补足（与 mod 自己的迁移一致），
///   避免之后在游戏里手动解锁时提示材料不足。
SkillFillPlan planSkillFill({
  required List<Map<String, Object?>> pcRows,
  required List<Map<String, Object?>> itemRows,
  required Map<String, Map<String, Object?>> boards,
}) {
  final pcUpdates = <Map<String, Object?>>[];
  var skipped = 0;
  final requiredItems = <int, int>{};

  for (final row in pcRows) {
    final pcId = '${row['pcId']}';
    final board = boards[pcId];
    if (board == null) {
      skipped++;
      continue;
    }
    final maxSlots = board['maximumSlots'];
    if (maxSlots is! List || maxSlots.isEmpty) {
      skipped++;
      continue;
    }
    final current = row['slotSkills'];
    if (_slotsKey(current) != _slotsKey(maxSlots)) {
      pcUpdates.add({...row, 'slotSkills': maxSlots});
    }
    final items = board['requiredItems'];
    if (items is Map) {
      items.forEach((k, v) {
        final id = int.tryParse('$k');
        final n = v is num ? v.toInt() : int.tryParse('$v');
        if (id == null || n == null || n <= 0) return;
        requiredItems[id] = (requiredItems[id] ?? 0) + n;
      });
    }
  }

  // 材料：按 itemId 找到已有行，不足就补到需求值；没有行就新建。
  final itemById = <int, Map<String, Object?>>{};
  var fallbackUserId = 1;
  for (final row in itemRows) {
    final id = row['itemId'];
    final uid = row['userId'];
    if (uid is num) fallbackUserId = uid.toInt();
    if (id is num) itemById[id.toInt()] = row;
  }
  final itemUpdates = <Map<String, Object?>>[];
  requiredItems.forEach((itemId, need) {
    final row = itemById[itemId];
    if (row == null) {
      itemUpdates.add({
        'userId': fallbackUserId,
        'itemId': itemId,
        'amount': need,
        'reservedAmount': 0,
        'readState': 1,
      });
      return;
    }
    final amount = row['amount'];
    final have = amount is num ? amount.toInt() : 0;
    if (have < need) {
      itemUpdates.add({...row, 'amount': need});
    }
  });

  return SkillFillPlan(
    pcUpdates: pcUpdates,
    itemUpdates: itemUpdates,
    total: pcRows.length,
    changed: pcUpdates.length,
    skippedNoBoard: skipped,
  );
}
