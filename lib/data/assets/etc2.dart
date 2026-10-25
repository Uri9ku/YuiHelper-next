import 'dart:typed_data';

/// ETC2 RGBA8（ETC1 色彩块 + EAC alpha 块）的纯 Dart 解码器。
///
/// 布局依据：
/// - ETC1 部分按 rg_etc1（richgel999/rg-etc1）的位域表；其 `get_byte_bits(ofs, num)`
///   的寻址是「ofs = 该字段低位在 64 位大端字里的位号，字节号 = 7 - (ofs>>3)」，
///   等价于本文件的 [_bits]。这个约定不依赖宿主字节序。
/// - EAC alpha 部分按 Khronos ETC2 规范的 alpha 块（表 4.6 的 16×8 修饰表）。
/// - 每个 4×4 块 16 字节：前 8 字节 ETC1 色彩，后 8 字节 EAC alpha。
///
/// 这是「换模型页渲染真实模型」的地基：游戏里的纹理全是 PKM/ETC2。

/// ETC1 的 8 张强度修饰表（Khronos ETC1 规范 s_etc1_intensity_modifiers）。
const List<List<int>> _etc1IntenTables = [
  [-8, -2, 2, 8],
  [-17, -5, 5, 17],
  [-29, -9, 9, 29],
  [-42, -13, 13, 42],
  [-60, -18, 18, 60],
  [-80, -24, 24, 80],
  [-106, -33, 33, 106],
  [-183, -47, 47, 183],
];

/// 存储的 2 bit 选择器值 → 强度表下标（rg_etc1 的 g_etc1_to_selector_index）。
const List<int> _selectorMap = [2, 3, 1, 0];

/// EAC alpha 的 16 张修饰表（Khronos ETC2 规范）。
const List<List<int>> _alphaTables = [
  [-3, -6, -9, -15, 2, 5, 8, 14],
  [-3, -7, -10, -13, 2, 6, 9, 12],
  [-2, -5, -8, -13, 1, 4, 7, 12],
  [-2, -4, -6, -13, 1, 3, 5, 12],
  [-3, -6, -8, -12, 2, 5, 7, 11],
  [-3, -7, -9, -11, 2, 6, 8, 10],
  [-4, -7, -8, -11, 3, 6, 7, 10],
  [-3, -5, -8, -11, 2, 4, 7, 10],
  [-2, -6, -8, -10, 1, 5, 7, 9],
  [-2, -5, -8, -10, 1, 4, 7, 9],
  [-2, -4, -8, -10, 1, 3, 7, 9],
  [-2, -5, -7, -10, 1, 4, 6, 9],
  [-3, -4, -7, -10, 2, 3, 6, 9],
  [-1, -2, -3, -10, 0, 1, 2, 9],
  [-4, -6, -8, -9, 3, 5, 7, 8],
  [-3, -5, -7, -9, 2, 4, 6, 8],
];

/// 取一段字段：[lsPos] 是字段**最低位**在位域里的位置，[num] 是位数。
///
/// 位域约定见 [_bits]：位置 P 对应字节 `7 - (P >> 3)` 的第 `P & 7` 位，
/// 字段的第 k 位在位置 `lsPos + k`。字段可跨字节。
int _bits(List<int> b, int lsPos, int num) {
  var v = 0;
  for (var k = 0; k < num; k++) {
    final pos = lsPos + k;
    final byte = 7 - (pos >> 3);
    final bit = pos & 7;
    if ((b[byte] >> bit) & 1 != 0) v |= 1 << k;
  }
  return v;
}

int _clamp255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

int _expand4(int v) => (v << 4) | v;
int _expand5(int v) => (v << 3) | (v >> 2);

/// 4×4 块内 (x,y) 的 ETC1 选择器。选择器按**列主序**存放：bitIndex = x*4+y。
int _selectorAt(List<int> b, int x, int y) {
  final bitIndex = etc2RowMajor ? y * 4 + x : x * 4 + y;
  // LSB 平面在位域 0-15，MSB 平面在 16-31；每平面 16 位，位 i 对应列主序第 i 个像素。
  final lsb = _bits(b, bitIndex, 1);
  final msb = _bits(b, 16 + bitIndex, 1);
  return _selectorMap[(msb << 1) | lsb];
}

/// 解码一个 4×4 ETC1 色彩块的 8 字节，写入 [dst]（RGB，行主序 RGBA，宽 [bw]）。
void _decodeEtc1Block(List<int> b, List<int> dst, int bw, int bx, int by) {
  final flip = _bits(b, 32, 1) != 0;
  final diff = _bits(b, 33, 1) != 0;
  final tableSub1 = _bits(b, 34, 3); // 子块 1 的强度表号
  final tableSub0 = _bits(b, 37, 3); // 子块 0 的强度表号

  final List<int> base0, base1;
  if (diff) {
    final r5 = _bits(b, 59, 5);
    final g5 = _bits(b, 51, 5);
    final b5 = _bits(b, 43, 5);
    final dr = _sign3(_bits(b, 56, 3));
    final dg = _sign3(_bits(b, 48, 3));
    final db = _sign3(_bits(b, 40, 3));
    final r1 = (r5 + dr).clamp(0, 31);
    final g1 = (g5 + dg).clamp(0, 31);
    final b1 = (b5 + db).clamp(0, 31);
    base0 = [_expand5(r5), _expand5(g5), _expand5(b5)];
    base1 = [_expand5(r1), _expand5(g1), _expand5(b1)];
  } else {
    base0 = [
      _expand4(_bits(b, 60, 4)),
      _expand4(_bits(b, 52, 4)),
      _expand4(_bits(b, 44, 4)),
    ];
    base1 = [
      _expand4(_bits(b, 56, 4)),
      _expand4(_bits(b, 48, 4)),
      _expand4(_bits(b, 40, 4)),
    ];
  }

  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      // flip=1：上 2 行 / 下 2 行；flip=0：左 2 列 / 右 2 列。
      final sub = flip ? (y < 2 ? 0 : 1) : (x < 2 ? 0 : 1);
      final base = sub == 0 ? base0 : base1;
      final m =
          _etc1IntenTables[sub == 0 ? tableSub0 : tableSub1][_selectorAt(
            b,
            x,
            y,
          )];
      final p = (bx + x) + (by + y) * bw;
      dst[p * 4 + 0] = _clamp255(base[0] + m);
      dst[p * 4 + 1] = _clamp255(base[1] + m);
      dst[p * 4 + 2] = _clamp255(base[2] + m);
    }
  }
}

int _sign3(int v) => v >= 4 ? v - 8 : v;

/// 解码一个 4×4 EAC alpha 块的 8 字节，写入 [dst] 的 alpha 通道。
///
/// 布局（位域，与 [_bits] 同一约定）：
/// - 位域 56-63：基码（8 bit）
/// - 位域 52-55：倍率（4 bit）
/// - 位域 48-51：修饰表号（4 bit）
/// - 位域 0-47：16 个 3 bit 像素索引，列主序，像素 0 的索引低位在位置 0。
void _decodeAlphaBlock(List<int> b, List<int> dst, int bw, int bx, int by) {
  final base = _bits(b, 56, 8);
  final mult = _bits(b, 52, 4);
  final table = _alphaTables[_bits(b, 48, 4)];

  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final i = etc2RowMajor ? y * 4 + x : x * 4 + y;
      // 16 个 3 bit 索引：像素 0 的索引高位在位域 47，所以字段低位 = 45 - i*3。
      final idx = _bits(b, 45 - i * 3, 3);
      final p = (bx + x) + (by + y) * bw;
      dst[p * 4 + 3] = _clamp255(base + mult * table[idx]);
    }
  }
}

/// 实验开关：每块内 alpha 与 color 的先后次序。默认 color 在前。
bool etc2AlphaFirst = false;

/// 实验开关：块内像素索引按行主序（x*4+y 换成 y*4+x）。
bool etc2RowMajor = false;

/// 解码 PKM 的 ETC2 RGBA8 像素数据为 RGBA8。
///
/// [data] 是去掉 16 字节 PKM 头后的像素数据；[width]/[height] 是**对齐后**的尺寸。
/// 解码统计：平坦块占比与颜色数，用来在多个候选布局之间自动判优。
final class Etc2Stats {
  int flat = 0;
  int blocks = 0;
  final Set<int> colors = <int>{};
}

Etc2Stats decodeEtc2Rgba8Stats(Uint8List data, int width, int height) {
  if (width % 4 != 0 || height % 4 != 0) {
    throw ArgumentError('PKM 尺寸必须按 4 对齐：${width}x$height');
  }
  final need = (width >> 2) * (height >> 2) * 16;
  if (data.length < need) {
    throw ArgumentError('ETC2 数据不足：需要 $need 字节，实际 ${data.length}');
  }
  final out = Uint8List(width * height * 4);
  final st = Etc2Stats();
  var o = 0;
  for (var by = 0; by < height; by += 4) {
    for (var bx = 0; bx < width; bx += 4) {
      final color = etc2AlphaFirst
          ? data.sublist(o + 8, o + 16)
          : data.sublist(o, o + 8);
      final alpha = etc2AlphaFirst
          ? data.sublist(o, o + 8)
          : data.sublist(o + 8, o + 16);
      o += 16;
      _decodeEtc1Block(color, out, width, bx, by);
      _decodeAlphaBlock(alpha, out, width, bx, by);
      st.blocks++;
      final px = <int>[];
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final p = (bx + x) + (by + y) * width;
          px.add(
            (out[p * 4] << 24) |
                (out[p * 4 + 1] << 16) |
                (out[p * 4 + 2] << 8) |
                out[p * 4 + 3],
          );
        }
      }
      final uniq = px.toSet().length;
      if (uniq == 1) st.flat++;
      if (st.colors.length < 4096) st.colors.addAll(px);
    }
  }
  return st;
}

Uint8List decodeEtc2Rgba8(Uint8List data, int width, int height) {
  if (width % 4 != 0 || height % 4 != 0) {
    throw ArgumentError('PKM 尺寸必须按 4 对齐：${width}x$height');
  }
  final out = Uint8List(width * height * 4);
  final need = (width >> 2) * (height >> 2) * 16;
  if (data.length < need) {
    throw ArgumentError('ETC2 数据不足：需要 $need 字节，实际 ${data.length}');
  }
  var o = 0;
  for (var by = 0; by < height; by += 4) {
    for (var bx = 0; bx < width; bx += 4) {
      final color = etc2AlphaFirst
          ? data.sublist(o + 8, o + 16)
          : data.sublist(o, o + 8);
      final alpha = etc2AlphaFirst
          ? data.sublist(o, o + 8)
          : data.sublist(o + 8, o + 16);
      o += 16;
      _decodeEtc1Block(color, out, width, bx, by);
      _decodeAlphaBlock(alpha, out, width, bx, by);
    }
  }
  return out;
}
