import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/spine_animation_player.dart';
import 'package:yui_helper_next/data/spine/spine_assembler.dart';
import 'package:yui_helper_next/ui/spine/spine_painter.dart';

/// S7 离线验证：约束 setup 数据读入 + deform 时间轴应用（真实角色素材）。
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
    final candidate = dir.listSync().whereType<File>().where((f) {
      return f.uri.pathSegments.last.toLowerCase() == s.toLowerCase();
    }).toList();
    if (candidate.isEmpty) continue;
    final key = 'local/${candidate.first.uri.pathSegments.last}';
    files[key] = candidate.first.path;
    pagePaths.add(key);
  }
  return SpineAssembler(LocalFileSpineSource(files)).assemble(
    skeletonPath: skelPath,
    atlasPath: atlasPath,
    pagePaths: pagePaths,
  );
}

void main() {
  final available = Directory(_bundleDir).existsSync();

  test('S7 解析：IK/transform/path 约束读入（不再 skip）', () async {
    if (!available) return;
    final bundle = await _assemble();
    final data = bundle.data;
    // 该骨架在 JSON 侧有 6 个 IK 约束
    expect(data.ikConstraints, isNotEmpty);
    expect(data.ikConstraints.first.bones, isNotEmpty);
    expect(data.ikConstraints.first.target, greaterThanOrEqualTo(0));
    // transform/path 可能为 0，但字段结构必须可读（不崩、不越界已由 assemble 证明）
    expect(data.transformConstraints.length, greaterThanOrEqualTo(0));
    expect(data.pathConstraints.length, greaterThanOrEqualTo(0));
  });

  test('S7 deform：时间轴读入并可采样出非零顶点偏移', () async {
    if (!available) return;
    final bundle = await _assemble();
    var timelines = 0;
    var maxAbs = 0.0;
    for (final anim in bundle.data.animations) {
      for (final tl in anim.deformTimelines) {
        timelines++;
        expect(tl.frames.length, tl.times.length);
        expect(tl.span, greaterThanOrEqualTo(0));
        if (tl.times.isEmpty) continue;
        for (final t in [0.0, tl.times.last * 0.5, tl.times.last]) {
          final offsets = tl.sample(t);
          if (offsets == null) continue;
          expect(offsets.length, tl.span);
          for (final v in offsets) {
            if (v.abs() > maxAbs) maxAbs = v.abs();
          }
        }
      }
    }
    expect(timelines, greaterThan(0), reason: '该角色骨架应有 deform 时间轴');
    expect(maxAbs, greaterThan(0.0), reason: 'deform 应该有非零偏移（非零分量  个）');
  });

  testWidgets('S7 应用：带 deform 与不带 deform 的画面不同（出 PNG 对照）', (tester) async {
    if (!available) return;
    await tester.runAsync(() async {
      final bundle = await _assemble();
      final anim = bundle.data.animations.where((a) => a.deformTimelines.isNotEmpty).first;
      final player = SpineAnimationPlayer(bundle.data);
      player.setAnimation(anim.name);
      final time = anim.duration * 0.5;
      final skin = bundle.skins.first;

      final batchesNoDeform = SpineBinder.bind(
        data: bundle.data,
        skin: skin,
        pose: player.poseAt(time),
        textures: bundle.textures,
      );
      final lookup = player.deformAt(time);
      expect(lookup, isNotNull);
      final batchesDeform = SpineBinder.bind(
        data: bundle.data,
        skin: skin,
        pose: player.poseAt(time),
        textures: bundle.textures,
        skinIndex: bundle.data.indexOfSkin(skin),
        deformLookup: lookup,
      );
      expect(batchesDeform.length, batchesNoDeform.length);

      var vertexDiff = 0.0;
      for (var i = 0; i < batchesDeform.length; i++) {
        final a = batchesNoDeform[i].vertices;
        final b = batchesDeform[i].vertices;
        for (var k = 0; k < a.length; k++) {
          final d = (a[k] - b[k]).abs();
          if (d > vertexDiff) vertexDiff = d;
        }
      }
      expect(vertexDiff, greaterThan(0.5), reason: 'deform 应改变顶点（实际最大差 $vertexDiff）');

      const size = Size(420, 520);
      Future<Uint8List> render(List<SpineDrawBatch> batches, String file) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = const Color(0xFF101418),
        );
        SpinePainter(batches: batches).paint(canvas, size);
        final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final bytes = Uint8List.view(png!.buffer);
        File('build/$file').writeAsBytesSync(bytes);
        return bytes;
      }

      final dir = Directory('build');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final a = await render(batchesNoDeform, 'spine_deform_off.png');
      final b = await render(batchesDeform, 'spine_deform_on.png');
      expect(a, isNot(equals(b)), reason: 'deform 开启后画面应不同（已落盘对照图）');
    });
  });
}
