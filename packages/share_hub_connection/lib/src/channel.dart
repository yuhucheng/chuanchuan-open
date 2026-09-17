import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'identity.dart';

/// Length-prefixed bounded frames. No payload logging and no unbounded queue.
class WireChannel {
  WireChannel(this.socket) {
    unawaited(
      socket.done.then<void>((_) => _ended(), onError: (Object _) => _ended()),
    );
    _subscription = socket.listen(
      _receive,
      onDone: _ended,
      onError: (Object _) {
        _ended();
      },
    );
  }
  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _frames = Queue<Map<String, dynamic>>();
  List<int> _buffer = [];
  Completer<Map<String, dynamic>>? _waiting;
  bool _closed = false;
  static const maximumFrameBytes = 8192;
  int _frameLimit = maximumFrameBytes;
  void enableSessionFrames() => _frameLimit = 131072;

  void _receive(Uint8List bytes) {
    if (_closed) return;
    if (_buffer.length + bytes.length > _frameLimit * 8) {
      close();
      return;
    }
    _buffer.addAll(bytes);
    try {
      while (_buffer.length >= 4) {
        final size =
            (_buffer[0] << 24) |
            (_buffer[1] << 16) |
            (_buffer[2] << 8) |
            _buffer[3];
        if (size <= 0 || size > _frameLimit) {
          throw const ConnectionFailure('invalid_message');
        }
        if (_buffer.length < size + 4) return;
        final message = jsonDecode(utf8.decode(_buffer.sublist(4, size + 4)));
        _buffer = _buffer.sublist(size + 4);
        if (message is! Map<String, dynamic>) {
          throw const ConnectionFailure('invalid_message');
        }
        final waiting = _waiting;
        if (waiting != null) {
          _waiting = null;
          waiting.complete(message);
        } else {
          if (_frames.length >= 8) {
            throw const ConnectionFailure('rate_limited');
          }
          _frames.add(message);
        }
      }
    } catch (_) {
      close();
    }
  }

  Future<Map<String, dynamic>> next() {
    if (_closed) return Future.error(const ConnectionFailure('disconnected'));
    if (_frames.isNotEmpty) return Future.value(_frames.removeFirst());
    if (_waiting != null) throw StateError('Only one reader is allowed.');
    return (_waiting = Completer<Map<String, dynamic>>()).future;
  }

  void send(Map<String, dynamic> message) {
    if (_closed) throw const ConnectionFailure('disconnected');
    final bytes = utf8.encode(jsonEncode(message));
    if (bytes.length > _frameLimit) {
      throw const ConnectionFailure('invalid_message');
    }
    final header = ByteData(4)..setUint32(0, bytes.length);
    socket.add([...header.buffer.asUint8List(), ...bytes]);
  }

  void _ended() {
    if (_closed) return;
    _closed = true;
    _buffer.clear();
    _frames.clear();
    final waiting = _waiting;
    _waiting = null;
    waiting?.completeError(const ConnectionFailure('disconnected'));
  }

  void close() {
    _ended();
    socket.destroy();
    unawaited(_subscription.cancel());
  }
}
