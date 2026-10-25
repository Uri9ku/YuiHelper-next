import 'package:flutter/material.dart';

import '../../backend.dart';
import '../tokens.dart';
import '../widgets/foundation.dart';

/// C 任务领取（一级 Tab 页）。
///
/// 数据来自 `backend.claims.preview()` 的 `missionRows`：
/// `state == 3` 可领取、`state == 4` 已领取、其余进行中。
/// 使命表里没有中文任务名，所以标题如实显示「使命 #<missionId>」，
/// 不编造任务名、奖励或进度分母。
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.backend});

  final YuiHelperBackend backend;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  /// `state` 语义见 `domain/claim_plan.dart`：3 可领，4 已领，其它进行中。
  static const int _stateClaimed = 4;

  ClaimPreview? _preview;
  String? _previewError;
  AppErrorKind? _errorKind;
  bool _busy = false;
  bool _claiming = false;
  int _segment = 0;
  String? _notice;
  bool _noticeOk = false;

  /// 重置任务的写前倒计时（null = 没在进行）。
  int? _resetCountdown;
  bool _resetting = false;

  /// 单页最多渲染多少条使命：表里有 4513 行，不能一次性建 4513 个卡片。
  static const int _maxRowsPerPage = 60;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh({bool keepNotice = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _previewError = null;
      if (!keepNotice) _notice = null;
    });
    final result = await widget.backend.claims.preview();
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Ok<ClaimPreview>(:final value):
          _preview = value;
          _previewError = null;
        case Err<ClaimPreview>(:final error):
          _preview = null;
          _previewError = error.userMessage;
          _errorKind = error.kind;
      }
    });
  }

  /// 后端的使命领取只有整批接口：行内「领取」与底部按钮是同一提交。
  Future<void> _claimMissions() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _claiming = true;
      _notice = null;
    });
    final result = await widget.backend.claims.claimMissions();
    if (!mounted) return;
    final String message;
    final bool ok;
    switch (result) {
      case Ok<ClaimOutcome>(:final value):
        message = value.summary;
        ok = true;
      case Err<ClaimOutcome>(:final error):
        message = error.userMessage;
        ok = false;
    }
    setState(() {
      _busy = false;
      _claiming = false;
      _notice = message;
      _noticeOk = ok;
    });
    await _refresh(keepNotice: true);
  }

  int _bucketOf(Map<String, Object?> row) {
    final state = row['state'];
    if (state == kMissionStateClaimable) return 0;
    if (state == _stateClaimed) return 2;
    return 1;
  }

  /// 重置任务：确认 → 5 秒倒计时（请切回游戏）→ 写表 → 重新读取校验。
  ///
  /// 引擎的业务请求只在游戏前台处理；和换模型注入一样用倒计时把“用户切回游戏”
  /// 和“发出请求”错开。写表用的是 `user/push`，成功后按 pull 回来的事实报数。
  Future<void> _resetMissions({required bool restore}) async {
    if (_resetting || _resetCountdown != null || _claiming) return;
    final total = _preview?.missionRows.length;
    final confirmed = await _confirmReset(restore: restore, total: total);
    if (!confirmed || !mounted) return;

    setState(() {
      _notice = null;
      _resetting = true;
      _resetCountdown = 5;
    });
    for (var left = 5; left > 0; left--) {
      if (!mounted) return;
      setState(() => _resetCountdown = left);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() => _resetCountdown = null);

    final result = restore
        ? await widget.backend.claims.restoreMissions()
        : await widget.backend.claims.resetMissions();
    if (!mounted) return;
    final String message;
    final bool ok;
    switch (result) {
      case Ok<MissionResetOutcome>(:final value):
        ok = true;
        message = restore
            ? '已撤销重置：${value.updated} 条使命改回「已领取」'
                  '（当前可领取 ${value.claimableAfter} 条）。'
            : '已重置 ${value.updated} 条使命（当前可领取 ${value.claimableAfter} 条）；'
                  '奖励可以再次领取，点「一键领取」即可。';
      case Err<MissionResetOutcome>(:final error):
        ok = false;
        message = error.userMessage;
    }
    setState(() {
      _resetting = false;
      _notice = message;
      _noticeOk = ok;
    });
    await _refresh(keepNotice: true);
  }

  Future<bool> _confirmReset({
    required bool restore,
    required int? total,
  }) async {
    final countText = total == null ? '全部使命' : '全部 $total 条使命';
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        title: Text(
          restore ? '撤销重置？' : '重置所有任务？',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              restore
                  ? '会把当前所有「可领取」的使命改回「已领取」（state=4），'
                        '用于撤回上一次重置；已经领到的奖励不会退回。'
                  : '会把$countText重置为「可领取」，奖励可以再次领取。',
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 10),
            const Text(
              '· 需要切回游戏并保持前台，写入才会被处理\n'
              '· 游戏内任务界面不会自动刷新\n'
              '· 会直接改存档，建议先备份（root 可复制 state.json）',
              style: TextStyle(fontSize: 11, height: 1.8, color: AppColors.ink2),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: restore ? AppColors.accent : AppColors.danger,
            ),
            child: Text(restore ? '确认撤销' : '继续重置'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  List<Map<String, Object?>> _rowsOf(int segment) {
    final preview = _preview;
    if (preview == null) return const [];
    return [
      for (final row in preview.missionRows)
        if (_bucketOf(row) == segment) row,
    ];
  }

  String get _subtitle {
    if (_previewError != null) return '游戏未连接 · 点右上角刷新重试';
    final preview = _preview;
    if (preview == null) return '正在读取使命表…';
    return '使命 · 全部栏目 · 可领取 ${preview.missionClaimable} 项';
  }

  bool get _disconnected =>
      _errorKind == AppErrorKind.refused || _errorKind == AppErrorKind.timeout;

  String get _errorTitle => _disconnected ? '游戏未连接' : '读取使命表失败';

  String get _errorHint =>
      _disconnected ? '先打开游戏并保持前台，再点「重新连接」。' : '请稍后重试；如果一直失败，重启游戏后再试。';

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final List<Widget> body;
    if (_previewError != null) {
      body = _errorBody();
    } else if (preview == null) {
      body = _loadingBody();
    } else {
      body = _contentBody(preview);
    }
    return AppPageBody(
      children: [
        AppPageHeader(
          title: '任务领取',
          subtitle: _subtitle,
          trailing: IconCircleButton(
            icon: Icons.refresh_rounded,
            onPressed: _busy ? null : () => _refresh(),
          ),
        ),
        ...body,
        if (_notice != null) ...[
          WarningStrip(
            _notice!,
            tone: _noticeOk ? StripTone.success : StripTone.danger,
          ),
          const SizedBox(height: AppSpace.inner),
        ],
        const SizedBox(height: AppSpace.card),
        if (_resetCountdown != null) _resetCountdownCard(),
        _dangerCard(),
      ],
    );
  }

  List<Widget> _errorBody() => [
    WarningStrip(_previewError!, tone: StripTone.danger),
    const SizedBox(height: AppSpace.card),
    EmptyState(
      icon: _disconnected
          ? Icons.cloud_off_rounded
          : Icons.error_outline_rounded,
      title: _errorTitle,
      detail: _errorHint,
    ),
    const SizedBox(height: AppSpace.card),
    AppButton(
      label: _disconnected ? '重新连接' : '重新读取',
      onPressed: _busy ? null : () => _refresh(),
    ),
    const SizedBox(height: AppSpace.inner),
  ];

  List<Widget> _loadingBody() => [
    const SizedBox(height: AppSpace.page),
    const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
    const SizedBox(height: AppSpace.xs),
    const Center(child: Text('正在读取使命表…', style: AppText.caption)),
  ];

  List<Widget> _contentBody(ClaimPreview preview) {
    final claimable = preview.missionClaimable;
    final allRows = _rowsOf(_segment);
    final rows = allRows.take(_maxRowsPerPage).toList();
    final hidden = allRows.length - rows.length;
    return [
      SegmentedBar(
        items: [
          '可领取 $claimable',
          '进行中 ${preview.missionInProgress}',
          '已完成 ${preview.missionClaimed}',
        ],
        index: _segment,
        onChanged: (index) => setState(() => _segment = index),
      ),
      if (_segment == 0 && claimable > 0)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xs),
          child: Text(
            '「领取」会一次提交全部可领取的使命，领取后列表自动刷新。',
            style: AppText.caption.copyWith(color: AppColors.ink3),
          ),
        ),
      const SizedBox(height: AppSpace.card),
      if (rows.isEmpty)
        EmptyState(
          icon: _emptyIcon(_segment),
          title: _emptyTitle(_segment),
          detail: _emptyDetail(_segment),
        )
      else ...[
        for (final row in rows) _missionCard(row),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.inner),
            child: Text(
              '共 ${allRows.length} 条，当前只展示前 $_maxRowsPerPage 条；'
              '「一键领取」会处理全部可领取项。',
              style: AppText.caption.copyWith(color: AppColors.ink3),
            ),
          ),
      ],
      const SizedBox(height: AppSpace.card),
      AppButton(
        label: _claiming ? '正在领取…' : '一键领取 · $claimable 项',
        onPressed: _busy || claimable == 0 ? null : _claimMissions,
      ),
      const SizedBox(height: AppSpace.inner),
    ];
  }

  /// 危险操作卡：重置所有任务 / 撤销重置。
  ///
  /// 设计规范里 danger 色只用于破坏性确认场景，这里正好用上；
  /// 动作本身要游戏前台，所以用 5 秒倒计时把“切回游戏”与写入错开。
  /// 它**不依赖预览数据**：即使当前显示“游戏未连接”，也能先点重置、
  /// 切回游戏后由倒计时里的 pull+push 完成（这正是引擎后台不响应的兜底）。
  Widget _dangerCard() {
    final total = _preview?.missionRows.length;
    final disabled = _resetting || _resetCountdown != null || _claiming;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Expanded(child: Text('重置任务', style: AppText.cardTitle)),
              StatusChip('危险', tone: ChipTone.danger),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          const WarningStrip(
            '会直接修改游戏存档：把全部使命重置为「可领取」，奖励可以再次领取；'
            '游戏内任务界面不会自动刷新。',
            tone: StripTone.danger,
          ),
          const SizedBox(height: AppSpace.inner),
          const Text(
            '点重置后 5 秒内切回游戏并保持前台，写入完成后回来查看结果。'
            '建议先用 root 备份 state.json；可随时「撤销重置」把可领取改回已领取。',
            style: TextStyle(fontSize: 10, height: 1.6, color: AppColors.ink2),
          ),
          const SizedBox(height: AppSpace.inner),
          _DangerButton(
            label: _resetting
                ? '正在重置…'
                : total == null
                ? '重置所有任务（全部使命）'
                : '重置所有任务（$total 条）',
            onPressed: disabled ? null : () => _resetMissions(restore: false),
          ),
          const SizedBox(height: AppSpace.xs),
          TextButton(
            onPressed: disabled ? null : () => _resetMissions(restore: true),
            child: const Text('撤销重置（把可领取改回已领取）'),
          ),
        ],
      ),
    );
  }

  Widget _resetCountdownCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.card),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.inner,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: AppColors.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.inner),
        border: Border.all(color: AppColors.warningBorder),
      ),
      child: Row(
        children: [
          Text(
            '$_resetCountdown',
            style: const TextStyle(
              fontSize: 30,
              height: 1,
              fontWeight: FontWeight.w700,
              color: AppColors.warningInk,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '秒后开始重置',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warningInk,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '现在切回游戏，保持在前台',
                  style: TextStyle(fontSize: 10, color: AppColors.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _missionCard(Map<String, Object?> row) {
    final id = row['missionId'];
    final name = id is int ? '使命 #$id' : '使命 #未知';
    final state = row['state'];
    final claimable = state == kMissionStateClaimable;
    final claimed = state == _stateClaimed;

    final parts = <String>[
      claimable
          ? '已完成 · 可领取'
          : claimed
          ? '已领取'
          : '进行中',
    ];
    final progress = row['progress'];
    if (progress is num) parts.add('进度 $progress');
    final meta = parts.join(' · ');

    final Widget trailing;
    if (claimable) {
      trailing = _ClaimButton(
        label: '领取',
        onPressed: _busy ? null : _claimMissions,
      );
    } else if (claimed) {
      trailing = const StatusChip('已领取');
    } else {
      trailing = const StatusChip('进行中', tone: ChipTone.warning);
    }

    return TaskCard(
      name: name,
      meta: meta,
      mutedName: claimed,
      trailing: trailing,
    );
  }

  IconData _emptyIcon(int segment) => switch (segment) {
    0 => Icons.task_alt_rounded,
    1 => Icons.hourglass_empty_rounded,
    _ => Icons.inventory_2_outlined,
  };

  String _emptyTitle(int segment) => switch (segment) {
    0 => '没有可领取的使命',
    1 => '没有进行中的使命',
    _ => '还没有已领取的使命',
  };

  String _emptyDetail(int segment) => switch (segment) {
    0 => '使命都领完了，或者还没完成；完成后回到这里刷新。',
    1 => '当前所有使命都已完成或已领取。',
    _ => '领取成功后的使命会归档到这里。',
  };
}

/// 7.4 危险按钮：高 44，只在破坏性确认后使用（设计规范里 danger 的唯一用途）。
class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      height: 44,
      child: Material(
        color: enabled ? AppColors.danger : AppColors.disabledBg,
        borderRadius: BorderRadius.circular(AppRadius.inner),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppRadius.inner),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: enabled ? AppColors.surface : AppColors.ink3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 7.4 小按钮：高 26、圆角 12、蓝底白字（设计稿 btn-s）。
class _ClaimButton extends StatelessWidget {
  const _ClaimButton({required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  static const double _height = 26;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      height: _height,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          disabledBackgroundColor: AppColors.disabledBg,
          foregroundColor: AppColors.surface,
          disabledForegroundColor: AppColors.ink3,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.inner),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.inner),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: enabled ? AppColors.surface : AppColors.ink3,
          ),
        ),
      ),
    );
  }
}
