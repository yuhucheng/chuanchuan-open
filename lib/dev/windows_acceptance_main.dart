// Windows acceptance entry: drives the desktop channel's observation-only
// window controls, which cannot be reached by real clicks from a host process.
// It writes one report file and exits. It never renders the product UI, so it
// must never be the entry point of a shipped build.
//
//   flutter run -d windows -t lib/dev/windows_acceptance_main.dart
//
// Rebuilding the product afterwards is mandatory: running any other entry
// overwrites the Debug kernel payload, which would otherwise launch this
// report instead of the client.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const MethodChannel _desktop = MethodChannel('dev.sharehub.client/desktop');
const String _reportPath =
    r'D:\code\chuan-agent\.workbuddy\tmp\win_acceptance.txt';

Future<String> _call(String method, [Object? arguments]) async {
  try {
    if (method == 'system.indicators') {
      final value = await _desktop.invokeListMethod<dynamic>(method);
      return 'list=$value';
    }
    final value = await _desktop.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    return value == null ? 'null' : value.toString();
  } on PlatformException catch (error) {
    return 'PlatformException(${error.code})';
  } catch (error) {
    return 'ERROR($error)';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = StringBuffer();
  report.writeln(
    'initialize=${await _call('initialize', <String, Object>{'connectionSupported': true})}',
  );
  report.writeln('state=${await _call('window.state')}');
  for (final action in <String>[
    'minimize',
    'deminiaturize',
    'hide',
    'unhide',
    'reopen',
    'nope',
  ]) {
    report.writeln(
      'action($action)=${await _call('window.action', <String, Object>{'action': action})}',
    );
  }
  report.writeln('indicators=${await _call('system.indicators')}');
  File(_reportPath).writeAsStringSync(report.toString());
  exit(0);
}
