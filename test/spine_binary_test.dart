import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/atlas_variant.dart';
import 'package:yui_helper_next/data/spine/skeleton_pose.dart';
import 'package:yui_helper_next/data/spine/spine_binary.dart';

/// Spine 二进制解析器的**合成样本**测试。
///
/// 用代码手工拼出 `.skel` 字节，不依赖任何游戏资源，
/// 所以在任何机器上都能跑。真实样本的端到端校验在 `spine_render_e2e_test.dart`。
void main() {
  group('varint / string', () {
    test('单字节 varint+', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(bones: [_bone('root')]),
      );
      expect(data.bones.length, 1);
      expect(data.bones.first.name, 'root');
    });

    test('多字节 varint+（128 以上）', () {
      // 造 130 根骨，骨骼数就要用两字节 varint 表示
      final bones = [for (var i = 0; i < 130; i++) _bone('b$i', parent: i == 0 ? null : i - 1)];
      final data = SpineBinaryParser.parse(_buildSkeleton(bones: bones));
      expect(data.bones.length, 130);
      expect(data.bones.last.name, 'b129');
    });
  });

  group('头���', () {
    test('解析 version / 宽高', () {
      final data = SpineBinaryParser.parse(_buildSkeleton());
      expect(data.version, '3.6.53');
      expect(data.width, 4096);
      expect(data.height, 3488);
    });

    test('缺少 version 时抛异常', () {
      final bytes = _buildSkeleton(withVersion: false);
      expect(
        () => SpineBinaryParser.parse(bytes),
        throwsA(isA<SpineFormatException>()),
      );
    });

    test('数据被截断时抛异常', () {
      final bytes = _buildSkeleton();
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length ~/ 2);
      expect(
        () => SpineBinaryParser.parse(truncated),
        throwsA(isA<SpineFormatException>()),
      );
    });
  });

  group('骨骼层级', () {
    test('父子关系正确', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [
            _bone('root'),
            _bone('chest', parent: 0, x: 10, y: 20),
            _bone('head', parent: 1, x: 0, y: 30),
          ],
        ),
      );
      expect(data.bones[0].parentIndex, isNull);
      expect(data.bones[1].parentIndex, 0);
      expect(data.bones[2].parentIndex, 1);
    });

    test('bind pose：子骨骼世界坐标 = 父坐标 + 局部偏移', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [
            _bone('root'),
            _bone('chest', parent: 0, x: 10, y: 20),
            _bone('head', parent: 1, x: 0, y: 30),
          ],
        ),
      );
      final pose = SkeletonPose.bindPose(data);
      expect(pose.bones[1].worldX, closeTo(10, 1e-4));
      expect(pose.bones[1].worldY, closeTo(20, 1e-4));
      expect(pose.bones[2].worldX, closeTo(10, 1e-4));
      expect(pose.bones[2].worldY, closeTo(50, 1e-4));
    });

    test('bind pose：父骨骼旋转 90° 时子骨骼被带到正确位置', () {
      // root 旋转 90°，子骨骼局部 (100,0) → 世界 (0,100)
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [
            _bone('root', rotation: 90),
            _bone('child', parent: 0, x: 100, y: 0),
          ],
        ),
      );
      final pose = SkeletonPose.bindPose(data);
      expect(pose.bones[1].worldX, closeTo(0, 1e-4));
      expect(pose.bones[1].worldY, closeTo(100, 1e-4));
    });
  });

  group('插槽与皮肤', () {
    test('插槽挂在正确骨骼上并记录默认附件名', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [_bone('root'), _bone('arm', parent: 0)],
          slots: [
            _Slot('arm_slot', boneIndex: 1, attachment: 'arm_img'),
          ],
        ),
      );
      expect(data.slots.length, 1);
      expect(data.slots.first.name, 'arm_slot');
      expect(data.slots.first.boneIndex, 1);
      expect(data.slots.first.attachmentName, 'arm_img');
    });

    test('区域附件：矩形与变换字段', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [_bone('root')],
          slots: [_Slot('s', boneIndex: 0)],
          attachments: [
            _RegionAttachment(
              name: 'img',
              slotIndex: 0,
              x: 5,
              y: 6,
              width: 32,
              height: 64,
              rotation: 15,
            ),
          ],
        ),
      );
      final att = data.defaultSkin.attachment(0, 'img');
      expect(att, isA<SpineRegionAttachment>());
      final region = att as SpineRegionAttachment;
      expect(region.width, 32);
      expect(region.height, 64);
      expect(region.rotation, 15);
      expect(region.x, 5);
      expect(region.y, 6);
    });

    test('网格附件：UV、三角形、未加权顶点', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [_bone('root')],
          slots: [_Slot('s', boneIndex: 0)],
          attachments: [
            _MeshAttachment(
              name: 'mesh',
              slotIndex: 0,
              uvs: [0, 0, 1, 0, 1, 1, 0, 1],
              triangles: [0, 1, 2, 0, 2, 3],
              vertices: [0, 0, 10, 0, 10, 10, 0, 10],
            ),
          ],
        ),
      );
      final att = data.defaultSkin.attachment(0, 'mesh');
      expect(att, isA<SpineMeshAttachment>());
      final mesh = att as SpineMeshAttachment;
      expect(mesh.vertexCount, 4);
      expect(mesh.triangles.length, 6);
      expect(mesh.isWeighted, isFalse);

      // 未加权顶点相对插槽骨骼做变换（root 在原点、无旋转 → 原样）
      final pose = SkeletonPose.bindPose(data);
      final world = skinMeshVertices(mesh, pose, 0);
      expect(world[0], closeTo(0, 1e-4));
      expect(world[2], closeTo(10, 1e-4));
      expect(world[5], closeTo(10, 1e-4));
    });

    test('网格附件：加权顶点按骨骼权重混合', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [_bone('root'), _bone('far', parent: 0, x: 100, y: 0)],
          slots: [_Slot('s', boneIndex: 0)],
          attachments: [
            _MeshAttachment(
              name: 'weighted',
              slotIndex: 0,
              uvs: [0, 0, 1, 1],
              triangles: [0, 1, 0],
              weighted: [
                [_Influence(0, 0, 0, 0.5), _Influence(1, 0, 0, 0.5)],
                [_Influence(1, 0, 0, 1.0)],
              ],
            ),
          ],
        ),
      );
      final mesh = data.defaultSkin.attachment(0, 'weighted') as SpineMeshAttachment;
      expect(mesh.isWeighted, isTrue);

      final pose = SkeletonPose.bindPose(data);
      final world = skinMeshVertices(mesh, pose, 0);
      // 顶点 0：一半在 root(0,0)，一半在 far(100,0) → (50,0)
      expect(world[0], closeTo(50, 1e-4));
      expect(world[1], closeTo(0, 1e-4));
      // 顶点 1：全在 far → (100,0)
      expect(world[2], closeTo(100, 1e-4));
    });

    test('命名皮肤独立于默认皮肤', () {
      final data = SpineBinaryParser.parse(
        _buildSkeleton(
          bones: [_bone('root')],
          slots: [_Slot('s', boneIndex: 0)],
          attachments: [
            _RegionAttachment(name: 'base', slotIndex: 0, width: 10, height: 10),
          ],
          namedSkins: [
            _NamedSkin('01_sword', [
              _RegionAttachment(
                name: 'sword',
                slotIndex: 0,
                width: 99,
                height: 88,
              ),
            ]),
          ],
        ),
      );
      expect(data.skins.length, 1);
      expect(data.skins.first.name, '01_sword');
      expect(data.defaultSkin.attachment(0, 'base'), isNotNull);
      expect(data.defaultSkin.attachment(0, 'sword'), isNull);
      expect(data.skins.first.attachment(0, 'sword'), isNotNull);
      expect(data.skin(name: '01_sword').name, '01_sword');
      // 找不到时回退默认皮肤
      expect(data.skin(name: '不存在').name, 'default');
    });
  });

  group('图集变体名推断', () {
    test('相对路径取最后一段', () {
      expect(
        atlasVariantOf('../../saoal/asset/source/spine/characterAtlas/chara_2/alice_integrator/'),
        'alice_integrator',
      );
    });

    test('Windows 反斜杠路径', () {
      expect(atlasVariantOf(r'..\..\01_set\kirito_cathedral\'), 'kirito_cathedral');
    });

    test('绝对路径不可信，返回 null', () {
      expect(atlasVariantOf('C:/Users/someone/Desktop/'), isNull);
      expect(atlasVariantOf('D:/saoal/asset/source/spine/characterAtlas/chara_1/x/'), isNull);
    });

    test('最后一段是泛用目录名时返回 null', () {
      expect(atlasVariantOf('../../sample/chara_2/images/'), isNull);
    });

    test('null / 空串', () {
      expect(atlasVariantOf(null), isNull);
      expect(atlasVariantOf('   '), isNull);
    });

    test('变体名必须是纯 ASCII', () {
      expect(isAtlasVariantName('kirito_cathedral'), isTrue);
      expect(isAtlasVariantName('素体シート'), isFalse);
      expect(isAtlasVariantName('has space'), isFalse);
    });
  });
}

// ── 合成 .skel 构造 ─────────────────────────────────────────────────────

const _version = '3.6.53';

final class _Bone {
  _Bone(
    this.name, {
    this.parent,
    this.x = 0,
    this.y = 0,
    this.rotation = 0,
  });
  final String name;
  final int? parent;
  final double x;
  final double y;
  final double rotation;
}

_Bone _bone(String name, {int? parent, double x = 0, double y = 0, double rotation = 0}) =>
    _Bone(name, parent: parent, x: x, y: y, rotation: rotation);

final class _Slot {
  _Slot(this.name, {required this.boneIndex, this.attachment});
  final String name;
  final int boneIndex;
  final String? attachment;
}

final class _RegionAttachment {
  _RegionAttachment({
    required this.name,
    required this.slotIndex,
    this.x = 0,
    this.y = 0,
    this.rotation = 0,
    this.width = 10,
    this.height = 10,
  });
  final String name;
  final int slotIndex;
  final double x;
  final double y;
  final double rotation;
  final double width;
  final double height;

  /// 区域附件固定按 1 写；需要缩放时改这里（测试目前都用 1）。
  static const double scaleX = 1;
  static const double scaleY = 1;
}

final class _Influence {
  _Influence(this.boneIndex, this.x, this.y, this.weight);
  final int boneIndex;
  final double x;
  final double y;
  final double weight;
}

final class _MeshAttachment {
  _MeshAttachment({
    required this.name,
    required this.slotIndex,
    required this.uvs,
    required this.triangles,
    this.vertices,
    this.weighted,
  });
  final String name;
  final int slotIndex;
  final List<double> uvs;
  final List<int> triangles;
  final List<double>? vertices;
  final List<List<_Influence>>? weighted;
}

final class _NamedSkin {
  _NamedSkin(this.name, this.attachments);
  final String name;
  final List<Object> attachments;
}

/// 按官方 3.6 布局拼出一份最小可解析的 `.skel`。
Uint8List _buildSkeleton({
  List<_Bone>? bones,
  List<_Slot>? slots,
  List<Object>? attachments,
  List<_NamedSkin>? namedSkins,
  bool withVersion = true,
}) {
  final w = _Writer();
  w.string('testhash');
  w.string(withVersion ? _version : '');
  w.float(4096);
  w.float(3488);
  w.boolean(false); // nonessential=false → 不写 fps/images/audio

  final boneList = bones ?? [_bone('root')];
  w.varint(boneList.length);
  for (var i = 0; i < boneList.length; i++) {
    final b = boneList[i];
    w.string(b.name);
    if (i > 0) w.varint(b.parent ?? 0);
    w.float(b.rotation); // rotation
    w.float(b.x); // x
    w.float(b.y); // y
    w.float(1); // scaleX
    w.float(1); // scaleY
    w.float(0); // shearX
    w.float(0); // shearY
    w.float(0); // length
    w.varint(0); // transformMode
  }

  final slotList = slots ?? const <_Slot>[];
  w.varint(slotList.length);
  for (final s in slotList) {
    w.string(s.name);
    w.varint(s.boneIndex);
    w.color(255, 255, 255, 255);
    w.color(255, 255, 255, 255);
    w.string(s.attachment);
    w.varint(0); // blendMode
  }

  w.varint(0); // IK
  w.varint(0); // transform
  w.varint(0); // path

  // 默认皮肤
  _writeSkin(w, attachments ?? const []);

  // 命名皮肤
  final skins = namedSkins ?? const <_NamedSkin>[];
  w.varint(skins.length);
  for (final s in skins) {
    w.string(s.name);
    _writeSkin(w, s.attachments);
  }

  w.varint(0); // events
  w.varint(0); // animations
  return w.toBytes();
}

void _writeSkin(_Writer w, List<Object> attachments) {
  if (attachments.isEmpty) {
    w.varint(0);
    return;
  }
  // 按 slotIndex 分组
  final bySlot = <int, List<Object>>{};
  for (final a in attachments) {
    final slotIndex = switch (a) {
      _RegionAttachment r => r.slotIndex,
      _MeshAttachment m => m.slotIndex,
      _ => 0,
    };
    (bySlot[slotIndex] ??= []).add(a);
  }
  w.varint(bySlot.length);
  final keys = bySlot.keys.toList()..sort();
  for (final slotIndex in keys) {
    final list = bySlot[slotIndex]!;
    w.varint(slotIndex);
    w.varint(list.length);
    for (final a in list) {
      // ⚠ 每个附件两个名字：skin 层 placeholder + 附件自身 name
      final name = switch (a) {
        _RegionAttachment r => r.name,
        _MeshAttachment m => m.name,
        _ => 'x',
      };
      w.string(name); // placeholder
      w.string(name); // attachment name
      switch (a) {
        case _RegionAttachment r:
          w.byte(0); // REGION
          w.string(r.name); // path
          w.float(r.rotation);
          w.float(r.x);
          w.float(r.y);
          w.float(_RegionAttachment.scaleX);
          w.float(_RegionAttachment.scaleY);
          w.float(r.width);
          w.float(r.height);
          w.color(255, 255, 255, 255);
        case _MeshAttachment m:
          w.byte(2); // MESH
          w.string(m.name); // path
          w.color(255, 255, 255, 255);
          final vertexCount = m.uvs.length ~/ 2;
          w.varint(vertexCount);
          for (final uv in m.uvs) {
            w.float(uv);
          }
          w.varint(m.triangles.length);
          for (final t in m.triangles) {
            w.short(t);
          }
          if (m.weighted != null) {
            w.boolean(true);
            for (final infs in m.weighted!) {
              w.varint(infs.length);
              for (final inf in infs) {
                w.varint(inf.boneIndex);
                w.float(inf.x);
                w.float(inf.y);
                w.float(inf.weight);
              }
            }
          } else {
            w.boolean(false);
            for (final v in m.vertices!) {
              w.float(v);
            }
          }
          w.varint(0); // hull
          w.varint(0); // edges
          w.float(10); // width
          w.float(10); // height
        default:
          throw StateError('unsupported');
      }
    }
  }
}

/// 大端二进制写入器（与解析器对称）。
final class _Writer {
  final BytesBuilder _b = BytesBuilder();

  Uint8List toBytes() => _b.toBytes();

  void byte(int v) => _b.addByte(v & 0xFF);

  void short(int v) {
    _b.addByte((v >> 8) & 0xFF);
    _b.addByte(v & 0xFF);
  }

  void boolean(bool v) => byte(v ? 1 : 0);

  void float(double v) {
    final d = ByteData(4)..setFloat32(0, v, Endian.big);
    _b.add(d.buffer.asUint8List());
  }

  void color(int r, int g, int b, int a) {
    byte(r);
    byte(g);
    byte(b);
    byte(a);
  }

  void varint(int value) {
    var v = value;
    while (true) {
      final low = v & 0x7F;
      v >>= 7;
      if (v != 0) {
        byte(low | 0x80);
      } else {
        byte(low);
        return;
      }
    }
  }

  void string(String? s) {
    if (s == null) {
      varint(0);
      return;
    }
    final bytes = Uint8List.fromList(s.codeUnits);
    varint(bytes.length + 1);
    _b.add(bytes);
  }
}

