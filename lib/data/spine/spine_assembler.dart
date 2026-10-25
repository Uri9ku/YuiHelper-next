import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../assets/texture_atlas.dart';
import '../spine/spine_binary.dart';
import '../spine/skeleton_pose.dart';
import 'spine_oracle.dart';
import '../../ui/spine/spine_painter.dart';
import 'spine_texture_cache.dart';

/// 一页贴图的原始像素（RGBA8888）。
final class SpinePagePixels {
  const SpinePagePixels({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

/// 装配一个角色所需的三种资源来源（设备取数 / 本地文件，二选一）。
abstract interface class SpineAssetSource {
  /// 骨架明文（`.skelenc` 解密后 = Spine 3.6 二进制）。
  Future<Uint8List?> skeletonBytes(String logicalPath);

  /// 图集文本（`.atlas`）。
  Future<String?> atlasText(String logicalPath);

  /// 页贴图像素（`.pkmenc` 解码后）。
  Future<SpinePagePixels?> pagePixels(String logicalPath);
}

/// 装配失败的分类（UI 按此给文案，不画假模型）。
enum AssembleFailure { noSkeleton, noAtlas, badSkeleton, badAtlas, noPages }

final class SpineAssembleException implements Exception {
  const SpineAssembleException(this.failure, this.message);

  final AssembleFailure failure;
  final String message;

  @override
  String toString() => 'SpineAssembleException($failure): $message';
}

/// 装配结果：可直接交给 [SpinePainter] 渲染。
final class SpineRenderBundle {
  SpineRenderBundle({
    required this.skeletonPath,
    required this.atlasPath,
    required this.data,
    required this.atlas,
    required this.textures,
    required this.pose,
    required this.skins,
    required this.batchesBySkin,
    required this.missingPages,
  });

  final String skeletonPath;
  final String atlasPath;
  final SpineSkeletonData data;
  final TextureAtlas atlas;
  final List<SpineAtlasPageTexture> textures;
  final SkeletonPose pose;

  /// 有网格/区域附件的皮肤（default 优先），供 UI 切换服装。
  final List<SpineSkin> skins;

  final Map<String, List<SpineDrawBatch>> batchesBySkin;

  /// 图集声明了但没有拿到像素的页（空表示完整）。
  final List<String> missingPages;

  bool get isComplete => missingPages.isEmpty;

  /// 默认皮肤的批次。
  List<SpineDrawBatch> get batches =>
      batchesBySkin[skins.isEmpty ? 'default' : skins.first.name] ?? const [];

  List<SpineDrawBatch> batchesFor(String? skinName) {
    if (skinName == null) return batches;
    return batchesBySkin[skinName] ?? batches;
  }
}

/// 把 骨架 + 图集 + 页贴图 装配成可渲染对象（S4）。
///
/// 只做数据装配与校验；不依赖任何 UI 状态，便于单测/离线工具复用。
/// 一套图集（身体 / 脸 / 武器各一套；3.6 运行时一次只认一个 atlas，
/// 装配器把多套页纹理合并成一个可绘制池）。
final class SpineAtlasSpec {
  const SpineAtlasSpec({required this.atlasPath, required this.pagePaths});

  final String atlasPath;
  final List<String> pagePaths;
}

final class SpineAssembler {
  SpineAssembler(this.source);

  final SpineAssetSource source;

  Future<SpineRenderBundle> assemble({
    required String skeletonPath,
    required String atlasPath,
    required List<String> pagePaths,
  }) {
    return assembleMulti(
      skeletonPath: skeletonPath,
      atlases: [SpineAtlasSpec(atlasPath: atlasPath, pagePaths: pagePaths)],
    );
  }

  /// 多图集装配：角色 = 身体图集 + 脸图集（需要时再加武器图集）。
  ///
  /// Spine 3.6 运行时一次只认一个 atlas；这里把多套图集的页纹理合并成一个池，
  /// 由 [SpineBinder.findRegion] 按 region 名跨套查找。
  Future<SpineRenderBundle> assembleMulti({
    required String skeletonPath,
    required List<SpineAtlasSpec> atlases,
  }) async {
    final skelBytes = await source.skeletonBytes(skeletonPath);
    if (skelBytes == null || skelBytes.isEmpty) {
      throw const SpineAssembleException(AssembleFailure.noSkeleton, '没有拿到骨架解密数据');
    }

    final SpineSkeletonData data;
    try {
      data = SpineBinaryParser.parse(skelBytes);
    } catch (e) {
      throw SpineAssembleException(AssembleFailure.badSkeleton, '骨架解析失败：$e');
    }

    final textures = <SpineAtlasPageTexture>[];
    final missing = <String>[];
    var declaredPages = 0;
    TextureAtlas? firstAtlas;
    for (final spec in atlases) {
      final atlasText = await source.atlasText(spec.atlasPath);
      if (atlasText == null || atlasText.isEmpty) {
        if (atlases.length == 1) {
          throw const SpineAssembleException(AssembleFailure.noAtlas, '没有拿到图集文本');
        }
        continue;
      }
      final TextureAtlas atlas;
      try {
        atlas = parseAtlas(atlasText);
      } catch (e) {
        throw SpineAssembleException(AssembleFailure.badAtlas, '图集解析失败：$e');
      }
      firstAtlas ??= atlas;
      declaredPages += atlas.pages.length;
      for (var i = 0; i < atlas.pages.length; i++) {
        final path = i < spec.pagePaths.length ? spec.pagePaths[i] : '';
        SpinePagePixels? pixels;
        if (path.isNotEmpty) {
          pixels = await source.pagePixels(path);
        }
        if (pixels == null) {
          missing.add(atlas.pages[i].image);
          continue;
        }
        final image = await _toImage(pixels);
        textures.add(SpineAtlasPageTexture(image: image, atlas: atlas, pageIndex: i));
      }
    }
    if (firstAtlas == null) {
      throw const SpineAssembleException(AssembleFailure.noAtlas, '没有拿到任何图集文本');
    }
    if (textures.isEmpty) {
      throw SpineAssembleException(
        AssembleFailure.noPages,
        '图集声明 $declaredPages 页，但一页像素都没拿到（缺：${missing.join(', ')}）',
      );
    }

    final pose = SkeletonPose.bindPose(data);
    final batchesBySkin = <String, List<SpineDrawBatch>>{};
    final drawableSkins = <SpineSkin>[];
    // 注意：解析器把 default 皮肤单独放在 defaultSkin，命名皮肤才在 skins 里。
    final seenSkins = <String>{};
    final allSkins = <SpineSkin>[
      for (final s in <SpineSkin>[data.defaultSkin, ...data.skins])
        if (seenSkins.add(s.name)) s,
    ];
    for (final skin in allSkins) {
      final batches = SpineBinder.bind(data: data, skin: skin, pose: pose, textures: textures);
      if (batches.isEmpty) continue;
      drawableSkins.add(skin);
      batchesBySkin[skin.name] = batches;
    }
    // default 优先
    drawableSkins.sort((a, b) {
      if (a.name == 'default') return -1;
      if (b.name == 'default') return 1;
      return a.name.compareTo(b.name);
    });

    return SpineRenderBundle(
      skeletonPath: skeletonPath,
      atlasPath: atlases.isEmpty ? '' : atlases.first.atlasPath,
      data: data,
      atlas: firstAtlas,
      textures: textures,
      pose: pose,
      skins: drawableSkins,
      batchesBySkin: batchesBySkin,
      missingPages: missing,
    );
  }

  static Future<ui.Image> _toImage(SpinePagePixels pixels) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels.rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: pixels.width,
      height: pixels.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  }
}

/// 设备来源：骨架/图集走 [SpineOracle]（A 类可按时取），页贴图走 [SpineTextureCache]（B 类缓存）。
final class DeviceSpineSource implements SpineAssetSource {
  DeviceSpineSource({SpineOracle? oracle, SpineTextureCache? textures})
      : _oracle = oracle ?? SpineOracle(),
        _textures = textures ?? SpineTextureCache(DeviceCachedSource());

  final SpineOracle _oracle;
  final SpineTextureCache _textures;

  final Map<String, Uint8List> _bytesCache = <String, Uint8List>{};
  bool _cacheIndexed = false;

  /// 一次注入取多条（骨架 + 图集），减少注入次数。
  Future<void> prefetch(Iterable<String> logicalPaths) async {
    final todo = logicalPaths.where((p) => !_bytesCache.containsKey(p)).toList();
    if (todo.isEmpty) return;
    final result = await _oracle.fetch(todo);
    _bytesCache.addAll(result.assets.map((k, v) => MapEntry(k, v.bytes)));
    if (result.failures.isNotEmpty && result.assets.isEmpty) {
      throw SpineOracleException(
        OracleFailure.badResult,
        'A 类资源取数失败：${result.failures.values.first}',
      );
    }
  }

  @override
  Future<Uint8List?> skeletonBytes(String logicalPath) async {
    await prefetch([logicalPath]);
    return _bytesCache[logicalPath];
  }

  @override
  Future<String?> atlasText(String logicalPath) async {
    await prefetch([logicalPath]);
    final bytes = _bytesCache[logicalPath];
    if (bytes == null) return null;
    return String.fromCharCodes(bytes);
  }

  @override
  Future<SpinePagePixels?> pagePixels(String logicalPath) async {
    if (!_cacheIndexed) {
      await _textures.refresh();
      _cacheIndexed = true;
    }
    final tex = await _textures.load(logicalPath);
    if (tex == null) return null;
    return SpinePagePixels(width: tex.width, height: tex.height, rgba: tex.rgba);
  }
}

/// 本地文件来源（离线验证 / 单测）：逻辑路径 → 本地文件映射。
///
/// 页贴图支持 PNG（解码成 RGBA）与 `.raw`（若 meta 缺失则按文件同名 `.json` 读尺寸）。
final class LocalFileSpineSource implements SpineAssetSource {
  LocalFileSpineSource(this.files);

  /// logicalPath → 本地绝对路径
  final Map<String, String> files;

  @override
  Future<Uint8List?> skeletonBytes(String logicalPath) async {
    final path = files[logicalPath];
    if (path == null) return null;
    final f = File(path);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  @override
  Future<String?> atlasText(String logicalPath) async {
    final path = files[logicalPath];
    if (path == null) return null;
    final f = File(path);
    return f.existsSync() ? f.readAsString() : null;
  }

  @override
  Future<SpinePagePixels?> pagePixels(String logicalPath) async {
    final path = files[logicalPath];
    if (path == null) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rgba = raw?.buffer.asUint8List() ?? Uint8List(0);
    final pixels = SpinePagePixels(width: img.width, height: img.height, rgba: rgba);
    img.dispose();
    return pixels;
  }
}
