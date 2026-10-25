/// Spine 约束的 setup 数据（S7：读出来备用；IK 求解在 S8，见文档）。
library;

/// IK 约束：`bones[i]` 是链上的骨骼，`target` 是目标骨骼。
final class SpineIkConstraintData {
  const SpineIkConstraintData({
    required this.name,
    required this.order,
    required this.bones,
    required this.target,
    required this.mix,
    required this.bendPositive,
  });

  final String name;
  final int order;
  final List<int> bones;
  final int target;
  final double mix;
  final bool bendPositive;
}

/// Transform 约束（旋转/位移/缩放/剪切跟随目标）。
final class SpineTransformConstraintData {
  const SpineTransformConstraintData({
    required this.name,
    required this.order,
    required this.bones,
    required this.target,
    required this.local,
    required this.relative,
    required this.offsetRotation,
    required this.offsetX,
    required this.offsetY,
    required this.offsetScaleX,
    required this.offsetScaleY,
    required this.offsetShearY,
    required this.mixRotate,
    required this.mixTranslate,
    required this.mixScale,
    required this.mixShear,
  });

  final String name;
  final int order;
  final List<int> bones;
  final int target;
  final bool local;
  final bool relative;
  final double offsetRotation;
  final double offsetX;
  final double offsetY;
  final double offsetScaleX;
  final double offsetScaleY;
  final double offsetShearY;
  // 3.6 的 transform 约束只有 4 个 mix（rotate/translate/scale/shear），
  // 不是 3.8 的 6 个逐分量 mix。
  final double mixRotate;
  final double mixTranslate;
  final double mixScale;
  final double mixShear;
}

/// Path 约束（沿路径摆放骨骼）。
final class SpinePathConstraintData {
  const SpinePathConstraintData({
    required this.name,
    required this.order,
    required this.bones,
    required this.targetSlot,
    required this.positionMode,
    required this.spacingMode,
    required this.rotateMode,
    required this.rotation,
    required this.position,
    required this.spacing,
    required this.mixRotate,
    required this.mixTranslate,
  });

  final String name;
  final int order;
  final List<int> bones;
  final int targetSlot;
  final int positionMode;
  final int spacingMode;
  final int rotateMode;
  // 3.6 的 path 约束只有 2 个 mix（rotate/translate）
  final double rotation;
  final double position;
  final double spacing;
  final double mixRotate;
  final double mixTranslate;
}
