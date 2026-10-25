import 'package:flutter_test/flutter_test.dart';
import 'package:yui_helper_next/data/assets/texture_atlas.dart';

/// 合成的两页图集：故意包含多页、rotate:true、缺字段三种情况。
const String _atlas = '''
page_a.png
size: 100,50
format: RGBA8888
filter: Linear,Linear
repeat: none
head
  rotate: false
  xy: 10, 20
  size: 30, 40
  orig: 30, 40
  offset: 0, 0
  index: -1
hand_rotated
  rotate: true
  xy: 5, 6
  size: 12, 8
  orig: 12, 8
  offset: 0, 0
  index: 2
page_b.png
size: 200,100
format: RGBA8888
filter: Nearest,Nearest
repeat: none
sparse
  rotate: false
  xy: 1, 2
  size: 3, 4
''';

void main() {
  group('parseAtlas', () {
    final atlas = parseAtlas(_atlas);

    test('支持多页，页属性解析正确', () {
      expect(atlas.pages, hasLength(2));
      expect(atlas.pages[0].image, 'page_a.png');
      expect(atlas.pages[0].width, 100);
      expect(atlas.pages[0].height, 50);
      expect(atlas.pages[0].format, 'RGBA8888');
      expect(atlas.pages[0].repeat, 'none');
      expect(atlas.pages[1].image, 'page_b.png');
      expect(atlas.pages[1].filter, 'Nearest,Nearest');
    });

    test('区域归属到正确的页', () {
      expect(atlas.pages[0].regions.map((r) => r.name), ['head', 'hand_rotated']);
      expect(atlas.pages[1].regions.map((r) => r.name), ['sparse']);
      expect(atlas.region('head')!.pageIndex, 0);
      expect(atlas.region('sparse')!.pageIndex, 1);
    });

    test('坐标与 index 解析正确', () {
      final head = atlas.region('head')!;
      expect(head.x, 10);
      expect(head.y, 20);
      expect(head.width, 30);
      expect(head.height, 40);
      expect(head.index, -1);
      expect(atlas.region('hand_rotated')!.index, 2);
    });

    test('rotate=true 时源矩形旋转（宽高互换）', () {
      final r = atlas.region('hand_rotated')!;
      expect(r.rotate, isTrue);
      // 语义尺寸 12x8，存储是 8x12
      expect(r.width, 12);
      expect(r.height, 8);
      expect(r.srcRect.width, 8);
      expect(r.srcRect.height, 12);
      expect(r.srcRect.left, 5);
      expect(r.srcRect.top, 6);
    });

    test('缺字段容错：orig/offset/index 用默认值补', () {
      final r = atlas.region('sparse')!;
      expect(r.width, 3);
      expect(r.height, 4);
      expect(r.origWidth, 3, reason: 'orig 缺失时退化为 size');
      expect(r.origHeight, 4);
      expect(r.offsetX, 0);
      expect(r.index, -1);
    });

    test('regions 跨页汇总，查不到的名字返回 null', () {
      expect(atlas.regions, hasLength(3));
      expect(atlas.region('nope'), isNull);
    });

    test('空文本不会崩', () {
      final empty = parseAtlas('');
      expect(empty.pages, isEmpty);
    });
  });
}
