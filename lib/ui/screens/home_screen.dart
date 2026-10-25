import 'package:flutter/material.dart';

import '../../backend.dart';
import '../tokens.dart';
import '../widgets/foundation.dart';
import 'claim_all_screen.dart';
import 'model_swap_screen.dart';
import 'param_screen.dart';

/// A 工作台：四张功能卡 + 分段快速定位。
///
/// 数据能取真就取真（领取预览 / 换模型环境），取不到就写「游戏未连接」，
/// 不在主页伪造成“已连接、数据正常”。
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.backend,
    required this.onSwitchTab,
  });

  final YuiHelperBackend backend;
  final ValueChanged<int> onSwitchTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _anchors = {
    0: GlobalKey(),
    1: GlobalKey(),
    2: GlobalKey(),
    3: GlobalKey(),
  };

  int _segment = 0;
  bool _busy = false;
  bool? _engineOk;
  ClaimPreview? _preview;
  String? _previewError;
  SwapStatus? _swap;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ping = await widget.backend.ping();
    final preview = await widget.backend.claims.preview();
    final swap = await widget.backend.modelSwap.status();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _engineOk = ping is Ok<bool>;
      if (preview case Ok<ClaimPreview>(:final value)) {
        _preview = value;
        _previewError = null;
      } else if (preview case Err<ClaimPreview>(:final error)) {
        _preview = null;
        _previewError = error.userMessage;
      }
      _swap = swap;
    });
  }

  Future<void> _claimMissions() async {
    setState(() => _busy = true);
    final result = await widget.backend.claims.claimMissions();
    if (!mounted) return;
    String message;
    switch (result) {
      case Ok<ClaimOutcome>(:final value):
        message = value.summary;
      case Err<ClaimOutcome>(:final error):
        message = error.userMessage;
    }
    setState(() => _busy = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
    await _refresh();
  }

  void _jumpTo(int segment) {
    setState(() => _segment = segment);
    final context = _anchors[segment]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: 0.05,
      );
    }
  }

  Future<void> _openQuickJump() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('快速跳转', style: AppText.cardTitle),
                const SizedBox(height: 6),
                Text('设计稿里的入口都列在这里', style: AppText.caption),
                const SizedBox(height: 12),
                for (final item in <(IconData, String, VoidCallback)>[
                  (Icons.tune_rounded, '数值修改', () => _push(const ParamScreen())),
                  (Icons.shield_outlined, '装配装备', () => widget.onSwitchTab(1)),
                  (Icons.checklist_rounded, '任务领取', () => widget.onSwitchTab(2)),
                  (Icons.view_in_ar_rounded, '修改模型', () => _push(ModelSwapScreen(backend: widget.backend))),
                  (Icons.redeem_rounded, '领取所有奖励', () => _push(ClaimAllScreen(backend: widget.backend))),
                  (Icons.settings_outlined, '设置 / 关于', () => widget.onSwitchTab(3)),
                ])
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(item.$1, size: 20, color: AppColors.accent),
                    title: Text(item.$2, style: const TextStyle(fontSize: 13)),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.ink3),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      item.$3();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final claimable = _preview?.missionClaimable;
    final subtitle = _engineOk == true
        ? '游戏已连接 · ${widget.backend.endpoint}'
        : '游戏未连接 · 点右上角刷新重试';
    return AppPageBody(
      scrollController: _scroll,
      children: [
        AppPageHeader(
          title: '工作台',
          subtitle: subtitle,
          trailing: IconCircleButton(
            icon: Icons.search_rounded,
            onPressed: _openQuickJump,
          ),
        ),
        SegmentedBar(
          items: const ['数值', '装备', '任务', '模型'],
          index: _segment,
          onChanged: _jumpTo,
        ),
        const SizedBox(height: AppSpace.card),

        // 1 数值修改
        AppCard(
          key: _anchors[0],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardHeader(
                title: '数值修改',
                actionText: '编辑参数',
                onAction: () => _push(const ParamScreen()),
              ),
              KpiRow(
                children: [
                  const KpiTile(label: '生命值', value: '9,999'),
                  const KpiTile(label: '金币', value: '99,999'),
                  const KpiTile(label: '攻击', value: '1,240', highlight: true),
                ],
              ),
            ],
          ),
        ),

        // 2 装配装备
        AppCard(
          key: _anchors[1],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardHeader(
                title: '装配装备',
                actionText: '查看',
                onAction: () => widget.onSwitchTab(1),
              ),
              Row(
                children: [
                  const Expanded(
                    child: _MiniSlot(icon: Icons.auto_awesome, name: '专属'),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: _MiniSlot(icon: Icons.auto_awesome, name: '专属'),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: _MiniSlot(icon: Icons.auto_awesome, name: '专属'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MiniSlot(
                      icon: Icons.add,
                      name: '空',
                      empty: true,
                      onTap: () => widget.onSwitchTab(1),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // 3 任务领取
        AppCard(
          key: _anchors[2],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardHeader(
                title: '任务领取',
                actionText: '全部领取',
                onAction: () => _push(ClaimAllScreen(backend: widget.backend)),
              ),
              Builder(
                builder: (context) {
                  final String meta;
                  if (_previewError != null) {
                    meta = '游戏未连接 · $_previewError';
                  } else if (_preview == null) {
                    meta = '读取中…';
                  } else {
                    meta =
                        '可领取 ${_preview!.missionClaimable} 项 · 进行中 ${_preview!.missionInProgress} 项 · 已领取 ${_preview!.missionClaimed} 项';
                  }
                  return TaskCard(
                    name: claimable == null || claimable == 0
                        ? '使命 · 全部栏目'
                        : '可领取使命 $claimable 项',
                    meta: meta,
                    trailing: StatusChip(
                      claimable == null
                          ? '未知'
                          : claimable == 0
                              ? '暂无'
                              : '$claimable 项',
                      tone: claimable == null
                          ? ChipTone.idle
                          : claimable == 0
                              ? ChipTone.idle
                              : ChipTone.success,
                    ),
                  );
                },
              ),
              AppButton(
                label: '领取全部使命',
                height: 38,
                onPressed: (claimable == null || claimable == 0)
                    ? null
                    : _claimMissions,
              ),
            ],
          ),
        ),

        // 4 修改模型
        AppCard(
          key: _anchors[3],
          padding: const EdgeInsets.all(AppSpace.card),
          onTap: () => _push(ModelSwapScreen(backend: widget.backend)),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.sub,
                  borderRadius: BorderRadius.circular(AppRadius.inner),
                ),
                child: const Icon(Icons.view_in_ar_rounded, size: 22, color: AppColors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('修改模型', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      _swap == null
                          ? '读取设备状态…'
                          : !_swap!.hasRoot
                              ? '需要 root · 当前未授权'
                              : !_swap!.gameRunning
                                  ? '先打开游戏，再启动注入'
                                  : _swap!.injectorRunning
                                      ? '注入器运行中 ${_swap!.injectorPid ?? ''}'
                                      : '游戏运行中 · 注入器未启动',
                      style: const TextStyle(fontSize: 10, color: AppColors.ink2),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.ink3),
            ],
          ),
        ),

        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      ],
    );
  }
}

class _MiniSlot extends StatelessWidget {
  const _MiniSlot({
    required this.icon,
    required this.name,
    this.empty = false,
    this.onTap,
  });

  final IconData icon;
  final String name;
  final bool empty;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 66,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: empty ? AppColors.sunken : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(color: empty ? AppColors.borderStrong : AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: empty ? const Color(0xFFB4BAC4) : AppColors.accent),
            const Spacer(),
            Text(
              name,
              style: TextStyle(fontSize: 8, color: empty ? AppColors.ink3 : AppColors.ink),
            ),
          ],
        ),
      ),
    );
  }
}
