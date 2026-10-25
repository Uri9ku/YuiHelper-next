import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../data/spine/spine_assembler.dart';
import '../../data/spine/spine_path_table.dart';
import '../../data/spine/spine_preview_loader.dart';
import 'spine_preview_view.dart';

/// Spine 真模型预览页（S4）：从 `paths.json` 选变体 → 运行时取数 → 渲染。
///
/// 前置：root + 游戏已启动（骨架/图集走注入取数；页贴图走 mod 解码缓存）。
class SpinePreviewPage extends StatefulWidget {
  const SpinePreviewPage({super.key});

  @override
  State<SpinePreviewPage> createState() => _SpinePreviewPageState();
}

class _SpinePreviewPageState extends State<SpinePreviewPage> {
  SpinePathTable? _table;
  Object? _error;
  String _query = '';
  String? _selected;

  static final SpineAssetSource _source = DeviceSpineSource();

  @override
  void initState() {
    super.initState();
    _loadTable();
  }

  Future<void> _loadTable() async {
    try {
      final text = await rootBundle.loadString(SpinePathTable.assetPath);
      if (!mounted) return;
      setState(() => _table = SpinePathTable.parse(text));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Spine 模型预览')),
      body: _selected == null ? _list(scheme) : _detail(scheme),
    );
  }

  Widget _list(ColorScheme scheme) {
    if (_error != null) {
      return Center(child: Text('paths.json 读取失败：$_error'));
    }
    final table = _table;
    if (table == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final variants = table.variants.keys
        .where((v) => _query.isEmpty || v.toLowerCase().contains(_query.toLowerCase()))
        .toList()
      ..sort();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: '搜索变体名，如 kirito / edith / alice',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Text(
                '共 ${table.variantCount} 个变体 / ${table.atlasCount} 个图集 / ${table.skeletonCount} 个骨架路径',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.separated(
            itemCount: variants.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: scheme.outlineVariant),
            itemBuilder: (context, i) {
              final v = variants[i];
              final entry = table.variants[v]!;
              final hasSkel = entry.skeletonHashes.isNotEmpty ||
                  table.baseSkeleton() != null;
              return ListTile(
                dense: true,
                title: Text(v, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  '图集 ${entry.atlasHashes.length} 套'
                  '${hasSkel ? '' : ' · 无骨架路径'}',
                  style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
                ),
                trailing: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
                onTap: () => setState(() => _selected = v),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _detail(ColorScheme scheme) {
    final variant = _selected!;
    final table = _table!;
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, size: 18),
            onPressed: () => setState(() => _selected = null),
          ),
          title: Text(variant, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '取数中…（需要 root + 游戏已启动，约 40~60 秒）',
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SpinePreviewView(
              height: double.infinity,
              load: () => loadVariantPreview(
                table: table,
                variant: variant,
                source: _source,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
