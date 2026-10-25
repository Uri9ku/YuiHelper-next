import 'dart:math' as math;

/// LibGDX 纹理图集（`.atlas`）文本格式解析。
///
/// 游戏里的 1,706 份 `.atlas` 是**明文**的（像素在加密块里，区域表是明文的），
/// 所以「每个槽位在图集里的矩形」这一层不需要解密，直接解析即可。
///
/// 格式要点（实测，见 `readable/atlas/`）：
/// - 页头：页名**不缩进**，随后的 `size/format/filter/repeat` 也**不缩进**。
/// - 区域：区域名**不缩进**，随后的 `rotate/xy/size/orig/offset/index` **缩进**。
///   这就把「页名」和「区域名」区分开了（两者都不缩进）。
/// - 1,657 / 1,706 个图集是**多页**的（最多 5 页）——必须支持多页。
/// - `rotate: true` 只有 1 例，但仍然要处理：表示存储时顺时针旋转了 90°。
/// - 没有 `splits` / `pads`（9 宫格拉伸）——不解析。

/// 图集里的一页（对应一张纹理图）。
final class AtlasPage {
  const AtlasPage({
    required this.image,
    required this.width,
    required this.height,
    required this.format,
    required this.filter,
    required this.repeat,
    required this.regions,
  });

  /// 这一页的纹理文件名（如 `kirito_cathedral.png`）。
  final String image;
  final int width;
  final int height;

  /// 如 `RGBA8888`。
  final String format;

  /// 如 `Linear,Linear`。
  final String filter;

  /// 如 `none`。
  final String repeat;

  final List<AtlasRegion> regions;
}

/// 图集里的一个区域（Spine 里叫 attachment / 游戏里叫槽位）。
final class AtlasRegion {
  const AtlasRegion({
    required this.name,
    required this.pageIndex,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotate,
    required this.origWidth,
    required this.origHeight,
    required this.offsetX,
    required this.offsetY,
    required this.index,
  });

  final String name;

  /// 所属页在 [TextureAtlas.pages] 里的下标。
  final int pageIndex;

  /// 图集里的左上角（像素，坐标系原点在图集左上）。
  final int x;
  final int y;

  /// 图集里占的像素尺寸。
  ///
  /// `rotate` 为 true 时，存储是 (height × width)，绘制时要转回来；
  /// 这里给的是**未旋转**的语义尺寸，[srcRect] 会按 rotate 换算。
  final int width;
  final int height;

  /// 存储时是否顺时针旋转了 90°。
  final bool rotate;

  /// 打包前的原始尺寸（用来还原被裁掉透明边之前的画布）。
  final int origWidth;
  final int origHeight;

  /// 原始画布左上角 → 实际像素左上角的位移（通常为 0）。
  final int offsetX;
  final int offsetY;

  /// 同名区域的分帧下标，-1 表示唯一。
  final int index;

  /// 在图集纹理里的源矩形（[AtlasRegion] 的坐标已按 rotate 换算过）。
  math.Rectangle<int> get srcRect => rotate
      ? math.Rectangle<int>(x, y, height, width)
      : math.Rectangle<int>(x, y, width, height);
}

/// 一份完整的图集（可含多页）。
final class TextureAtlas {
  const TextureAtlas(this.pages);

  final List<AtlasPage> pages;

  /// 全部区域（跨页）。
  Iterable<AtlasRegion> get regions sync* {
    for (final p in pages) {
      yield* p.regions;
    }
  }

  /// 按名字查区域；重名时返回第一个。
  AtlasRegion? region(String name) {
    for (final r in regions) {
      if (r.name == name) return r;
    }
    return null;
  }
}

bool _isIndented(String line) =>
    line.startsWith(' ') || line.startsWith('\t');

String? _nextMeaningful(List<String> lines, int from) {
  for (var i = from; i < lines.length; i++) {
    final l = lines[i];
    if (l.trim().isNotEmpty) return l;
  }
  return null;
}

/// 解析一行 `key: value`。
(String, String)? _keyValue(String line) {
  final i = line.indexOf(':');
  if (i <= 0) return null;
  return (line.substring(0, i).trim(), line.substring(i + 1).trim());
}

int _intOf(String v, int fallback) => int.tryParse(v.trim()) ?? fallback;

List<int> _pair(String v, int fallbackA, int fallbackB) {
  final parts = v.split(',');
  if (parts.length < 2) {
    return [_intOf(v, fallbackA), fallbackB];
  }
  return [_intOf(parts[0], fallbackA), _intOf(parts[1], fallbackB)];
}

/// 解析 LibGDX `.atlas` 文本。
///
/// 容错优先：缺字段按默认值补，坏行跳过 —— 图集是外部数据，不能让解析崩掉。
TextureAtlas parseAtlas(String text) {
  final lines = text.split('\n').map((l) => l.replaceAll('\r', '')).toList();
  final pages = <AtlasPage>[];

  String? image;
  var pageW = 0;
  var pageH = 0;
  var format = '';
  var filter = '';
  var repeat = '';
  var pageRegions = <AtlasRegion>[];
  var pageIndex = -1;

  void flushPage() {
    if (image == null) return;
    pages.add(
      AtlasPage(
        image: image!,
        width: pageW,
        height: pageH,
        format: format,
        filter: filter,
        repeat: repeat,
        regions: pageRegions,
      ),
    );
    image = null;
    pageW = 0;
    pageH = 0;
    format = '';
    filter = '';
    repeat = '';
    pageRegions = <AtlasRegion>[];
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty || _isIndented(line)) {
      i++;
      continue;
    }

    final name = line.trim();
    final next = _nextMeaningful(lines, i + 1);
    // 页名后面紧跟**不缩进**的 `size:`；区域名后面是**缩进**的属性。
    final isPageHeader =
        next != null && !_isIndented(next) && next.contains(':');

    if (isPageHeader) {
      flushPage();
      pageIndex++;
      image = name;
      i++;
      while (i < lines.length) {
        final l = lines[i];
        if (l.trim().isEmpty) {
          i++;
          continue;
        }
        if (_isIndented(l)) break;
        final kv = _keyValue(l);
        if (kv == null) break; // 下一个块的名字行
        final (k, v) = kv;
        switch (k) {
          case 'size':
            final p = _pair(v, 0, 0);
            pageW = p[0];
            pageH = p[1];
          case 'format':
            format = v;
          case 'filter':
            filter = v;
          case 'repeat':
            repeat = v;
        }
        i++;
      }
      continue;
    }

    // 区域块
    var rotate = false;
    var x = 0;
    var y = 0;
    var w = 0;
    var h = 0;
    var ow = 0;
    var oh = 0;
    var ox = 0;
    var oy = 0;
    var index = -1;
    i++;
    while (i < lines.length) {
      final l = lines[i];
      if (l.trim().isEmpty) {
        i++;
        continue;
      }
      if (!_isIndented(l)) break;
      final kv = _keyValue(l);
      if (kv != null) {
        final (k, v) = kv;
        switch (k) {
          case 'rotate':
            rotate = v.toLowerCase() == 'true';
          case 'xy':
            final p = _pair(v, 0, 0);
            x = p[0];
            y = p[1];
          case 'size':
            final p = _pair(v, 0, 0);
            w = p[0];
            h = p[1];
          case 'orig':
            final p = _pair(v, w, h);
            ow = p[0];
            oh = p[1];
          case 'offset':
            final p = _pair(v, 0, 0);
            ox = p[0];
            oy = p[1];
          case 'index':
            index = _intOf(v, -1);
        }
      }
      i++;
    }
    pageRegions.add(
      AtlasRegion(
        name: name,
        pageIndex: pageIndex < 0 ? 0 : pageIndex,
        x: x,
        y: y,
        width: w,
        height: h,
        rotate: rotate,
        origWidth: ow == 0 ? w : ow,
        origHeight: oh == 0 ? h : oh,
        offsetX: ox,
        offsetY: oy,
        index: index,
      ),
    );
  }

  flushPage();
  return TextureAtlas(pages);
}
