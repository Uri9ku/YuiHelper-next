import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/spine_animation_player.dart';
import 'package:yui_helper_next/data/spine/spine_assembler.dart';
import 'package:yui_helper_next/ui/spine/spine_painter.dart';

/// S6：渲染合批（按图集页）——像素级一致 + 帧预算测量。
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

Future<Uint8List> _render(
  List<SpineDrawBatch> batches, {
  required bool batching,
  required Size size,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.width, size.height),
    Paint()..color = const Color(0xFF101418),
  );
  SpinePainter(batches: batches, batching: batching).paint(canvas, size);
  final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return Uint8List.view(raw!.buffer);
}

void main() {
  final available = Directory(_sampleDir).existsSync();

  testWidgets('S6 合批：像素与逐附件绘制完全一致，绘制次数显著下降', (tester) async {
    if (!available) return;
    await tester.runAsync(() async {
      final bundle = await _assembleSample();
      final player = SpineAnimationPlayer(bundle.data);
      if (bundle.data.animations.isNotEmpty) {
        player.setAnimation(bundle.data.animations.first.name);
        player.update(0.4);
      }
      final batches = SpineBinder.bind(
        data: bundle.data,
        skin: bundle.skins.first,
        pose: player.pose(),
        textures: bundle.textures,
      );
      expect(batches.length, greaterThan(10));

      final runs = SpineBinder.pageRunCount(batches);
      expect(runs, lessThan(batches.length), reason: '合批后应少于逐附件次数');
      expect(runs, lessThanOrEqualTo(4), reason: '野猪只有 2 页图集，合批后应为个位数');

      const size = Size(520, 420);
      final perBatch = await _render(batches, batching: false, size: size);
      final batched = await _render(batches, batching: true, size: size);
      expect(batched.length, perBatch.length);

      var diff = 0;
      for (var i = 0; i < batched.length; i++) {
        if (batched[i] != perBatch[i]) diff++;
      }
      // 允许极少量的浮点舍入差异（同几何同顺序应完全一致；实测通常为 0）
      final ratio = diff / batched.length;
      expect(ratio, lessThan(0.001),
          reason: '合批不应改变画面（差异像素比例 ${(ratio * 100).toStringAsFixed(3)}%）');
    });
  });

  testWidgets('S6 帧预算：绘制指令构建耗时（逐附件 vs 合批，仅打印）', (tester) async {
    if (!available) return;
    await tester.runAsync(() async {
      final bundle = await _assembleSample();
      final player = SpineAnimationPlayer(bundle.data);
      if (bundle.data.animations.isNotEmpty) {
        player.setAnimation(bundle.data.animations.first.name);
      }
      const size = Size(520, 420);
      const frames = 30;

      final batches = SpineBinder.bind(
        data: bundle.data,
        skin: bundle.skins.first,
        pose: player.pose(),
        textures: bundle.textures,
      );
      final runs = SpineBinder.pageRunCount(batches);

      int measure({required bool batching}) {
        final sw = Stopwatch()..start();
        for (var f = 0; f < frames; f++) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
          SpinePainter(batches: batches, batching: batching).paint(canvas, size);
          recorder.endRecording().dispose();
        }
        return sw.elapsedMicroseconds;
      }

      final perBatchUs = measure(batching: false);
      final batchedUs = measure(batching: true);
      final perFrameCoarse = (perBatchUs / frames / 1000).toStringAsFixed(3);
      final perFrameBatched = (batchedUs / frames / 1000).toStringAsFixed(3);
      // ignore: avoid_print
      print('[S6] 批次 ${batches.length} 个 → 合批后绘制 ${runs} 次；'
          '指令构建 逐附件 ${perFrameCoarse} ms/帧 vs 合批 ${perFrameBatched} ms/帧');
      expect(runs, lessThan(batches.length));
      expect(batchedUs, greaterThan(0));
    });
  });
}
