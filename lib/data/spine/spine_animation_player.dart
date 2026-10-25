import 'skeleton_pose.dart';
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

  /// 指定时间点的姿态：套用骨骼时间轴 → 计算世界变换。
  SkeletonPose poseAt(double time) {
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

    return SkeletonPose.fromLocals(
      data,
      BoneLocals(
        rotation: rotation,
        x: x,
        y: y,
        scaleX: scaleX,
        scaleY: scaleY,
        shearX: shearX,
        shearY: shearY,
      ),
    );
  }
}
