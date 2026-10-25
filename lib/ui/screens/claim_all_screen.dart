import 'package:flutter/material.dart';

import '../../backend.dart';
import '../tokens.dart';
import '../widgets/foundation.dart';

/// F 领取所有奖励（二级 push 页）。
///
/// 顺序固定：使命 → 礼物盒 → 赛季 → 活动角色。
/// 到账数只认游戏回应；任一步失败立即停，绝不把前半段成功包装成「全部完成」。
class ClaimAllScreen extends StatefulWidget {
  const ClaimAllScreen({super.key, required this.backend});

  final YuiHelperBackend backend;

  @override
  State<ClaimAllScreen> createState() => _ClaimAllScreenState();
}

/// 四类渠道，声明顺序就是执行顺序（见 claim-all.html 03 渠道表）。
enum _Channel {
  missions('使命 · 全部栏目', '使命', '一般 · 每日 · 每周 · 活动 · 公会'),
  gifts('礼物盒', '礼物盒', '礼物盒表内全部行，一次领完'),
  season('赛季奖励', '赛季', '通行证 · 活动等级 · 逐轮核对到账'),
  event('活动角色奖励', '活动角色', '服务端按角色类型与进度判定');

  const _Channel(this.title, this.shortLabel, this.meta);

  final String title;
  final String shortLabel;
  final String meta;
}

enum _RowState { pending, running, success, empty, failed, skipped }

final class _RowResult {
  const _RowResult(this.state, [this.claimed = 0]);

  final _RowState state;
  final int claimed;
}

class _ClaimAllScreenState extends State<ClaimAllScreen> {
  static const List<_Channel> _channels = [
    _Channel.missions,
    _Channel.gifts,
    _Channel.season,
    _Channel.event,
  ];

  /// 与设计稿一致：正文 20 页边距，底部固定 CTA 上 10 / 下 18。
  static const EdgeInsets _bodyPadding = EdgeInsets.fromLTRB(
    AppSpace.page,
    0,
    AppSpace.page,
    AppSpace.page,
  );
  static const EdgeInsets _ctaPadding = EdgeInsets.fromLTRB(
    AppSpace.page,
    10,
    AppSpace.page,
    18,
  );

  final Map<_Channel, _RowResult> _rows = {
    for (final channel in _channels)
      channel: const _RowResult(_RowState.pending),
  };
  final Map<_Channel, int> _claimedByChannel = {
    for (final channel in _channels) channel: 0,
  };
  final List<String> _log = <String>[];

  ClaimPreview? _preview;
  AppErrorKind? _errorKind;
  String? _errorMessage;
  bool _loading = true;
  bool _running = false;
  bool _fullRun = false;
  bool _finished = false;
  bool _logOpen = true;
  int _step = -1;
  int _failedStep = -1;
  String? _failureMessage;
  int _claimedTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
      _errorKind = null;
    });
    final result = await widget.backend.claims.preview();
    if (!mounted) return;
    switch (result) {
      case Ok<ClaimPreview>(:final value):
        setState(() {
          _loading = false;
          _preview = value;
          _errorMessage = null;
          _errorKind = null;
          _running = false;
          _fullRun = false;
          _finished = false;
          _step = -1;
          _failedStep = -1;
          _failureMessage = null;
          _claimedTotal = 0;
          for (final channel in _channels) {
            _rows[channel] = const _RowResult(_RowState.pending);
            _claimedByChannel[channel] = 0;
          }
          _log.add(
            '${_stamp()}读取预览 · 使命可领 ${_formatCount(value.missionClaimable)}，'
            '礼物盒 ${_formatCount(value.giftCount)}，'
            '赛季 ${_formatCount(value.seasonCount)}，'
            '活动角色 ${_formatCount(value.eventCount)}',
          );
        });
      case Err<ClaimPreview>(:final error):
        setState(() {
          _loading = false;
          _preview = null;
          _errorMessage = error.userMessage;
          _errorKind = error.kind;
          _log.add('${_stamp()}读取失败 · ${error.userMessage}');
        });
    }
  }

  /// 领取后只刷新各渠道计数，不重置行结果（结果由本次领取决定）。
  Future<void> _refreshCounts() async {
    final result = await widget.backend.claims.preview();
    if (!mounted) return;
    switch (result) {
      case Ok<ClaimPreview>(:final value):
        setState(() => _preview = value);
      case Err<ClaimPreview>(:final error):
        setState(() => _log.add('${_stamp()}刷新预览失败 · ${error.userMessage}'));
    }
  }

  void _toggleLog() => setState(() => _logOpen = !_logOpen);

  Future<Result<ClaimOutcome>> _callChannel(_Channel channel) =>
      switch (channel) {
        _Channel.missions => widget.backend.claims.claimMissions(),
        _Channel.gifts => widget.backend.claims.claimGifts(),
        _Channel.season => widget.backend.claims.claimSeasonRewards(),
        _Channel.event => widget.backend.claims.claimEventCharacterRewards(),
      };

  /// 一键领取全部：严格按 使命 → 礼物盒 → 赛季 → 活动角色 顺序执行。
  ///
  /// [from] > 0 表示从失败的第 [from] 步重试，保留前面已到账的结果。
  Future<void> _claimAll({int from = 0}) async {
    if (_running || _preview == null) return;
    setState(() {
      _running = true;
      _fullRun = true;
      _finished = false;
      _step = from;
      _failedStep = -1;
      _failureMessage = null;
      if (from == 0) {
        _claimedTotal = 0;
        for (final channel in _channels) {
          _rows[channel] = const _RowResult(_RowState.pending);
          _claimedByChannel[channel] = 0;
        }
        _log.add('${_stamp()}开始领取 · 顺序 使命 → 礼物盒 → 赛季 → 活动角色');
      } else {
        for (var index = from; index < _channels.length; index++) {
          _rows[_channels[index]] = const _RowResult(_RowState.pending);
        }
        _log.add('${_stamp()}开始领取 · 从第 ${from + 1} 步继续');
      }
    });

    for (var step = from; step < _channels.length; step++) {
      final channel = _channels[step];
      if (!mounted) return;
      setState(() {
        _step = step;
        _rows[channel] = const _RowResult(_RowState.running);
        _log.add('${_stamp()}第 ${step + 1} / 4 步 · ${channel.title}');
      });

      final result = await _callChannel(channel);
      if (!mounted) return;

      switch (result) {
        case Ok<ClaimOutcome>(:final value):
          setState(() {
            _rows[channel] = value.claimedCount > 0
                ? _RowResult(_RowState.success, value.claimedCount)
                : const _RowResult(_RowState.empty);
            _claimedTotal += value.claimedCount;
            _claimedByChannel[channel] =
                (_claimedByChannel[channel] ?? 0) + value.claimedCount;
            _log.add(
              '${_stamp()}${channel.shortLabel}完成 · '
              '${value.claimedCount > 0 ? '到账 ${_formatCount(value.claimedCount)} 项' : '无内容'}',
            );
            for (final line in value.log) {
              _log.add('${_stamp()}$line');
            }
          });
        case Err<ClaimOutcome>(:final error):
          setState(() {
            _rows[channel] = const _RowResult(_RowState.failed);
            for (var index = step + 1; index < _channels.length; index++) {
              _rows[_channels[index]] = const _RowResult(_RowState.skipped);
            }
            _failedStep = step;
            _failureMessage =
                '第 ${step + 1} 步「${channel.title}」失败：${error.userMessage}';
            _running = false;
            _fullRun = false;
            _step = -1;
            _log.add(
              '${_stamp()}第 ${step + 1} / 4 步 · ${channel.shortLabel}失败，已停止',
            );
            _log.add('${_stamp()}${error.userMessage}');
          });
          return;
      }
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _fullRun = false;
      _step = -1;
      _finished = true;
      _log.add('${_stamp()}全部完成 · 共到账 ${_formatCount(_claimedTotal)} 项');
    });
    await _refreshCounts();
  }

  /// 单行领取（排障用）：只跑一个渠道，结束后刷新计数，不进入「全部完成」。
  Future<void> _claimSingle(_Channel channel) async {
    // 整轮失败时交给底部「从第 N 步重试」，避免单行领取把失败态冲掉。
    if (_running || _loading || _preview == null || _failedStep >= 0) return;
    setState(() {
      _running = true;
      _fullRun = false;
      _failureMessage = null;
      _step = -1;
      _rows[channel] = const _RowResult(_RowState.running);
      _log.add('${_stamp()}单独领取 · ${channel.title}');
    });

    final result = await _callChannel(channel);
    if (!mounted) return;
    switch (result) {
      case Ok<ClaimOutcome>(:final value):
        setState(() {
          _running = false;
          _step = -1;
          _claimedTotal += value.claimedCount;
          _claimedByChannel[channel] =
              (_claimedByChannel[channel] ?? 0) + value.claimedCount;
          _rows[channel] = value.claimedCount > 0
              ? _RowResult(_RowState.success, value.claimedCount)
              : const _RowResult(_RowState.empty);
          _log.add('${_stamp()}${channel.shortLabel} · ${value.summary}');
          for (final line in value.log) {
            _log.add('${_stamp()}$line');
          }
        });
        await _refreshCounts();
      case Err<ClaimOutcome>(:final error):
        setState(() {
          _running = false;
          _step = -1;
          _rows[channel] = const _RowResult(_RowState.failed);
          _failureMessage = '「${channel.title}」领取失败：${error.userMessage}';
          _log.add('${_stamp()}${channel.shortLabel}失败 · ${error.userMessage}');
        });
    }
  }

  int _available(_Channel channel, ClaimPreview preview) => switch (channel) {
    _Channel.missions => preview.missionClaimable,
    _Channel.gifts => preview.giftCount,
    _Channel.season => preview.seasonCount,
    _Channel.event => preview.eventCount,
  };

  int _totalAvailable(ClaimPreview preview) {
    var total = 0;
    for (final channel in _channels) {
      total += _available(channel, preview);
    }
    return total;
  }

  bool _isEmpty(ClaimPreview preview) =>
      !_running && _totalAvailable(preview) == 0 && _claimedTotal == 0;

  String _breakdown() {
    final parts = [
      for (final channel in _channels)
        '${channel.shortLabel} ${_formatCount(_claimedByChannel[channel] ?? 0)}',
    ];
    return parts.join(' · ');
  }

  String _successSummary() {
    final parts = [
      for (final channel in _channels)
        '${channel.shortLabel} ${_formatCount(_claimedByChannel[channel] ?? 0)}',
    ];
    return '共到账 ${_formatCount(_claimedTotal)} 项（${parts.join('，')}）。'
        '请重启游戏，客户端才会重新拉取存档。';
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final List<Widget> content;
    if (_errorMessage != null) {
      content = _errorContent();
    } else if (preview == null) {
      content = _loadingContent();
    } else {
      content = _content(preview);
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: AppNavBar(
                title: '领取所有奖励',
                onBack: () => Navigator.of(context).maybePop(),
                actionText: '日志',
                onAction: _toggleLog,
              ),
            ),
            Expanded(
              child: AppPageBody(padding: _bodyPadding, children: content),
            ),
            Padding(padding: _ctaPadding, child: _bottomButton(context)),
          ],
        ),
      ),
    );
  }

  List<Widget> _loadingContent() => [
    const SizedBox(height: AppSpace.page),
    const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
    const SizedBox(height: AppSpace.xs),
    const Center(child: Text('正在读取四类奖励表…', style: AppText.caption)),
  ];

  List<Widget> _errorContent() {
    final disconnected =
        _errorKind == AppErrorKind.refused ||
        _errorKind == AppErrorKind.timeout;
    return [
      const SizedBox(height: AppSpace.card),
      EmptyState(
        icon: disconnected
            ? Icons.cloud_off_rounded
            : Icons.error_outline_rounded,
        title: disconnected ? '游戏未连接' : '读取奖励表失败',
        detail: _errorMessage ?? '读取奖励表失败',
        height: 240,
      ),
      const SizedBox(height: AppSpace.card),
      Text(
        disconnected
            ? '先打开游戏并保持前台，再点底部「重新连接」；连不上时不会显示 0 项。'
            : '点底部「重新连接」重新读取；一直失败就重启游戏后再试。',
        style: AppText.caption.copyWith(color: AppColors.ink3),
      ),
      const SizedBox(height: AppSpace.card),
      if (_logOpen)
        LogPanel(
          lines: _log.reversed.toList(growable: false),
          title: '领取日志',
          trailing: Text('${_log.length} 条', style: AppText.caption),
        ),
    ];
  }

  List<Widget> _content(ClaimPreview preview) {
    final empty = _isEmpty(preview);
    final failure = _failureMessage;
    return [
      if (failure != null) ...[
        WarningStrip(failure, tone: StripTone.danger),
        const SizedBox(height: AppSpace.inner),
      ],
      _summaryCard(preview),
      if (_finished && _claimedTotal > 0) ...[
        WarningStrip(_successSummary(), tone: StripTone.success),
        const SizedBox(height: AppSpace.inner),
      ],
      if (empty) ...[
        const EmptyState(
          icon: Icons.inbox_outlined,
          title: '没有可领取的东西',
          detail: '四类奖励都没有可领取内容。先完成游戏里的目标，再回来刷新。',
          height: 180,
        ),
        const SizedBox(height: AppSpace.card),
      ],
      for (final channel in _channels) _channelRow(channel, preview),
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.card),
        child: Text(
          '点按渠道行可单独领取 · 顺序：使命 → 礼物盒 → 赛季 → 活动角色；任一步失败立即停止。',
          style: AppText.caption.copyWith(color: AppColors.ink3),
        ),
      ),
      if (_logOpen)
        LogPanel(
          lines: _log.reversed.toList(growable: false),
          title: '领取日志',
          trailing: Text('${_log.length} 条', style: AppText.caption),
          maxLines: 80,
        ),
    ];
  }

  Widget _summaryCard(ClaimPreview preview) {
    if (_running && _fullRun) {
      final index = _step < 0
          ? 0
          : (_step >= _channels.length ? _channels.length - 1 : _step);
      final channel = _channels[index];
      return AppCard(
        padding: const EdgeInsets.all(AppSpace.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(
              title: '领取进度',
              trailing: Text(
                '第 ${index + 1} / 4 步 · ${channel.title}',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: AppColors.accent,
                ),
              ),
            ),
            AppProgressBar(value: index / _channels.length),
            const SizedBox(height: AppSpace.xs),
            Text(
              '已到账 ${_formatCount(_claimedTotal)} 项 · 正在核对${channel.title}',
              style: AppText.caption,
            ),
          ],
        ),
      );
    }

    if (_finished) {
      return AppCard(
        padding: const EdgeInsets.all(AppSpace.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CardHeader(
              title: '领取结果',
              trailing: StatusChip('全部完成', tone: ChipTone.success),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(_formatCount(_claimedTotal), style: AppText.numericLarge),
                const SizedBox(width: AppSpace.x2s),
                const Text('项', style: AppText.caption),
                const Spacer(),
                const Text('已执行 4 / 4 步', style: AppText.caption),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(_breakdown(), style: AppText.caption),
          ],
        ),
      );
    }

    if (_failedStep >= 0) {
      final failed = _channels[_failedStep];
      return AppCard(
        padding: const EdgeInsets.all(AppSpace.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(
              title: '已到账',
              trailing: Text(
                '停在 ${_failedStep + 1} / 4 步',
                style: AppText.caption,
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(_formatCount(_claimedTotal), style: AppText.numericLarge),
                const SizedBox(width: AppSpace.x2s),
                const Text('项', style: AppText.caption),
                const Spacer(),
                Text('「${failed.shortLabel}」失败', style: AppText.caption),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(_breakdown(), style: AppText.caption),
          ],
        ),
      );
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpace.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardHeader(title: '本次可领取', trailing: StatusChip('4 类奖励')),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _formatCount(_totalAvailable(preview)),
                style: AppText.numericLarge,
              ),
              const SizedBox(width: AppSpace.x2s),
              const Text('项', style: AppText.caption),
            ],
          ),
          const SizedBox(height: AppSpace.inner),
          KpiRow(
            children: [
              KpiTile(
                label: '使命',
                value: _formatCount(preview.missionClaimable),
                valueSize: 12,
              ),
              KpiTile(
                label: '礼物盒',
                value: _formatCount(preview.giftCount),
                valueSize: 12,
              ),
              KpiTile(
                label: '赛季',
                value: _formatCount(preview.seasonCount),
                valueSize: 12,
              ),
              KpiTile(
                label: '活动角色',
                value: _formatCount(preview.eventCount),
                valueSize: 12,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            '数字来自任务表与三类奖励表的行数，实际到账以游戏回应为准。',
            style: AppText.caption.copyWith(color: AppColors.ink3),
          ),
        ],
      ),
    );
  }

  Widget _channelRow(_Channel channel, ClaimPreview preview) {
    final row = TaskCard(
      name: channel.title,
      meta: channel.meta,
      trailing: _statusChip(channel, preview),
    );
    if (_running ||
        _loading ||
        _failedStep >= 0 ||
        _available(channel, preview) == 0) {
      return row;
    }
    return GestureDetector(
      onTap: () => _claimSingle(channel),
      behavior: HitTestBehavior.opaque,
      child: row,
    );
  }

  Widget _statusChip(_Channel channel, ClaimPreview preview) {
    final result = _rows[channel] ?? const _RowResult(_RowState.pending);
    switch (result.state) {
      case _RowState.pending:
        if (_running && _fullRun) {
          return Text(
            '待执行',
            style: AppText.caption.copyWith(color: AppColors.ink3),
          );
        }
        final available = _available(channel, preview);
        if (available == 0) return const StatusChip('无内容');
        return StatusChip(
          '可领取 ${_formatCount(available)}',
          tone: ChipTone.accent,
        );
      case _RowState.running:
        return const StatusChip('领取中…', tone: ChipTone.accent);
      case _RowState.success:
        return StatusChip(
          '✓ ${_formatCount(result.claimed)}',
          tone: ChipTone.success,
        );
      case _RowState.empty:
        return const StatusChip('无内容');
      case _RowState.failed:
        return const StatusChip('失败', tone: ChipTone.danger);
      case _RowState.skipped:
        return Text(
          '未执行',
          style: AppText.caption.copyWith(color: AppColors.ink3),
        );
    }
  }

  Widget _bottomButton(BuildContext context) {
    if (_errorMessage != null) {
      return AppButton(
        label: '重新连接',
        onPressed: _loading ? null : () => _load(),
      );
    }
    final preview = _preview;
    if (preview == null) {
      return const AppButton(label: '读取中…', onPressed: null);
    }
    if (_loading) {
      return const AppButton(label: '读取中…', onPressed: null);
    }
    if (_running) {
      if (_fullRun) {
        final index = _step < 0 ? 0 : _step;
        return AppButton(label: '正在领取…（第 ${index + 1} / 4 步）', onPressed: null);
      }
      return const AppButton(label: '正在领取…', onPressed: null);
    }
    if (_finished) {
      if (_claimedTotal == 0) {
        return AppButton(
          label: '返回',
          primary: false,
          onPressed: () => Navigator.of(context).maybePop(),
        );
      }
      return AppButton(
        label: '完成',
        onPressed: () => Navigator.of(context).maybePop(),
      );
    }
    if (_failedStep >= 0) {
      return AppButton(
        label: '从第 ${_failedStep + 1} 步重试',
        onPressed: () => _claimAll(from: _failedStep),
      );
    }
    final total = _totalAvailable(preview);
    if (total == 0) {
      return AppButton(
        label: _claimedTotal > 0 ? '完成' : '返回',
        primary: _claimedTotal > 0,
        onPressed: () => Navigator.of(context).maybePop(),
      );
    }
    return AppButton(
      label: '一键领取全部 · ${_formatCount(total)} 项',
      onPressed: () => _claimAll(),
    );
  }

  static String _formatCount(int value) => value.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (match) => '${match[1]},',
  );

  static String _stamp() {
    final now = DateTime.now();
    return '${_pad2(now.hour)}:${_pad2(now.minute)}:${_pad2(now.second)} ';
  }

  static String _pad2(int value) => value.toString().padLeft(2, '0');
}
