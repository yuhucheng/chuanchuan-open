import 'package:flutter/services.dart';

class SelectedFile {
  const SelectedFile({
    required this.token,
    required this.name,
    required this.size,
  });
  final String token;
  final String name;
  final int size;
}

/// Local capabilities from a native picker, never arbitrary filesystem paths.
abstract interface class FileAccess {
  Future<List<SelectedFile>> pickFiles();
  Future<Uint8List> read(String token, int offset, int length);
  Future<void> finish(String token);
  Future<void> release(String token);
}

class MethodChannelFileAccess implements FileAccess {
  static const _channel = MethodChannel('dev.sharehub.client/platform');
  static const _drops = MethodChannel('dev.sharehub.client/files/drop');

  void setDropHandler(
    Future<void> Function(List<SelectedFile>)? onDrop, {
    void Function(String)? onError,
  }) {
    _drops.setMethodCallHandler(
      onDrop == null
          ? null
          : (call) async {
              if (call.method == 'files.dropError' &&
                  call.arguments is String) {
                onError?.call(call.arguments as String);
                return true;
              }
              if (call.method != 'files.dropped' || call.arguments is! List) {
                throw PlatformException(code: 'invalid_drop');
              }
              final files = (call.arguments as List).map((entry) {
                if (entry is! Map ||
                    entry['token'] is! String ||
                    entry['name'] is! String ||
                    entry['size'] is! int) {
                  throw PlatformException(code: 'invalid_drop');
                }
                return SelectedFile(
                  token: entry['token'] as String,
                  name: entry['name'] as String,
                  size: entry['size'] as int,
                );
              }).toList();
              await onDrop(files);
              return true;
            },
    );
  }

  @override
  Future<List<SelectedFile>> pickFiles() async {
    final result = await _channel.invokeListMethod<dynamic>('files.pick') ?? [];
    return result
        .map(
          (item) => SelectedFile(
            token: item['token'] as String,
            name: item['name'] as String,
            size: item['size'] as int,
          ),
        )
        .toList();
  }

  @override
  Future<Uint8List> read(String token, int offset, int length) async =>
      (await _channel.invokeMethod<Uint8List>('files.read', {
        'token': token,
        'offset': offset,
        'length': length,
      }))!;
  @override
  Future<void> finish(String token) =>
      _channel.invokeMethod('files.finish', token);
  @override
  Future<void> release(String token) =>
      _channel.invokeMethod('files.release', token);
}
