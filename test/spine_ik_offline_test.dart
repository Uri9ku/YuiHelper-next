import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/skeleton_pose.dart';
import 'package:yui_helper_next/data/spine/spine_animation_player.dart';
import 'package:yui_helper_next/data/spine/spine_assembler.dart';
import 'package:yui_helper_next/data/spine/spine_binary.dart';
import 'package:yui_helper_next/ui/spine/spine_painter.dart';

/// S8 离线验证：IK 求解让骨链末端更接近目标骨骼。
const String _bundleDir =
    r'C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine\Bundles\Characters\Administrator\Cathedral';

Future<SpineRenderBundle> _assemble() async {
  final dir = Directory(_bundleDir);
  final files = <String, String>{};
  String? skelPath;
  String? atlasPath;
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    final lower = name.toLowerCase();
    if (lower.endsWith('.skel') && skelPath == null) {
      skelPath = 'local/$name';
      files[skelPath] = f.path;
    } else if (lower.endsWith('.atlas') && atlasPath == null) {
      atlasPath = 'local/$name';
      files[atlasPath] = f.path;
    }
  }
  if (skelPath == null || atlasPath == null) {
    throw StateError('样例目录缺少 skel/atlas：$_bundleDir');
  }
  final atlasText = File(files[atlasPath]!).readAsStringSync();
  final pagePaths = <String>[];
  for (final line in atlasText.split('\n')) {
    final s = line.trim();
    if (!s.toLowerCase().endsWith('.png')) continue;
    final candidates = dir.listSync().whereType<File>().where((f) {
      return f.uri.pathSegments.last.toLowerCase() == s.toLowerCase();
    }).toList();
    if (candidates.isEmpty) continue;
    final key = 'local/${candidates.first.uri.pathSegments.last}';
    files[key] = candidates.first.path;
    pagePaths.add(key);
  }
  return SpineAssembler(LocalFileSpineSource(files)).assemble(
    skeletonPath: skelPath,
    atlasPath: atlasPath,
    pagePaths: pagePaths,
  );
}

/// 约束末端（1 骨 = 骨骼原点；2 骨 = 子骨原点 + 子骨长度方向）。
(double, double) _endEffector(SpineSkeletonData data, SkeletonPose pose, List<int> bones) {
  if (bones.length == 1) {
    final b = pose.bones[bones[0]];
    final bone = data.bones[bones[0]];
    final angle = math.atan2(b.c, b.a);
    return (b.worldX + math.cos(angle) * bone.length, b.worldY + math.sin(angle) * bone.length);
  }
  final child = pose.bones[bones[1]];
  final childBone = data.bones[bones[1]];
  final angle = math.atan2(child.c, child.a);
  return (
    child.worldX + math.cos(angle) * childBone.length,
    child.worldY + math.sin(angle) * childBone.length,
  );
}

double _dist((double, double) a, (double, double) b) =>
    math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

void main() {
  final available = Directory(_bundleDir).existsSync();

  test('S8 IK：求解后骨链末端更接近目标（逐约束验证）', () async {
    if (!available) return;
    final bundle = await _assemble();
    final data = bundle.data;
    expect(data.ikConstraints, isNotEmpty);

    final anim = data.animations.firstWhere((a) => a.boneTimelines.isNotEmpty);
    final player = SpineAnimationPlayer(data);
    player.setAnimation(anim.name);
    final time = anim.duration * 0.5;

    final fkPose = player.poseAt(time, solveIk: false);
    final ikPose = player.poseAt(time);

    var improved = 0;
    var total = 0;
    for (final c in data.ikConstraints) {
      final target = pose2d(fkPose, c.target);
      final before = _dist(_endEffector(data, fkPose, c.bones), target);
      final after = _dist(_endEffector(data, ikPose, c.bones), pose2d(ikPose, c.target));
      total++;
      // ignore: avoid_print
      print('[IK] ${c.name} bones=${c.bones.length} before=${before.toStringAsFixed(1)} after=${after.toStringAsFixed(1)}');
      if (after <= before + math.max(1.0, before * 0.005)) improved++;
      expect(after.isFinite, isTrue);
    }
    // 允许 1 单位 / 0.5% 的数值容差（角色高 ~2000 单位；目标不可达时 Spine 也只是近似）
    expect(improved, total,
        reason: '所有 IK 约束都不应把末端明显拉远（$improved/$total 达标）');
    // 至少有一处明显收敛，证明真的在解而不是空转
    var bestBefore = 0.0;
    var bestAfter = 0.0;
    for (final c in data.ikConstraints) {
      final before =
          _dist(_endEffector(data, fkPose, c.bones), pose2d(fkPose, c.target));
      final after = _dist(_endEffector(data, ikPose, c.bones), pose2d(ikPose, c.target));
      if (before - after > bestBefore - bestAfter) {
        bestBefore = before;
        bestAfter = after;
      }
    }
    expect(bestBefore - bestAfter, greaterThan(0.5),
        reason: '至少一个约束末端应明显靠近目标（${bestBefore.toStringAsFixed(1)} → ${bestAfter.toStringAsFixed(1)}）');
  });

  testWidgets('S8 渲染：FK vs IK 画面不同（出 PNG 对照）', (tester) async {
    if (!available) return;
    await tester.runAsync(() async {
      final bundle = await _assemble();
      final anim = bundle.data.animations.firstWhere((a) => a.boneTimelines.isNotEmpty);
      final player = SpineAnimationPlayer(bundle.data);
      player.setAnimation(anim.name);
      final time = anim.duration * 0.5;
      final skin = bundle.skins.first;

      List<SpineDrawBatch> bind(SkeletonPose pose) => SpineBinder.bind(
            data: bundle.data,
            skin: skin,
            pose: pose,
            textures: bundle.textures,
            skinIndex: bundle.data.indexOfSkin(skin),
            deformLookup: player.deformAt(time),
          );

      final fk = bind(player.poseAt(time, solveIk: false));
      final ik = bind(player.poseAt(time));
      expect(fk.length, ik.length);

      var maxDiff = 0.0;
      for (var i = 0; i < fk.length; i++) {
        final a = fk[i].vertices;
        final b = ik[i].vertices;
        for (var k = 0; k < a.length; k++) {
          final d = (a[k] - b[k]).abs();
          if (d > maxDiff) maxDiff = d;
        }
      }
      expect(maxDiff, greaterThan(0.1), reason: 'IK 应改变顶点（实际最大差 $maxDiff）');

      const size = Size(420, 520);
      Future<void> render(List<SpineDrawBatch> batches, String file) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = const Color(0xFF101418),
        );
        SpinePainter(batches: batches).paint(canvas, size);
        final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        File('build/$file').writeAsBytesSync(Uint8List.view(png!.buffer));
      }

      await render(fk, 'spine_ik_off.png');
      await render(ik, 'spine_ik_on.png');
    });
  });
}

(double, double) pose2d(SkeletonPose pose, int boneIndex) {
  final b = pose.bones[boneIndex];
  return (b.worldX, b.worldY);
}
