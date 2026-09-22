// Generated from assets/design/design-tokens.json. Do not edit values by hand.
import 'package:flutter/material.dart';

abstract final class FieldTokens {
  static const ink = Color(0xFF12161A);
  static const inkSecondary = Color(0xFF3A4249);
  static const inkDisabled = Color(0xFF8A949B);
  static const paper = Color(0xFFF5F7F7);
  static const paperRaised = Color(0xFFFFFFFF);
  static const paperGroup = Color(0xFFE8ECEC);
  static const amber = Color(0xFFF26A2E);
  static const amberText = Color(0xFFB4471A);
  static const cyan = Color(0xFF29D3C4);
  static const cyanText = Color(0xFF0F766E);
  static const muted = Color(0xFF68737A);
  static const mutedDark = Color(0xFF8A9494);
  static const line = Color(0xFFE3E9E9);
  static const surfaceDark = Color(0xFF191E23);
  static const surfaceDarkHigh = Color(0xFF20262C);
  static const lineDark = Color(0xFF2A3138);
  static const success = Color(0xFF2E9E63);
  static const successText = Color(0xFF1E6B43);
  static const warning = Color(0xFFD97706);
  static const warningText = Color(0xFF8A4B00);
  static const danger = Color(0xFFC8352B);
  static const dangerText = Color(0xFFA3271F);
  static const chipRadius = 8.0;
  static const cardRadius = 16.0;
  static const panelRadius = 20.0;
  static const appiconRadius = 40.0;
  static const nodeRadius = 12.0;
  static const bodyFontFamily = 'Source Han Sans CN';
  static const bodyFontFallback = <String>[
    'Noto Sans SC',
    'PingFang SC',
    'Microsoft YaHei UI',
    'sans-serif',
  ];
  static const monoFontFamily = 'Noto Sans Mono';
  static const monoFontFallback = <String>[
    'SF Mono',
    'Cascadia Code',
    'monospace',
  ];
  static const displayStyle = TextStyle(
    fontSize: 36.0,
    height: 1.2222222222222223,
    fontWeight: FontWeight.w500,
  );
  static const h1Style = TextStyle(
    fontSize: 30.0,
    height: 1.2666666666666666,
    fontWeight: FontWeight.w500,
  );
  static const h2Style = TextStyle(
    fontSize: 24.0,
    height: 1.3333333333333333,
    fontWeight: FontWeight.w500,
  );
  static const h3Style = TextStyle(
    fontSize: 20.0,
    height: 1.4,
    fontWeight: FontWeight.w500,
  );
  static const bodyLargeStyle = TextStyle(
    fontSize: 16.0,
    height: 1.5,
    fontWeight: FontWeight.w400,
  );
  static const bodyStyle = TextStyle(
    fontSize: 14.0,
    height: 1.5714285714285714,
    fontWeight: FontWeight.w400,
  );
  static const captionStyle = TextStyle(
    fontSize: 12.0,
    height: 1.5,
    fontWeight: FontWeight.w400,
  );
  static const codeStyle = TextStyle(
    fontSize: 18.0,
    height: 1.3333333333333333,
    fontWeight: FontWeight.w500,
    fontFamily: monoFontFamily,
    fontFamilyFallback: monoFontFallback,
  );
  static const spaceUnit = 8.0;
  static const space4 = 4.0;
  static const space8 = 8.0;
  static const space12 = 12.0;
  static const space16 = 16.0;
  static const space24 = 24.0;
  static const space32 = 32.0;
  static const space40 = 40.0;
  static const space48 = 48.0;
  static const space64 = 64.0;
  static const nodeWidth = 150.0;
  static const nodePadding = 16.0;
  static const touchTargetMin = 48.0;
  static const toolbarTarget = 40.0;
  static const focusWidth = 2.0;
  static const focusOffset = 2.0;
  static const holdDuration = Duration(milliseconds: 600);
  static const lightTheme = FieldThemeColors(
    background: paper,
    surface: paperRaised,
    raised: paperGroup,
    text: ink,
    secondaryText: inkSecondary,
    weakText: muted,
    decoration: line,
    link: cyanText,
    self: amberText,
    focus: cyanText,
  );
  static const darkTheme = FieldThemeColors(
    background: ink,
    surface: surfaceDark,
    raised: surfaceDarkHigh,
    text: paper,
    secondaryText: mutedDark,
    decoration: lineDark,
    link: cyan,
    self: amber,
    focus: cyan,
  );
}

/// Only roles explicitly supplied by the design palette are represented.
class FieldThemeColors {
  const FieldThemeColors({
    required this.background,
    required this.surface,
    required this.raised,
    required this.text,
    required this.secondaryText,
    required this.decoration,
    required this.link,
    required this.self,
    required this.focus,
    this.weakText,
  });
  final Color background;
  final Color surface;
  final Color raised;
  final Color text;
  final Color secondaryText;
  final Color decoration;
  final Color link;
  final Color self;
  final Color focus;
  final Color? weakText;
}
