import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/spine/spine_animation_player.dart';
import '../../data/spine/spine_assembler.dart';
import '../../data/spine/spine_binary.dart';
import 'spine_painter.dart';

/// Spine 预览卡（S4 渲染 + S5 动作）：
/// 加载 → 真渲染 / 缺件如实提示 / 动画播放（播放/暂停/选择/循环）/ 皮肤切换 / 线框。
///
/// 与旧版纪律一致：**不做假模型**，也不假装能播没有的动作。
class SpinePreviewView extends StatefulWidget {
  const SpinePreviewView({
    super.key,
    required this.load,
    this.height = 280,
    this.background,
    this.showToolbar = true,
    this.autoPlay = true,
    this.preferAnimation = 'idle_battle',
  });

  /// 装配入口（数据来源由调用方决定：设备取数 / 本地文件）。
  final Future<SpineRenderBundle> Function() load;

  final double height;
  final Color? background;
  final bool showToolbar;

  /// 加载后是否自动播放第一条合适动画。
  final bool autoPlay;

  /// 自动播放时优先找的动画名前缀（找不到就用第一条）。
  final String preferAnimation;

  @override
  State<SpinePreviewView> createState() => _SpinePreviewViewState();
}

class _SpinePreviewViewState extends State<SpinePreviewView> with SingleTickerProviderStateMixin {
  Future<SpineRenderBundle>? _future;
  SpineRenderBundle? _bundle;
  SpineAnimationPlayer? _player;
  Object? _error;
  String? _skin;
  String? _animName;
  bool _wireframe = false;
  bool _loading = false;
  bool _playing = false;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  double _animTime = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _reload();
  }

  @override
  void didUpdateWidget(covariant SpinePreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.load != widget.load) _reload();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _loading = true;
      _error = null;
      _bundle = null;
      _player = null;
      _skin = null;
      _animName = null;
      _playing = false;
      _ticker?.stop();
      _lastTick = Duration.zero;
      _animTime = 0;
      _future = widget.load();
    });
    _future!.then((bundle) {
      if (!mounted) return;
      final player = SpineAnimationPlayer(bundle.data);
      String? animName;
      if (bundle.data.animations.isNotEmpty) {
        final preferred = bundle.data.animations
            .where((a) => a.name.startsWith(widget.preferAnimation))
            .toList();
        animName = (preferred.isNotEmpty ? preferred.first : bundle.data.animations.first).name;
        player.setAnimation(animName);
      }
      setState(() {
        _loading = false;
        _bundle = bundle;
        _player = player;
        _skin = bundle.skins.isEmpty ? null : bundle.skins.first.name;
        _animName = animName;
        _playing = widget.autoPlay && animName != null;
      });
      if (_playing) {
        _lastTick = Duration.zero;
        _ticker?.start();
      }
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    });
  }

  void _onTick(Duration elapsed) {
    final player = _player;
    if (!_playing || player == null || !player.hasAnimation) {
      _lastTick = elapsed;
      return;
    }
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == Duration.zero) return;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    setState(() {
      player.update(dt);
      _animTime = player.time;
    });
  }

  void _togglePlay() {
    final player = _player;
    if (player == null || !player.hasAnimation) return;
    setState(() {
      _playing = !_playing;
      if (_playing) {
        _lastTick = Duration.zero;
        _ticker?.start();
      } else {
        _ticker?.stop();
      }
    });
  }

  void _selectAnimation(String? name) {
    final player = _player;
    if (player == null) return;
    setState(() {
      _animName = name;
      player.setAnimation(name);
      _animTime = 0;
      _playing = widget.autoPlay && name != null;
      if (_playing) {
        _lastTick = Duration.zero;
        _ticker?.start();
      } else {
        _ticker?.stop();
      }
    });
  }

  SpineSkin _chosenSkin(SpineRenderBundle bundle) {
    for (final s in bundle.skins) {
      if (s.name == _skin) return s;
    }
    return bundle.skins.first;
  }

  List<SpineDrawBatch> _currentBatches(SpineRenderBundle bundle) {
    final player = _player;
    if (player == null || !player.hasAnimation) return bundle.batchesFor(_skin);
    return SpineBinder.bind(
      data: bundle.data,
      skin: _chosenSkin(bundle),
      pose: player.pose(),
      textures: bundle.textures,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bundle = _bundle;
    final batches = bundle == null ? const <SpineDrawBatch>[] : _currentBatches(bundle);
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
          Positioned.fill(child: _body(scheme, batches)),
          if (widget.showToolbar && bundle != null && !_loading && _error == null)
            _toolbar(scheme, bundle),
          if (bundle != null && !_loading && _error == null)
            Positioned(left: 8, bottom: 6, child: _statusLine(scheme, bundle)),
        ],
      ),
    );
  }

  Widget _statusLine(ColorScheme scheme, SpineRenderBundle bundle) {
    final player = _player;
    final parts = <String>[
      if (player?.hasAnimation == true)
        '${player!.animationName}  ${_animTime.toStringAsFixed(2)}/${player.duration.toStringAsFixed(2)}s'
            '${_playing ? '' : '（暂停）'}',
      if (!bundle.isComplete) '缺 ${bundle.missingPages.length} 页贴图',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
    );
  }

  Widget _body(ColorScheme scheme, List<SpineDrawBatch> batches) {
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
    if (batches.isEmpty) {
      return _hint(
        scheme,
        icon: Icons.layers_clear_outlined,
        title: '骨架已解析，但没有可绘制的部件',
        detail: '皮肤：${bundle.skins.map((s) => s.name).take(6).join(', ')}',
      );
    }
    return CustomPaint(
      painter: SpinePainter(
        batches: batches,
        background: Colors.transparent,
        wireframe: _wireframe,
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

  Widget _toolbar(ColorScheme scheme, SpineRenderBundle bundle) {
    final anims = bundle.data.animations;
    return Positioned(
      right: 8,
      top: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (anims.isNotEmpty)
            _pill(
              scheme,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _animName,
                  isDense: true,
                  style: TextStyle(fontSize: 10.5, color: scheme.onSurface),
                  items: anims
                      .map((a) => DropdownMenuItem(value: a.name, child: Text(a.name)))
                      .toList(),
                  onChanged: _selectAnimation,
                ),
              ),
            ),
          if (anims.isNotEmpty) const SizedBox(width: 6),
          if (anims.isNotEmpty)
            _iconToggle(
              scheme,
              icon: _playing ? Icons.pause : Icons.play_arrow,
              active: _playing,
              onTap: _togglePlay,
            ),
          if (anims.isNotEmpty) const SizedBox(width: 6),
          if (bundle.skins.length > 1)
            _pill(
              scheme,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _skin,
                  isDense: true,
                  style: TextStyle(fontSize: 10.5, color: scheme.onSurface),
                  items: bundle.skins
                      .map((s) => DropdownMenuItem(value: s.name, child: Text(s.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _skin = v),
                ),
              ),
            ),
          if (bundle.skins.length > 1) const SizedBox(width: 6),
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

  Widget _pill(ColorScheme scheme, {required Widget child}) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      constraints: const BoxConstraints(maxWidth: 150),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
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
