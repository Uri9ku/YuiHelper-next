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
    this.deformTimelines = const <SpineDeformTimeline>[],
    this.ikTimelines = const <SpineIkTimeline>[],
    this.hasSlotTimelines = false,
    this.hasDeformTimelines = false,
    this.hasDrawOrderTimeline = false,
    this.eventCount = 0,
  });

  final String name;

  /// 秒
  final double duration;

  final List<SpineBoneTimeline> boneTimelines;

  /// deform 时间轴（S7：已读入，装配时按附件应用）
  final List<SpineDeformTimeline> deformTimelines;

  /// IK 约束时间轴（S7：已读入；求解在 S8）
  final List<SpineIkTimeline> ikTimelines;

  final bool hasSlotTimelines;
  final bool hasDeformTimelines;
  final bool hasDrawOrderTimeline;
  final int eventCount;
}

/// deform 时间轴里的一帧：从 [start] 开始的 [values] 个逐顶点偏移（x,y 平铺）。
final class SpineDeformFrame {
  SpineDeformFrame({required this.start, required this.values});

  final int start;
  final List<double> values;

  int get end => start + values.length;
}

/// deform 时间轴：网格附件的逐顶点偏移（布料/裙摆/肌肉形变）。
///
/// 官方 3.6 的 deform 帧只存「一段区间」的偏移（start + values），不是整段顶点；
/// 采样时把各帧统一展开到 `[0, span)` 再插值。
final class SpineDeformTimeline {
  SpineDeformTimeline({
    required this.skinIndex,
    required this.slotIndex,
    required this.attachmentName,
    required this.times,
    required this.frames,
    required this.curves,
  });

  final int skinIndex;
  final int slotIndex;
  final String attachmentName;
  final List<double> times;
  final List<SpineDeformFrame> frames;
  final List<SpineCurve> curves;

  /// 展开后的每帧长度（所有帧 end 的最大值，向上取偶）
  int get span {
    var m = 0;
    for (final f in frames) {
      if (f.end > m) m = f.end;
    }
    return m.isEven ? m : m + 1;
  }

  double get duration => times.isEmpty ? 0 : times.last;

  List<double> _expand(SpineDeformFrame frame, int span) {
    final out = List<double>.filled(span, 0);
    for (var i = 0; i < frame.values.length && frame.start + i < span; i++) {
      out[frame.start + i] = frame.values[i];
    }
    return out;
  }

  /// 采样某时刻的顶点偏移（长度 = [span]，未覆盖的顶点为 0）。
  List<double>? sample(double time) {
    final n = times.length;
    if (n == 0 || frames.length != n) return null;
    final width = span;
    if (width == 0) return null;
    if (time <= times.first) return _expand(frames.first, width);
    if (time >= times.last) return _expand(frames.last, width);
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
    final spanT = t1 - t0;
    final raw = spanT <= 0 ? 0.0 : ((time - t0) / spanT).clamp(0.0, 1.0);
    final k = (lo < curves.length ? curves[lo] : const SpineCurve.linear()).evaluate(raw);
    final a = _expand(frames[lo], width);
    final b = _expand(frames[hi], width);
    for (var i = 0; i < width; i++) {
      a[i] = a[i] + (b[i] - a[i]) * k;
    }
    return a;
  }
}

/// IK 时间轴：逐帧改约束的 mix / bend。
final class SpineIkTimeline {
  SpineIkTimeline({
    required this.constraintIndex,
    required this.times,
    required this.mix,
    required this.bendPositive,
  });

  final int constraintIndex;
  final List<double> times;
  final List<double> mix;
  final List<int> bendPositive;

  double get duration => times.isEmpty ? 0 : times.last;

  ({double mix, bool bendPositive})? sample(double time) {
    final n = times.length;
    if (n == 0) return null;
    var i = 0;
    if (time >= times.last) {
      i = n - 1;
    } else if (time > times.first) {
      while (i + 1 < n && times[i + 1] <= time) {
        i++;
      }
    }
    return (mix: mix[i], bendPositive: bendPositive[i] != 0);
  }
}

