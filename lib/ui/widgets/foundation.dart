import 'package:flutter/material.dart';

import '../tokens.dart';

/// 组件层：全部来自 `design/ui-system.html` 的 7.x 组件实物。
/// 页面只组合这些组件，不直接写字面量样式。

/// 7.1 AppCard 卡片：白底、1px 描边、18 圆角，不用阴影。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.pad),
    this.margin = const EdgeInsets.only(bottom: AppSpace.card),
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
    return Padding(
      padding: margin,
      child: onTap == null
          ? card
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: card,
              ),
            ),
    );
  }
}

/// 卡片标题行：左侧标题 + 右侧动作。
class CardHeader extends StatelessWidget {
  const CardHeader({
    super.key,
    required this.title,
    this.actionText,
    this.onAction,
    this.trailing,
    this.trailingColor = AppColors.accent,
    this.titleSize = 14,
  });

  final String title;
  final String? actionText;
  final VoidCallback? onAction;
  final Widget? trailing;
  final Color trailingColor;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.inner),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: AppText.cardTitle.copyWith(fontSize: titleSize),
            ),
          ),
          if (trailing != null) trailing!,
          if (trailing == null && actionText != null)
            GestureDetector(
              onTap: onAction,
              behavior: HitTestBehavior.opaque,
              child: Text(
                actionText!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: onAction == null ? AppColors.ink3 : trailingColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 7.4 Button：主按钮 52 高 / 次按钮 38 高 / 小按钮 26 高。
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.height = 52,
    this.primary = true,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final bool primary;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final bg = disabled
        ? AppColors.disabledBg
        : primary
        ? AppColors.accent
        : AppColors.surface;
    final fg = disabled
        ? AppColors.ink3
        : primary
        ? Colors.white
        : AppColors.accent;
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: height >= 44 ? 13 : 11,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ],
    );
    return SizedBox(
      height: height,
      width: expand ? double.infinity : null,
      child: primary
          ? DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  height >= 44 ? AppRadius.tile : 13,
                ),
                boxShadow: disabled || !primary ? null : AppShadows.e3,
              ),
              child: FilledButton(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: bg,
                  disabledBackgroundColor: AppColors.disabledBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      height >= 44 ? AppRadius.tile : 13,
                    ),
                  ),
                  padding: EdgeInsets.zero,
                ),
                child: child,
              ),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                backgroundColor: bg,
                foregroundColor: fg,
                side: const BorderSide(color: AppColors.accentBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    height >= 44 ? AppRadius.tile : 13,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: child,
            ),
    );
  }
}

enum ChipTone { idle, accent, success, warning, danger }

/// 7.9 状态标签：高 24、圆角 12、字号 10。
class StatusChip extends StatelessWidget {
  const StatusChip(this.text, {super.key, this.tone = ChipTone.idle});

  final String text;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch (tone) {
      ChipTone.accent => (AppColors.accentSoft, AppColors.accentBorder, AppColors.accent),
      ChipTone.success => (AppColors.successSoft, AppColors.successBorder, AppColors.successInk),
      ChipTone.warning => (AppColors.warningSoft, AppColors.warningBorder, AppColors.warningInk),
      ChipTone.danger => (AppColors.dangerSoft, AppColors.dangerBorder, AppColors.danger),
      ChipTone.idle => (AppColors.sub, AppColors.border, AppColors.ink2),
    };
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }
}

enum StripTone { warning, danger, success }

/// 7.9 提示条：只承载会阻断操作的信息。
class WarningStrip extends StatelessWidget {
  const WarningStrip(this.text, {super.key, this.tone = StripTone.warning});

  final String text;
  final StripTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg, icon) = switch (tone) {
      StripTone.warning => (
          AppColors.warningSoft,
          AppColors.warningBorder,
          AppColors.warningInk,
          Icons.warning_amber_rounded,
        ),
      StripTone.danger => (
          AppColors.dangerSoft,
          AppColors.dangerBorder,
          AppColors.danger,
          Icons.error_outline_rounded,
        ),
      StripTone.success => (
          AppColors.successSoft,
          AppColors.successBorder,
          AppColors.successInk,
          Icons.check_circle_outline_rounded,
        ),
    };
    return Container(
      padding: const EdgeInsets.all(AppSpace.inner),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.inner),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 10, height: 15 / 10, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// 返回圆钮 36 / 44 热区。
class IconCircleButton extends StatelessWidget {
  const IconCircleButton({super.key, required this.icon, this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Material(
          color: AppColors.surface,
          shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(icon, size: 18, color: AppColors.ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// 二级页导航栏：高 44，标题 17 居中，右侧动作 12。
class AppNavBar extends StatelessWidget {
  const AppNavBar({
    super.key,
    required this.title,
    this.onBack,
    this.actionText,
    this.onAction,
  });

  final String title;
  final VoidCallback? onBack;
  final String? actionText;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          if (onBack != null)
            IconCircleButton(icon: Icons.chevron_left_rounded, onPressed: onBack)
          else
            const SizedBox(width: 44),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.h2,
            ),
          ),
          SizedBox(
            width: 44,
            child: actionText == null
                ? null
                : GestureDetector(
                    onTap: onAction,
                    behavior: HitTestBehavior.opaque,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        actionText!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: onAction == null
                              ? AppColors.ink3
                              : AppColors.accent,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 大标题页头（一级页）：26/32 标题 + 11 副标题。
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.display),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: const TextStyle(fontSize: 11, color: AppColors.ink2)),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 7.2 分段控制器：高 40、底 #E8EAEE、选中白块。
class SegmentedBar extends StatelessWidget {
  const SegmentedBar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.segBg,
        borderRadius: BorderRadius.circular(AppRadius.inner),
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  decoration: BoxDecoration(
                    color: i == index ? AppColors.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.seg),
                    boxShadow: i == index
                        ? const [
                            BoxShadow(
                              color: Color(0x14121A26),
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    items[i],
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: i == index ? FontWeight.w600 : FontWeight.w400,
                      color: i == index ? AppColors.ink : AppColors.ink2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 7.3 胶囊 Tab 栏：高 62、36 圆角、e2 投影、选中黑底。
class PillTabBar extends StatelessWidget {
  const PillTabBar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<PillTabItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.e2,
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  decoration: BoxDecoration(
                    color: i == index ? AppColors.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.tab),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        items[i].icon,
                        size: 18,
                        color: i == index ? Colors.white : AppColors.tabInactive,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        items[i].label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: i == index ? Colors.white : AppColors.tabInactive,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PillTabItem {
  const PillTabItem(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// 7.5 KPI 数值块。
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
    this.valueSize = 16,
  });

  final String label;
  final String value;
  final bool highlight;
  final double valueSize;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: highlight ? AppColors.accentSoft : AppColors.sub,
          borderRadius: BorderRadius.circular(AppRadius.inner),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                height: 15 / 10,
                color: highlight ? AppColors.accent : AppColors.ink2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.numeric.copyWith(
                fontSize: valueSize,
                color: highlight ? AppColors.accent : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class KpiRow extends StatelessWidget {
  const KpiRow({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          children[i],
        ],
      ],
    );
  }
}

/// 7.6 槽位卡：3 列网格里的 110×92 单元；空槽用虚线。
class SlotTile extends StatelessWidget {
  const SlotTile({
    super.key,
    required this.icon,
    required this.name,
    this.attr,
    this.empty = false,
    this.onTap,
  });

  final IconData icon;
  final String name;
  final String? attr;
  final bool empty;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      height: 92,
      padding: const EdgeInsets.all(AppSpace.inner),
      decoration: BoxDecoration(
        color: empty ? AppColors.sunken : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        border: Border.all(
          color: empty ? AppColors.borderStrong : AppColors.border,
          style: empty ? BorderStyle.solid : BorderStyle.solid,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: empty ? const Color(0xFFB4BAC4) : AppColors.accent,
          ),
          const Spacer(),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: empty ? AppColors.ink3 : AppColors.ink,
            ),
          ),
          if (attr != null) ...[
            const SizedBox(height: 2),
            Text(
              attr!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                height: 13 / 9,
                color: empty ? const Color(0xFFB4BAC4) : AppColors.accent,
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return body;
    return GestureDetector(onTap: onTap, child: body);
  }
}

/// 7.7 任务卡：三种状态由 trailing 决定。
class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.name,
    required this.meta,
    this.progress,
    this.progressWarn = false,
    this.trailing,
    this.mutedName = false,
  });

  final String name;
  final String meta;
  final double? progress;
  final bool progressWarn;
  final Widget? trailing;
  final bool mutedName;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(AppSpace.card),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: mutedName ? AppColors.ink2 : AppColors.ink,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          Text(meta, style: AppText.caption),
          if (progress != null) ...[
            const SizedBox(height: 8),
            AppProgressBar(value: progress!, warn: progressWarn),
          ],
        ],
      ),
    );
  }
}

/// 进度条：高 4、圆角 2、蓝/琥珀。
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.value,
    this.warn = false,
    this.height = 4,
  });

  final double value;
  final bool warn;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: value.clamp(0, 1),
        minHeight: height,
        backgroundColor: AppColors.barBg,
        valueColor: AlwaysStoppedAnimation(
          warn ? AppColors.warning : AppColors.accent,
        ),
      ),
    );
  }
}

/// 换模型页的体检行：30 高、18 方块标记。
class EnvRow extends StatelessWidget {
  const EnvRow({
    super.key,
    required this.label,
    required this.state,
    required this.value,
  });

  /// null = 未启动/未知（灰色 —，不是红 ✕）。
  final bool? state;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg, mark) = switch (state) {
      true => (AppColors.successSoft, AppColors.successBorder, AppColors.successInk, Icons.check_rounded),
      false => (AppColors.dangerSoft, AppColors.dangerBorder, AppColors.danger, Icons.close_rounded),
      null => (AppColors.sunken, AppColors.borderStrong, AppColors.ink3, Icons.remove_rounded),
    };
    return Container(
      height: 30,
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.sub,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: border),
            ),
            child: Icon(mark, size: 12, color: fg),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.ink)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }
}

/// 换模型页的映射行：A/B 圆标 + 名称/id 两行 + 箭头。
class MapRow extends StatelessWidget {
  const MapRow({
    super.key,
    required this.badge,
    required this.name,
    required this.id,
    this.onTap,
  });

  final String badge;
  final String name;
  final String id;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.inner),
      decoration: BoxDecoration(
        color: AppColors.sub,
        borderRadius: BorderRadius.circular(AppRadius.inner),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.accentBorder),
            ),
            child: Text(
              badge,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.ink,
                    height: 1.35,
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
          const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.ink3),
        ],
      ),
    );
    if (onTap == null) return row;
    return GestureDetector(onTap: onTap, child: row);
  }
}

/// 日志面板：等宽 9–10px、时间 --ink3、正文 --ink-2。
class LogPanel extends StatelessWidget {
  const LogPanel({
    super.key,
    required this.lines,
    this.title = '日志',
    this.trailing,
    this.emptyText = '还没有记录',
    this.maxLines = 120,
  });

  final List<String> lines;
  final String title;
  final Widget? trailing;
  final String emptyText;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink2,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          if (lines.isEmpty)
            Text(
              emptyText,
              style: const TextStyle(fontSize: 11, color: AppColors.ink3),
            )
          else
            for (final line in lines.take(maxLines))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  line,
                  style: AppText.mono.copyWith(fontSize: 9.5, color: AppColors.ink2),
                ),
              ),
        ],
      ),
    );
  }
}

/// 空态：虚线感由 sunken + 图标 + 两行文案组成，不渲染假数据。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.height = 220,
  });

  final IconData icon;
  final String title;
  final String detail;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.sunken,
        borderRadius: BorderRadius.circular(AppRadius.inner),
        border: Border.all(color: AppColors.borderStrong),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 26, color: AppColors.ink3.withValues(alpha: 0.7)),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, height: 15 / 10.5, color: AppColors.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面骨架：一级页统一 20 页边距 + 底部留白（给悬浮 Tab 让位）。
class AppPageBody extends StatelessWidget {
  const AppPageBody({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 110),
    this.scrollController,
  });

  final List<Widget> children;
  final EdgeInsets padding;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      padding: padding,
      children: children,
    );
  }
}
