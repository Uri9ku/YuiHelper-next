import 'dart:math' as math;

import 'skeleton_pose.dart';
import 'spine_binary.dart';
import 'spine_constraint_data.dart';

/// IK 约束求解（S8）：把骨链末端拉到目标骨骼上（1 骨 = 瞄准；2 骨 = 余弦定理）。
///
/// 说明（v1 边界）：
/// - 只解 **IK**；transform / path 约束仍未求解（数据已读入，见主报告 §14.15）；
/// - 支持逐帧 mix / bend 覆盖（来自 `SpineAnimation.ikTimelines`）；
/// - 每解一个约束就重算一次世界变换（骨头 ~250 根、约束 ~6 个，开销可忽略）。
final class SpineIkSolver {
  SpineIkSolver._();

  /// 解全部 IK 约束；[locals] 会被就地修改（旋转），返回最终姿态。
  static SkeletonPose solve({
    required SpineSkeletonData data,
    required BoneLocals locals,
    Map<int, ({double mix, bool bendPositive})> overrides = const {},
  }) {
    if (data.ikConstraints.isEmpty || locals.rotation == null) {
      return SkeletonPose.fromLocals(data, locals);
    }
    var pose = SkeletonPose.fromLocals(data, locals);
    final ordered = [...data.ikConstraints]..sort((a, b) => a.order.compareTo(b.order));
    for (var ci = 0; ci < ordered.length; ci++) {
      final c = ordered[ci];
      final o = overrides[ci];
      final mix = (o?.mix ?? c.mix).clamp(0.0, 1.0);
      if (mix <= 0) continue;
      final bend = o?.bendPositive ?? c.bendPositive;
      pose = _solveOne(data, locals, pose, c, mix, bend);
    }
    return pose;
  }

  static SkeletonPose _solveOne(
    SpineSkeletonData data,
    BoneLocals locals,
    SkeletonPose pose,
    SpineIkConstraintData c,
    double mix,
    bool bend,
  ) {
    final bones = c.bones;
    if (bones.isEmpty || c.target < 0 || c.target >= pose.bones.length) return pose;
    final target = pose.bones[c.target];
    final tx = target.worldX;
    final ty = target.worldY;

    if (bones.length == 1) {
      final b = pose.bones[bones[0]];
      final bone = data.bones[bones[0]];
      final curAngle = math.atan2(b.c, b.a);
      final tipX = b.worldX + math.cos(curAngle) * bone.length;
      final tipY = b.worldY + math.sin(curAngle) * bone.length;
      if (math.sqrt(math.pow(tipX - tx, 2) + math.pow(tipY - ty, 2)) <= 0.5) return pose;
      final desired = math.atan2(ty - b.worldY, tx - b.worldX);
      final current = math.atan2(b.c, b.a);
      final delta = _shortestDelta(current, desired) * mix;
      locals.rotation![bones[0]] += delta * 180 / math.pi;
      return SkeletonPose.fromLocals(data, locals);
    }

    final parentIdx = bones[0];
    final childIdx = bones[1];
    final parent = pose.bones[parentIdx];
    final child = pose.bones[childIdx];
    final childBone = data.bones[childIdx];

    final px = parent.worldX;
    final py = parent.worldY;
    // 末端 = 子骨骨骼原点 + 子骨长度方向（子骨 length 为 0 时退化为原点）
    final childAngle = math.atan2(child.c, child.a);
    final ex = child.worldX + math.cos(childAngle) * childBone.length;
    final ey = child.worldY + math.sin(childAngle) * childBone.length;

    final beforeDist0 = math.sqrt(math.pow(ex - tx, 2) + math.pow(ey - ty, 2));
    if (beforeDist0 <= 0.5) return pose;

    final a = math.sqrt(math.pow(child.worldX - px, 2) + math.pow(child.worldY - py, 2));
    final b = childBone.length.abs() > 1e-3 ? childBone.length : 0.0;
    final l = math.sqrt(math.pow(tx - px, 2) + math.pow(ty - py, 2));
    if (a <= 1e-6 || l <= 1e-6) return pose;
    if (b <= 1e-6) {
      // 退化为 1 骨瞄准
      final desired = math.atan2(ty - py, tx - px);
      final current = math.atan2(parent.c, parent.a);
      locals.rotation![parentIdx] += _shortestDelta(current, desired) * mix * 180 / math.pi;
      return SkeletonPose.fromLocals(data, locals);
    }

    final lClamped = l.clamp((a - b).abs() + 1e-3, a + b - 1e-3);
    final cosA = ((a * a + lClamped * lClamped - b * b) / (2 * a * lClamped)).clamp(-1.0, 1.0);
    final cosB = ((a * a + b * b - lClamped * lClamped) / (2 * a * b)).clamp(-1.0, 1.0);
    final angleP = math.atan2(ty - py, tx - px);
    final alpha = math.acos(cosA);
    final beta = math.acos(cosB);
    final sign = bend ? 1.0 : -1.0;

    // 目标世界角：父骨 = 指向目标 ∓ alpha；子骨 = + (π - beta)（相对父骨）
    final desiredParent = angleP - sign * alpha;
    final desiredChild = desiredParent + sign * (math.pi - beta);

    var currentParent = math.atan2(parent.c, parent.a);
    locals.rotation![parentIdx] +=
        _shortestDelta(currentParent, desiredParent) * mix * 180 / math.pi;
    var newPose = SkeletonPose.fromLocals(data, locals);
    currentParent = math.atan2(newPose.bones[parentIdx].c, newPose.bones[parentIdx].a);
    final currentChild = math.atan2(newPose.bones[childIdx].c, newPose.bones[childIdx].a);
    locals.rotation![childIdx] += _shortestDelta(currentChild, desiredChild) * mix * 180 / math.pi;
    newPose = SkeletonPose.fromLocals(data, locals);

    // 兜底：若解完比原来更远（目标不可达/方向异常），回退该约束的改动
    final beforeDist = math.sqrt(math.pow(ex - tx, 2) + math.pow(ey - ty, 2));
    final afterPose = newPose.bones[childIdx];
    final afterAngle = math.atan2(afterPose.c, afterPose.a);
    final afterEx = afterPose.worldX + math.cos(afterAngle) * childBone.length;
    final afterEy = afterPose.worldY + math.sin(afterAngle) * childBone.length;
    final afterDist = math.sqrt(math.pow(afterEx - tx, 2) + math.pow(afterEy - ty, 2));
    if (afterDist.isNaN || afterDist > beforeDist * 1.001) {
      return pose;
    }
    return newPose;
  }

  /// 两个角度之间的最短差（弧度，-π..π）。
  static double _shortestDelta(double from, double to) {
    var d = to - from;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    return d;
  }
}
