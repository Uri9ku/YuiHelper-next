/// Spine 动画时间轴数据（S5）：从 `.skelenc` 二进制里读出来的纯数据。
///
/// 只依赖 dart 核心库——解析器（spine_binary.dart）会 import 本文件，
/// 播放器（spine_animation_player.dart）再把它和骨架数据组合起来采样。
library;

/// 帧间曲线（Spine 3.6：0=linear、1=stepped、2=bezier）。
final class SpineCurve {
  const SpineCurve.linear()
      : type = 0,
        cx1 = 0,
        cy1 = 0,
        cx2 = 0,
        cy2 = 0;

  const SpineCurve.stepped()
      : type = 1,
        cx1 = 0,
        cy1 = 0,
        cx2 = 0,
        cy2 = 0;

  const SpineCurve.bezier(this.cx1, this.cy1, this.cx2, this.cy2) : type = 2;

  final int type;
  final double cx1;
  final double cy1;
  final double cx2;
  final double cy2;

  /// 把归一化时间 [t]（0..1，帧内比例）映射成曲线上的比例。
  double evaluate(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    switch (type) {
      case 1:
        return 0; // stepped：保持前一个关键帧
      case 2:
        return _bezierY(t);
      default:
        return t;
    }
  }

  /// 先按 x 反解参数 u，再取 y（与官方 spine-c 的 bezier 采样同思路）。
  double _bezierY(double x) {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (_bezier(mid, cx1, cx2) < x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return _bezier((lo + hi) / 2, cy1, cy2);
  }

  static double _bezier(double t, double c1, double c2) {
    final u = 1 - t;
    return 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t;
  }
}

/// 骨骼时间轴（rotate / translate / scale / shear 统一表示）。
///
/// [stride] = 1（rotate）或 2（translate/scale/shear）；
/// [values] 按帧顺序平铺：帧 i 的第 c 个分量 = values[i*stride + c]。
final class SpineBoneTimeline {
  SpineBoneTimeline({
    required this.boneIndex,
    required this.kind,
    required this.times,
    required this.values,
    required this.curves,
    required this.stride,
  });

  final int boneIndex;

  /// rotate / translate / scale / shear
  final String kind;

  final List<double> times;
  final List<double> values;

  /// 长度 = 帧数-1（最后一帧没有曲线）
  final List<SpineCurve> curves;

  final int stride;

  double get duration => times.isEmpty ? 0 : times.last;

  /// 采样第 [component] 个分量在 [time] 处的值；没有帧返回 null。
  double? sample(double time, int component) {
    final n = times.length;
    if (n == 0) return null;
    if (time <= times.first) return values[component % stride];
    if (time >= times.last) return values[(n - 1) * stride + component % stride];
    var lo = 0;
    var hi = n - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] <= time) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final t0 = times[lo];
    final t1 = times[hi];
    final span = t1 - t0;
    final raw = span <= 0 ? 0.0 : ((time - t0) / span).clamp(0.0, 1.0);
    final curve = lo < curves.length ? curves[lo] : const SpineCurve.linear();
    final k = curve.evaluate(raw);
    final a = values[lo * stride + component % stride];
    final b = values[hi * stride + component % stride];
    return a + (b - a) * k;
  }
}

/// 一条动画（时长 + 骨骼时间轴；事件/绘制顺序等当前只读不应用）。
final class SpineAnimation {
  SpineAnimation({
    required this.name,
    required this.duration,
    required this.boneTimelines,
    this.hasSlotTimelines = false,
    this.hasDeformTimelines = false,
    this.hasDrawOrderTimeline = false,
    this.eventCount = 0,
  });

  final String name;

  /// 秒
  final double duration;

  final List<SpineBoneTimeline> boneTimelines;

  final bool hasSlotTimelines;
  final bool hasDeformTimelines;
  final bool hasDrawOrderTimeline;
  final int eventCount;
}
