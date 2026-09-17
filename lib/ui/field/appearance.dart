import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

class Appearance extends ChangeNotifier {
  static const channel = MethodChannel('dev.sharehub.client/desktop');
  ThemeMode mode = ThemeMode.system;
  String? error;
  int _revision = 0;
  bool _disposed = false;
  Future<void> load() async {
    final revision = _revision;
    try {
      final value = await channel.invokeMethod<String>('appearance.read');
      if (_disposed || revision != _revision) return;
      mode =
          ThemeMode.values.where((item) => item.name == value).firstOrNull ??
          ThemeMode.system;
      notifyListeners();
    } on MissingPluginException {
      // Hosts without preference storage keep the system default.
    } catch (_) {
      if (!_disposed) {
        error = '无法读取主题偏好，已跟随系统。';
        notifyListeners();
      }
    }
  }

  Future<void> select(ThemeMode value) async {
    final revision = ++_revision;
    mode = value;
    error = null;
    notifyListeners();
    try {
      await channel.invokeMethod<void>('appearance.write', value.name);
    } catch (_) {
      if (!_disposed && revision == _revision) {
        error = '主题已切换，但未能保存；下次启动将读取原偏好。';
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
  final text = dark ? FieldTokens.paper : FieldTokens.ink;
  final surface = dark ? FieldTokens.surfaceDark : FieldTokens.paperRaised;
  final accent = dark ? FieldTokens.cyan : FieldTokens.cyanText;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    platform: platform,
  );
  return base.copyWith(
    scaffoldBackgroundColor: dark ? FieldTokens.ink : FieldTokens.paper,
    colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
        .copyWith(
          primary: accent,
          onPrimary: dark ? FieldTokens.ink : FieldTokens.paperRaised,
          surface: surface,
          onSurface: text,
          secondary: dark ? FieldTokens.amber : FieldTokens.amberText,
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
          fontFamily: 'Source Han Sans CN',
          fontFamilyFallback: const [
            'Noto Sans SC',
            'PingFang SC',
            'Microsoft YaHei UI',
          ],
          bodyColor: text,
          displayColor: text,
        ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FieldTokens.cardRadius),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FieldTokens.panelRadius),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FieldTokens.nodeRadius),
      ),
    ),
  );
}
