import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';

final class ReceiveDirectory {
  const ReceiveDirectory({required this.token, required this.label});
  final String token, label;
}

/// Native stop capability, not a substitute for sealed session authorization.
/// The host opens this only after checking the retained FileTransferContext.
final class ReceiveScope {
  const ReceiveScope({
    required this.token,
    required this.key,
    required this.deadlineMicros,
  });
  final String token, key;
  final int deadlineMicros;
}

final class ReceiveMetadata {
  const ReceiveMetadata({
    required this.name,
    required this.size,
    required this.sha256,
  });
  final String name, sha256;
  final int size;
}

final class ReceiveFile {
  const ReceiveFile({
    required this.token,
    required this.metadata,
    required this.key,
    required this.deadlineMicros,
  });
  final String token, key;
  final ReceiveMetadata metadata;
  final int deadlineMicros;
}

final class ReceiveCheckpoint {
  const ReceiveCheckpoint({
    required this.offset,
    required this.sha256,
    required this.identity,
  });
  final int offset;
  final String sha256, identity;
}

/// Only a successful native atomic commit can return this receipt. Append's
/// offset and a checkpoint never imply a complete published file.
final class ReceiveReceipt {
  const ReceiveReceipt({
    required this.name,
    required this.size,
    required this.sha256,
  });
  final String name, sha256;
  final int size;
}

enum ReceiveStopMode { pause, cancel }

enum ReceiveStopState { paused, cancelled, committing, committed }

final class ReceiveAccessFailure implements Exception {
  const ReceiveAccessFailure(this.code);
  final String code;
  @override
  String toString() => 'ReceiveAccessFailure($code)';
}

/// Local opaque capabilities. No method accepts a filesystem path.
/// Native implementations independently enforce identity, original deadlines,
/// scope epochs, bounded I/O, atomic publication and cleanup ownership.
abstract interface class ReceiveAccess {
  /// Reopens the native saved destination; uses Downloads/串串 only when no
  /// setting exists. Invalid saved settings fail rather than silently falling back.
  Future<ReceiveDirectory> configuredDirectory();

  /// Native picker selection is persisted before returning its fresh capability.
  Future<ReceiveDirectory?> pickDirectory();
  Future<void> releaseDirectory(ReceiveDirectory directory);
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  });
  Future<ReceiveStopState> stopScope(ReceiveScope scope, ReceiveStopMode mode);
  Future<void> closeScope(ReceiveScope scope);
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  });
  Future<int> append(
    ReceiveFile file,
    ReceiveScope scope,
    int offset,
    Uint8List bytes,
  );
  Future<ReceiveCheckpoint> checkpoint(ReceiveFile file);
  Future<void> resume(
    ReceiveFile file,
    ReceiveScope scope,
    ReceiveCheckpoint checkpoint,
  );
  Future<ReceiveReceipt> commit(ReceiveFile file, ReceiveScope scope);
  Future<void> abort(ReceiveFile file);
  Future<void> retryCleanup(ReceiveFile file);
  Future<void> release(ReceiveFile file);
}

final class MethodChannelReceiveAccess implements ReceiveAccess {
  static const _channel = MethodChannel('dev.sharehub.client/platform');
  Future<Object?> _call(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(
        'files.receive.$method',
        arguments,
      );
    } on PlatformException catch (error) {
      throw ReceiveAccessFailure(_nativeFailureCode(error.code));
    } on MissingPluginException {
      throw const ReceiveAccessFailure('platform_unavailable');
    }
  }

  static String _nativeFailureCode(String code) => switch (code) {
    'invalid_token' ||
    'stale_scope' ||
    'invalid_name' ||
    'invalid_range' ||
    'resource_limit' ||
    'unsupported_storage' ||
    'directory_changed' ||
    'source_changed' ||
    'integrity_mismatch' ||
    'permission_denied' ||
    'disk_full' ||
    'io_failure' ||
    'cancelled' ||
    'paused' ||
    'expired' ||
    'clock_unavailable' ||
    'name_exhausted' ||
    'cleanup_failed' ||
    'settings_unavailable' => code,
    _ => 'io_failure',
  };

  @override
  Future<ReceiveDirectory> configuredDirectory() async =>
      _directory(await _call('directoryConfigured'));

  @override
  Future<ReceiveDirectory?> pickDirectory() async {
    final result = await _call('directoryPick');
    return result == null ? null : _directory(result);
  }

  @override
  Future<void> releaseDirectory(ReceiveDirectory directory) async {
    _token(directory.token);
    await _call('directoryRelease', directory.token);
  }

  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async {
    _token(key);
    if (deadlineMicros <= 0 || deadlineMicros > FileLimits.maxOffset) {
      _fail('invalid_range');
    }
    return ReceiveScope(
      token: _nativeToken(
        await _call('scopeOpen', {
          'key': key,
          'deadlineMicros': deadlineMicros,
        }),
      ),
      key: key,
      deadlineMicros: deadlineMicros,
    );
  }

  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async {
    _token(scope.token);
    final state = switch (await _call('scopeStop', {
      'scope': scope.token,
      'mode': mode.name,
    })) {
      'paused' => ReceiveStopState.paused,
      'cancelled' => ReceiveStopState.cancelled,
      'committing' => ReceiveStopState.committing,
      'committed' => ReceiveStopState.committed,
      _ => _fail('invalid_native_result'),
    };
    if (mode == ReceiveStopMode.cancel && state == ReceiveStopState.paused) {
      _fail('invalid_native_result');
    }
    return state;
  }

  @override
  Future<void> closeScope(ReceiveScope scope) async {
    _token(scope.token);
    await _call('scopeClose', scope.token);
  }

  @override
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  }) async {
    _token(directory.token);
    _token(scope.token);
    _token(scope.key);
    _metadata(metadata);
    if (scope.deadlineMicros <= 0 ||
        scope.deadlineMicros > FileLimits.maxOffset) {
      _fail('invalid_range');
    }
    final token = _nativeToken(
      await _call('begin', {
        'directory': directory.token,
        'scope': scope.token,
        'name': metadata.name,
        'size': metadata.size,
        'sha256': metadata.sha256,
      }),
    );
    return ReceiveFile(
      token: token,
      metadata: metadata,
      key: scope.key,
      deadlineMicros: scope.deadlineMicros,
    );
  }

  @override
  Future<int> append(
    ReceiveFile file,
    ReceiveScope scope,
    int offset,
    Uint8List bytes,
  ) async {
    _binding(file, scope);
    if (offset < 0 ||
        offset > file.metadata.size ||
        bytes.isEmpty ||
        bytes.length > FileLimits.chunkBytes ||
        bytes.length > file.metadata.size - offset) {
      _fail('invalid_range');
    }
    final result = await _call('append', {
      'token': file.token,
      'scope': scope.token,
      'offset': offset,
      'bytes': bytes,
    });
    if (result is! int || result != offset + bytes.length) {
      _fail('invalid_native_result');
    }
    return result;
  }

  @override
  Future<ReceiveCheckpoint> checkpoint(ReceiveFile file) async {
    _token(file.token);
    final value = _map(await _call('checkpoint', file.token));
    final offset = value['offset'];
    if (offset is! int || offset < 0 || offset > file.metadata.size) {
      _fail('invalid_native_result');
    }
    return ReceiveCheckpoint(
      offset: offset,
      sha256: _nativeHash(value['sha256']),
      identity: _nativeToken(value['identity']),
    );
  }

  @override
  Future<void> resume(
    ReceiveFile file,
    ReceiveScope scope,
    ReceiveCheckpoint checkpoint,
  ) async {
    _binding(file, scope);
    _token(checkpoint.identity);
    if (checkpoint.offset < 0 ||
        checkpoint.offset > file.metadata.size ||
        !_hash(checkpoint.sha256)) {
      _fail('invalid_range');
    }
    await _call('resume', {
      'token': file.token,
      'scope': scope.token,
      'offset': checkpoint.offset,
      'sha256': checkpoint.sha256,
      'identity': checkpoint.identity,
    });
  }

  @override
  Future<ReceiveReceipt> commit(ReceiveFile file, ReceiveScope scope) async {
    _binding(file, scope);
    final value = _map(
      await _call('commit', {'token': file.token, 'scope': scope.token}),
    );
    final name = value['name'], size = value['size'];
    final hash = _nativeHash(value['sha256']);
    if (name is! String ||
        size is! int ||
        size != file.metadata.size ||
        hash != file.metadata.sha256) {
      _fail('invalid_native_result');
    }
    try {
      validateFileName(name);
    } on FileProtocolFailure {
      _fail('invalid_native_result');
    }
    return ReceiveReceipt(name: name, size: size, sha256: hash);
  }

  @override
  Future<void> abort(ReceiveFile file) async {
    _token(file.token);
    await _call('abort', file.token);
  }

  @override
  Future<void> retryCleanup(ReceiveFile file) async {
    _token(file.token);
    await _call('retryCleanup', file.token);
  }

  @override
  Future<void> release(ReceiveFile file) async {
    _token(file.token);
    await _call('release', file.token);
  }

  static void _binding(ReceiveFile file, ReceiveScope scope) {
    _token(file.token);
    _token(scope.token);
    if (file.key != scope.key || file.deadlineMicros != scope.deadlineMicros) {
      _fail('scope_mismatch');
    }
  }

  static void _metadata(ReceiveMetadata metadata) {
    validateFileName(metadata.name);
    if (metadata.size < 0 ||
        metadata.size > FileLimits.maxOffset ||
        !_hash(metadata.sha256)) {
      _fail('invalid_range');
    }
  }

  static ReceiveDirectory _directory(Object? value) {
    final map = _map(value);
    final label = map['label'];
    if (label is! String ||
        label.isEmpty ||
        label.contains('\u0000') ||
        label.length > 4096) {
      _fail('invalid_native_result');
    }
    return ReceiveDirectory(token: _nativeToken(map['token']), label: label);
  }

  static Map<Object?, Object?> _map(Object? value) {
    if (value is! Map) _fail('invalid_native_result');
    return value;
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
    } on ReceiveAccessFailure {
      _fail('invalid_native_result');
    }
    return value;
  }

  static bool _hash(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  static String _nativeHash(Object? value) {
    if (value is! String || !_hash(value)) _fail('invalid_native_result');
    return value;
  }

  static Never _fail(String code) => throw ReceiveAccessFailure(code);
}
