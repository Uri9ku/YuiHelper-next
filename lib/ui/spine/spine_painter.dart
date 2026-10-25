import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/assets/texture_atlas.dart';
import '../../data/spine/skeleton_pose.dart';
import '../../data/spine/spine_binary.dart';

/// 一张图集页的纹理：像素 + 所属图集 + 页下标。
final class SpineAtlasPageTexture {
  const SpineAtlasPageTexture({
    required this.image,
    required this.atlas,
    required this.pageIndex,
  });

  final ui.Image image;
  final TextureAtlas atlas;
  final int pageIndex;

  /// 图集页的**实际像素宽高**（以解码后的纹理为准，不是 atlas 声明尺寸）。
  ///
  /// ETC/PKM 纹理按 4 像素对齐，实际常比声明大 1~2 px；UV 若按声明尺寸算会整体偏移。
  int get width => image.width;
  int get height => image.height;
}

/// 一个待绘制批次：一个附件 → 一块图集区域 + 蒙皮后的世界顶点。
final class SpineDrawBatch {
  SpineDrawBatch({
    required this.region,
    required this.page,
    required this.vertices,
    required this.uvs,
    required this.triangles,
  });

  final AtlasRegion region;
  final SpineAtlasPageTexture page;

  /// Spine 世界坐标（Y 向上），长度 = 顶点数 * 2。
  final Float32List vertices;

  /// 纹理坐标 0..1，原点在图集页左上，长度 = 顶点数 * 2。
  final Float32List uvs;

  final Uint16List triangles;
}

/// 把骨架在某个皮肤下绑定成可绘制批次（bind pose）。
abstract final class SpineBinder {
  static List<SpineDrawBatch> bind({
    required SpineSkeletonData data,
    required SpineSkin skin,
    required SkeletonPose pose,
    required List<SpineAtlasPageTexture> textures,
    int skinIndex = 0,
    List<double>? Function(int skinIndex, int slotIndex, String attachment)? deformLookup,
  }) {
    final batches = <SpineDrawBatch>[];
    for (final slotIndex in skin.slotIndices) {
      final slot = data.slots[slotIndex];
      for (final attachment in skin.attachmentsOfSlot(slotIndex).values) {
        if (attachment is SpineMeshAttachment) {
          final hit = findRegion(textures, attachment.path);
          if (hit == null) continue;
          final (page, region) = hit;
          final deform = deformLookup?.call(skinIndex, slotIndex, attachment.name);
          batches.add(
            SpineDrawBatch(
              region: region,
              page: page,
              vertices: skinMeshVertices(
                attachment,
                pose,
                slot.boneIndex,
                deform: deform,
              ),
              uvs: _meshUvs(attachment, region, page),
              triangles: attachment.triangles,
            ),
          );
        } else if (attachment is SpineRegionAttachment) {
          final hit = findRegion(textures, attachment.path);
          if (hit == null) continue;
          final (page, region) = hit;
          final corners = regionCorners(attachment, pose, slot.boneIndex);
          final verts = Float32List(8);
          for (var i = 0; i < 4; i++) {
            verts[i * 2] = corners[i].$1;
            verts[i * 2 + 1] = corners[i].$2;
          }
          batches.add(
            SpineDrawBatch(
              region: region,
              page: page,
              vertices: verts,
              uvs: _regionUvs(region, page),
              triangles: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
            ),
          );
        }
      }
    }
    return batches;
  }

  /// 在多个图集页里找区域（多图集合成：身体/脸/武器各一套）。
  static (SpineAtlasPageTexture, AtlasRegion)? findRegion(
    List<SpineAtlasPageTexture> textures,
    String name,
  ) {
    for (final page in textures) {
      for (final region in page.atlas.pages[page.pageIndex].regions) {
        if (region.name == name) return (page, region);
      }
    }
    return null;
  }

  static Float32List _meshUvs(
    SpineMeshAttachment mesh,
    AtlasRegion region,
    SpineAtlasPageTexture page,
  ) {
    final r = region.srcRect;
    final pw = page.width.toDouble();
    final ph = page.height.toDouble();
    final rw = r.width.toDouble();
    final rh = r.height.toDouble();
    final out = Float32List(mesh.uvs.length);
    for (var i = 0; i < mesh.uvs.length; i += 2) {
      out[i] = (r.left + mesh.uvs[i] * rw) / pw;
      out[i + 1] = (r.top + mesh.uvs[i + 1] * rh) / ph;
    }
    return out;
  }

  static Float32List _regionUvs(AtlasRegion region, SpineAtlasPageTexture page) {
    final r = region.srcRect;
    final pw = page.width.toDouble();
    final ph = page.height.toDouble();
    final left = r.left / pw;
    final right = (r.left + r.width) / pw;
    final top = r.top / ph;
    final bottom = (r.top + r.height) / ph;
    // 顺序与 regionCorners 一致：左下、右下、右上、左上
    return Float32List.fromList([left, bottom, right, bottom, right, top, left, top]);
  }

  /// 全部批次的 Spine 空间包围盒（用于自适应缩放）。
  static Rect boundsOf(List<SpineDrawBatch> batches) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final batch in batches) {
      for (var i = 0; i < batch.vertices.length; i += 2) {
        final x = batch.vertices[i];
        final y = batch.vertices[i + 1];
        if (!x.isFinite || !y.isFinite) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    if (!minX.isFinite || !minY.isFinite) return Rect.zero;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// 合批后的绘制次数（相邻同页算一次）；用于测试/性能诊断。
  static int pageRunCount(List<SpineDrawBatch> batches) {
    if (batches.isEmpty) return 0;
    var runs = 1;
    for (var i = 1; i < batches.length; i++) {
      if (!identical(batches[i].page, batches[i - 1].page)) runs++;
    }
    return runs;
  }

  /// 线框顶点（只画三角形边，调试/三态提示用）。
  static List<Offset> wireframeSegments(List<SpineDrawBatch> batches) {
    final out = <Offset>[];
    for (final batch in batches) {
      final idx = batch.triangles;
      for (var i = 0; i + 2 < idx.length; i += 3) {
        for (var e = 0; e < 3; e++) {
          final a = idx[i + e];
          final b = idx[i + (e + 1) % 3];
          if (a * 2 + 1 >= batch.vertices.length || b * 2 + 1 >= batch.vertices.length) {
            continue;
          }
          out.add(Offset(batch.vertices[a * 2], batch.vertices[a * 2 + 1]));
          out.add(Offset(batch.vertices[b * 2], batch.vertices[b * 2 + 1]));
        }
      }
    }
    return out;
  }
}

/// 绘制 bind pose（纹理模式 / 线框模式）。
class SpinePainter extends CustomPainter {
  SpinePainter({
    required this.batches,
    this.background,
    this.padding = 0.94,
    this.wireframe = false,
    this.wireColor = const Color(0xFF6EE7B7),
    this.batching = true,
  });

  final List<SpineDrawBatch> batches;
  final Color? background;
  final double padding;
  final bool wireframe;
  final Color wireColor;

  /// 是否按图集页合批（默认开：把相邻同页批次合并成一次 drawVertices）。
  final bool batching;

  @override
  void paint(Canvas canvas, Size size) {
    if (background != null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = background!);
    }
    if (batches.isEmpty) return;

    final bounds = SpineBinder.boundsOf(batches);
    if (bounds.isEmpty || bounds.width.abs() < 1e-6 || bounds.height.abs() < 1e-6) {
      return;
    }

    final scale = math.min(
      size.width * padding / bounds.width.abs(),
      size.height * padding / bounds.height.abs(),
    );
    if (!scale.isFinite || scale <= 0) return;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    // Spine 的 Y 朝上，Canvas 的 Y 朝下：翻转 Y 让角色正立
    canvas.scale(scale, -scale);
    canvas.translate(-bounds.center.dx, -bounds.center.dy);

    if (wireframe) {
      _paintWireframe(canvas);
    } else if (batching) {
      _paintBatched(canvas);
    } else {
      for (final batch in batches) {
        _paintBatch(canvas, batch);
      }
    }
    canvas.restore();
  }

  void _paintBatched(Canvas canvas) {
    // 合批：把连续的、同一图集页的批次合并成一次 drawVertices。
    // 只合并"相邻"批次，保证与逐附件绘制的叠加顺序完全一致（像素级一致）。
    var i = 0;
    while (i < batches.length) {
      final page = batches[i].page;
      var j = i + 1;
      while (j < batches.length && identical(batches[j].page, page)) {
        j++;
      }
      _paintRun(canvas, batches.sublist(i, j), page);
      i = j;
    }
  }

  void _paintRun(Canvas canvas, List<SpineDrawBatch> run, SpineAtlasPageTexture page) {
    var vertexCount = 0;
    var indexCount = 0;
    for (final b in run) {
      vertexCount += b.vertices.length ~/ 2;
      indexCount += b.triangles.length;
    }
    if (vertexCount == 0 || indexCount < 3) return;

    final positions = Float32List(vertexCount * 2);
    final texCoords = Float32List(vertexCount * 2);
    final indices = Uint16List(indexCount);
    final pw = page.width.toDouble();
    final ph = page.height.toDouble();
    var vBase = 0;
    var iBase = 0;
    for (final b in run) {
      final count = b.vertices.length ~/ 2;
      for (var i = 0; i < count; i++) {
        final x = b.vertices[i * 2];
        final y = b.vertices[i * 2 + 1];
        if (!x.isFinite || !y.isFinite) return;
        positions[(vBase + i) * 2] = x;
        positions[(vBase + i) * 2 + 1] = y;
        texCoords[(vBase + i) * 2] = b.uvs[i * 2] * pw;
        texCoords[(vBase + i) * 2 + 1] = b.uvs[i * 2 + 1] * ph;
      }
      for (var k = 0; k < b.triangles.length; k++) {
        indices[iBase + k] = b.triangles[k] + vBase;
      }
      vBase += count;
      iBase += b.triangles.length;
    }
    if (vBase > 0xFFFF) return; // 单次 drawVertices 索引上限

    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..shader = ui.ImageShader(
        page.image,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
      );
    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: texCoords,
        indices: indices,
      ),
      BlendMode.srcOver,
      paint,
    );
  }

  void _paintWireframe(Canvas canvas) {
    final paint = Paint()
      ..color = wireColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path();
    for (final batch in batches) {
      final idx = batch.triangles;
      for (var i = 0; i + 2 < idx.length; i += 3) {
        for (var e = 0; e < 3; e++) {
          final a = idx[i + e];
          final b = idx[i + (e + 1) % 3];
          if (a * 2 + 1 >= batch.vertices.length || b * 2 + 1 >= batch.vertices.length) {
            continue;
          }
          path.moveTo(batch.vertices[a * 2], batch.vertices[a * 2 + 1]);
          path.lineTo(batch.vertices[b * 2], batch.vertices[b * 2 + 1]);
        }
      }
    }
    canvas.drawPath(path, paint);
  }

  void _paintBatch(Canvas canvas, SpineDrawBatch batch) {
    final count = batch.vertices.length ~/ 2;
    if (count == 0 || batch.triangles.length < 3) return;

    final imgW = batch.page.image.width.toDouble();
    final imgH = batch.page.image.height.toDouble();
    final positions = Float32List(count * 2);
    final texCoords = Float32List(count * 2);
    var allFinite = true;
    for (var i = 0; i < count; i++) {
      final x = batch.vertices[i * 2];
      final y = batch.vertices[i * 2 + 1];
      if (!x.isFinite || !y.isFinite) {
        allFinite = false;
        break;
      }
      positions[i * 2] = x;
      positions[i * 2 + 1] = y;
      texCoords[i * 2] = batch.uvs[i * 2] * imgW;
      texCoords[i * 2 + 1] = batch.uvs[i * 2 + 1] * imgH;
    }
    if (!allFinite) return;

    final maxIndex = count - 1;
    final safe = <int>[];
    for (final idx in batch.triangles) {
      if (idx <= maxIndex) safe.add(idx);
    }
    if (safe.length < 3) return;

    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..shader = ui.ImageShader(
        batch.page.image,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
      );

    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: texCoords,
        indices: Uint16List.fromList(safe),
      ),
      BlendMode.srcOver,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant SpinePainter oldDelegate) =>
      oldDelegate.batches != batches ||
      oldDelegate.background != background ||
      oldDelegate.padding != padding ||
      oldDelegate.wireframe != wireframe ||
      oldDelegate.batching != batching;
}
