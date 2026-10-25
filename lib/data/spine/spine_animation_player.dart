import 'skeleton_pose.dart';
import 'spine_ik_solver.dart';
import 'spine_animation_data.dart';
import 'spine_binary.dart';

/// 单条动画播放器（S5 v1）：时间推进 + 姿态采样（FK 骨骼时间轴）。
///
/// 边界（诚实标注）：
/// - 已应用：rotate / translate / scale / shear 四类骨骼时间轴（含 linear/stepped/bezier 曲线）；
/// - 未应用：IK / transform / path 约束求解、deform 网格形变、drawOrder、slot 颜色与附件切换
///   （数据已读入但 v1 不生效——战斗待机/普攻这类 FK 动作看不出来，但布料形变与换装动作会缺）；
/// - 不做多动画混合（mix），只播单条。
final class SpineAnimationPlayer {
  SpineAnimationPlayer(this.data);

  final SpineSkeletonData data;

  SpineAnimation? _animation;
  double _time = 0;
  bool _loop = true;

  SpineAnimation? get animation => _animation;
  String? get animationName => _animation?.name;
  double get time => _time;
  double get duration => _animation?.duration ?? 0;
  bool get loop => _loop;
  bool get hasAnimation => _animation != null;

  /// 选择动画（不支持混合；[loop] 控制循环）。
  void setAnimation(String? name, {bool loop = true}) {
    _loop = loop;
    _time = 0;
    if (name == null || name.isEmpty) {
      _animation = null;
      return;
    }
    _animation = data.findAnimation(name);
  }

  /// 推进时间（秒）。未选动画时不动。
  void update(double dt) {
    final anim = _animation;
    if (anim == null || dt <= 0) return;
    final dur = anim.duration;
    if (dur <= 0) return;
    _time += dt;
    if (_loop) {
      while (_time > dur) {
        _time -= dur;
      }
    } else if (_time > dur) {
      _time = dur;
    }
  }

  /// 当前姿态（未选动画时返回 bind pose）。
  SkeletonPose pose() => poseAt(_time);

  /// 某时刻的 deform 查找器（传给 `SpineBinder.bind` 的 `deformLookup`）。
  ///
  /// 键 = skinIndex:slotIndex:attachmentName；没有 deform 数据时返回 null。
  List<double>? Function(int skinIndex, int slotIndex, String attachment)? deformAt(double time) {
    final anim = _animation;
    if (anim == null || anim.deformTimelines.isEmpty) return null;
    final map = <String, List<double>>{};
    for (final tl in anim.deformTimelines) {
      final offsets = tl.sample(time);
      if (offsets == null) continue;
      map['${tl.skinIndex}:${tl.slotIndex}:${tl.attachmentName}'] = offsets;
    }
    if (map.isEmpty) return null;
    return (skinIndex, slotIndex, attachment) => map['$skinIndex:$slotIndex:$attachment'];
  }

  /// IK 时间轴在 [time] 处的 mix/bend 覆盖（约束下标 → 覆盖值）。
  Map<int, ({double mix, bool bendPositive})> ikOverridesAt(double time) {
    final anim = _animation;
    if (anim == null || anim.ikTimelines.isEmpty) return const {};
    final out = <int, ({double mix, bool bendPositive})>{};
    for (final tl in anim.ikTimelines) {
      final v = tl.sample(time);
      if (v != null) out[tl.constraintIndex] = v;
    }
    return out;
  }

  /// 指定时间点的姿态：套用骨骼时间轴 → 世界变换 → IK 求解。
  ///
  /// [solveIk] 为 false 时只做 FK（调试/对照用）。
  SkeletonPose poseAt(double time, {bool solveIk = true}) {
    final anim = _animation;
    if (anim == null) return SkeletonPose.bindPose(data);

    final count = data.bones.length;
    final rotation = List<double>.generate(count, (i) => data.bones[i].rotation);
    final x = List<double>.generate(count, (i) => data.bones[i].x);
    final y = List<double>.generate(count, (i) => data.bones[i].y);
    final scaleX = List<double>.generate(count, (i) => data.bones[i].scaleX);
    final scaleY = List<double>.generate(count, (i) => data.bones[i].scaleY);
    final shearX = List<double>.generate(count, (i) => data.bones[i].shearX);
    final shearY = List<double>.generate(count, (i) => data.bones[i].shearY);

    for (final tl in anim.boneTimelines) {
      final bi = tl.boneIndex;
      if (bi < 0 || bi >= count) continue;
      final bone = data.bones[bi];
      switch (tl.kind) {
        case 'rotate':
          final v = tl.sample(time, 0);
          if (v != null) rotation[bi] = bone.rotation + v;
        case 'translate':
          final vx = tl.sample(time, 0);
          final vy = tl.sample(time, 1);
          if (vx != null) x[bi] = bone.x + vx;
          if (vy != null) y[bi] = bone.y + vy;
        case 'scale':
          final vx = tl.sample(time, 0);
          final vy = tl.sample(time, 1);
          if (vx != null) scaleX[bi] = bone.scaleX * vx;
          if (vy != null) scaleY[bi] = bone.scaleY * vy;
        case 'shear':
          final vx = tl.sample(time, 0);
          final vy = tl.sample(time, 1);
          if (vx != null) shearX[bi] = bone.shearX + vx;
          if (vy != null) shearY[bi] = bone.shearY + vy;
      }
    }

    final locals = BoneLocals(
      rotation: rotation,
      x: x,
      y: y,
      scaleX: scaleX,
      scaleY: scaleY,
      shearX: shearX,
      shearY: shearY,
    );
    if (!solveIk) return SkeletonPose.fromLocals(data, locals);
    return SpineIkSolver.solve(
      data: data,
      locals: locals,
      overrides: ikOverridesAt(time),
    );
  }
}
