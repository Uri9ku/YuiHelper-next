import 'package:flutter/material.dart';

import '../../data/spine/spine_assembler.dart';
import 'spine_painter.dart';

/// Spine 预览卡（S4）：加载 → 真渲染 / 缺件如实提示 / 线框切换 / 皮肤切换。
///
/// 与旧版纪律一致：**不做假模型**。没骨架、没图集、没页贴图时都给明确文案。
class SpinePreviewView extends StatefulWidget {
  const SpinePreviewView({
    super.key,
    required this.load,
    this.height = 280,
    this.background,
    this.showToolbar = true,
  });

  /// 装配入口（由调用方决定数据来源：设备取数 / 本地文件）。
  final Future<SpineRenderBundle> Function() load;

  final double height;
  final Color? background;
  final bool showToolbar;

  @override
  State<SpinePreviewView> createState() => _SpinePreviewViewState();
}

class _SpinePreviewViewState extends State<SpinePreviewView> {
  Future<SpineRenderBundle>? _future;
  SpineRenderBundle? _bundle;
  Object? _error;
  String? _skin;
  bool _wireframe = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant SpinePreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.load != widget.load) _reload();
  }

  void _reload() {
    setState(() {
      _loading = true;
      _error = null;
      _bundle = null;
      _skin = null;
      _future = widget.load();
    });
    _future!.then((bundle) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _bundle = bundle;
        _skin = bundle.skins.isEmpty ? null : bundle.skins.first.name;
      });
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: widget.background ?? scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(child: _body(scheme)),
          if (widget.showToolbar && _bundle != null) _toolbar(scheme),
        ],
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(height: 10),
            Text('正在取数并装配…', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }
    if (_error != null) {
      return _hint(
        scheme,
        icon: Icons.error_outline,
        title: '装配失败',
        detail: _error is SpineAssembleException
            ? (_error! as SpineAssembleException).message
            : '$_error',
      );
    }
    final bundle = _bundle;
    if (bundle == null) {
      return _hint(scheme, icon: Icons.hourglass_empty, title: '还没有数据', detail: '点「刷新」重新取数');
    }
    if (bundle.batches.isEmpty) {
      return _hint(
        scheme,
        icon: Icons.layers_clear_outlined,
        title: '骨架已解析，但没有可绘制的部件',
        detail: '皮肤：${bundle.skins.map((s) => s.name).take(6).join(', ')}',
      );
    }
    return CustomPaint(
      painter: SpinePainter(
        batches: bundle.batchesFor(_skin),
        background: Colors.transparent,
        wireframe: _wireframe,
      ),
      child: bundle.isComplete
          ? null
          : Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '缺 ${bundle.missingPages.length} 页贴图：${bundle.missingPages.take(2).join(', ')}'
                  '${bundle.missingPages.length > 2 ? ' …' : ''}（去游戏里打开该角色一次可补齐）',
                  style: TextStyle(fontSize: 10, color: scheme.error),
                ),
              ),
            ),
    );
  }

  Widget _hint(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String detail,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: scheme.outline),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(ColorScheme scheme) {
    final bundle = _bundle!;
    return Positioned(
      right: 8,
      top: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (bundle.skins.length > 1)
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _skin,
                  isDense: true,
                  style: TextStyle(fontSize: 11, color: scheme.onSurface),
                  items: bundle.skins
                      .map((s) => DropdownMenuItem(value: s.name, child: Text(s.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _skin = v),
                ),
              ),
            ),
          const SizedBox(width: 6),
          _iconToggle(
            scheme,
            icon: _wireframe ? Icons.texture : Icons.grid_on,
            active: _wireframe,
            onTap: () => setState(() => _wireframe = !_wireframe),
          ),
          const SizedBox(width: 6),
          _iconToggle(scheme, icon: Icons.refresh, onTap: _reload),
        ],
      ),
    );
  }

  Widget _iconToggle(
    ColorScheme scheme, {
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer : scheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Icon(icon, size: 15, color: active ? scheme.onPrimaryContainer : scheme.onSurface),
      ),
    );
  }
}
