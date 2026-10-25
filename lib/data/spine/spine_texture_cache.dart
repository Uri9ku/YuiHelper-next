import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../assets/etc2.dart';
import '../root_shell.dart';

/// 一张已解码的页贴图（RGBA8888）。
final class SpineCachedTexture {
  const SpineCachedTexture({
    required this.logicalPath,
    required this.width,
    required this.height,
    required this.rgba,
    required this.kind,
    required this.fmt,
    required this.alphaCoverage,
  });

  /// 游戏内逻辑路径（与 `paths.json` 的 page 路径一致）
  final String logicalPath;
  final int width;
  final int height;

  /// RGBA8888，长度 = width*height*4
  final Uint8List rgba;

  /// tex（未压缩）/ ctex（ETC2 压缩）
  final String kind;

  /// GL 枚举（37496 = ETC2_RGBA8_EAC）
  final int fmt;

  /// alpha>0 的像素占比（诊断用：0 表示解出空白图）
  final double alphaCoverage;

  int get byteSize => rgba.length;
}

/// 缓存文件来源（设备 / 本地目录，二选一，测试可注入）。
abstract interface class CachedFileSource {
  /// 列出缓存目录里的文件名（不含路径）。
  Future<List<String>> listFiles();

  Future<Uint8List?> readBytes(String name);

  Future<String?> readText(String name);
}

/// 本地目录（离线工具 / 测试用）。
final class LocalDirCachedSource implements CachedFileSource {
  LocalDirCachedSource(String path) : _dir = Directory(path);

  final Directory _dir;

  @override
  Future<List<String>> listFiles() async {
    if (!_dir.existsSync()) return const [];
    return _dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList(growable: false);
  }

  @override
  Future<Uint8List?> readBytes(String name) async {
    final f = File('${_dir.path}${Platform.pathSeparator}$name');
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  @override
  Future<String?> readText(String name) async {
    final f = File('${_dir.path}${Platform.pathSeparator}$name');
    if (!f.existsSync()) return null;
    return f.readAsString();
  }
}

/// 设备上的 mod 解码缓存：`/data/user/0/<pkg>/files/saoub_all/`（root 读）。
///
/// 已实测：1,404 文件 / 563 MB；文件名形如
/// `r0052_4096x204_ctex_contents_localization_tc_files_spine_characterAtlas_chara_2_edith_darkside2.pkmenc.raw`
/// 同名 `.json` 带 `kind/w/h/fmt/bpp/rel` 元数据。
final class DeviceCachedSource implements CachedFileSource {
  DeviceCachedSource({
    ShellRunner? shell,
    this.gamePackage = 'com.bandainamcoent.saoars',
    this.dirName = 'saoub_all',
  }) : _shell = shell ?? const RootShell().run;

  final ShellRunner _shell;
  final String gamePackage;
  final String dirName;

  String get deviceDir => '/data/user/0/$gamePackage/files/$dirName';

  @override
  Future<List<String>> listFiles() async {
    final r = await _shell('ls $deviceDir 2>/dev/null', timeout: const Duration(seconds: 20));
    if (!r.ok || r.out.trim().isEmpty) return const [];
    return r.out
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !s.contains('Permission denied'))
        .toList(growable: false);
  }

  @override
  Future<Uint8List?> readBytes(String name) async {
    final r = await _shell('base64 $deviceDir/$name 2>/dev/null', timeout: const Duration(seconds: 60));
    if (!r.ok || r.out.trim().isEmpty) return null;
    try {
      return base64Decode(r.out.replaceAll(RegExp(r'\s'), ''));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> readText(String name) async {
    final r = await _shell('cat $deviceDir/$name 2>/dev/null', timeout: const Duration(seconds: 30));
    final out = r.out.trim();
    if (!r.ok || out.isEmpty) return null;
    return out;
  }
}

/// mod 解码缓存读取器（S3 的页贴图来源）。
///
/// 页贴图**不能**走 `DataCache::read`（B 类资源返回空，已实测），
/// 但 mod 客户端会把解码结果按「实际加载过的资源」落盘到 `saoub_all`；
/// 因此这里按逻辑路径匹配缓存条目并解码（tex 直读 / ctex 走 ETC2）。
final class SpineTextureCache {
  SpineTextureCache(this.source, {this.alphaFirst = true});

  final CachedFileSource source;

  /// ETC2 RGBA8 EAC 的块顺序：该 build 的 ctex **alpha 块在前**（实测：
  /// 用本地 PNG 对照，alphaFirst=true 时平均色/覆盖率一致，false 时整体偏红）。
  final bool alphaFirst;

  static final RegExp _nameRe =
      RegExp(r'^(.+?)_(\d+)x(\d+)_(tex|ctex)_(.+)\.(raw|json)$', caseSensitive: false);

  final Map<String, String> _byRelToken = <String, String>{}; // relToken → 条目基名
  final Map<String, String> _byName = <String, String>{}; // 文件名 → 条目基名
  List<String> _entries = const [];

  List<String> get entries => _entries;
  int get entryCount => _entries.length;

  /// 扫描缓存目录，建立索引（按条目基名，如 `r0052_4096x204_ctex_...pkmenc`）。
  Future<void> refresh() async {
    _byRelToken.clear();
    _byName.clear();
    final files = await source.listFiles();
    final entries = <String>{};
    for (final name in files) {
      final m = _nameRe.firstMatch(name);
      if (m == null) continue;
      final base = name.substring(0, name.length - (name.endsWith('.json') ? 5 : 4));
      entries.add(base);
      _byName[name] = base;
      _byRelToken[m.group(5)!.toLowerCase()] = base;
    }
    _entries = entries.toList(growable: false)..sort();
  }

  /// 找到某个逻辑路径对应的缓存条目基名。
  ///
  /// 缓存里的 relToken 形如 `contents_localization_tc_files_spine_characterAtlas/...`（下划线化），
  /// 我们只按「以逻辑路径的下划线化形式结尾」匹配，避免跨目录误配。
  String? findEntry(String logicalPath) {
    final token = logicalPath.replaceAll('/', '_').toLowerCase();
    for (final entry in _byRelToken.entries) {
      if (entry.key.endsWith(token)) return entry.value;
    }
    return null;
  }

  /// 解码某逻辑路径对应的页贴图；没有缓存或格式不支持时返回 null。
  Future<SpineCachedTexture?> load(String logicalPath) async {
    final entry = findEntry(logicalPath);
    if (entry == null) return null;
    return decodeEntry(entry, logicalPath: logicalPath);
  }

  /// 解码一个条目基名。
  Future<SpineCachedTexture?> decodeEntry(String entryBase, {String? logicalPath}) async {
    final metaText = await source.readText('$entryBase.json');
    if (metaText == null) return null;
    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(metaText) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final kind = (meta['kind'] as String?) ?? '';
    final width = (meta['w'] as num?)?.toInt() ?? 0;
    final height = (meta['h'] as num?)?.toInt() ?? 0;
    final fmt = (meta['fmt'] as num?)?.toInt() ?? 0;
    final bpp = (meta['bpp'] as num?)?.toInt() ?? 0;
    final rel = (meta['rel'] as String?) ?? entryBase;
    if (width <= 0 || height <= 0) return null;

    final raw = await source.readBytes('$entryBase.raw');
    if (raw == null) return null;

    final Uint8List? rgba = _decodeRaw(raw, kind: kind, fmt: fmt, bpp: bpp, width: width, height: height);
    if (rgba == null) return null;

    return SpineCachedTexture(
      logicalPath: logicalPath ?? rel,
      width: width,
      height: height,
      rgba: rgba,
      kind: kind,
      fmt: fmt,
      alphaCoverage: _alphaCoverage(rgba),
    );
  }

  Uint8List? _decodeRaw(
    Uint8List raw, {
    required String kind,
    required int fmt,
    required int bpp,
    required int width,
    required int height,
  }) {
    if (kind == 'tex') {
      if (bpp == 4) {
        if (raw.length < width * height * 4) return null;
        return Uint8List.sublistView(raw, 0, width * height * 4);
      }
      if (bpp == 3) {
        if (raw.length < width * height * 3) return null;
        final out = Uint8List(width * height * 4);
        for (var i = 0, j = 0; i < width * height; i++, j += 3) {
          out[i * 4] = raw[j];
          out[i * 4 + 1] = raw[j + 1];
          out[i * 4 + 2] = raw[j + 2];
          out[i * 4 + 3] = 255;
        }
        return out;
      }
      return null;
    }
    if (kind == 'ctex') {
      // 37496 = 0x9278 GL_COMPRESSED_RGBA8_ETC2_EAC（游戏里 spine 页贴图用的就是它）
      if (fmt == 37496) {
        try {
          etc2AlphaFirst = alphaFirst;
          return decodeEtc2Rgba8(raw, width, height);
        } catch (_) {
          return null;
        }
      }
      return null;
    }
    return null;
  }

  static double _alphaCoverage(Uint8List rgba) {
    if (rgba.isEmpty) return 0;
    var opaque = 0;
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] != 0) opaque++;
    }
    return opaque / (rgba.length / 4);
  }
}
