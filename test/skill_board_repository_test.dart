import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/skill_board_repository.dart';

Map<String, Object?> _pc(int pcId, List<Map<String, Object?>> slots) => {
      'userId': 1,
      'pcId': pcId,
      'slotSkills': slots,
    };

Map<String, Object?> _item(int itemId, int amount) => {
      'userId': 1,
      'itemId': itemId,
      'amount': amount,
      'reservedAmount': 0,
      'readState': 1,
    };

void main() {
  group('planSkillFill', () {
    test('技能板不同 -> 推送新的 slotSkills', () {
      final boards = {
        '100': {
          'maximumSlots': [
            {'slot': 1, 'level': 5, 'pcSlotSkillId': 11, 'isExtraSlot': false},
            {'slot': 2, 'level': 2, 'pcSlotSkillId': 12, 'isExtraSlot': false},
          ],
          'requiredItems': <String, Object?>{},
        },
      };
      final plan = planSkillFill(
        pcRows: [
          _pc(100, [
            {'slot': 1, 'level': 1, 'pcSlotSkillId': 11, 'isExtraSlot': false},
          ]),
        ],
        itemRows: const [],
        boards: boards,
      );
      expect(plan.changed, 1);
      expect(plan.total, 1);
      final slots = plan.pcUpdates.single['slotSkills'] as List;
      expect(slots.length, 2);
      expect((slots.first as Map)['level'], 5);
    });

    test('已经满板 -> 不产生 pc 更新', () {
      final maxSlots = [
        {'slot': 1, 'level': 5, 'pcSlotSkillId': 11, 'isExtraSlot': false},
      ];
      final plan = planSkillFill(
        pcRows: [_pc(100, maxSlots)],
        itemRows: const [],
        boards: {
          '100': {'maximumSlots': maxSlots, 'requiredItems': <String, Object?>{}},
        },
      );
      expect(plan.changed, 0);
      expect(plan.pcUpdates, isEmpty);
    });

    test('没有技能板数据的角色被跳过', () {
      final plan = planSkillFill(
        pcRows: [_pc(999, const [])],
        itemRows: const [],
        boards: const {},
      );
      expect(plan.changed, 0);
      expect(plan.skippedNoBoard, 1);
    });

    test('材料不足 -> 补到需求值；已有足够 -> 不动', () {
      final boards = {
        '100': {
          'maximumSlots': [
            {'slot': 1, 'level': 5, 'pcSlotSkillId': 11, 'isExtraSlot': false},
          ],
          'requiredItems': {'5001': 100, '5002': 10},
        },
      };
      final plan = planSkillFill(
        pcRows: [_pc(100, const [])],
        itemRows: [_item(5001, 30), _item(5002, 99)],
        boards: boards,
      );
      expect(plan.itemUpdates.length, 1, reason: '只有 5001 需要补');
      final updated = plan.itemUpdates.single;
      expect(updated['itemId'], 5001);
      expect(updated['amount'], 100);
    });

    test('材料行不存在 -> 新建一行', () {
      final boards = {
        '100': {
          'maximumSlots': [
            {'slot': 1, 'level': 5, 'pcSlotSkillId': 11, 'isExtraSlot': false},
          ],
          'requiredItems': {'7001': 5},
        },
      };
      final plan = planSkillFill(
        pcRows: [_pc(100, const [])],
        itemRows: [_item(1, 999)],
        boards: boards,
      );
      expect(plan.itemUpdates.single['itemId'], 7001);
      expect(plan.itemUpdates.single['amount'], 5);
      expect(plan.itemUpdates.single['userId'], 1);
    });

    test('多个角色的材料需求累加', () {
      final slot = [
        {'slot': 1, 'level': 5, 'pcSlotSkillId': 11, 'isExtraSlot': false},
      ];
      final boards = {
        '100': {'maximumSlots': slot, 'requiredItems': {'5001': 10}},
        '101': {'maximumSlots': slot, 'requiredItems': {'5001': 15}},
      };
      final plan = planSkillFill(
        pcRows: [_pc(100, const []), _pc(101, const [])],
        itemRows: [_item(5001, 0)],
        boards: boards,
      );
      expect(plan.itemUpdates.single['amount'], 25);
    });
  });
}

