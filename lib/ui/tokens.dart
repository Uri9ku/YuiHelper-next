import 'package:flutter/material.dart';

/// 设计令牌：唯一来源是 `design/ui-system.html` 的 `:root`。
///
/// 页面只允许引用这里的常量，不允许写色值/圆角/间距字面量。
abstract final class AppColors {
  static const bg = Color(0xFFF4F5F7);
  static const surface = Color(0xFFFFFFFF);
  static const sub = Color(0xFFF7F8FA);
  static const sunken = Color(0xFFFAFBFC);
  static const border = Color(0xFFE9EBEF);
  static const borderStrong = Color(0xFFDDE1E8);

  static const ink = Color(0xFF12141A);
  static const ink2 = Color(0xFF5B6472);
  static const ink3 = Color(0xFF9AA0AA);

  static const accent = Color(0xFF2563EB);
  static const accentPress = Color(0xFF1D4ED8);
  static const accentSoft = Color(0xFFEFF4FF);
  static const accentBorder = Color(0xFFB9CBF2);

  static const success = Color(0xFF10B981);
  static const successInk = Color(0xFF059669);
  static const successSoft = Color(0xFFECFDF5);
  static const successBorder = Color(0xFFC7F0DF);

  static const warning = Color(0xFFF59E0B);
  static const warningInk = Color(0xFFB45309);
  static const warningSoft = Color(0xFFFFF8EE);
  static const warningBorder = Color(0xFFFBE3BE);

  static const danger = Color(0xFFDC2626);
  static const dangerSoft = Color(0xFFFEF2F2);
  static const dangerBorder = Color(0xFFFBD5D5);

  static const disabledBg = Color(0xFFF1F3F6);
  static const segBg = Color(0xFFE8EAEE);
  static const barBg = Color(0xFFEDEFF3);
  static const tabInactive = Color(0xFF8A909B);
}

abstract final class AppRadius {
  static const pill = 36.0;
  static const tab = 26.0;
  static const card = 18.0;
  static const tile = 16.0;
  static const inner = 12.0;
  static const seg = 9.0;
}

abstract final class AppSpace {
  static const page = 20.0;
  static const card = 14.0;
  static const pad = 16.0;
  static const inner = 12.0;
  static const xs = 8.0;
  static const x2s = 4.0;
}

abstract final class AppText {
  static const display = TextStyle(
    fontSize: 26,
    height: 32 / 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: AppColors.ink,
  );
  static const h2 = TextStyle(
    fontSize: 17,
    height: 24 / 17,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
  );
  static const cardTitle = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
  );
  static const body = TextStyle(
    fontSize: 12,
    height: 19 / 12,
    color: AppColors.ink,
  );
  static const caption = TextStyle(
    fontSize: 10,
    height: 15 / 10,
    color: AppColors.ink2,
  );
  static const micro = TextStyle(
    fontSize: 9,
    height: 13 / 9,
    fontWeight: FontWeight.w500,
    color: AppColors.ink3,
  );
  static const numeric = TextStyle(
    fontSize: 16,
    height: 20 / 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    fontFeatures: [FontFeature.tabularFigures()],
    color: AppColors.ink,
  );
  static const numericLarge = TextStyle(
    fontSize: 26,
    height: 30 / 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    fontFeatures: [FontFeature.tabularFigures()],
    color: AppColors.ink,
  );
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 9,
    height: 1.5,
    color: AppColors.ink3,
  );
}

abstract final class AppShadows {
  static const e1 = [
    BoxShadow(color: Color(0x0A12141A), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const e2 = [
    BoxShadow(color: Color(0x0F12141A), blurRadius: 18, offset: Offset(0, 6)),
  ];
  static const e3 = [
    BoxShadow(color: Color(0x472563EB), blurRadius: 20, offset: Offset(0, 8)),
  ];
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.light,
      surface: AppColors.surface,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textTheme: const TextTheme(
      titleLarge: AppText.display,
      titleMedium: AppText.h2,
      titleSmall: AppText.cardTitle,
      bodyMedium: AppText.body,
      bodySmall: AppText.caption,
      labelSmall: AppText.micro,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 5,
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.segBg,
      thumbColor: Colors.white,
      overlayColor: Color(0x142563EB),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 22),
    ),
  );
}
