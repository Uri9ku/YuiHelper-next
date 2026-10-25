import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/spine_assembler.dart';
import 'package:yui_helper_next/ui/spine/spine_painter.dart';
import 'package:yui_helper_next/ui/spine/spine_preview_view.dart';

/// 离线端到端：用解包目录里现成的「Viewer-ready」样例（skel + atlas + 页 PNG）
/// 走完整装配 → 渲染 → 出 PNG，验证「取数 → 解析 → 贴图」闭环。
///
/// 没有解包目录的机器自动跳过（CI 友好）。
const String _sampleDir =
    r'C:\Users\Administrator\Desktop\解包\解包结果\资产库\Spine\_Stage0_ViewerReady\FrenzyBoar101';

Future<_Sample> _loadSample() async {
  final dir = Directory(_sampleDir);
  final atlasFile = File('${dir.path}${Platform.pathSeparator}FrenzyBoar101.atlas');
  final skelFile = File('${dir.path}${Platform.pathSeparator}FrenzyBoar101.skel');
  final atlasText = await atlasFile.readAsString();
  // 从图集文本里按声明顺序取页名
  final pageNames = <String>[];
  for (final line in atlasText.split('\n')) {
    final s = line.trim();
    if (s.toLowerCase().endsWith('.png')) pageNames.add(s);
  }
  final files = <String, String>{
    'local/FrenzyBoar101.skel': skelFile.path,
    'local/FrenzyBoar101.atlas': atlasFile.path,
  };
  final pagePaths = <String>[];
  for (final name in pageNames) {
    final p = '${dir.path}${Platform.pathSeparator}$name';
    if (File(p).existsSync()) {
      files['local/$name'] = p;
      pagePaths.add('local/$name');
    }
  }
  return _Sample(files: files, pagePaths: pagePaths);
}

final class _Sample {
  _Sample({required this.files, required this.pagePaths});
  final Map<String, String> files;
  final List<String> pagePaths;
}

void main() {
  final available = Directory(_sampleDir).existsSync();

  test('离线装配 FrenzyBoar101：骨架/图集/页贴图齐全，批次非空', () async {
    if (!available) {
      // 缺资源的环境跳过（与旧版 e2e 同一策略）
      return;
    }
    final sample = await _loadSample();
    expect(sample.pagePaths.length, greaterThanOrEqualTo(1));
    final assembler = SpineAssembler(LocalFileSpineSource(sample.files));
    final bundle = await assembler.assemble(
      skeletonPath: 'local/FrenzyBoar101.skel',
      atlasPath: 'local/FrenzyBoar101.atlas',
      pagePaths: sample.pagePaths,
    );
    expect(bundle.data.bones.length, greaterThan(20));
    expect(bundle.atlas.pages.length, greaterThanOrEqualTo(1));
    expect(bundle.textures, isNotEmpty);
    expect(bundle.skins, isNotEmpty);
    expect(bundle.batches, isNotEmpty);
    expect(bundle.missingPages, isEmpty);
    // 每个批次顶点/三角形都得有限且索引合法
    for (final b in bundle.batches) {
      expect(b.vertices.length.isEven, isTrue);
      expect(b.triangles.length % 3, 0);
      final maxIndex = b.vertices.length ~/ 2 - 1;
      for (final i in b.triangles) {
        expect(i, lessThanOrEqualTo(maxIndex));
      }
    }
  });

  testWidgets('离线渲染出图：画面非空白，并落盘 build/spine_offline_render.png', (tester) async {
    if (!available) return;
    // 图片解码 / toImage / toByteData 必须跑在 real async 里（否则假时钟卡住）
    await tester.runAsync(() async {
      final sample = await _loadSample();
      final assembler = SpineAssembler(LocalFileSpineSource(sample.files));
      final bundle = await assembler.assemble(
        skeletonPath: 'local/FrenzyBoar101.skel',
        atlasPath: 'local/FrenzyBoar101.atlas',
        pagePaths: sample.pagePaths,
      );

    const size = Size(520, 420);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, size.width, size.height),
    );
    // 深色底，便于看透明边缘
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = const Color(0xFF101418));
    SpinePainter(batches: bundle.batches).paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(raw, isNotNull);

    final rgba = raw!.buffer.asUint8List();
    var opaque = 0;
    var nonBackground = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      if (rgba[i + 3] != 0) opaque++;
      // 背景是 0x101418；统计"明显不是背景"的像素
      if ((rgba[i] - 0x10).abs() + (rgba[i + 1] - 0x14).abs() + (rgba[i + 2] - 0x18).abs() > 30) {
        nonBackground++;
      }
    }
    final total = rgba.length ~/ 4;
    final coverage = nonBackground / total;
    expect(opaque, total, reason: '整幅画布应被背景覆盖（不透明）');
    expect(coverage, greaterThan(0.02), reason: '角色像素覆盖率应 >2%（实际 ${(coverage * 100).toStringAsFixed(1)}%）');

    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(png, isNotNull);
    final outDir = Directory('build');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final outFile = File('build/spine_offline_render.png');
    outFile.writeAsBytesSync(Uint8List.view(png!.buffer));
    expect(outFile.existsSync(), isTrue);
    // 顺带出线框图，便于人眼确认几何
    final wireRecorder = ui.PictureRecorder();
    final wireCanvas = Canvas(wireRecorder, Rect.fromLTWH(0, 0, size.width, size.height));
    wireCanvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = const Color(0xFF101418));
    SpinePainter(batches: bundle.batches, wireframe: true).paint(wireCanvas, size);
    final wireImage = await wireRecorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
      final wirePng = await wireImage.toByteData(format: ui.ImageByteFormat.png);
      File('build/spine_offline_wireframe.png').writeAsBytesSync(Uint8List.view(wirePng!.buffer));
    });
  });

  testWidgets('SpinePreviewView 三态：缺数据时给出明确文案（不画假模型）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpinePreviewView(load: () async => throw const SpineAssembleException(
              AssembleFailure.noPages,
              '图集声明 2 页，但一页像素都没拿到（缺：a.png, b.png）',
            )),
      ),
    ));
    await tester.pump(); // 触发加载
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('装配失败'), findsOneWidget);
    expect(find.textContaining('一页像素都没拿到'), findsOneWidget);
  });
}
