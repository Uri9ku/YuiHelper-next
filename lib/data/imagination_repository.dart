import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../domain/result.dart';
import 'local_api_client.dart';

/// 想象力一键装配：把每个角色的**专属想象力**装进它已解锁的想象力槽位。
///
/// 数据来源：`tool/make_imagination_table.py` -> `assets/imagination_fill.json`
/// （由离线 catalog 的 `imaginationPolicy.specificPcIds` 生成：每个角色恰好一个专属想象力）。
///
/// 走本地离线接口的通用表同步（`user/pull` + `user/push`），和「领取奖励」同一条链路；
/// 和技能推送一样，需要带 `hash.before.pc` 的版本栅栏 token。
final class ImaginationRepository {
  ImaginationRepository({
    required this.api,
    Future<List<int>> Function(String asset)? loadAsset,
  }) : _loadAsset = loadAsset ?? _bundleAsset;

  final LocalApiClient api;
  final Future<List<int>> Function(String asset) _loadAsset;

  static Future<List<int>> _bundleAsset(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// 给所有已拥有角色装上各自的专属想象力。
  Future<Result<String>> equipExclusive() async {
    final tableResult = await _loadTable();
    if (tableResult is Err<Map<String, Map<String, Object?>>>) {
      return Err(tableResult.error);
    }
    final table = (tableResult as Ok<Map<String, Map<String, Object?>>>).value;

    final pcResult = await api.pull('pc');
    if (pcResult is Err<Map<String, Object?>>) return Err(pcResult.error);
    final stockResult = await api.pull('imaginationStock');
    if (stockResult is Err<Map<String, Object?>>) return Err(stockResult.error);

    final pcOk = pcResult as Ok<Map<String, Object?>>;
    final stockOk = stockResult as Ok<Map<String, Object?>>;
    final pcRows = _rowsOf(pcOk.value, 'pc');
    final stockRows = _rowsOf(stockOk.value, 'imaginationStock');

    final plan = planImaginationFill(
      pcRows: pcRows,
      stockRows: stockRows,
      table: table,
    );
    if (plan.pcUpdates.isEmpty) {
      return Ok(
        '没有需要装配的角色（${plan.total} 个角色，'
        '${plan.skipped} 个未解锁槽位或没有专属想象力）。',
      );
    }

    final body = <String, Object?>{
      'table': [
        {
          'put': {'pc': plan.pcUpdates},
        },
      ],
    };
    final token = _tokenOf(pcOk.value, 'pc');
    if (token != null) {
      body['hash'] = {
        'before': {'pc': token},
      };
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

    return Ok(
      '已给 ${plan.changed} 个角色装上专属想象力'
      '（共 ${plan.filled} 个槽位）；请重启游戏让客户端重新拉取存档。',
    );
  }

  Future<Result<Map<String, Map<String, Object?>>>> _loadTable() async {
    try {
      final raw = await _loadAsset('assets/imagination_fill.json');
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map) {
        return const Err(
          AppError(
            kind: AppErrorKind.badJson,
            userMessage: '内置想象力数据格式不对。',
            detail: 'not a map',
          ),
        );
      }
      final chars = decoded['characters'];
      if (chars is! Map) {
        return const Err(
          AppError(
            kind: AppErrorKind.badJson,
            userMessage: '内置想象力数据缺少 characters。',
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
          userMessage: '读取内置想象力数据失败。',
          detail: e.toString(),
        ),
      );
    }
  }

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

  static String? _tokenOf(Map<String, Object?> body, String alias) {
    final hash = body['hash'];
    if (hash is! Map) return null;
    final v = hash[alias];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 只读预检：算出「有多少角色/槽位可以装配」，不推送。
  ///
  /// 与 [equipExclusive] 共用同一套拉表 + 计划；B 装配装备页用它，
  /// 避免把「能装多少」写成静态假数字。
  Future<Result<ImaginationPreview>> preview() async {
    final tableResult = await _loadTable();
    if (tableResult is Err<Map<String, Map<String, Object?>>>) {
      return Err(tableResult.error);
    }
    final table = (tableResult as Ok<Map<String, Map<String, Object?>>>).value;

    final pcResult = await api.pull('pc');
    if (pcResult is Err<Map<String, Object?>>) return Err(pcResult.error);
    final stockResult = await api.pull('imaginationStock');
    if (stockResult is Err<Map<String, Object?>>) return Err(stockResult.error);

    final pcRows = _rowsOf((pcResult as Ok<Map<String, Object?>>).value, 'pc');
    final stockRows = _rowsOf(
      (stockResult as Ok<Map<String, Object?>>).value,
      'imaginationStock',
    );
    final plan = planImaginationFill(
      pcRows: pcRows,
      stockRows: stockRows,
      table: table,
    );

    final sample = plan.pcUpdates.isEmpty ? null : plan.pcUpdates.first;
    final pcId = sample == null ? null : '${sample['pcId']}';
    final meta = pcId == null ? null : table[pcId];
    final unlockedRaw = sample?['lastImaginationUnlockCount'];
    final unlocked = unlockedRaw is num ? unlockedRaw.toInt().clamp(0, 4) : 0;
    final slots = <int>[];
    final rawSlots = sample?['imaginationSlots'];
    if (rawSlots is List) {
      for (final s in rawSlots) {
        if (s is Map) {
          final stockId = s['imaginationStockId'];
          if (stockId is num) slots.add(stockId.toInt());
        }
      }
    }
    final imagRaw = meta?['imaginationId'];
    return Ok(
      ImaginationPreview(
        total: plan.total,
        changed: plan.changed,
        filled: plan.filled,
        skipped: plan.skipped,
        samplePcId: pcId,
        sampleImaginationId: imagRaw is num ? imagRaw.toInt() : null,
        sampleUnlockedSlots: unlocked,
        sampleSlots: slots,
      ),
    );
  }
}

/// 只读预检的结果：装多少角色/槽位，以及一个可展示的样本角色。
final class ImaginationPreview {
  const ImaginationPreview({
    required this.total,
    required this.changed,
    required this.filled,
    required this.skipped,
    required this.samplePcId,
    required this.sampleImaginationId,
    required this.sampleUnlockedSlots,
    required this.sampleSlots,
  });

  final int total;
  final int changed;
  final int filled;
  final int skipped;
  final String? samplePcId;
  final int? sampleImaginationId;
  final int sampleUnlockedSlots;
  final List<int> sampleSlots;
}

/// 一次装配的改动。
final class ImaginationFillPlan {
  const ImaginationFillPlan({
    required this.pcUpdates,
    required this.total,
    required this.changed,
    required this.filled,
    required this.skipped,
  });

  final List<Map<String, Object?>> pcUpdates;
  final int total;
  final int changed;
  final int filled;
  final int skipped;
}

/// 纯函数：算出要推送的 pc 行（便于单测，不碰网络）。
///
/// 规则：
/// - 只装**已解锁**的槽位（`lastImaginationUnlockCount`，最多 4）；
/// - 只填空槽（已有别的想象力的槽不动）；
/// - 同一个角色的多个槽用**不同的库存副本**（stock id 不重复）。
ImaginationFillPlan planImaginationFill({
  required List<Map<String, Object?>> pcRows,
  required List<Map<String, Object?>> stockRows,
  required Map<String, Map<String, Object?>> table,
}) {
  // imaginationId -> 可用库存 id（升序）
  final stockByImag = <int, List<int>>{};
  for (final row in stockRows) {
    final imagId = row['imaginationId'];
    final id = row['id'];
    if (imagId is! num || id is! num) continue;
    stockByImag.putIfAbsent(imagId.toInt(), () => <int>[]).add(id.toInt());
  }
  for (final ids in stockByImag.values) {
    ids.sort();
  }

  final updates = <Map<String, Object?>>[];
  var filledSlots = 0;
  var skipped = 0;

  for (final pc in pcRows) {
    final pcId = '${pc['pcId']}';
    final meta = table[pcId];
    if (meta == null) {
      skipped++;
      continue;
    }
    final imagId = meta['imaginationId'];
    if (imagId is! num) {
      skipped++;
      continue;
    }
    final unlock = pc['lastImaginationUnlockCount'];
    final unlocked = unlock is num ? unlock.toInt() : 0;
    final maxSlots = unlocked > 4 ? 4 : unlocked;
    if (maxSlots <= 0) {
      skipped++;
      continue;
    }
    final copies = stockByImag[imagId.toInt()] ?? const <int>[];
    if (copies.isEmpty) {
      skipped++;
      continue;
    }

    // 现有槽位：slot -> stockId
    final current = <int, int>{};
    final rawSlots = pc['imaginationSlots'];
    if (rawSlots is List) {
      for (final s in rawSlots) {
        if (s is! Map) continue;
        final slot = s['slot'];
        final stockId = s['imaginationStockId'];
        if (slot is num)
          current[slot.toInt()] = stockId is num ? stockId.toInt() : 0;
      }
    }

    final used = <int>{
      for (final v in current.values)
        if (v != 0) v,
    };
    var copyCursor = 0;
    var slotFilled = 0;
    final next = <int, int>{};
    for (var slot = 1; slot <= maxSlots; slot++) {
      final existing = current[slot] ?? 0;
      if (existing != 0) {
        next[slot] = existing;
        continue;
      }
      // 找一个还没用过的副本
      while (copyCursor < copies.length && used.contains(copies[copyCursor])) {
        copyCursor++;
      }
      if (copyCursor >= copies.length) {
        next[slot] = 0;
        continue;
      }
      final pick = copies[copyCursor++];
      used.add(pick);
      next[slot] = pick;
      slotFilled++;
    }

    if (slotFilled == 0) continue;
    filledSlots += slotFilled;
    updates.add({
      ...pc,
      'imaginationSlots': [
        for (var slot = 1; slot <= maxSlots; slot++)
          {'slot': slot, 'imaginationStockId': next[slot] ?? 0},
      ],
    });
  }

  return ImaginationFillPlan(
    pcUpdates: updates,
    total: pcRows.length,
    changed: updates.length,
    filled: filledSlots,
    skipped: skipped,
  );
}
