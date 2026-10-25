import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/imagination_repository.dart';

Map<String, Object?> _pc(
  int pcId, {
  int unlock = 4,
  List<Map<String, Object?>> slots = const [],
}) =>
    {
      'userId': 1,
      'pcId': pcId,
      'lastImaginationUnlockCount': unlock,
      'imaginationSlots': slots,
    };

Map<String, Object?> _stock(int id, int imagId) => {
      'userId': 1,
      'id': id,
      'imaginationId': imagId,
      'isFavorite': false,
      'readState': 1,
    };

void main() {
  group('planImaginationFill', () {
    test('空槽 -> 用不同副本填满已解锁槽位', () {
      final plan = planImaginationFill(
        pcRows: [_pc(100)],
        stockRows: [_stock(1, 9001), _stock(2, 9001), _stock(3, 9001)],
        table: {
          '100': {'imaginationId': 9001, 'slots': 4},
        },
      );
      expect(plan.changed, 1);
      expect(plan.filled, 3, reason: '只有 3 份库存，就填 3 格');
      final slots = plan.pcUpdates.single['imaginationSlots'] as List;
      expect(slots.length, 4);
      final ids = [
        for (final s in slots) (s as Map)['imaginationStockId'],
      ];
      expect(ids.where((v) => v != 0).length, 3);
      expect(ids.toSet().length, 4, reason: '3 个非零 + 1 个 0，不应重复');
    });

    test('已有槽位保留，不重复用同一副本', () {
      final plan = planImaginationFill(
        pcRows: [
          _pc(100, slots: [
            {'slot': 1, 'imaginationStockId': 1},
          ]),
        ],
        stockRows: [_stock(1, 9001), _stock(2, 9001)],
        table: {
          '100': {'imaginationId': 9001, 'slots': 4},
        },
      );
      final slots = (plan.pcUpdates.single['imaginationSlots'] as List)
          .cast<Map<String, Object?>>();
      expect(slots.first['imaginationStockId'], 1);
      expect(slots[1]['imaginationStockId'], 2, reason: '跳过已用的 1 号副本');
      expect(slots[2]['imaginationStockId'], 0);
    });

    test('未解锁槽位（unlock=0）不处理', () {
      final plan = planImaginationFill(
        pcRows: [_pc(100, unlock: 0)],
        stockRows: [_stock(1, 9001)],
        table: {
          '100': {'imaginationId': 9001, 'slots': 4},
        },
      );
      expect(plan.changed, 0);
      expect(plan.skipped, 1);
    });

    test('没有专属想象力的角色跳过', () {
      final plan = planImaginationFill(
        pcRows: [_pc(999)],
        stockRows: [_stock(1, 9001)],
        table: {
          '100': {'imaginationId': 9001, 'slots': 4},
        },
      );
      expect(plan.changed, 0);
      expect(plan.skipped, 1);
    });

    test('没有库存副本时跳过', () {
      final plan = planImaginationFill(
        pcRows: [_pc(100)],
        stockRows: [_stock(1, 1234)],
        table: {
          '100': {'imaginationId': 9001, 'slots': 4},
        },
      );
      expect(plan.changed, 0);
      expect(plan.skipped, 1);
    });

    test('多个角色各自用自己的专属想象力', () {
      final plan = planImaginationFill(
        pcRows: [_pc(100), _pc(101)],
        stockRows: [
          _stock(1, 9001),
          _stock(2, 9002),
        ],
        table: {
          '100': {'imaginationId': 9001, 'slots': 4},
          '101': {'imaginationId': 9002, 'slots': 4},
        },
      );
      expect(plan.changed, 2);
      final first = (plan.pcUpdates[0]['imaginationSlots'] as List)
          .cast<Map<String, Object?>>()
          .first['imaginationStockId'];
      final second = (plan.pcUpdates[1]['imaginationSlots'] as List)
          .cast<Map<String, Object?>>()
          .first['imaginationStockId'];
      expect([first, second], [1, 2]);
    });
  });
}
