// ignore_for_file: avoid_print
// S3 探针：离线解码 mod 的解码缓存（saoub_all），验证 tex/ctex → RGBA 链路。
//
// 用法：
//   dart run tools/s3_texture_probe.dart "<缓存目录>"                    # 列统计 + 抽样解码
//   dart run tools/s3_texture_probe.dart "<缓存目录>" --path files/spine/characterAtlas/chara_2/edith_darkside2.pkmenc
//   dart run tools/s3_texture_probe.dart "<缓存目录>" --filter spine --limit 5

import 'dart:io';
import 'dart:typed_data';

import 'package:yui_helper_next/data/assets/etc2.dart';
import 'package:yui_helper_next/data/spine/spine_texture_cache.dart';

Future<int> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('用法: dart run tools/s3_texture_probe.dart <缓存目录> [--path <逻辑路径>] [--filter <子串>] [--limit N]');
    return 2;
  }
  String? opt(String name) {
    final i = args.indexOf('--$name');
    if (i < 0 || i + 1 >= args.length) return null;
    return args[i + 1];
  }

  final dir = positional.first;
  if (!Directory(dir).existsSync()) {
    stderr.writeln('[!] 缓存目录不存在: $dir');
    return 2;
  }
  final limit = int.tryParse(opt('limit') ?? '') ?? 3;
  final filter = opt('filter');
  final wantPath = opt('path');

  if (args.contains('--alpha-first')) {
    etc2AlphaFirst = true;
  }
  final cache = SpineTextureCache(LocalDirCachedSource(dir));
  final sw = Stopwatch()..start();
  await cache.refresh();
  print('[+] 缓存条目 ${cache.entryCount} 个（索引耗时 ${sw.elapsedMilliseconds} ms）');

  final spineEntries = cache.entries.where((e) => e.toLowerCase().contains('spine')).toList();
  print('[+] 其中 spine 相关条目 ${spineEntries.length} 个；示例：');
  for (final e in spineEntries.take(3)) {
    print('    $e');
  }

  if (wantPath != null) {
    final entry = cache.findEntry(wantPath);
    print('[*] 查找 $wantPath -> ${entry ?? '未命中'}');
    if (entry == null) return 1;
    final sw2 = Stopwatch()..start();
    final tex = await cache.decodeEntry(entry, logicalPath: wantPath);
    if (tex == null) {
      print('[!] 解码失败（格式不支持或数据异常）');
      return 1;
    }
    _report(tex, sw2.elapsedMilliseconds);
    return 0;
  }

  final targets = spineEntries
      .where((e) => e.endsWith('.raw') == false && e.endsWith('.json') == false)
      .where((e) => filter == null || e.toLowerCase().contains(filter.toLowerCase()))
      .take(limit)
      .toList();
  var ok = 0;
  for (final e in targets) {
    final sw2 = Stopwatch()..start();
    final tex = await cache.decodeEntry(e);
    if (tex == null) {
      print('[!] $e -> 解码失败');
      continue;
    }
    ok++;
    _report(tex, sw2.elapsedMilliseconds, name: e);
  }
  print('[=] 解码成功 $ok/${targets.length}');
  return ok == targets.length ? 0 : 1;
}

void _report(SpineCachedTexture tex, int ms, {String? name}) {
  final stats = _avgRgb(tex.rgba);
  print('[+] ${name ?? tex.logicalPath}');
  print('    ${tex.width}x${tex.height} kind=${tex.kind} fmt=${tex.fmt} '
      'bytes=${tex.byteSize} alpha=${(tex.alphaCoverage * 100).toStringAsFixed(1)}% '
      'avgRGB=${stats[0].toStringAsFixed(0)},${stats[1].toStringAsFixed(0)},${stats[2].toStringAsFixed(0)} '
      '(${ms} ms)');
}

List<double> _avgRgb(Uint8List rgba) {
  var r = 0.0, g = 0.0, b = 0.0;
  var n = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] == 0) continue;
    r += rgba[i];
    g += rgba[i + 1];
    b += rgba[i + 2];
    n++;
  }
  if (n == 0) return [0, 0, 0];
  return [r / n, g / n, b / n];
}
