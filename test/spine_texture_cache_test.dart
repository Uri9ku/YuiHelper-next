import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/spine/spine_texture_cache.dart';

/// 内存版缓存来源：按文件名返回预设内容，便于单测。
final class FakeCacheSource implements CachedFileSource {
  FakeCacheSource(this.files);

  final Map<String, List<int>> files;

  @override
  Future<List<String>> listFiles() async => files.keys.toList();

  @override
  Future<Uint8List?> readBytes(String name) async {
    final v = files[name];
    return v == null ? null : Uint8List.fromList(v);
  }

  @override
  Future<String?> readText(String name) async {
    final v = files[name];
    return v == null ? null : utf8.decode(v);
  }
}

Map<String, List<int>> _rgbaEntry({
  String base = 'r0001_2x2_tex_contents_localization_tc_files_spine_characterAtlas_chara_2_test.pkmenc',
  required int w,
  required int h,
  required List<int> raw,
  int bpp = 4,
  String rel = 'contents/localization/tc/files/spine/characterAtlas/chara_2/test.pkmenc',
}) {
  return {
    '$base.json': utf8.encode(jsonEncode({
      'seq': 1,
      'kind': 'tex',
      'w': w,
      'h': h,
      'fmt': 0,
      'bytes': raw.length,
      'rel': rel,
      'bpp': bpp,
      'compressed': false,
    })),
    '$base.raw': raw,
  };
}

void main() {
  group('SpineTextureCache 索引与匹配', () {
    test('refresh 只索引 raw/json 成对条目，并按逻辑路径后缀匹配', () async {
      final files = <String, List<int>>{
        ..._rgbaEntry(w: 2, h: 2, raw: List<int>.filled(16, 200)),
        // 干扰项：另一个目录的同名文件，不应被误配
        ..._rgbaEntry(
          base: 'r0002_2x2_tex_contents_localization_tc_files_spine_faceAtlas_chara_2_test.pkmenc',
          w: 2,
          h: 2,
          raw: List<int>.filled(16, 10),
          rel: 'contents/localization/tc/files/spine/faceAtlas/chara_2/test.pkmenc',
        ),
        'README.txt': utf8.encode('x'),
      };
      final cache = SpineTextureCache(FakeCacheSource(files));
      await cache.refresh();

      expect(cache.entryCount, 2);
      expect(
        cache.findEntry('files/spine/characterAtlas/chara_2/test.pkmenc'),
        contains('characterAtlas'),
      );
      expect(
        cache.findEntry('files/spine/faceAtlas/chara_2/test.pkmenc'),
        contains('faceAtlas'),
      );
      expect(cache.findEntry('files/spine/characterAtlas/chara_2/missing.pkmenc'), isNull);
    });
  });

  group('SpineTextureCache 解码', () {
    test('tex + bpp=4 直接取 RGBA，alpha 覆盖率正确', () async {
      final rgba = <int>[
        255, 0, 0, 255, // 红
        0, 255, 0, 255, // 绿
        0, 0, 255, 0, // 全透明蓝
        9, 9, 9, 128, // 半透明
      ];
      final cache = SpineTextureCache(FakeCacheSource(_rgbaEntry(w: 2, h: 2, raw: rgba)));
      await cache.refresh();
      final tex = await cache.load('files/spine/characterAtlas/chara_2/test.pkmenc');
      expect(tex, isNotNull);
      expect(tex!.width, 2);
      expect(tex.height, 2);
      expect(tex.kind, 'tex');
      expect(tex.rgba.length, 16);
      expect(tex.rgba.sublist(0, 4), [255, 0, 0, 255]);
      expect(tex.alphaCoverage, closeTo(0.75, 1e-9));
    });

    test('tex + bpp=3 会扩展到 RGBA（alpha=255）', () async {
      final rgb = <int>[10, 20, 30, 40, 50, 60];
      final cache = SpineTextureCache(
        FakeCacheSource(_rgbaEntry(w: 2, h: 1, raw: rgb, bpp: 3)),
      );
      await cache.refresh();
      final tex = await cache.load('files/spine/characterAtlas/chara_2/test.pkmenc');
      expect(tex, isNotNull);
      expect(tex!.rgba, [10, 20, 30, 255, 40, 50, 60, 255]);
      expect(tex.alphaCoverage, 1.0);
    });

    test('缺 json / 缺 raw / 未知格式都返回 null（不抛）', () async {
      final onlyRaw = <String, List<int>>{
        'r0001_2x2_tex_contents_localization_tc_files_spine_characterAtlas_chara_2_test.pkmenc.raw':
            List<int>.filled(16, 1),
      };
      final c1 = SpineTextureCache(FakeCacheSource(onlyRaw));
      await c1.refresh();
      expect(await c1.decodeEntry('r0001_2x2_tex_contents_localization_tc_files_spine_characterAtlas_chara_2_test.pkmenc'), isNull);

      final badFmt = <String, List<int>>{
        'r0001_2x2_ctex_contents_localization_tc_files_spine_characterAtlas_chara_2_test.pkmenc.json':
            utf8.encode(jsonEncode({'kind': 'ctex', 'w': 4, 'h': 4, 'fmt': 12345, 'rel': 'x'})),
        'r0001_2x2_ctex_contents_localization_tc_files_spine_characterAtlas_chara_2_test.pkmenc.raw':
            List<int>.filled(16, 0),
      };
      final c2 = SpineTextureCache(FakeCacheSource(badFmt));
      await c2.refresh();
      expect(
        await c2.decodeEntry('r0001_2x2_ctex_contents_localization_tc_files_spine_characterAtlas_chara_2_test.pkmenc'),
        isNull,
      );
    });

    test('数据不足（raw 比 w*h*4 短）返回 null', () async {
      final cache = SpineTextureCache(
        FakeCacheSource(_rgbaEntry(w: 4, h: 4, raw: List<int>.filled(10, 1))),
      );
      await cache.refresh();
      expect(await cache.load('files/spine/characterAtlas/chara_2/test.pkmenc'), isNull);
    });
  });
}
