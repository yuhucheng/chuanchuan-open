import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

enum AppearanceFailure { read, write }

class Appearance extends ChangeNotifier {
  static const channel = MethodChannel('dev.sharehub.client/desktop');
  ThemeMode mode = ThemeMode.system;
  String? error;
  AppearanceFailure? failure;
  String get retryLabel =>
      failure == AppearanceFailure.read ? '重试读取主题' : '重试保存主题';
  Future<void> retry() =>
      failure == AppearanceFailure.read ? load() : select(mode);
  int _revision = 0;
  bool _disposed = false;
  Future<void> load() async {
    final revision = ++_revision;
    try {
      final value = await channel.invokeMethod<String>('appearance.read');
      if (_disposed || revision != _revision) return;
      mode =
          ThemeMode.values.where((item) => item.name == value).firstOrNull ??
          ThemeMode.system;
      error = null;
      failure = null;
      notifyListeners();
    } on MissingPluginException {
      // Hosts without preference storage keep the system default.
      if (!_disposed && revision == _revision) {
        error = null;
        failure = null;
        notifyListeners();
      }
    } catch (_) {
      if (!_disposed && revision == _revision) {
        error = '无法读取主题偏好，暂用当前主题，请重试读取。';
        failure = AppearanceFailure.read;
        notifyListeners();
      }
    }
  }

  Future<void> select(ThemeMode value) async {
    final revision = ++_revision;
    mode = value;
    error = null;
    failure = null;
    notifyListeners();
    try {
      await channel.invokeMethod<void>('appearance.write', value.name);
    } catch (_) {
      if (!_disposed && revision == _revision) {
        error = '主题已切换，但未能保存；下次启动将读取原偏好。';
        failure = AppearanceFailure.write;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

ThemeData fieldTheme(Brightness brightness, TargetPlatform platform) {
  final dark = brightness == Brightness.dark;
  final colors = dark ? FieldTokens.darkTheme : FieldTokens.lightTheme;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    platform: platform,
  );
  return base.copyWith(
    scaffoldBackgroundColor: colors.background,
    hintColor: colors.weakText ?? colors.secondaryText,
    dividerColor: colors.decoration,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: colors.link,
          brightness: brightness,
        ).copyWith(
          primary: colors.link,
          onPrimary: dark ? FieldTokens.ink : FieldTokens.paperRaised,
          surface: colors.surface,
          surfaceContainerHighest: colors.raised,
          onSurface: colors.text,
          onSurfaceVariant: colors.secondaryText,
          // Informative boundaries need contrast; decoration is only for rules.
          outline: colors.secondaryText,
          outlineVariant: colors.decoration,
          secondary: colors.self,
          onSecondary: dark ? FieldTokens.ink : FieldTokens.paperRaised,
          // No dark error-text token is supplied. Preserve Material's existing
          // accessible dark error palette instead of using the dim graphic red.
          error: dark ? null : FieldTokens.dangerText,
          onError: dark ? null : FieldTokens.paperRaised,
        ),
    textTheme: base.textTheme
        .copyWith(
          displayLarge: FieldTokens.displayStyle,
          headlineLarge: FieldTokens.h1Style,
          headlineMedium: FieldTokens.h2Style,
          headlineSmall: FieldTokens.h3Style,
          bodyLarge: FieldTokens.bodyLargeStyle,
          bodyMedium: FieldTokens.bodyStyle,
          bodySmall: FieldTokens.captionStyle,
        )
        .apply(
          fontFamily: FieldTokens.bodyFontFamily,
          fontFamilyFallback: FieldTokens.bodyFontFallback,
          bodyColor: colors.text,
          displayColor: colors.text,
        ),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FieldTokens.cardRadius),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FieldTokens.panelRadius),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.raised,
      // The light weak-text color is specified for paper, not the darker
      // grouped fill; keep input labels/hints at the secondary-text contrast.
      hintStyle: TextStyle(color: colors.secondaryText),
      labelStyle: TextStyle(color: colors.secondaryText),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FieldTokens.nodeRadius),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FieldTokens.nodeRadius),
        borderSide: BorderSide(color: colors.secondaryText),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FieldTokens.nodeRadius),
        borderSide: BorderSide(
          color: colors.focus,
          width: FieldTokens.focusWidth,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: colors.decoration),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FieldTokens.chipRadius),
      ),
    ),
  );
}
