import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../backend.dart';
import '../../data/spine/spine_assembler.dart';
import '../../data/spine/spine_path_table.dart';
import '../../data/spine/spine_preview_loader.dart';
import '../spine/spine_preview_page.dart';
import '../spine/spine_preview_view.dart';
import '../tokens.dart';
import '../widgets/foundation.dart';

/// E 修改模型（二级页，从工作台或其它 Tab push 进来）。
///
/// 一条可检查的流程：环境体检 → 选 A/B（同骨架集）→ 骨骼线稿预览 →
/// 部署并启动注入（5 秒倒计时）→ 应用 / 关闭替换。全程只改内存规则，
/// 不写存档、不改游戏文件，停止注入即可还原。
class ModelSwapScreen extends StatefulWidget {
  const ModelSwapScreen({super.key, required this.backend});

  final YuiHelperBackend backend;

  @override
  State<ModelSwapScreen> createState() => _ModelSwapScreenState();
}

enum _Busy { none, loading, deploying, starting, applying, stopping, log }

class _ModelSwapScreenState extends State<ModelSwapScreen> {
  /// 枚举与名称表都读不到时用的示例候选（只用于把流程走通，不伪造游戏数据）。
  static const List<String> _fallbackCharacters = <String>[
    'kirito_cathedral',
    'eugeo_woodcutter',
  ];

  _Busy _busy = _Busy.none;

  SwapStatus? _status;
  bool _statusLoaded = false;

  List<String> _characters = const <String>[];
  Map<String, String> _names = const <String, String>{};
  Map<String, String> _variantBones = const <String, String>{};
  bool _usingFallback = false;

  String? _fromId;
  String? _toId;

  String? _errorMessage;
  String? _successMessage;

  bool _applied = false;
  bool _offsetMismatch = false;

  List<String> _logLines = const <String>[];
  String? _logMeta;
  String? _logReadError;

  List<String> _deploySteps = const <String>[];

  int? _countdown;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 读取
  // ------------------------------------------------------------------

  Future<SwapStatus?> _readStatus() async {
    try {
      return await widget.backend.modelSwap.status();
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshAll() async {
    if (_busy != _Busy.none || _countdown != null) return;
    setState(() {
      _busy = _Busy.loading;
      _errorMessage = null;
      _successMessage = null;
    });

    final statusFuture = _readStatus();
    final enumFuture = widget.backend.modelSwap.readEnum();
    final namesFuture = widget.backend.modelSwap.readNames();
    final bonesFuture = widget.backend.modelSwap.readVariantBones();
    final logFuture = widget.backend.modelSwap.logSnapshot();

    final status = await statusFuture;
    final enumResult = await enumFuture;
    final namesResult = await namesFuture;
    final bonesResult = await bonesFuture;
    final logResult = await logFuture;
    if (!mounted) return;

    final candidates = <String>{};
    if (enumResult case Ok<ModelEnumSnapshot>(:final value)) {
      candidates.addAll(value.characters);
    }
    if (namesResult case Ok<Map<String, String>>(:final value)) {
      candidates.addAll(value.keys);
    }
    final sorted = candidates.toList()..sort();

    setState(() {
      _busy = _Busy.none;
      _status = status;
      _statusLoaded = true;
      _usingFallback = sorted.isEmpty;
      _characters = sorted.isEmpty ? _fallbackCharacters : sorted;
      if (namesResult case Ok<Map<String, String>>(:final value)) {
        _names = value;
      }
      if (bonesResult case Ok<Map<String, String>>(:final value)) {
        _variantBones = value;
      }
      _applyLogResult(logResult);
    });
  }

  Future<void> _reloadStatusAndLog() async {
    final status = await _readStatus();
    final logResult = await widget.backend.modelSwap.logSnapshot();
    if (!mounted) return;
    setState(() {
      _status = status;
      _statusLoaded = true;
      _applyLogResult(logResult);
    });
  }

  Future<void> _loadLog() async {
    if (_busy != _Busy.none) return;
    setState(() => _busy = _Busy.log);
    final result = await widget.backend.modelSwap.logSnapshot();
    if (!mounted) return;
    setState(() {
      _busy = _Busy.none;
      _applyLogResult(result);
    });
  }

  void _applyLogResult(Result<String> result) {
    switch (result) {
      case Ok<String>(:final value):
        _applyLog(value);
      case Err<String>(:final error):
        _logLines = const <String>[];
        _logMeta = null;
        _logReadError = error.userMessage;
    }
  }

  /// 一次 su 调用带回「日志尾部 + 模型改写数 + 偏移错位数 + 日志字节数」。
  void _applyLog(String raw) {
    final sections = raw.split('@@@COUNTS');
    final body = sections.isEmpty ? raw : sections.first;
    _logLines = <String>[
      for (final line in body.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    _logReadError = null;

    var models = '';
    var mismatches = '0';
    var bytes = '';
    if (sections.length > 1) {
      final counts = <String>[
        for (final line in sections[1].split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];
      if (counts.isNotEmpty) models = counts[0];
      if (counts.length > 1) mismatches = counts[1];
      if (counts.length > 2) bytes = counts[2];
    }
    final mismatchValue = int.tryParse(mismatches) ?? 0;
    _offsetMismatch = mismatchValue > 0;
    final pieces = <String>[
      if (models.isNotEmpty) '模型改写 $models 次',
      if (mismatchValue > 0) '偏移错位 $mismatchValue 次',
      if (bytes.isNotEmpty) '$bytes 字节',
    ];
    _logMeta = pieces.isEmpty ? null : pieces.join(' · ');
  }

  // ------------------------------------------------------------------
  // 动作
  // ------------------------------------------------------------------

  /// 部署注入器 → 5 秒倒计时 → 启动注入。倒计时期间 CTA 全程禁用。
  Future<void> _deployAndStart() async {
    if (_busy != _Busy.none || _countdown != null) return;
    setState(() {
      _busy = _Busy.deploying;
      _errorMessage = null;
      _successMessage = null;
      _deploySteps = const <String>[];
    });
    final result = await widget.backend.modelSwap.deploy();
    if (!mounted) return;
    switch (result) {
      case Ok<List<String>>(:final value):
        setState(() {
          _busy = _Busy.none;
          _deploySteps = value;
          _successMessage = '部署完成，5 秒后开始注入。现在切回游戏，保持在前台。';
          _countdown = 5;
        });
        _startCountdown();
      case Err<List<String>>(:final error):
        setState(() {
          _busy = _Busy.none;
          _errorMessage = error.userMessage;
        });
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final next = (_countdown ?? 0) - 1;
      if (next <= 0) {
        timer.cancel();
        setState(() => _countdown = null);
        _startInjector();
      } else {
        setState(() => _countdown = next);
      }
    });
  }

  Future<void> _startInjector() async {
    if (_busy != _Busy.none) return;
    setState(() => _busy = _Busy.starting);
    final result = await widget.backend.modelSwap.start();
    if (!mounted) return;
    switch (result) {
      case Ok<String>(:final value):
        setState(() {
          _busy = _Busy.none;
          _successMessage = value;
        });
      case Err<String>(:final error):
        setState(() {
          _busy = _Busy.none;
          _errorMessage = error.userMessage;
        });
    }
    await _reloadStatusAndLog();
  }

  Future<void> _applyRule() async {
    final from = _fromId;
    final to = _toId;
    if (from == null || to == null) return;

    final check = validateModelIds(from, to);
    if (check is Err<void>) {
      setState(() => _errorMessage = check.error.userMessage);
      return;
    }
    if (_crossSkeleton) {
      setState(
        () => _errorMessage =
            '两个角色不在同一骨架集（${_boneOf(from)} 与 ${_boneOf(to)}），会缺骨架、比例错乱。',
      );
      return;
    }

    setState(() {
      _busy = _Busy.applying;
      _errorMessage = null;
      _successMessage = null;
    });
    final result = await widget.backend.modelSwap.applyRule(
      ModelSwapRule(from: from, to: to),
    );
    if (!mounted) return;
    if (result is Ok<void>) {
      setState(() {
        _busy = _Busy.none;
        _applied = true;
        _successMessage =
            '替换已生效：${_displayName(from)} → ${_displayName(to)}。已加载的模型需重进场景刷新。';
      });
    } else if (result is Err<void>) {
      setState(() {
        _busy = _Busy.none;
        _errorMessage = result.error.userMessage;
      });
    }
    await _reloadStatusAndLog();
  }

  Future<void> _closeRule() async {
    if (_busy != _Busy.none) return;
    setState(() {
      _busy = _Busy.applying;
      _errorMessage = null;
      _successMessage = null;
    });
    final result = await widget.backend.modelSwap.applyRule(null);
    if (!mounted) return;
    if (result is Ok<void>) {
      setState(() {
        _busy = _Busy.none;
        _applied = false;
        _successMessage = '已关闭替换：规则已清空。已加载的模型需重进场景才恢复原样。';
      });
    } else if (result is Err<void>) {
      setState(() {
        _busy = _Busy.none;
        _errorMessage = result.error.userMessage;
      });
    }
    await _reloadStatusAndLog();
  }

  Future<void> _stopInjector() async {
    if (_busy != _Busy.none || _countdown != null) return;
    setState(() {
      _busy = _Busy.stopping;
      _errorMessage = null;
      _successMessage = null;
    });
    final result = await widget.backend.modelSwap.stop();
    if (!mounted) return;
    if (result is Ok<void>) {
      setState(() {
        _busy = _Busy.none;
        _applied = false;
        _successMessage = '已停止注入，本次替换已还原。';
      });
    } else if (result is Err<void>) {
      setState(() {
        _busy = _Busy.none;
        _errorMessage = result.error.userMessage;
      });
    }
    await _reloadStatusAndLog();
  }

  // ------------------------------------------------------------------
  // 角色选择
  // ------------------------------------------------------------------

  Future<void> _pick(bool forA) async {
    if (_applied || _busy != _Busy.none || _countdown != null) return;
    final candidates = _candidates(forA);
    if (candidates.isEmpty) {
      setState(() {
        _errorMessage = forA
            ? '还没有可选的候选角色：先打开游戏、启动注入让它收集一次枚举，或点右上角刷新。'
            : '没有和角色 A 同一骨架集的其他角色，换一个 A 再试。';
      });
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      builder: (sheetContext) => _CharacterPickerSheet(
        title: forA ? '选择角色 A' : '选择角色 B',
        subtitle: forA
            ? '候选来自游戏枚举与名称表${_usingFallback ? '（枚举为空，已回退示例候选）' : ''}'
            : '只列出与 A 同一骨架集（${_boneOf(_fromId) ?? '未收录'}）的角色',
        characters: candidates,
        names: _names,
        bones: _variantBones,
        selectedId: forA ? _fromId : _toId,
        onPick: (id) => Navigator.of(sheetContext).pop(id),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (forA) {
        _fromId = picked;
        if (_toId == picked) _toId = null;
      } else {
        _toId = picked;
      }
      _errorMessage = null;
      _successMessage = null;
    });
  }

  List<String> _candidates(bool forA) {
    final pool = _characters;
    if (forA) return pool;
    final from = _fromId;
    final bone = _boneOf(from);
    if (from == null || bone == null) {
      return <String>[
        for (final id in pool)
          if (id != from) id,
      ];
    }
    return <String>[
      for (final id in pool)
        if (id != from && _boneOf(id) == bone) id,
    ];
  }

  String? _boneOf(String? id) {
    if (id == null) return null;
    final bone = _variantBones[id];
    if (bone == null || bone.isEmpty) return null;
    return bone;
  }

  bool get _sameBoneSet {
    final a = _boneOf(_fromId);
    final b = _boneOf(_toId);
    return a != null && b != null && a == b;
  }

  bool get _crossSkeleton {
    final a = _boneOf(_fromId);
    final b = _boneOf(_toId);
    return a != null && b != null && a != b;
  }

  String _displayName(String? id) {
    if (id == null) return '—';
    return _names[id] ?? id;
  }

  // ------------------------------------------------------------------
  // CTA / 提示
  // ------------------------------------------------------------------

  String? get _busyLabel => switch (_busy) {
    _Busy.loading => '正在读取设备状态…',
    _Busy.deploying => '正在部署注入器…',
    _Busy.starting => '正在启动注入…',
    _Busy.applying => '正在写入规则…',
    _Busy.stopping => '正在停止注入…',
    _Busy.log => '正在读取日志…',
    _Busy.none => null,
  };

  String get _ctaLabel {
    if (_countdown != null) return '$_countdown 秒后开始注入…';
    final busyLabel = _busyLabel;
    if (busyLabel != null) return busyLabel;
    final status = _status;
    if (status == null) {
      return _statusLoaded ? '无法读取设备状态' : '正在读取设备状态…';
    }
    if (!status.hasRoot) return '需要 root';
    if (!status.gameRunning) return '请先启动游戏';
    if (_offsetMismatch) return '请先停用本功能';
    if (!status.injectorRunning) return '部署并启动注入';
    if (_applied) return '关闭替换';
    return '应用替换';
  }

  bool get _ctaEnabled {
    if (_busy != _Busy.none || _countdown != null) return false;
    final status = _status;
    if (status == null) return false;
    if (!status.hasRoot || !status.gameRunning || _offsetMismatch) return false;
    if (!status.injectorRunning) return true;
    if (_applied) return true;
    if (_fromId == null || _toId == null) return false;
    if (_crossSkeleton) return false;
    return true;
  }

  VoidCallback? get _ctaAction {
    if (!_ctaEnabled) return null;
    final status = _status;
    if (status == null) return null;
    if (!status.injectorRunning) return _deployAndStart;
    if (_applied) return _closeRule;
    return _applyRule;
  }

  IconData get _ctaIcon {
    final status = _status;
    if (status != null && !status.injectorRunning) {
      return Icons.play_arrow_rounded;
    }
    if (_applied) return Icons.undo_rounded;
    return Icons.check_rounded;
  }

  String get _envHint {
    if (!_statusLoaded) return '正在读取设备与游戏状态…';
    final status = _status;
    if (status == null) return '读取设备状态失败，请点右上角刷新重试。';
    if (!status.hasRoot) return '没有拿到 root 权限（未授权或设备未 root），换模型用不了；其他功能不受影响。';
    if (!status.gameRunning) return '没找到游戏进程，先把游戏打开再回来。';
    if (!status.injectorRunning) return '注入器未启动，先部署并启动它。';
    return '换的是「角色这个 id」的模型：看板 / 战斗队伍 / 剧情演出会一起变。';
  }

  // ------------------------------------------------------------------
  // build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: AppNavBar(
                title: '修改模型',
                onBack: () => Navigator.of(context).pop(),
                actionText: '刷新',
                onAction: _busy == _Busy.none && _countdown == null
                    ? _refreshAll
                    : null,
              ),
            ),
            Expanded(
              child: AppPageBody(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.page,
                  0,
                  AppSpace.page,
                  AppSpace.page,
                ),
                children: <Widget>[
                  _buildEnvCard(),
                  const SizedBox(height: AppSpace.xs),
                  Text(_envHint, style: AppText.caption),
                  const SizedBox(height: AppSpace.card),

                  if (_statusLoaded && _status == null) ...[
                    const WarningStrip(
                      '读取设备状态失败，请点右上角刷新重试。',
                      tone: StripTone.danger,
                    ),
                    const SizedBox(height: AppSpace.card),
                  ],

                  if (_offsetMismatch) ...[
                    const WarningStrip(
                      '钩子偏移对不上：游戏可能已更新，换模型不会生效。请先停用本功能',
                      tone: StripTone.danger,
                    ),
                    const SizedBox(height: AppSpace.card),
                  ],

                  if (_errorMessage != null) ...[
                    WarningStrip(_errorMessage!, tone: StripTone.danger),
                    const SizedBox(height: AppSpace.card),
                  ],

                  if (_successMessage != null) ...[
                    WarningStrip(_successMessage!, tone: StripTone.success),
                    const SizedBox(height: AppSpace.card),
                  ],

                  if (_crossSkeleton) ...[
                    WarningStrip(
                      '两个角色不在同一骨架集（${_boneOf(_fromId)} 与 ${_boneOf(_toId)}），'
                      '会缺骨架、比例错乱。',
                      tone: StripTone.warning,
                    ),
                    const SizedBox(height: AppSpace.card),
                  ],

                  if (_countdown != null) ...[
                    _CountdownCard(seconds: _countdown!),
                    const SizedBox(height: AppSpace.card),
                  ],

                  if (_deploySteps.isNotEmpty) ...[
                    _DeployStepsCard(steps: _deploySteps),
                    const SizedBox(height: AppSpace.card),
                  ],

                  _buildMappingCard(),
                  _buildPreviewCard(),
                  const SizedBox(height: AppSpace.xs),
                  const Text(
                    '改规则不会热重载已加载的模型：要重进场景或重启游戏。',
                    style: AppText.caption,
                  ),
                  const SizedBox(height: AppSpace.card),

                  LogPanel(
                    lines: _logLines,
                    title: '注入日志',
                    emptyText: _logReadError ?? '还没有注入日志，启动注入后这里会出现记录。',
                    maxLines: 10,
                    trailing: GestureDetector(
                      onTap: _busy == _Busy.none ? _loadLog : null,
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        _busy == _Busy.log ? '读取中…' : '刷新',
                        style: AppText.caption.copyWith(
                          color: _busy == _Busy.log
                              ? AppColors.ink3
                              : AppColors.accent,
                        ),
                      ),
                    ),
                  ),

                  if (_logMeta != null) ...[
                    const SizedBox(height: AppSpace.x2s),
                    Text(_logMeta!, style: AppText.micro),
                  ],

                  const SizedBox(height: AppSpace.xs),
                  const Text('不写存档、不改游戏文件；停止注入即完全还原。', style: AppText.caption),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                AppSpace.inner,
                AppSpace.page,
                AppSpace.page,
              ),
              child: AppButton(
                label: _ctaLabel,
                icon: _ctaIcon,
                onPressed: _ctaAction,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEnvCard() {
    final status = _status;
    final loaded = _statusLoaded;

    final bool? rootState = !loaded
        ? null
        : (status == null ? null : status.hasRoot);
    final String rootValue = !loaded
        ? '读取中'
        : (status == null ? '未知' : (status.hasRoot ? '已授权' : '未授权'));

    final bool? gameState = !loaded
        ? null
        : (status == null ? null : status.gameRunning);
    final String gameValue = !loaded
        ? '读取中'
        : (status == null
              ? '未知'
              : (status.gameRunning
                    ? '运行中 · ${status.gamePid ?? '—'}'
                    : '未检测到进程'));

    final bool? injectorState = !loaded
        ? null
        : (status == null ? null : (status.injectorRunning ? true : null));
    final String injectorValue = !loaded
        ? '读取中'
        : (status == null
              ? '未知'
              : (status.injectorRunning
                    ? '运行中 · ${status.injectorPid ?? '—'}'
                    : '未启动'));

    final canStop =
        loaded &&
        status != null &&
        status.injectorRunning &&
        _busy == _Busy.none &&
        _countdown == null;

    return AppCard(
      padding: const EdgeInsets.all(AppSpace.xs),
      child: Column(
        children: <Widget>[
          CardHeader(
            title: '环境体检',
            actionText: _busy == _Busy.stopping ? '停止中…' : '停止注入',
            onAction: canStop ? _stopInjector : null,
          ),
          EnvRow(label: 'root', state: rootState, value: rootValue),
          EnvRow(label: '游戏进程', state: gameState, value: gameValue),
          EnvRow(label: '注入器', state: injectorState, value: injectorValue),
        ],
      ),
    );
  }

  Widget _buildMappingCard() {
    final interactive = !_applied && _busy == _Busy.none && _countdown == null;
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.inner),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CardHeader(title: '替换映射', trailing: _mappingChip()),
          MapRow(
            badge: 'A',
            name: _fromId == null ? '未选择角色 A' : _displayName(_fromId),
            id: _fromId ?? '—',
            onTap: interactive ? () => _pick(true) : null,
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpace.inner,
              top: AppSpace.x2s,
              bottom: AppSpace.x2s,
            ),
            child: Text(_applied ? '↓ 已替换为' : '↓ 替换成', style: AppText.caption),
          ),
          MapRow(
            badge: 'B',
            name: _toId == null ? '未选择角色 B' : _displayName(_toId),
            id: _toId ?? '—',
            onTap: interactive ? () => _pick(false) : null,
          ),
          if (_sameBoneSet) ...[
            const SizedBox(height: AppSpace.xs),
            Text('只显示同一骨架集（${_boneOf(_fromId)}）的角色。', style: AppText.caption),
          ],
          if (_applied) ...[
            const SizedBox(height: AppSpace.xs),
            const Text('影响范围：主界面看板 / 战斗队伍 / 剧情演出', style: AppText.caption),
          ],
        ],
      ),
    );
  }

  Widget _mappingChip() {
    if (_applied) return const StatusChip('生效中', tone: ChipTone.success);
    if (_fromId == null || _toId == null) return const StatusChip('未选择');
    if (_crossSkeleton) {
      return const StatusChip('跨骨架集', tone: ChipTone.danger);
    }
    if (_sameBoneSet) {
      return const StatusChip('同一骨架集', tone: ChipTone.success);
    }
    return const StatusChip('骨架集未收录');
  }

  /// S1 产出的路径表（1 MB 级 JSON，进程内只解析一次）。
  static SpinePathTable? _spineTable;

  /// E 页预览：按当前选中的角色 A 变体装配真模型。
  ///
  /// 骨架/图集走注入取数（A 类）；页贴图走 mod 解码缓存（B 类）。
  /// 前置：root + 游戏已启动；缺件由 SpinePreviewView 如实提示，不画假模型。
  Future<SpineRenderBundle> _loadSpinePreview(String variant) async {
    final table = _spineTable ??=
        SpinePathTable.parse(await rootBundle.loadString(SpinePathTable.assetPath));
    return loadVariantPreview(
      table: table,
      variant: variant,
      source: DeviceSpineSource(),
    );
  }

  Widget _buildPreviewCard() {
    final from = _fromId;
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.inner),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CardHeader(
            title: '模型预览',
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                from ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono,
              ),
            ),
          ),
          Container(
            height: 150,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.sub,
              borderRadius: BorderRadius.circular(AppRadius.inner),
              border: Border.all(color: AppColors.border),
            ),
            child: from == null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Icon(
                        Icons.view_in_ar_outlined,
                        size: 26,
                        color: AppColors.ink3,
                      ),
                      const SizedBox(height: AppSpace.xs),
                      const Text('还没有选择角色 A', style: AppText.body),
                      const SizedBox(height: AppSpace.x2s),
                      const Text(
                        '选好 A 后在这里显示骨骼线稿（示意）',
                        style: AppText.micro,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  )
                : SpinePreviewView(
                    load: () => _loadSpinePreview(from),
                    height: 150,
                    background: AppColors.sub,
                    showToolbar: false,
                  ),
          ),
          const SizedBox(height: AppSpace.xs),
          Row(
            children: <Widget>[
              Expanded(
                child: Container(
                  height: 28,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                  decoration: BoxDecoration(
                    color: AppColors.sub,
                    borderRadius: BorderRadius.circular(AppRadius.inner),
                  ),
                  child: const Text('默认皮肤', style: AppText.caption),
                ),
              ),
              const SizedBox(width: AppSpace.xs),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.inner),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Icon(
                  Icons.view_in_ar_rounded,
                  size: 14,
                  color: AppColors.ink2,
                ),
              ),
              const SizedBox(width: AppSpace.xs),
              const Text('实时取数', style: AppText.micro),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '预览从游戏运行时取数（需 root + 游戏在前台）；缺骨架/缺贴图会如实提示，不画假模型。',
            style: AppText.micro,
          ),
          const SizedBox(height: AppSpace.x2s),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SpinePreviewPage()),
              ),
              child: const Text('浏览全部变体（真渲染）', style: AppText.caption),
            ),
          ),
        ],
      ),
    );
  }
}

/// 5 秒倒计时：大号秒数 + 「现在切回游戏，保持前台」。
class _CountdownCard extends StatelessWidget {
  const _CountdownCard({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.inner),
      decoration: BoxDecoration(
        color: AppColors.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.inner),
        border: Border.all(color: AppColors.warningBorder),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '$seconds',
            style: AppText.numericLarge.copyWith(color: AppColors.warningInk),
          ),
          const SizedBox(width: AppSpace.inner),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '秒后开始注入',
                  style: AppText.cardTitle.copyWith(
                    color: AppColors.warningInk,
                  ),
                ),
                const SizedBox(height: AppSpace.x2s),
                const Text('现在切回游戏，保持在前台', style: AppText.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 部署进度：逐行展示 `deploy()` 返回的步骤日志。
class _DeployStepsCard extends StatelessWidget {
  const _DeployStepsCard({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CardHeader(
            title: '部署进度',
            trailing: Text(
              '${steps.length} / ${steps.length} 完成',
              style: AppText.micro,
            ),
          ),
          for (final step in steps) _StepRow(step),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.x2s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 4,
            height: 4,
            margin: const EdgeInsets.only(top: AppSpace.x2s),
            decoration: const BoxDecoration(
              color: AppColors.successInk,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              text,
              style: AppText.mono.copyWith(color: AppColors.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// 角色选择器：候选来自枚举 + 名称表，行的右侧标出骨架集，跨集一眼可见。
class _CharacterPickerSheet extends StatelessWidget {
  const _CharacterPickerSheet({
    required this.title,
    required this.subtitle,
    required this.characters,
    required this.names,
    required this.bones,
    required this.selectedId,
    required this.onPick,
  });

  final String title;
  final String subtitle;
  final List<String> characters;
  final Map<String, String> names;
  final Map<String, String> bones;
  final String? selectedId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            AppSpace.pad,
            AppSpace.page,
            AppSpace.inner,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: AppText.cardTitle),
              const SizedBox(height: AppSpace.x2s),
              Text(subtitle, style: AppText.caption),
              const SizedBox(height: AppSpace.inner),
              Expanded(
                child: ListView.builder(
                  itemCount: characters.length,
                  itemBuilder: (context, index) {
                    final id = characters[index];
                    return _CandidateTile(
                      name: names[id] ?? id,
                      id: id,
                      bone: bones[id],
                      selected: id == selectedId,
                      onTap: () => onPick(id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.name,
    required this.id,
    required this.bone,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String id;
  final String? bone;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: Material(
        color: selected ? AppColors.accentSoft : AppColors.sub,
        borderRadius: BorderRadius.circular(AppRadius.inner),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.inner),
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.inner),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.inner),
              border: Border.all(
                color: selected ? AppColors.accentBorder : AppColors.border,
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono,
                      ),
                    ],
                  ),
                ),
                if (bone != null) ...[
                  const SizedBox(width: AppSpace.xs),
                  StatusChip(
                    bone!,
                    tone: selected ? ChipTone.accent : ChipTone.idle,
                  ),
                ],
                if (selected) ...[
                  const SizedBox(width: AppSpace.x2s),
                  const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: AppColors.accent,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
