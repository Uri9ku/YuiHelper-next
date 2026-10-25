import 'spine_assembler.dart';
import 'spine_path_table.dart';

/// 按 `paths.json` 里的变体装配一份可渲染模型（S4 的入口）。
///
/// 规则（与游戏行为一致）：
/// - 外观 = 身体图集（characterAtlas）+ 脸图集（faceAtlas）的页贴图；
/// - 骨架 = 变体关联的服装骨架；若没有则退到 `kind == base` 的战斗素体
///   （战斗/移动动作都在素体里，见主报告 §2.3）；
/// - 页贴图只从 mod 解码缓存取（`DataCache::read` 对 B 类返回空，见 §14.10）。
Future<SpineRenderBundle> loadVariantPreview({
  required SpinePathTable table,
  required String variant,
  required SpineAssetSource source,
}) async {
  final entry = table.variants[variant];
  if (entry == null) {
    throw SpineAssembleException(
      AssembleFailure.noSkeleton,
      'paths.json 里没有变体「$variant」（可能该服装骨架路径还没解出来，见 docs/_s1 §5）',
    );
  }

  final atlases = <SpineAtlasSpec>[];
  for (final hash in entry.atlasHashes) {
    final atlas = table.atlases[hash];
    if (atlas == null) continue;
    if (atlas.kind != 'characterAtlas' && atlas.kind != 'faceAtlas' && atlas.kind != 'weaponAtlas') {
      continue;
    }
    atlases.add(SpineAtlasSpec(atlasPath: atlas.path, pagePaths: atlas.pagePaths));
  }
  if (atlases.isEmpty) {
    throw SpineAssembleException(
      AssembleFailure.noAtlas,
      '变体「$variant」没有可用的图集路径（S1 未覆盖）',
    );
  }

  final skeleton = table.skeletonOfVariant(variant) ?? table.baseSkeleton();
  if (skeleton == null) {
    throw const SpineAssembleException(AssembleFailure.noSkeleton, '没有可用骨架（连素体骨架都没解出）');
  }

  // 设备来源：把骨架 + 图集一次性取回，减少注入次数
  if (source is DeviceSpineSource) {
    await source.prefetch([skeleton.path, ...atlases.map((a) => a.atlasPath)]);
  }

  return SpineAssembler(source).assembleMulti(
    skeletonPath: skeleton.path,
    atlases: atlases,
  );
}
