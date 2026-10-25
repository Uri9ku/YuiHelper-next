library;

import 'dart:convert';
import 'dart:typed_data';

import 'spine_animation_data.dart';
import 'spine_constraint_data.dart';

/// Spine 二进制骨架（`.skel`）解析器 —— 纯 Dart、零依赖。
///
/// # 为什么是这个版本
///
/// 游戏（SAOUB 3.7.0 / `libapp.so`）用的是官方 **spine-c 3.6.53**，导出的骨骼是
/// 二进制 `.skel`。逻辑以官方 `SkeletonBinary.c`（3.6.53 tag）为基准，
/// 再用**30 万行真实骨骼数据反推校正**——下面三处与官方不一致的地方，
/// 都是「只有按它读，整份文件才能恰好读完」才确定的，见各 `_read*` 的注释。
///
/// # 正确性判据
///
/// 唯一的判据是 **`consumed == bytes.length`**：
/// 二进制格式没有任何分隔符，任何一个字段多读/少读 1 字节，
/// 末尾位置就不可能对上。300 份真实骨骼全部满足该判据。
///
/// 参考：https://en.esotericsoftware.com/spine-binary-format

/// 解析失败（数据损坏、版本不符、或本项目尚未覆盖的附件类型）。
class SpineFormatException implements Exception {
  const SpineFormatException(this.message);
  final String message;

  @override
  String toString() => 'SpineFormatException: $message';
}

/// 附件类型常量（与官方 `SP_ATTACHMENT_*` 一致）。
abstract final class SpineAttachmentType {
  static const int region = 0;
  static const int boundingBox = 1;
  static const int mesh = 2;
  static const int linkedMesh = 3;
  static const int path = 4;
  static const int point = 5;
  static const int clipping = 6;
}

/// 一根骨骼的 setup pose（静止姿势）数据。
final class SpineBoneData {
  const SpineBoneData({
    required this.index,
    required this.name,
    required this.parentIndex,
    required this.rotation,
    required this.x,
    required this.y,
    required this.scaleX,
    required this.scaleY,
    required this.shearX,
    required this.shearY,
    required this.length,
    required this.transformMode,
  });

  final int index;
  final String name;

  /// 父骨骼下标；根骨骼为 null。
  final int? parentIndex;

  /// 以下都是**相对父骨骼**的局部变换，单位为「度 / 世界单位」。
  final double rotation;
  final double x;
  final double y;
  final double scaleX;
  final double scaleY;
  final double shearX;
  final double shearY;
  final double length;

  /// 0 = normal（默认）；其余见官方 `TRANSFORM_*` 常量。
  final int transformMode;

  @override
  String toString() => 'SpineBoneData($name, parent=$parentIndex)';
}

/// 一个插槽（Spine 的 slot ≈ 游戏里一个可换的部件）。
final class SpineSlotData {
  const SpineSlotData({
    required this.index,
    required this.name,
    required this.boneIndex,
    required this.attachmentName,
    required this.blendMode,
  });

  final int index;
  final String name;
  final int boneIndex;

  /// setup pose 下这个插槽挂的附件名；为 null 表示不挂。
  final String? attachmentName;

  /// 0 = normal, 1 = additive, 2 = multiply, 3 = screen。
  final int blendMode;

  @override
  String toString() => 'SpineSlotData($name, bone=$boneIndex, att=$attachmentName)';
}

/// 一个区域附件（`ATTACHMENT_REGION`）：一张矩形图。
final class SpineRegionAttachment {
  const SpineRegionAttachment({
    required this.name,
    required this.path,
    required this.rotation,
    required this.x,
    required this.y,
    required this.scaleX,
    required this.scaleY,
    required this.width,
    required this.height,
    required this.color,
  });

  final String name;

  /// 用来在图集里找区域的名字（通常等于 [name]）。
  final String path;
  final double rotation;
  final double x;
  final double y;
  final double scaleX;
  final double scaleY;
  final double width;
  final double height;

  /// RGBA，0..1。
  final List<double> color;
}

/// 一个网格顶点的骨骼绑定：`(boneIndex, localX, localY)` 加权重。
final class SpineVertexInfluence {
  const SpineVertexInfluence({
    required this.boneIndex,
    required this.x,
    required this.y,
    required this.weight,
  });

  final int boneIndex;
  final double x;
  final double y;
  final double weight;
}

/// 一个网格附件（`ATTACHMENT_MESH`）：**角色身体的主构成**。
///
/// 实测 300 份骨骼里有 91,831 个网格附件、只有 558 个区域附件——
/// 也就是说「只画矩形」画不出角色，必须按三角形 + 骨骼权重蒙皮。
final class SpineMeshAttachment {
  SpineMeshAttachment({
    required this.name,
    required this.path,
    required this.uvs,
    required this.triangles,
    required this.influences,
    required this.unweightedVertices,
    required this.color,
    required this.width,
    required this.height,
  });

  final String name;
  final String path;

  /// 纹理坐标，长度 = 顶点数 * 2，取值 0..1（原点在左上）。
  final Float32List uvs;

  /// 三角形顶点下标，长度是 3 的倍数。
  final Uint16List triangles;

  /// 加权顶点：每个顶点一个 `List<SpineVertexInfluence>`。
  /// 未加权时为 null（改用 [unweightedVertices]）。
  final List<List<SpineVertexInfluence>>? influences;

  /// 未加权顶点：直接是相对**插槽骨骼**的坐标，长度 = 顶点数 * 2。
  final Float32List? unweightedVertices;

  final List<double> color;
  final double width;
  final double height;

  /// 顶点数（= uvs.length / 2）。
  int get vertexCount => uvs.length ~/ 2;

  bool get isWeighted => influences != null;
}

/// 一个皮肤的附件表：`slotIndex -> attachmentName -> attachment`。
final class SpineSkin {
  SpineSkin(this.name);

  final String name;

  final Map<int, Map<String, Object>> _attachments = {};

  void put(int slotIndex, String name, Object attachment) {
    (_attachments[slotIndex] ??= {})[name] = attachment;
  }

  /// 取某个插槽下某个名字的附件；没有返回 null。
  Object? attachment(int slotIndex, String name) =>
      _attachments[slotIndex]?[name];

  /// 某插槽下的全部附件名。
  Map<String, Object> attachmentsOfSlot(int slotIndex) =>
      _attachments[slotIndex] ?? const {};

  /// 皮肤里出现过的插槽下标（升序）。
  List<int> get slotIndices => _attachments.keys.toList()..sort();

  int get attachmentCount =>
      _attachments.values.fold(0, (sum, m) => sum + m.length);

  bool get isEmpty => _attachments.isEmpty;
}

/// 解析好的一份骨骼数据。
///
/// 只保留**渲染 bind pose 需要的部分**：骨骼、插槽、皮肤、区域与网格附件。
/// 动画时间轴目前只统计数量，不保留内容（见 [animationCount]）。
final class SpineSkeletonData {
  SpineSkeletonData({
    required this.hash,
    required this.version,
    required this.width,
    required this.height,
    required this.imagesPath,
    required this.bones,
    required this.slots,
    required this.defaultSkin,
    required this.skins,
    this.ikConstraints = const <SpineIkConstraintData>[],
    this.transformConstraints = const <SpineTransformConstraintData>[],
    this.pathConstraints = const <SpinePathConstraintData>[],
    required this.animationCount,
    required this.animationNames,
    this.animations = const <SpineAnimation>[],
    required this.eventCount,
    required this.consumedBytes,
  });

  /// 数据哈希（Spine 自己算的，不是文件哈希）。
  final String? hash;

  /// 导出它的 Spine 版本，实测恒为 `3.6.53`。
  final String version;

  /// setup pose 下所有附件包围盒的宽高。
  final double width;
  final double height;

  /// 骨骼里记录的图片路径（如 `../../saoal/asset/source/spine/characterAtlas/chara_1/x/`），
  /// 用于反查该角色属于哪个图集目录。
  final String? imagesPath;

  final List<SpineBoneData> bones;
  final List<SpineSlotData> slots;

  /// 默认皮肤（没被命名皮肤覆盖的附件都在这里）。
  final SpineSkin defaultSkin;

  /// 命名皮肤（游戏里用来做换装/表情）。
  final List<SpineSkin> skins;

  /// 约束 setup 数据（S7 读入；IK 求解在 S8）
  final List<SpineIkConstraintData> ikConstraints;
  final List<SpineTransformConstraintData> transformConstraints;
  final List<SpinePathConstraintData> pathConstraints;

  final int animationCount;
  final List<String> animationNames;

  /// 解析出的动画（S5 起保留时间轴内容；事件/绘制顺序只读不应用）。
  final List<SpineAnimation> animations;

  /// 按名字找动画。
  SpineAnimation? findAnimation(String name) {
    for (final a in animations) {
      if (a.name == name) return a;
    }
    return null;
  }
  final int eventCount;

  /// 解析结束时读到的字节数。**必须等于原始文件长度**，否则数据不可信。
  final int consumedBytes;

  /// 皮肤在二进制里的索引：default = 0，命名皮肤 = 1..n。
  int indexOfSkin(SpineSkin skin) {
    if (identical(skin, defaultSkin) || skin.name == defaultSkin.name) return 0;
    final i = skins.indexOf(skin);
    return i < 0 ? 0 : i + 1;
  }

  /// 按名字找皮肤；`name` 为空或找不到时回退到 [defaultSkin]。
  SpineSkin skin({String? name}) {
    if (name == null || name.isEmpty) return defaultSkin;
    for (final s in skins) {
      if (s.name == name) return s;
    }
    return defaultSkin;
  }
}

/// 按官方 3.6 二进制布局读取 `.skel`。
///
/// 用法：
/// ```dart
/// final data = SpineBinaryParser.parse(bytes);
/// assert(data.consumedBytes == bytes.length);
/// ```
abstract final class SpineBinaryParser {
  /// 解析整份 `.skel`。失败抛 [SpineFormatException]。
  static SpineSkeletonData parse(Uint8List bytes) {
    final r = _Reader(bytes);
    final hash = r.string();
    final version = (r.string() ?? '').trim();
    if (version.isEmpty) {
      throw const SpineFormatException('缺少 version 字段，不是有效骨骼文件');
    }
    final width = r.float();
    final height = r.float();
    final nonessential = r.boolean();

    String? imagesPath;
    if (nonessential) {
      r.float(); // fps，渲染用不到
      imagesPath = r.string();
      // 3.6.53 的这个构建**没有 audio 字段**（官方源码里有）。
      // 用「读完 audio 之后骨骼区是否合法」来判定，不合法就回退。
      final save = r.pos;
      try {
        r.string();
        if (!_bonesLookValid(r, nonessential)) {
          r.pos = save;
        }
      } catch (_) {
        r.pos = save;
      }
    }

    final bones = _readBones(r, nonessential);
    final slots = _readSlots(r);
    final ikConstraints = _readIkConstraints(r);
    final transformConstraints = _readTransformConstraints(r);
    final pathConstraints = _readPathConstraints(r);

    final defaultSkin = _readSkin(r, 'default');
    final skins = <SpineSkin>[];
    final skinCount = r.varint();
    for (var i = 0; i < skinCount; i++) {
      // ⚠ 3.6.53 的命名皮肤**没有** bones/ik/transform/path 计数段
      // （那是 3.8 才加的）。多读这四个 varint 会让整段错位。
      final name = r.string() ?? '';
      skins.add(_readSkin(r, name));
    }

    final eventCount = _skipEvents(r);
    final parsedAnimations = _readAnimations(r);

    return SpineSkeletonData(
      hash: hash,
      version: version,
      width: width,
      height: height,
      imagesPath: imagesPath,
      bones: bones,
      slots: slots,
      defaultSkin: defaultSkin,
      skins: skins,
      ikConstraints: ikConstraints,
      transformConstraints: transformConstraints,
      pathConstraints: pathConstraints,
      animationCount: parsedAnimations.count,
      animationNames: parsedAnimations.names,
      animations: parsedAnimations.animations,
      eventCount: eventCount,
      consumedBytes: r.pos,
    );
  }

  // ── 各段解析 ──────────────────────────────────────────────────────────

  static List<SpineBoneData> _readBones(_Reader r, bool nonessential) {
    final count = r.varint();
    final bones = <SpineBoneData>[];
    for (var i = 0; i < count; i++) {
      final name = r.string() ?? '';
      final parent = i == 0 ? null : r.varint();
      bones.add(
        SpineBoneData(
          index: i,
          name: name,
          parentIndex: parent,
          rotation: r.float(),
          x: r.float(),
          y: r.float(),
          scaleX: r.float(),
          scaleY: r.float(),
          shearX: r.float(),
          shearY: r.float(),
          length: r.float(),
          transformMode: r.varint(),
        ),
      );
      if (nonessential) r.color();
    }
    return bones;
  }

  static List<SpineSlotData> _readSlots(_Reader r) {
    final count = r.varint();
    final slots = <SpineSlotData>[];
    for (var i = 0; i < count; i++) {
      final name = r.string() ?? '';
      final boneIndex = r.varint();
      r.color(); // 插槽颜色
      r.color(); // dark color
      final attachmentName = r.string();
      final blend = r.varint();
      slots.add(
        SpineSlotData(
          index: i,
          name: name,
          boneIndex: boneIndex,
          attachmentName: attachmentName,
          blendMode: blend,
        ),
      );
    }
    return slots;
  }

  static List<SpineIkConstraintData> _readIkConstraints(_Reader r) {
    final count = r.varint();
    final out = <SpineIkConstraintData>[];
    for (var i = 0; i < count; i++) {
      final name = r.string() ?? '';
      final order = r.varint();
      final boneCount = r.varint();
      final bones = <int>[for (var b = 0; b < boneCount; b++) r.varint()];
      final target = r.varint();
      final mix = r.float();
      final bend = r.int8();
      out.add(SpineIkConstraintData(
        name: name,
        order: order,
        bones: bones,
        target: target,
        mix: mix,
        bendPositive: bend != 0,
      ));
    }
    return out;
  }

  static List<SpineTransformConstraintData> _readTransformConstraints(_Reader r) {
    final count = r.varint();
    final out = <SpineTransformConstraintData>[];
    for (var i = 0; i < count; i++) {
      final name = r.string() ?? '';
      final order = r.varint();
      final boneCount = r.varint();
      final bones = <int>[for (var b = 0; b < boneCount; b++) r.varint()];
      final target = r.varint();
      final local = r.boolean();
      final relative = r.boolean();
      final offsetRotation = r.float();
      final offsetX = r.float();
      final offsetY = r.float();
      final offsetScaleX = r.float();
      final offsetScaleY = r.float();
      final offsetShearY = r.float();
      final mixRotate = r.float();
      final mixTranslate = r.float();
      final mixScale = r.float();
      final mixShear = r.float();
      out.add(SpineTransformConstraintData(
        name: name,
        order: order,
        bones: bones,
        target: target,
        local: local,
        relative: relative,
        offsetRotation: offsetRotation,
        offsetX: offsetX,
        offsetY: offsetY,
        offsetScaleX: offsetScaleX,
        offsetScaleY: offsetScaleY,
        offsetShearY: offsetShearY,
        mixRotate: mixRotate,
        mixTranslate: mixTranslate,
        mixScale: mixScale,
        mixShear: mixShear,
      ));
    }
    return out;
  }

  static List<SpinePathConstraintData> _readPathConstraints(_Reader r) {
    final count = r.varint();
    final out = <SpinePathConstraintData>[];
    for (var i = 0; i < count; i++) {
      final name = r.string() ?? '';
      final order = r.varint();
      final boneCount = r.varint();
      final bones = <int>[for (var b = 0; b < boneCount; b++) r.varint()];
      final targetSlot = r.varint();
      final positionMode = r.varint();
      final spacingMode = r.varint();
      final rotateMode = r.varint();
      final rotation = r.float();
      final position = r.float();
      final spacing = r.float();
      final mixRotate = r.float();
      final mixTranslate = r.float();
      out.add(SpinePathConstraintData(
        name: name,
        order: order,
        bones: bones,
        targetSlot: targetSlot,
        positionMode: positionMode,
        spacingMode: spacingMode,
        rotateMode: rotateMode,
        rotation: rotation,
        position: position,
        spacing: spacing,
        mixRotate: mixRotate,
        mixTranslate: mixTranslate,
      ));
    }
    return out;
  }

  static SpineSkin _readSkin(_Reader r, String name) {
    final skin = SpineSkin(name);
    final slotCount = r.varint();
    if (slotCount == 0) return skin;
    for (var s = 0; s < slotCount; s++) {
      final slotIndex = r.varint();
      final attachmentCount = r.varint();
      for (var a = 0; a < attachmentCount; a++) {
        // ⚠ 每个附件有**两个**名字：
        //   1) skin 层的 placeholder name
        //   2) readAttachment 内部的真正 name（可能为 null → 复用 placeholder）
        // 官方 readSkin 就是 readString 之后把结果当 placeholder 传进 readAttachment，
        // 后者再 readString 一次。漏掉任何一个，第一个附件就错位。
        final placeholder = r.string() ?? '';
        final attachmentName = r.string() ?? placeholder;
        final type = r.int8();
        final attachment = _readAttachment(r, type, attachmentName);
        if (attachment != null) {
          skin.put(slotIndex, attachmentName, attachment);
        }
      }
    }
    return skin;
  }

  static Object? _readAttachment(_Reader r, int type, String name) {
    switch (type) {
      case SpineAttachmentType.region:
        final path = r.string() ?? name;
        return SpineRegionAttachment(
          name: name,
          path: path,
          rotation: r.float(),
          x: r.float(),
          y: r.float(),
          scaleX: r.float(),
          scaleY: r.float(),
          width: r.float(),
          height: r.float(),
          color: r.color(),
        );

      case SpineAttachmentType.boundingBox:
        _skipVertices(r, r.varint());
        r.color();
        return null;

      case SpineAttachmentType.mesh:
        return _readMesh(r, name);

      case SpineAttachmentType.linkedMesh:
        // 链接网格：数据来自另一个 skin/slot 的同名网格，这里只记名字。
        final path = r.string() ?? name;
        r.color();
        r.string(); // source skin
        r.string(); // source parent
        r.boolean(); // inherit deform
        r.float(); // width
        r.float(); // height
        return SpineLinkedMeshAttachment(name: name, path: path);

      case SpineAttachmentType.path:
        r.boolean(); // closed
        r.boolean(); // constantSpeed
        final vertexCount = r.varint();
        _skipVertices(r, vertexCount);
        for (var i = 0; i < vertexCount ~/ 3; i++) {
          r.float();
        }
        r.color();
        return null;

      case SpineAttachmentType.point:
        r.float();
        r.float();
        r.float();
        r.color();
        return null;

      case SpineAttachmentType.clipping:
        // ⚠ 顺序是 endSlotIndex → vertexCount → vertices → color，不能反
        r.varint(); // endSlotIndex
        _skipVertices(r, r.varint());
        r.color();
        return null;

      default:
        throw SpineFormatException('未知附件类型 $type（插槽 $name）');
    }
  }

  static SpineMeshAttachment _readMesh(_Reader r, String name) {
    final path = r.string() ?? name;
    final color = r.color();
    final vertexCount = r.varint();
    final uvs = r.floatArray(vertexCount * 2);
    final triangles = r.shortArray();
    final weighted = r.boolean();

    List<List<SpineVertexInfluence>>? influences;
    Float32List? unweighted;
    if (weighted) {
      influences = List.generate(vertexCount, (_) {
        final boneCount = r.varint();
        final list = <SpineVertexInfluence>[];
        for (var b = 0; b < boneCount; b++) {
          list.add(
            SpineVertexInfluence(
              boneIndex: r.varint(),
              x: r.float(),
              y: r.float(),
              weight: r.float(),
            ),
          );
        }
        return list;
      });
    } else {
      unweighted = r.floatArray(vertexCount * 2);
    }

    r.varint(); // hull length
    r.shortArray(); // edges
    final width = r.float();
    final height = r.float();

    return SpineMeshAttachment(
      name: name,
      path: path,
      uvs: uvs,
      triangles: triangles,
      influences: influences,
      unweightedVertices: unweighted,
      color: color,
      width: width,
      height: height,
    );
  }

  /// 跳过顶点数组：先一个 weighted 布尔，再按是否加权读不同结构。
  static void _skipVertices(_Reader r, int vertexCount) {
    final weighted = r.boolean();
    if (!weighted) {
      r.floatArray(vertexCount * 2);
      return;
    }
    for (var i = 0; i < vertexCount; i++) {
      final boneCount = r.varint();
      for (var b = 0; b < boneCount; b++) {
        r.varint();
        r.float();
        r.float();
        r.float();
      }
    }
  }

  /// 事件段：`name, intValue(varint-), floatValue, stringValue`。
  ///
  /// ⚠ 3.6.53 **没有** audio/volume/balance（3.8+ 才有）。
  /// 多读这 8 字节会让后面整段动画错位——这是最容易踩的坑。
  static int _skipEvents(_Reader r) {
    final count = r.varint();
    for (var i = 0; i < count; i++) {
      r.string();
      r.varint(positive: false);
      r.float();
      r.string();
    }
    return count;
  }

  /// 动画段：读取数量/名字/时间轴（S5）。字节布局与旧版 skip 完全一致，
  /// 判据仍是「读完恰好到 EOF」，所以解析器单测能直接验证没读错位。
  static ({int count, List<String> names, List<SpineAnimation> animations}) _readAnimations(
    _Reader r,
  ) {
    final count = r.varint();
    final names = <String>[];
    final animations = <SpineAnimation>[];
    for (var i = 0; i < count; i++) {
      final name = r.string() ?? '';
      names.add(name);
      animations.add(_readAnimationBody(r, name));
    }
    return (count: count, names: names, animations: animations);
  }

  static SpineAnimation _readAnimationBody(_Reader r, String name) {
    var duration = 0.0;

    // ── slot 时间轴（attachment / color / two-color）：读掉不应用 ──
    var hasSlotTimelines = false;
    final slotEntries = r.varint();
    for (var e = 0; e < slotEntries; e++) {
      r.varint(); // slot index
      final timelineCount = r.varint();
      for (var t = 0; t < timelineCount; t++) {
        hasSlotTimelines = true;
        final type = r.int8();
        final frames = r.varint();
        for (var f = 0; f < frames; f++) {
          final time = r.float();
          if (time > duration) duration = time;
          switch (type) {
            case 0:
              r.string();
            case 1:
              r.color();
              if (f < frames - 1) _readCurve(r);
            default:
              r.color();
              r.color();
              if (f < frames - 1) _readCurve(r);
          }
        }
      }
    }

    // ── 骨骼时间轴：rotate / translate / scale / shear（读进内存） ──
    final boneTimelines = <SpineBoneTimeline>[];
    final boneEntries = r.varint();
    for (var e = 0; e < boneEntries; e++) {
      final boneIndex = r.varint();
      final timelineCount = r.varint();
      for (var t = 0; t < timelineCount; t++) {
        final type = r.int8();
        final frames = r.varint();
        final stride = type == 0 ? 1 : 2;
        final times = <double>[];
        final values = <double>[];
        final curves = <SpineCurve>[];
        for (var f = 0; f < frames; f++) {
          final time = r.float();
          times.add(time);
          if (time > duration) duration = time;
          for (var v = 0; v < stride; v++) {
            values.add(r.float());
          }
          if (f < frames - 1) curves.add(_readCurve(r));
        }
        boneTimelines.add(
          SpineBoneTimeline(
            boneIndex: boneIndex,
            kind: switch (type) {
              0 => 'rotate',
              1 => 'translate',
              2 => 'scale',
              _ => 'shear',
            },
            times: times,
            values: values,
            curves: curves,
            stride: stride,
          ),
        );
      }
    }

    // ── IK 时间轴：保留（S7 读入；求解在 S8） ──
    final ikTimelines = <SpineIkTimeline>[];
    final ikCount = r.varint();
    for (var i = 0; i < ikCount; i++) {
      final constraintIndex = r.varint();
      final frames = r.varint();
      final times = <double>[];
      final mixes = <double>[];
      final bends = <int>[];
      for (var f = 0; f < frames; f++) {
        final time = r.float();
        times.add(time);
        if (time > duration) duration = time;
        mixes.add(r.float());
        bends.add(r.int8());
        if (f < frames - 1) _readCurve(r);
      }
      ikTimelines.add(SpineIkTimeline(
        constraintIndex: constraintIndex,
        times: times,
        mix: mixes,
        bendPositive: bends,
      ));
    }

    // ── transform 时间轴：读掉 ──
    final transformCount = r.varint();
    for (var i = 0; i < transformCount; i++) {
      r.varint();
      final frames = r.varint();
      for (var f = 0; f < frames; f++) {
        final time = r.float();
        if (time > duration) duration = time;
        for (var v = 0; v < 4; v++) {
          r.float();
        }
        if (f < frames - 1) _readCurve(r);
      }
    }

    // ── path 时间轴：读掉 ──
    final pathEntries = r.varint();
    for (var e = 0; e < pathEntries; e++) {
      r.varint();
      final timelineCount = r.varint();
      for (var t = 0; t < timelineCount; t++) {
        final type = r.int8();
        final frames = r.varint();
        final perFrame = type == 2 ? 2 : 1;
        for (var f = 0; f < frames; f++) {
          final time = r.float();
          if (time > duration) duration = time;
          for (var v = 0; v < perFrame; v++) {
            r.float();
          }
          if (f < frames - 1) _readCurve(r);
        }
      }
    }

    // ── deform 时间轴：保留（S7 应用） ──
    var hasDeformTimelines = false;
    final deformTimelines = <SpineDeformTimeline>[];
    final skinCount = r.varint();
    for (var s = 0; s < skinCount; s++) {
      final skinIndex = r.varint();
      final slotCount = r.varint();
      for (var sl = 0; sl < slotCount; sl++) {
        final slotIndex = r.varint();
        final deformCount = r.varint();
        for (var d = 0; d < deformCount; d++) {
          hasDeformTimelines = true;
          final attachmentName = r.string() ?? '';
          final frames = r.varint();
          final times = <double>[];
          final deformFrames = <SpineDeformFrame>[];
          final curves = <SpineCurve>[];
          for (var f = 0; f < frames; f++) {
            final time = r.float();
            times.add(time);
            if (time > duration) duration = time;
            final end = r.varint();
            if (end > 0) {
              final startIndex = r.varint();
              final values = r.floatArray(end);
              deformFrames.add(SpineDeformFrame(start: startIndex, values: values));
            } else {
              deformFrames.add(SpineDeformFrame(start: 0, values: const <double>[]));
            }
            if (f < frames - 1) curves.add(_readCurve(r));
          }
          deformTimelines.add(SpineDeformTimeline(
            skinIndex: skinIndex,
            slotIndex: slotIndex,
            attachmentName: attachmentName,
            times: times,
            frames: deformFrames,
            curves: curves,
          ));
        }
      }
    }

    // ── drawOrder ──
    var hasDrawOrder = false;
    final drawOrderFrames = r.varint();
    if (drawOrderFrames > 0) hasDrawOrder = true;
    for (var f = 0; f < drawOrderFrames; f++) {
      final time = r.float();
      if (time > duration) duration = time;
      final changeCount = r.varint();
      for (var c = 0; c < changeCount; c++) {
        r.varint();
        r.varint();
      }
    }

    // ── 动画内 event（3.6：没有 volume/balance） ──
    final eventCount = r.varint();
    for (var e = 0; e < eventCount; e++) {
      final time = r.float();
      if (time > duration) duration = time;
      r.varint();
      r.varint(positive: false);
      r.float();
      if (r.boolean()) {
        r.string();
      }
    }

    return SpineAnimation(
      name: name,
      duration: duration,
      boneTimelines: boneTimelines,
      deformTimelines: deformTimelines,
      ikTimelines: ikTimelines,
      hasSlotTimelines: hasSlotTimelines,
      hasDeformTimelines: hasDeformTimelines,
      hasDrawOrderTimeline: hasDrawOrder,
      eventCount: eventCount,
    );
  }

  /// 读一帧曲线：0=linear、1=stepped、2=bezier（后跟 4 个控制点）。
  static SpineCurve _readCurve(_Reader r) {
    final type = r.int8();
    if (type == 2) {
      final cx1 = r.float();
      final cy1 = r.float();
      final cx2 = r.float();
      final cy2 = r.float();
      return SpineCurve.bezier(cx1, cy1, cx2, cy2);
    }
    if (type == 1) return const SpineCurve.stepped();
    return const SpineCurve.linear();
  }

  /// 判定游标处「像不像骨骼区」，用于判断 header 里有没有 audio 字段。
  static bool _bonesLookValid(_Reader r, bool nonessential) {
    final save = r.pos;
    try {
      final count = r.varint();
      if (count <= 0 || count > 4000) return false;
      final name = r.string();
      if (name == null || name.isEmpty || name.length > 80) return false;
      for (final code in name.codeUnits) {
        if (code < 32 || code > 126) return false;
      }
      final values = List<double>.generate(8, (_) => r.float());
      final scaleX = values[3].abs();
      final scaleY = values[4].abs();
      return scaleX > 0.001 && scaleX < 1000 && scaleY > 0.001 && scaleY < 1000;
    } catch (_) {
      return false;
    } finally {
      r.pos = save;
    }
  }
}

/// 「链接网格」附件：可见性靠父网格，本身不带几何。
final class SpineLinkedMeshAttachment {
  const SpineLinkedMeshAttachment({required this.name, required this.path});

  final String name;
  final String path;
}

/// 大端二进制游标。
final class _Reader {
  _Reader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int pos = 0;

  void _need(int n) {
    if (pos + n > _bytes.length) {
      throw SpineFormatException(
        '读取越界：pos=$pos 需要 $n 字节，总共 ${_bytes.length} 字节',
      );
    }
  }

  int int8() {
    _need(1);
    final v = _bytes[pos];
    pos += 1;
    return v > 127 ? v - 256 : v;
  }

  bool boolean() => int8() != 0;

  double float() {
    _need(4);
    final v = _data.getFloat32(pos, Endian.big);
    pos += 4;
    return v;
  }

  /// RGBA 四字节 → 0..1 的 4 元组。
  ///
  /// 注意是 **4 字节**（RGBA），不是 3 字节 RGB：读成 3 字节会让每个插槽少读 1 字节。
  List<double> color() {
    _need(4);
    final out = [
      _bytes[pos] / 255.0,
      _bytes[pos + 1] / 255.0,
      _bytes[pos + 2] / 255.0,
      _bytes[pos + 3] / 255.0,
    ];
    pos += 4;
    return out;
  }

  /// `positive=true` 是 varint+，false 是 varint-（zigzag）。
  int varint({bool positive = true}) {
    var b = int8();
    var value = b & 0x7F;
    if (b & 0x80 != 0) {
      b = int8();
      value |= (b & 0x7F) << 7;
      if (b & 0x80 != 0) {
        b = int8();
        value |= (b & 0x7F) << 14;
        if (b & 0x80 != 0) {
          b = int8();
          value |= (b & 0x7F) << 21;
          if (b & 0x80 != 0) {
            value |= (int8() & 0x7F) << 28;
          }
        }
      }
    }
    if (!positive) {
      // zigzag 还原：(v >>> 1) ^ -(v & 1)
      value = ((value >>> 1) ^ -(value & 1));
    }
    return value;
  }

  /// `string`：varint+ 长度，0 = null，1 = 空串，否则读 `长度 - 1` 字节。
  String? string() {
    final count = varint();
    if (count == 0) return null;
    final take = count - 1;
    _need(take);
    final raw = Uint8List.sublistView(_bytes, pos, pos + take);
    pos += take;
    return utf8.decode(raw, allowMalformed: true);
  }

  Float32List floatArray(int n) {
    _need(4 * n);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _data.getFloat32(pos, Endian.big);
      pos += 4;
    }
    return out;
  }

  /// 带长度前缀的大端 16 位无符号整数数组（官方 `_readShortArray`）。
  Uint16List shortArray() {
    final n = varint();
    _need(2 * n);
    final out = Uint16List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (_bytes[pos] << 8) | _bytes[pos + 1];
      pos += 2;
    }
    return out;
  }
}
