import 'package:flutter/material.dart';

import '../../backend.dart';
import '../tokens.dart';
import '../widgets/foundation.dart';

/// B 装配装备（一级 Tab 页）。
///
/// 三个数字和槽位样本全部来自 `backend.imagination.preview()` 的设备侧实时读数；
/// 读不到就显示空态 / 失败提示，不写死示例数据，也不伪造成「已装配」。
class EquipScreen extends StatefulWidget {
  const EquipScreen({super.key, required this.backend});

  final YuiHelperBackend backend;

  @override
  State<EquipScreen> createState() => _EquipScreenState();
}

class _EquipScreenState extends State<EquipScreen> {
  bool _busy = false;
  bool _equipping = false;
  bool _equipDone = false;

  ImaginationPreview? _preview;
  String? _previewError;
  String? _equipMessage;
  String? _equipError;

  /// 解放所有角色（技能全满）。
  SkillPreview? _skillPreview;
  bool _skillBusy = false;
  bool _skillDone = false;
  String? _skillMessage;
  String? _skillError;
  int? _skillCountdown;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 只读预检：不改存档，刷新「能装多少 / 空多少」。
  Future<void> _refresh() async {
    if (_busy || _equipping) return;
    setState(() {
      _busy = true;
      _equipDone = false;
      _equipMessage = null;
      _equipError = null;
    });
    final result = await widget.backend.imagination.preview();
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Ok<ImaginationPreview>(:final value):
          _preview = value;
          _previewError = null;
        case Err<ImaginationPreview>(:final error):
          _preview = null;
          _previewError = error.userMessage;
      }
    });
    // 只有引擎真的响应了，才继续读技能板预检；否则省掉第二次 30s 超时。
    if (result is Ok<ImaginationPreview>) {
      final skills = await widget.backend.skills.preview();
      if (!mounted) return;
      setState(() {
        if (skills case Ok<SkillPreview>(:final value)) {
          _skillPreview = value;
        }
      });
    }
  }

  /// 解放所有角色：确认 → 5 秒倒计时（切回游戏）→ 写入 → 回 App 看结果。
  ///
  /// 走旧版同款 `SkillBoardRepository.fillAll()`：pc.slotSkills ← maximumSlots，
  /// 并补 requiredItems；写表带 hash.before.pc/item，失败原样报错。
  Future<void> _fillSkills() async {
    if (_skillBusy || _skillCountdown != null || _equipping) return;
    final preview = _skillPreview;
    final confirmed = await _confirmSkillFill(preview);
    if (!confirmed || !mounted) return;

    setState(() {
      _skillBusy = true;
      _skillMessage = null;
      _skillError = null;
      _skillDone = false;
      _skillCountdown = 5;
    });
    for (var left = 5; left > 0; left--) {
      if (!mounted) return;
      setState(() => _skillCountdown = left);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() => _skillCountdown = null);

    final result = await widget.backend.skills.fillAll();
    if (!mounted) return;
    setState(() {
      _skillBusy = false;
      switch (result) {
        case Ok<String>(:final value):
          _skillDone = true;
          _skillMessage = value;
        case Err<String>(:final error):
          _skillError = error.userMessage;
      }
    });
    if (result is Ok<String>) {
      await _refresh();
    }
  }

  Future<bool> _confirmSkillFill(SkillPreview? preview) async {
    final chars = preview?.changed ?? 0;
    final slots = preview?.slots ?? 0;
    final materials = preview?.materialTypes ?? 0;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        title: const Text(
          '解放所有角色？',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              chars > 0
                  ? '会把 $chars 个角色的技能槽全部点到满级（$slots 个槽位）'
                        '${materials > 0 ? '，并补足 $materials 种材料' : ''}。'
                  : '会把所有已拥有角色的技能槽全部点到满级，并补足所需材料。',
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 10),
            const Text(
              '· 需要切回游戏并保持前台，写入才会被处理\n'
              '· 游戏内技能界面不会自动刷新，完成后请重启游戏\n'
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
            style: TextButton.styleFrom(foregroundColor: AppColors.warningInk),
            child: const Text('继续解放'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 一次提交、整批接受或整批拒绝：过程态只有一个，不伪造百分比。
  Future<void> _equip() async {
    if (_busy || _equipping) return;
    setState(() {
      _equipping = true;
      _equipMessage = null;
      _equipError = null;
    });
    final result = await widget.backend.imagination.equipExclusive();
    if (!mounted) return;
    switch (result) {
      case Ok<String>(:final value):
        setState(() {
          _equipping = false;
          _equipDone = true;
          _equipMessage = value;
        });
      case Err<String>(:final error):
        setState(() {
          _equipping = false;
          _equipError = error.userMessage;
        });
    }
  }

  String _subtitle(ImaginationPreview? preview) {
    if (_equipping) return '正在装配 · 请不要切走游戏';
    if (_busy) return '正在读取角色与库存…';
    if (_previewError != null) return '读取失败 · 点右上角刷新重试';
    if (_equipDone) return '装配完成 · 请重启游戏';
    if (preview == null) return '数据来自游戏存档实时读取';
    if (preview.changed == 0) return '没有需要装配的角色';
    return '可装配 ${preview.changed} 个角色 · ${preview.filled} 个空槽位 · ${preview.skipped} 个跳过';
  }

  String get _ctaLabel {
    if (_equipping) return '正在装配…';
    if (_busy) return '正在读取角色表…';
    if (_previewError != null) return '重新读取';
    if (_equipDone) return '完成';
    final preview = _preview;
    if (preview == null) return '正在读取角色表…';
    if (preview.changed == 0) return '没有需要装配的角色';
    return '一键装配所有角色 · ${preview.changed} 个';
  }

  IconData get _ctaIcon {
    if (_equipDone) return Icons.check_rounded;
    if (_previewError != null) return Icons.refresh_rounded;
    return Icons.auto_awesome_rounded;
  }

  VoidCallback? get _ctaAction {
    if (_equipping || _busy) return null;
    if (_previewError != null || _equipDone) return _refresh;
    final preview = _preview;
    if (preview == null || preview.changed == 0) return null;
    return _equip;
  }

  String _kpi(int? value) => value == null ? '—' : '$value';

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final stocks = <int>[];
    if (preview != null) {
      for (final id in preview.sampleSlots) {
        if (id != 0) stocks.add(id);
      }
    }
    final hasSample =
        preview != null &&
        preview.samplePcId != null &&
        (stocks.isNotEmpty || preview.sampleUnlockedSlots > 0);
    final unlocked = preview?.sampleUnlockedSlots ?? 0;

    return AppPageBody(
      children: <Widget>[
        AppPageHeader(
          title: '装配装备',
          subtitle: _subtitle(preview),
          trailing: IconCircleButton(
            icon: Icons.refresh_rounded,
            onPressed: _busy || _equipping ? null : _refresh,
          ),
        ),

        // 写入失败：只给可执行动作，绝不显示成功文案。
        if (_equipError != null) ...[
          WarningStrip(_equipError!, tone: StripTone.danger),
          const SizedBox(height: AppSpace.card),
        ],

        // 写入成功：绿色确认条 + 必须重启的琥珀提示。
        if (_equipMessage != null) ...[
          WarningStrip(_equipMessage!, tone: StripTone.success),
          const SizedBox(height: AppSpace.xs),
          const WarningStrip('请重启游戏，让客户端重新拉取存档。'),
          const SizedBox(height: AppSpace.card),
        ],

        if (_previewError != null) ...[
          WarningStrip(_previewError!, tone: StripTone.danger),
          const SizedBox(height: AppSpace.card),
        ],

        if (_equipping) ...[
          const _EquipProgressCard(),
          const SizedBox(height: AppSpace.card),
        ],

        AppCard(
          padding: const EdgeInsets.all(AppSpace.inner),
          child: KpiRow(
            children: <Widget>[
              if (_equipDone) ...[
                KpiTile(label: '装配角色', value: _kpi(preview?.changed)),
                KpiTile(label: '填充槽位', value: _kpi(preview?.filled)),
                KpiTile(label: '跳过', value: _kpi(preview?.skipped)),
              ] else ...[
                KpiTile(label: '拥有角色', value: _kpi(preview?.total)),
                KpiTile(
                  label: '可装配',
                  value: _kpi(preview?.changed),
                  highlight: (preview?.changed ?? 0) > 0,
                ),
                KpiTile(label: '空槽位', value: _kpi(preview?.filled)),
              ],
            ],
          ),
        ),

        if (preview != null && preview.changed > 0 && hasSample) ...[
          Text(
            '样本 ${preview.samplePcId} · 专属想象力 ${preview.sampleImaginationId ?? '—'} · '
            '已装配 ${stocks.length} / $unlocked 槽位',
            style: AppText.caption,
          ),
          const SizedBox(height: AppSpace.xs),
          _SlotGrid(stocks: stocks, unlocked: unlocked),
          const SizedBox(height: AppSpace.card),
        ] else if (preview != null && preview.changed > 0) ...[
          const EmptyState(
            icon: Icons.grid_view_rounded,
            title: '暂无可展示的槽位样本',
            detail: '设备侧没有返回样本角色，点右上角刷新再试一次。',
          ),
          const SizedBox(height: AppSpace.card),
        ],

        if (preview != null && preview.changed == 0) ...[
          EmptyState(
            icon: Icons.auto_awesome_outlined,
            title: '没有需要装配的角色',
            detail:
                '${preview.total} 个角色里，${preview.skipped} 个未解锁槽位或没有专属想象力；'
                '其余已装满或没有可用的库存副本。',
          ),
          const SizedBox(height: AppSpace.xs),
          const Text('只填空槽：已有想象力的槽位不会被覆盖。', style: AppText.caption),
          const SizedBox(height: AppSpace.card),
        ],

        if (preview == null && _previewError == null && !_equipping) ...[
          const Text('正在读取角色与库存…', style: AppText.caption),
          const SizedBox(height: AppSpace.card),
        ],

        const _RulesCard(),
        const SizedBox(height: AppSpace.xs),
        const Text('装配后需重启游戏，客户端才会重新拉取存档。', style: AppText.caption),
        const SizedBox(height: AppSpace.card),

        AppButton(label: _ctaLabel, icon: _ctaIcon, onPressed: _ctaAction),
        const SizedBox(height: AppSpace.card),
        _skillCard(),
      ],
    );
  }

  /// 解放所有角色（技能全满）：旧版 YuiHelper 的「技能全满」，搬到 B 页。
  Widget _skillCard() {
    final preview = _skillPreview;
    final busy = _skillBusy || _skillCountdown != null;
    final total = preview?.total;
    final changed = preview?.changed;
    final slots = preview?.slots;
    final materials = preview?.materialTypes ?? 0;
    final skipped = preview?.skippedNoBoard ?? 0;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Expanded(child: Text('解放所有角色', style: AppText.cardTitle)),
              StatusChip('技能全满'),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '把每个已拥有角色的技能槽全部点到满级（含每槽等级上限），并按离线 catalog '
            '补足所需材料；没有技能板数据的角色会跳过。',
            style: TextStyle(fontSize: 10, height: 1.6, color: AppColors.ink2),
          ),
          const SizedBox(height: AppSpace.inner),
          KpiRow(
            children: <Widget>[
              KpiTile(label: '拥有角色', value: total == null ? '—' : '$total'),
              KpiTile(
                label: '待解放',
                value: changed == null ? '—' : '$changed',
                highlight: (changed ?? 0) > 0,
              ),
              KpiTile(label: '技能槽', value: slots == null ? '—' : '$slots'),
            ],
          ),
          if (materials > 0) ...[
            const SizedBox(height: AppSpace.xs),
            Text('将补足材料 $materials 种', style: AppText.caption),
          ],
          if (skipped > 0) ...[
            const SizedBox(height: AppSpace.x2s),
            Text('$skipped 个角色没有技能板数据，会跳过', style: AppText.caption),
          ],
          if (_skillError != null) ...[
            const SizedBox(height: AppSpace.inner),
            WarningStrip(_skillError!, tone: StripTone.danger),
          ],
          if (_skillMessage != null) ...[
            const SizedBox(height: AppSpace.inner),
            WarningStrip(_skillMessage!, tone: StripTone.success),
            const SizedBox(height: AppSpace.xs),
            const WarningStrip('请重启游戏，让客户端重新拉取存档。'),
          ],
          if (_skillCountdown != null) ...[
            const SizedBox(height: AppSpace.inner),
            _skillCountdownCard(),
          ],
          const SizedBox(height: AppSpace.inner),
          AppButton(
            label: _skillBusy
                ? '正在解放…'
                : _skillDone
                ? '完成'
                : changed == null
                ? '解放所有角色'
                : '解放所有角色 · $changed 个',
            icon: _skillDone ? Icons.check_rounded : Icons.auto_awesome_rounded,
            onPressed: busy
                ? null
                : _skillDone
                ? _refresh
                : _fillSkills,
          ),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '需要游戏在前台；完成后游戏内技能界面要重启/重进才会刷新。',
            style: TextStyle(fontSize: 10, height: 1.5, color: AppColors.ink3),
          ),
        ],
      ),
    );
  }

  Widget _skillCountdownCard() {
    return Container(
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
        children: <Widget>[
          Text(
            '$_skillCountdown',
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
              children: <Widget>[
                Text(
                  '秒后开始解放',
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
}

/// 装配中：整批提交没有真实百分比，用不确定进度条 + 文案，不编造 32 / 62。
class _EquipProgressCard extends StatelessWidget {
  const _EquipProgressCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const CardHeader(title: '正在装配…', actionText: '整批一次提交'),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: const LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: AppColors.barBg,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          const Text('写入期间不要切走游戏；数据过期会提示重启游戏后再试。', style: AppText.caption),
        ],
      ),
    );
  }
}

/// 2 × 2 槽位：前 N 个是有库存的专属槽位，已解锁的显示为空槽，未解锁的标灰。
class _SlotGrid extends StatelessWidget {
  const _SlotGrid({required this.stocks, required this.unlocked});

  final List<int> stocks;
  final int unlocked;

  Widget _tile(int index) {
    if (index < stocks.length) {
      return SlotTile(
        icon: Icons.auto_awesome_rounded,
        name: '专属想象力',
        attr: '${stocks[index]}',
      );
    }
    if (index < unlocked) {
      return const SlotTile(
        icon: Icons.add_rounded,
        name: '空槽位',
        attr: '已解锁 · 可装配',
        empty: true,
      );
    }
    return const SlotTile(
      icon: Icons.lock_outline_rounded,
      name: '未解锁',
      attr: '只装已解锁槽位',
      empty: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: _tile(0)),
            const SizedBox(width: AppSpace.xs),
            Expanded(child: _tile(1)),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        Row(
          children: <Widget>[
            Expanded(child: _tile(2)),
            const SizedBox(width: AppSpace.xs),
            Expanded(child: _tile(3)),
          ],
        ),
      ],
    );
  }
}

class _RulesCard extends StatelessWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context) {
    return const AppCard(
      padding: EdgeInsets.all(AppSpace.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CardHeader(title: '装配规则', actionText: '3 条'),
          _RuleLine('只填空槽，已装配的槽位不动'),
          _RuleLine('只装已解锁槽位（最多 4 个）'),
          _RuleLine('多槽位使用不同库存副本'),
        ],
      ),
    );
  }
}

class _RuleLine extends StatelessWidget {
  const _RuleLine(this.text);

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
              color: AppColors.borderStrong,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(child: Text(text, style: AppText.caption)),
        ],
      ),
    );
  }
}
