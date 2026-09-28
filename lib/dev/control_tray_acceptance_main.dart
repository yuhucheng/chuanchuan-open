// Opt-in desktop acceptance target. Never ship this entry point.
// It injects a native tray state with an active control operation while the
// notice is off, then checks the stop action stays enabled when the main
// window hides or closes to the background. It does not run SDK input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _desktop = MethodChannel('dev.sharehub.client/desktop');

Future<Map<String, Object?>> _state() async => Map<String, Object?>.from(
  (await _desktop.invokeMapMethod<String, Object?>('window.state')) ?? {},
);

bool _stopEnabled(Map<String, Object?> state) {
  final items = state['trayItems'] as List? ?? const [];
  return items.whereType<Map>().any(
    (item) => item['title'] == '停止控制' && item['enabled'] == true,
  );
}

Future<void> _probe() async {
  final report = <String, Object?>{};
  try {
    report['platform'] = Platform.operatingSystem;
    report['controlState'] = 'injected-native-state';
    report['initialize'] = await _desktop.invokeMapMethod<String, Object?>(
      'initialize',
      {'connectionSupported': true},
    );
    await _desktop.invokeMethod<void>('state', {
      'allowConnections': false,
      'controlActive': true,
      'controlNoticeEnabled': false,
    });
    Map<String, Object?> visible = await _state();
    for (var i = 0; i < 100 && visible['visible'] != true; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      visible = await _state();
    }
    await _desktop.invokeMethod<void>('window.action', {'action': 'hide'});
    final hidden = await _state();
    await _desktop.invokeMethod<void>('window.action', {'action': 'unhide'});
    await _desktop.invokeMethod<void>('window.action', {'action': 'close'});
    final closed = await _state();
    await _desktop.invokeMethod<void>('window.action', {'action': 'reopen'});
    await _desktop.invokeMethod<void>('state', {
      'allowConnections': false,
      'controlActive': false,
      'controlNoticeEnabled': false,
    });
    final stopped = await _state();
    report.addAll({
      'visible': visible,
      'hidden': hidden,
      'closed': closed,
      'stopped': stopped,
      'passed':
          visible['trayInstalled'] == true &&
          hidden['trayInstalled'] == true &&
          closed['trayInstalled'] == true &&
          (Platform.isMacOS || hidden['visible'] == false) &&
          closed['visible'] == false &&
          _stopEnabled(visible) &&
          _stopEnabled(hidden) &&
          _stopEnabled(closed) &&
          !_stopEnabled(stopped),
    });
  } catch (error) {
    report['passed'] = false;
    report['error'] = error.toString();
  }
  stdout.writeln('TRAY_PROBE_JSON=${jsonEncode(report)}');
  exit(report['passed'] == true ? 0 : 1);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.expand(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_probe()));
}
