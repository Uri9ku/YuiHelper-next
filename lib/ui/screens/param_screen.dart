import 'package:flutter/material.dart';

import '../tokens.dart';
import '../widgets/foundation.dart';

/// D 数值修改：预设 + 4 条参数滑杆 + diff 预览 + 风险提示。
///
/// 数值写入后端**没有**移植（本期只要领取/装配/换模型），所以主按钮
/// 保持禁用并在页脚说明；滑杆、预设与 diff 都是真实可交互的。
class ParamScreen extends StatefulWidget {
  const ParamScreen({super.key});

  @override
  State<ParamScreen> createState() => _ParamScreenState();
}

class _ParamScreenState extends State<ParamScreen> {
  final List<_Param> _params = [
    _Param('生命值', original: 1200, max: 9999, current: 9999),
    _Param('金币', original: 2400, max: 99999, current: 99999),
    _Param('攻击', original: 620, max: 2480, current: 1240),
    _Param('防御', original: 480, max: 1920, current: 960),
  ];
  int _preset = 1;

  static const _presets = ['安全', '激进', '极限'];

  void _applyPreset(int index) {
    // 三档预设是「占上限的比例」，与设计稿的初始值对齐：
    // 激进 = 生命/金币拉满、攻击/防御半程，正好是设计稿展示的那组数字。
    const ratios = [
      [0.4, 0.4, 0.35, 0.35],
      [1.0, 1.0, 0.5, 0.5],
      [1.0, 1.0, 1.0, 1.0],
    ];
    setState(() {
      _preset = index;
      for (var i = 0; i < _params.length; i++) {
        _params[i].current = (_params[i].max * ratios[index][i]).round();
      }
    });
  }

  void _reset() {
    setState(() {
      _preset = 1;
      for (final p in _params) {
        p.current = p.max;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final changed = _params.where((p) => p.current != p.original).toList();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: AppNavBar(
                title: '数值修改',
                onBack: () => Navigator.of(context).maybePop(),
                actionText: '重置',
                onAction: _reset,
              ),
            ),
            Expanded(
              child: AppPageBody(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.page,
                  0,
                  AppSpace.page,
                  20,
                ),
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < _presets.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: _PresetChip(
                            label: _presets[i],
                            active: _preset == i,
                            onTap: () => _applyPreset(i),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppSpace.card),
                  for (final p in _params)
                    AppCard(
                      padding: const EdgeInsets.all(AppSpace.card),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Text(
                                p.label,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _format(p.current),
                                style: AppText.numeric.copyWith(
                                  fontSize: 15,
                                  color: AppColors.accent,
                                ),
                              ),
                            ],
                          ),
                          Slider(
                            value: p.current.clamp(p.original, p.max).toDouble(),
                            min: p.original.toDouble(),
                            max: p.max.toDouble(),
                            onChanged: (value) {
                              setState(() {
                                p.current = value.round();
                                _preset = -1;
                              });
                            },
                          ),
                          Row(
                            children: [
                              Text(
                                '原始 ${_format(p.original)}',
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: AppColors.ink3,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '↑ +${_format(p.current - p.original)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.successInk,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CardHeader(
                          title: '改动预览',
                          actionText: '${changed.length} 项待写入',
                          onAction: null,
                        ),
                        if (changed.isEmpty)
                          const Text(
                            '当前没有改动',
                            style: TextStyle(fontSize: 12, color: AppColors.ink3),
                          )
                        else
                          for (final p in changed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${p.label} ${_format(p.original)} → ${_format(p.current)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.successInk,
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                  const WarningStrip(
                    '数值写入后端未接入：本页只实现设计稿里的选择与预览，不会修改存档。',
                    tone: StripTone.warning,
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                10,
                AppSpace.page,
                18,
              ),
              child: AppButton(
                label: '写入 ${changed.length} 项改动',
                onPressed: null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _format(int value) => value
      .toString()
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (match) => '${match[1]},');
}

class _Param {
  _Param(this.label, {required this.original, required this.max, required this.current});

  final String label;
  final int original;
  final int max;
  int current;
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.accentSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: active ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? AppColors.accent : AppColors.ink2,
          ),
        ),
      ),
    );
  }
}
