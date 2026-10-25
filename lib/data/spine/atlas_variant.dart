/// 从 `.skel` 里推断它属于哪个「图集变体」。
///
/// # 为什么需要这一步
///
/// 骨骼文件里没有干净的角色 id，但有一个 `images` 字段，记录导出时图集所在目录。
/// 实测 300 份骨骼里有 299 份带这个字段，但写法很杂：
///
/// ```text
/// ../../saoal/asset/source/spine/characterAtlas/chara_2/administrator_naked/
/// ../../../01_set/nergius_integrator/
/// C:/Users/z.natsumi.noguchi/Desktop/                      ← 绝对路径，没有信息
/// D:/saoal/asset/source/spine/characterAtlas/chara_1/mob_assassin_fa_hood_boss/
/// ../../素体シート/image_man/kirito_sao_gold/
/// ```
///
/// 而换模型页里的角色 id / 骨架集表用的就是最后那个目录名
/// （`alice_integrator`、`kirito_cathedral` …），所以只要取「最后一个有意义的路径段」。
library;

/// 从 `imagesPath` 推断图集变体名；推不出来返回 null。
///
/// 返回 null 的两种情况都很常见，调用方必须能接受：
/// - 字段缺失 / 为空；
/// - 是导出者机器上的绝对路径（`C:/Users/xxx/Desktop/`），最后一段没有信息量。
String? atlasVariantOf(String? imagesPath) {
  if (imagesPath == null) return null;
  var path = imagesPath.trim();
  if (path.isEmpty) return null;
  path = path.replaceAll(r'\', '/');

  final segments = path
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  if (segments.isEmpty) return null;

  // 绝对路径的最后一段往往只是一个目录名（Desktop、images、chara_2…），
  // 这些都不是图集变体，宁可不给也不给错。
  const useless = {
    'desktop',
    'images',
    'image_all',
    'image_man',
    'chara_1',
    'chara_2',
    'chara_3',
    'chara_4',
    'characteratlas',
  };
  final last = segments.last;
  if (useless.contains(last.toLowerCase())) return null;
  // 带盘符的绝对路径整体不可信
  if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return null;
  return last;
}

/// 判断一个字符串是否适合作图集变体名（纯 ASCII、无空格）。
///
/// 游戏的图集文件名都是 ASCII；带中文的（如 `素体シート`）是导出者的
/// 素材表目录，不是图集名。
bool isAtlasVariantName(String name) {
  if (name.isEmpty || name.length > 80) return false;
  return RegExp(r'^[A-Za-z0-9_.\-]+$').hasMatch(name);
}
