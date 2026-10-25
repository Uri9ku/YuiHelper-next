import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/skill_board_repository.dart';

void main() {
  test('已经满级、只是 slotSkills 数组顺序不同 -> 不重复写 pc', () {
    final maxSlots = [
      {'slot': 1, 'level': 8, 'pcSlotSkillId': 101, 'isExtraSlot': false},
      {'slot': 2, 'level': 3, 'pcSlotSkillId': 102, 'isExtraSlot': false},
    ];
    // 客户端会重排数组顺序，并改变每条槽的 JSON key 顺序（内容不变）。
    final reordered = [
      {'isExtraSlot': false, 'level': 3, 'pcSlotSkillId': 102, 'slot': 2},
      {'level': 8, 'slot': 1, 'isExtraSlot': false, 'pcSlotSkillId': 101},
    ];
    final plan = planSkillFill(
      pcRows: [
        {
          'userId': 1,
          'pcId': 100,
          'slotSkills': reordered,
        },
      ],
      itemRows: const [],
      boards: {
        '100': {'maximumSlots': maxSlots, 'requiredItems': const <String, Object?>{}},
      },
    );
    expect(plan.pcUpdates, isEmpty);
    expect(plan.changed, 0);
  });

  test('槽位内容真的不同 -> 仍然写 pc', () {
    final maxSlots = [
      {'slot': 1, 'level': 8, 'pcSlotSkillId': 101, 'isExtraSlot': false},
      {'slot': 2, 'level': 3, 'pcSlotSkillId': 102, 'isExtraSlot': false},
    ];
    final plan = planSkillFill(
      pcRows: [
        {
          'userId': 1,
          'pcId': 100,
          'slotSkills': [
            {'slot': 1, 'level': 1, 'pcSlotSkillId': 101, 'isExtraSlot': false},
          ],
        },
      ],
      itemRows: const [],
      boards: {
        '100': {'maximumSlots': maxSlots, 'requiredItems': const <String, Object?>{}},
      },
    );
    expect(plan.changed, 1);
    expect(plan.pcUpdates.single['slotSkills'], maxSlots);
  });
}
