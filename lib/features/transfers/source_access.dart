import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';

/// A native stop capability bound to one retained user selection. It does not
/// substitute for sealed session authorization or prove content integrity.
final class SourceScope {
  const SourceScope({
    required this.token,
    required this.fileToken,
    required this.key,
    required this.deadlineMicros,
  });
  final String token, fileToken, key;
  final int deadlineMicros;
}

final class SourceReadPass {
  const SourceReadPass({required this.id, required this.scope});
  final String id;
  final SourceScope scope;
}

enum SourceStopMode { pause, cancel }

enum SourceStopState { paused, cancelled }

final class SourceAccessFailure implements Exception {
  const SourceAccessFailure(this.code);
  final String code;
  @override
  String toString() => 'SourceAccessFailure($code)';
}

/// Network reads require the original grant deadline and a native fast stop
/// gate. Ordinary FileAccess remains for local preparation before this binding.
/// Neither interface accepts a filesystem path from Flutter or a remote peer.
abstract interface class SourceAccess {
  Future<SourceScope> openScope({
    required String fileToken,
    required String key,
    required int deadlineMicros,
  });
  Future<SourceStopState> stopScope(SourceScope scope, SourceStopMode mode);
  Future<void> closeScope(SourceScope scope);
  Future<SourceReadPass> beginPass(SourceScope scope);
  Future<Uint8List> readPass(SourceReadPass pass, int offset, int length);
  Future<void> finishPass(SourceReadPass pass);
}

final class MethodChannelSourceAccess implements SourceAccess {
  static const _channel = MethodChannel('dev.sharehub.client/platform');
  Future<Object?> _call(String method, [Object? args]) =>
      _channel.invokeMethod<Object?>('files.source.$method', args);

  @override
  Future<SourceScope> openScope({
    required String fileToken,
    required String key,
    required int deadlineMicros,
  }) async {
    _token(fileToken);
    _token(key);
    if (deadlineMicros <= 0 || deadlineMicros > FileLimits.maxOffset) {
      _fail('invalid_range');
    }
    return SourceScope(
      token: _nativeToken(
        await _call('scopeOpen', {
          'token': fileToken,
          'key': key,
          'deadlineMicros': deadlineMicros,
        }),
      ),
      fileToken: fileToken,
      key: key,
      deadlineMicros: deadlineMicros,
    );
  }

  @override
  Future<SourceStopState> stopScope(
    SourceScope scope,
    SourceStopMode mode,
  ) async {
    _token(scope.token);
    final state = switch (await _call('scopeStop', {
      'scope': scope.token,
      'mode': mode.name,
    })) {
      'paused' => SourceStopState.paused,
      'cancelled' => SourceStopState.cancelled,
      _ => _fail('invalid_native_result'),
    };
    if (mode == SourceStopMode.cancel && state != SourceStopState.cancelled) {
      _fail('invalid_native_result');
    }
    return state;
  }

  @override
  Future<void> closeScope(SourceScope scope) async {
    _token(scope.token);
    await _call('scopeClose', scope.token);
  }

  @override
  Future<SourceReadPass> beginPass(SourceScope scope) async => SourceReadPass(
    id: _nativeToken(await _call('beginPass', _binding(scope))),
    scope: scope,
  );

  @override
  Future<Uint8List> readPass(
    SourceReadPass pass,
    int offset,
    int length,
  ) async {
    final args = _pass(pass);
    if (offset < 0 ||
        length < 1 ||
        length > 256 * 1024 ||
        offset > FileLimits.maxOffset - length) {
      _fail('invalid_read');
    }
    final bytes = await _call('readPass', {
      ...args,
      'offset': offset,
      'length': length,
    });
    if (bytes is! Uint8List || bytes.length != length) {
      _fail('invalid_native_result');
    }
    return bytes;
  }

  @override
  Future<void> finishPass(SourceReadPass pass) async =>
      await _call('finishPass', _pass(pass));

  static Map<String, Object> _binding(SourceScope scope) {
    _token(scope.token);
    _token(scope.fileToken);
    return {'token': scope.fileToken, 'scope': scope.token};
  }

  static Map<String, Object> _pass(SourceReadPass pass) {
    _token(pass.id);
    return {..._binding(pass.scope), 'passId': pass.id};
  }

  static void _token(String token) {
    if (token.isEmpty ||
        token.contains('\u0000') ||
        utf8.encode(token).length > 256) {
      _fail('invalid_token');
    }
  }

  static String _nativeToken(Object? value) {
    if (value is! String) _fail('invalid_native_result');
    try {
      _token(value);
    } on SourceAccessFailure {
      _fail('invalid_native_result');
    }
    return value;
  }

  static Never _fail(String code) => throw SourceAccessFailure(code);
}
