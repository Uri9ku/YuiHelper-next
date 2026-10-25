import 'dart:convert';

/// Spine 图集条目（来自 `assets/spine/paths.json` 的 `atlases`）。
final class SpineAtlasEntry {
  const SpineAtlasEntry({
    required this.hash,
    required this.path,
    required this.kind,
    required this.dir,
    required this.category,
    required this.group,
    required this.label,
    required this.pages,
  });

  final String hash;

  /// 游戏内逻辑路径，如 `files/spine/characterAtlas/chara_2/edith_integrator.atlas`
  final String path;

  /// characterAtlas / faceAtlas / weaponAtlas / enemySpine
  final String kind;

  /// 目录键：chara_1..4 / 12_knuckle / enemy_xxx
  final String dir;

  final String category;
  final String group;
  final String label;

  /// 页文件名（含 `.png`），如 `edith_integrator.png`
  final List<String> pages;

  /// 页贴图逻辑路径：同目录 + 页名（去掉 .png）+ `.pkmenc`。
  List<String> get pagePaths => pages
      .map((p) => '${_dirnameOf(path)}/${p.replaceAll(RegExp(r'\.png$', caseSensitive: false), '')}.pkmenc')
      .toList(growable: false);
}

/// Spine 骨架条目（来自 `skeletons`）。
final class SpineSkeletonEntry {
  const SpineSkeletonEntry({required this.hash, required this.path, required this.kind});

  final String hash;

  /// `files/spine/characterSpine/f_chara_2/f_chara_2_v0.5_sword.skelenc`
  final String path;

  /// base（通用素体，战斗动作在这里）/ enemy / character
  final String kind;
}

/// 变体索引：一个变体（= 游戏内服装/敌人配色名）对应的图集与骨架。
final class SpineVariantEntry {
  const SpineVariantEntry({required this.atlasHashes, required this.skeletonHashes});

  final List<String> atlasHashes;
  final List<String> skeletonHashes;
}

/// `assets/spine/paths.json` 的只读视图（S1 产出，见 docs/_s1/README.md）。
///
/// 只做解析与查询，不碰 IO：测试可以直接喂 JSON 文本。
final class SpinePathTable {
  SpinePathTable({
    required this.atlases,
    required this.skeletons,
    required this.variants,
    required this.gameVersion,
  });

  static const String assetPath = 'assets/spine/paths.json';

  final Map<String, SpineAtlasEntry> atlases;
  final Map<String, SpineSkeletonEntry> skeletons;
  final Map<String, SpineVariantEntry> variants;
  final String gameVersion;

  int get atlasCount => atlases.length;
  int get skeletonCount => skeletons.length;
  int get variantCount => variants.length;

  factory SpinePathTable.parse(String jsonText) {
    final root = jsonDecode(jsonText) as Map<String, dynamic>;
    final atlases = <String, SpineAtlasEntry>{};
    final rawAtlases = (root['atlases'] as Map<String, dynamic>?) ?? const {};
    rawAtlases.forEach((hash, value) {
      final m = value as Map<String, dynamic>;
      atlases[hash] = SpineAtlasEntry(
        hash: hash,
        path: (m['path'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? '',
        dir: (m['dir'] as String?) ?? '',
        category: (m['category'] as String?) ?? '',
        group: (m['group'] as String?) ?? '',
        label: (m['label'] as String?) ?? '',
        pages: ((m['pages'] as List<dynamic>?) ?? const []).cast<String>(),
      );
    });

    final skeletons = <String, SpineSkeletonEntry>{};
    final rawSkeletons = (root['skeletons'] as Map<String, dynamic>?) ?? const {};
    rawSkeletons.forEach((hash, value) {
      final m = value as Map<String, dynamic>;
      skeletons[hash] = SpineSkeletonEntry(
        hash: hash,
        path: (m['path'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? '',
      );
    });

    final variants = <String, SpineVariantEntry>{};
    final rawVariants = (root['variants'] as Map<String, dynamic>?) ?? const {};
    rawVariants.forEach((name, value) {
      final m = value as Map<String, dynamic>;
      final atlasList = ((m['atlases'] as List<dynamic>?) ?? const [])
          .map((e) => ((e as Map<String, dynamic>)['hash'] as String?) ?? '')
          .where((h) => h.isNotEmpty)
          .toList(growable: false);
      final skeletonList = ((m['skeletons'] as List<dynamic>?) ?? const []).cast<String>();
      variants[name] = SpineVariantEntry(
        atlasHashes: atlasList,
        skeletonHashes: skeletonList,
      );
    });

    return SpinePathTable(
      atlases: atlases,
      skeletons: skeletons,
      variants: variants,
      gameVersion: (root['gameVersion'] as String?) ?? '',
    );
  }

  /// 取某变体的身体图集（优先 characterAtlas，其次 faceAtlas）。
  SpineAtlasEntry? bodyAtlasOf(String variant) {
    final entry = variants[variant];
    if (entry == null) return null;
    for (final kind in const ['characterAtlas', 'faceAtlas']) {
      for (final hash in entry.atlasHashes) {
        final atlas = atlases[hash];
        if (atlas != null && atlas.kind == kind) return atlas;
      }
    }
    return null;
  }

  /// 取某变体的脸图集。
  SpineAtlasEntry? faceAtlasOf(String variant) {
    final entry = variants[variant];
    if (entry == null) return null;
    for (final hash in entry.atlasHashes) {
      final atlas = atlases[hash];
      if (atlas != null && atlas.kind == 'faceAtlas') return atlas;
    }
    return null;
  }

  /// 取战斗用素体骨架（`kind == base`）。战斗/移动动作都在素体骨架里，
  /// 所以预览战斗动作时优先用它，而不是服装骨架。
  SpineSkeletonEntry? baseSkeleton() {
    for (final s in skeletons.values) {
      if (s.kind == 'base') return s;
    }
    return null;
  }

  /// 按骨架 hash 取条目。
  SpineSkeletonEntry? skeletonOf(String hash) => skeletons[hash];

  /// 某变体关联的第一个骨架（通常是服装骨架）。
  SpineSkeletonEntry? skeletonOfVariant(String variant) {
    final entry = variants[variant];
    if (entry == null || entry.skeletonHashes.isEmpty) return null;
    return skeletons[entry.skeletonHashes.first];
  }

  /// 全表涉及的所有逻辑路径（骨架 + 图集 + 页），用于取数/统计。
  Iterable<String> allPaths() sync* {
    for (final s in skeletons.values) {
      if (s.path.isNotEmpty) yield s.path;
    }
    for (final a in atlases.values) {
      if (a.path.isNotEmpty) yield a.path;
      yield* a.pagePaths;
    }
  }

  /// 图集与其页贴图的完整取数清单。
  List<String> fetchListForVariant(String variant) {
    final result = <String>[];
    final atlas = bodyAtlasOf(variant);
    if (atlas != null) {
      result.add(atlas.path);
      result.addAll(atlas.pagePaths);
    }
    final face = faceAtlasOf(variant);
    if (face != null && face.hash != atlas?.hash) {
      result.add(face.path);
      result.addAll(face.pagePaths);
    }
    final skel = skeletonOfVariant(variant);
    if (skel != null) result.add(skel.path);
    return result;
  }

}

String _dirnameOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}
