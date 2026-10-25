import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/spine_animation_player.dart';
import 'package:yui_helper_next/data/spine/spine_assembler.dart';
import 'package:yui_helper_next/ui/spine/spine_painter.dart';

/// S5 离线验证：真实骨架的时间轴采样 + 逐帧渲染（不依赖真机）。
const String _sampleDir =
    r'C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine\_Stage0_ViewerReady\FrenzyBoar101';

Future<SpineRenderBundle> _assembleSample() async {
  final dir = Directory(_sampleDir);
  final atlasFile = File('${dir.path}${Platform.pathSeparator}FrenzyBoar101.atlas');
  final skelFile = File('${dir.path}${Platform.pathSeparator}FrenzyBoar101.skel');
  final atlasText = await atlasFile.readAsString();
  final files = <String, String>{
    'local/FrenzyBoar101.skel': skelFile.path,
    'local/FrenzyBoar101.atlas': atlasFile.path,
  };
  final pagePaths = <String>[];
  for (final line in atlasText.split('\n')) {
    final s = line.trim();
    if (s.toLowerCase().endsWith('.png')) {
      final p = '${dir.path}${Platform.pathSeparator}$s';
      if (File(p).existsSync()) {
        files['local/$s'] = p;
        pagePaths.add('local/$s');
      }
    }
  }
  return SpineAssembler(LocalFileSpineSource(files)).assemble(
    skeletonPath: 'local/FrenzyBoar101.skel',
    atlasPath: 'local/FrenzyBoar101.atlas',
    pagePaths: pagePaths,
  );
}

void main() {
  final available = Directory(_sampleDir).existsSync();

  test('S5 解析：动画时间轴被读入（名字/时长/骨骼时间轴）', () async {
    if (!available) return;
    final bundle = await _assembleSample();
    expect(bundle.data.animations, isNotEmpty);
    expect(bundle.data.animations.length, bundle.data.animationCount);
    final idle = bundle.data.animations.where((a) => a.name.startsWith('idle_battle')).toList();
    expect(idle, isNotEmpty, reason: '野猪应有 idle_battle_* 动画');
    final anim = idle.first;
    expect(anim.duration, greaterThan(0.2));
    expect(anim.boneTimelines, isNotEmpty);
    // 曲线与帧数据的自洽：times 递增、values 长度 = frames*stride
    for (final tl in anim.boneTimelines) {
      expect(tl.values.length, tl.times.length * tl.stride);
      for (var i = 1; i < tl.times.length; i++) {
        expect(tl.times[i], greaterThanOrEqualTo(tl.times[i - 1]));
      }
      expect(tl.curves.length, tl.times.length - 1);
    }
  });

  test('S5 采样：不同时间点姿态不同（骨骼确实在动）', () async {
    if (!available) return;
    final bundle = await _assembleSample();
    final player = SpineAnimationPlayer(bundle.data);
    final name = bundle.data.animations
        .firstWhere((a) => a.name.startsWith('idle_battle'), orElse: () => bundle.data.animations.first)
        .name;
    player.setAnimation(name);
    expect(player.duration, greaterThan(0));

    final pose0 = player.poseAt(0);
    final poseMid = player.poseAt(player.duration * 0.5);
    expect(pose0.bones.length, poseMid.bones.length);
    var maxDelta = 0.0;
    for (var i = 0; i < pose0.bones.length; i++) {
      final dx = (pose0.bones[i].worldX - poseMid.bones[i].worldX).abs();
      final dy = (pose0.bones[i].worldY - poseMid.bones[i].worldY).abs();
      if (dx + dy > maxDelta) maxDelta = dx + dy;
    }
    expect(maxDelta, greaterThan(1.0), reason: '半周期后骨骼应有明显位移（实际 $maxDelta）');
  });

  testWidgets('S5 渲染：3 帧姿态渲染成 PNG（build/spine_anim_0..2.png）', (tester) async {
    if (!available) return;
    await tester.runAsync(() async {
      final bundle = await _assembleSample();
      final player = SpineAnimationPlayer(bundle.data);
      final name = bundle.data.animations
          .firstWhere((a) => a.name.startsWith('idle_battle'), orElse: () => bundle.data.animations.first)
          .name;
      player.setAnimation(name);

      const size = Size(520, 420);
      final dir = Directory('build');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final frames = <Uint8List>[];
      for (var f = 0; f < 3; f++) {
        final pose = player.poseAt(player.duration * (f / 3));
        final batches = SpineBinder.bind(
          data: bundle.data,
          skin: bundle.skins.first,
          pose: pose,
          textures: bundle.textures,
        );
        expect(batches, isNotEmpty);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = const Color(0xFF101418),
        );
        SpinePainter(batches: batches).paint(canvas, size);
        final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(png, isNotNull);
        final bytes = Uint8List.view(png!.buffer);
        File('build/spine_anim_$f.png').writeAsBytesSync(bytes);
        frames.add(bytes);
      }
      // 三帧不应完全相同（说明动画在推进）
      expect(frames[0], isNot(equals(frames[1])));
      expect(frames[1], isNot(equals(frames[2])));
    });
  });
}
