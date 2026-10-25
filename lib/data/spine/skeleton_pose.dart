/// bind pose（静止姿势）姿态计算：把骨骼的局部 setup pose 变换累乘成世界变换，
/// 再用骨骼权重把网格顶点蒙皮到世界坐标。
///
/// # 坐标约定
///
/// Spine 是 **Y 轴向上**、单位是「像素」，原点在角色脚底。
/// Flutter 的 Canvas 是 **Y 轴向下**。所以渲染时统一用一个外层变换翻转 Y，
/// 本文件内部**保持 Spine 的原始约定**（Y 向上），便于与官方实现逐字段对照。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'spine_binary.dart';

/// 一根骨骼在世界空间里的变换（Spine 官方 `spBone` 的子集）。
final class BonePose {
  BonePose({
    required this.x,
    required this.y,
    required this.rotation,
    required this.scaleX,
    required this.scaleY,
    required this.a,
    required this.b,
    required this.c,
    required this.d,
    required this.worldX,
    required this.worldY,
  });

  /// 局部量（相对父骨骼）。
  final double x;
  final double y;
  final double rotation;
  final double scaleX;
  final double scaleY;

  /// 官方 spine-c 的 2D 仿射分量（**行主序**，与官方 `spBone` 逐字段一致）：
  ///
  /// ```text
  /// worldX = a * lx + b * ly + worldX
  /// worldY = c * lx + d * ly + worldY
  /// ```
  ///
  /// 注意这里 a,b 是「x 行」，c,d 是「y 行」——不是数学课本里的列向量写法。
  /// 一开始按列主序写会让所有顶点的 Y 恒为 0（因为 b/d 恰好是 0），
  /// 所以这里刻意与官方保持同一命名，避免再犯。
  final double a;
  final double b;
  final double c;
  final double d;

  /// 世界坐标原点。
  final double worldX;
  final double worldY;

  /// 把骨骼局部坐标变换到世界坐标。
  (double, double) toWorld(double lx, double ly) =>
      (a * lx + b * ly + worldX, c * lx + d * ly + worldY);
}

/// 一份骨骼在 bind pose 下的完整姿态。
final class SkeletonPose {
  SkeletonPose(this.bones);

  /// 与 [SpineSkeletonData.bones] 一一对应。
  final List<BonePose> bones;

  /// 计算 bind pose（等于 setup pose：所有骨骼都取骨骼数据里的局部值）。
  ///
  /// 骨骼必须按**父在子前**排列——Spine 导出保证了这一点（父索引 < 子索引），
  /// 所以单趟顺序遍历即可。
  factory SkeletonPose.bindPose(SpineSkeletonData data) {
    final poses = List<BonePose>.filled(data.bones.length, _identityPose);
    for (final bone in data.bones) {
      final parent = bone.parentIndex == null ? null : poses[bone.parentIndex!];
      final radians = bone.rotation * math.pi / 180.0;

      // 官方 spBone_updateWorldTransform 的 NORMAL 分支：
      //   rotationX = rotation + shearX
      //   rotationY = rotation + 90 + shearY
      //   la = cos(rotationX) * scaleX,  lb = cos(rotationY) * scaleY
      //   lc = sin(rotationX) * scaleX,  ld = sin(rotationY) * scaleY
      final rotationX = radians + _deg2rad(bone.shearX);
      final rotationY = radians + math.pi / 2 + _deg2rad(bone.shearY);
      final la = math.cos(rotationX) * bone.scaleX;
      final lb = math.cos(rotationY) * bone.scaleY;
      final lc = math.sin(rotationX) * bone.scaleX;
      final ld = math.sin(rotationY) * bone.scaleY;

      if (parent == null) {
        poses[bone.index] = BonePose(
          x: bone.x,
          y: bone.y,
          rotation: bone.rotation,
          scaleX: bone.scaleX,
          scaleY: bone.scaleY,
          a: la,
          b: lb,
          c: lc,
          d: ld,
          worldX: bone.x,
          worldY: bone.y,
        );
      } else {
        // worldX = pa * x + pb * y + parentWorldX
        // worldY = pc * x + pd * y + parentWorldY
        final wx = parent.a * bone.x + parent.b * bone.y + parent.worldX;
        final wy = parent.c * bone.x + parent.d * bone.y + parent.worldY;
        poses[bone.index] = BonePose(
          x: bone.x,
          y: bone.y,
          rotation: bone.rotation,
          scaleX: bone.scaleX,
          scaleY: bone.scaleY,
          a: parent.a * la + parent.b * lc,
          b: parent.a * lb + parent.b * ld,
          c: parent.c * la + parent.d * lc,
          d: parent.c * lb + parent.d * ld,
          worldX: wx,
          worldY: wy,
        );
      }
    }
    return SkeletonPose(poses);
  }

  static double _deg2rad(double degrees) => degrees * math.pi / 180.0;
}

final BonePose _identityPose = BonePose(
  x: 0,
  y: 0,
  rotation: 0,
  scaleX: 1,
  scaleY: 1,
  a: 1,
  b: 0,
  c: 0,
  d: 1,
  worldX: 0,
  worldY: 0,
);

/// 把网格附件蒙皮成世界坐标的顶点列表（`[x0,y0,x1,y1,...]`，Spine 坐标）。
///
/// - 加权顶点：每个顶点按 `weight` 混合各骨骼绑定点；
/// - 未加权顶点：直接相对**插槽所属骨骼**做一次变换。
Float32List skinMeshVertices(
  SpineMeshAttachment mesh,
  SkeletonPose pose,
  int slotBoneIndex,
) {
  final count = mesh.vertexCount;
  final out = Float32List(count * 2);

  final influences = mesh.influences;
  if (influences != null) {
    for (var i = 0; i < count; i++) {
      var wx = 0.0;
      var wy = 0.0;
      for (final inf in influences[i]) {
        final bone = pose.bones[inf.boneIndex];
        final (px, py) = bone.toWorld(inf.x, inf.y);
        wx += px * inf.weight;
        wy += py * inf.weight;
      }
      out[i * 2] = wx;
      out[i * 2 + 1] = wy;
    }
    return out;
  }

  final raw = mesh.unweightedVertices!;
  final bone = pose.bones[slotBoneIndex];
  for (var i = 0; i < count; i++) {
    final (px, py) = bone.toWorld(raw[i * 2], raw[i * 2 + 1]);
    out[i * 2] = px;
    out[i * 2 + 1] = py;
  }
  return out;
}

/// 区域附件在 bind pose 下的四个角（Spine 坐标，顺序：左下、右下、右上、左上）。
///
/// 与官方 `spRegionAttachment_updateOffset` 一致：先把宽高按 scale 缩放，
/// 再以中心为基准旋转，最后加局部偏移。
List<(double, double)> regionCorners(
  SpineRegionAttachment region,
  SkeletonPose pose,
  int slotBoneIndex,
) {
  final radians = region.rotation * math.pi / 180.0;
  final cos = math.cos(radians);
  final sin = math.sin(radians);
  final localX = region.x;
  final localY = region.y;
  final halfW = region.width * region.scaleX / 2;
  final halfH = region.height * region.scaleY / 2;

  // 四个角相对区域中心
  const corners = [
    (-1.0, -1.0),
    (1.0, -1.0),
    (1.0, 1.0),
    (-1.0, 1.0),
  ];

  final bone = pose.bones[slotBoneIndex];
  final result = <(double, double)>[];
  for (final (sx, sy) in corners) {
    final rx = sx * halfW;
    final ry = sy * halfH;
    final lx = localX + rx * cos - ry * sin;
    final ly = localY + rx * sin + ry * cos;
    result.add(bone.toWorld(lx, ly));
  }
  return result;
}
