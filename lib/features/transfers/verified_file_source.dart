import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'file_access.dart';
import 'source_access.dart';
import 'source_authorization.dart';

enum SourcePhase {
  selected,
  verified,
  reading,
  finished,
  paused,
  cancelled,
  failed,
}

final class FileSourceFailure implements Exception {
  const FileSourceFailure(this.code);
  final String code;
  @override
  String toString() => 'FileSourceFailure($code)';
}

/// Pulls a retained native selection through two independent sequential passes.
/// The host must await verify before sending the offer, and wait for each peer
/// acknowledgement before pulling another block. Finished is local EOF only.
/// Token release remains with the selection queue; this object never owns paths.
final class VerifiedFileSource {
  VerifiedFileSource({
    required this.access,
    required this.file,
    required this.context,
  }) {
    final request = context.request;
    final name = switch (request) {
      FileOffer(:final name) || FileResume(:final name) => name,
      _ => null,
    };
    if (context.authorization is! LocalSessionRequest ||
        context.size != file.size ||
        name != file.name) {
      throw const FileSourceFailure('source_context_mismatch');
    }
    _authorization = SourceAuthorization(
      context,
      access,
      fileToken: file.token,
    );
  }

  final SourceAccess access;
  final SelectedFile file;
  final FileTransferContext context;
  late final SourceAuthorization _authorization;
  SourceScope? _scope;
  SourcePhase _phase = SourcePhase.selected;
  SourcePhase get phase => _phase;
  int _epoch = 0, _offset = 0;
  bool _busy = false;
  SourceReadPass? _pass;
  final _sendDigest = _DigestResult();
  ByteConversionSink? _sendSink;

  void _current(int epoch) {
    if (epoch != _epoch || _phase == SourcePhase.cancelled) {
      throw const FileSourceFailure('cancelled');
    }
    if (_phase == SourcePhase.paused) throw const FileSourceFailure('paused');
    _authorization.requireCurrent();
  }

  Future<void> _guard(int epoch) async {
    _current(epoch);
    await _authorization.check();
    _current(epoch);
    _authorization.requireCurrent();
  }

  Future<T> _run<T>(SourcePhase expected, Future<T> Function(int) body) async {
    if (_busy || _phase != expected) {
      throw const FileSourceFailure('source_unavailable');
    }
    _busy = true;
    final epoch = _epoch;
    try {
      await _guard(epoch);
      _current(epoch);
      final result = await body(epoch);
      _current(epoch);
      return result;
    } catch (_) {
      if (_phase != SourcePhase.cancelled && _phase != SourcePhase.paused) {
        _phase = SourcePhase.failed;
        unawaited(_authorization.stop(SourceStopMode.cancel));
      }
      _closeSendDigest();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<void> verify() => _run(SourcePhase.selected, (epoch) async {
    final scope = await _authorization.open();
    _scope = scope;
    await _guard(epoch);
    final pass = await access.beginPass(scope);
    await _guard(epoch);
    _current(epoch);
    final digest = _DigestResult();
    final sink = hashes.sha256.startChunkedConversion(digest);
    var offset = 0;
    try {
      while (offset < file.size) {
        final expected = math.min(256 * 1024, file.size - offset);
        final bytes = await access.readPass(pass, offset, expected);
        await _guard(epoch);
        _current(epoch);
        if (bytes.length != expected) {
          throw const FileSourceFailure('source_changed');
        }
        sink.add(bytes);
        offset += bytes.length;
      }
      await access.finishPass(pass);
      await _guard(epoch);
      _current(epoch);
    } finally {
      sink.close();
    }
    if (digest.value.toString() != context.sha256) {
      throw const FileSourceFailure('source_changed');
    }
    _phase = SourcePhase.verified;
  });

  /// A resumed pass still starts at byte zero. The verified prefix contributes
  /// to the independent full sending digest; peer offsets never become seeks.
  Future<void> beginSend({int offset = 0, String? prefixSha256}) =>
      _run(SourcePhase.verified, (epoch) async {
        final resumed = context.request is FileResume;
        if (offset < 0 ||
            offset > file.size ||
            (resumed &&
                (prefixSha256 == null ||
                    !RegExp(r'^[0-9a-f]{64}$').hasMatch(prefixSha256))) ||
            (!resumed && (offset != 0 || prefixSha256 != null))) {
          throw const FileSourceFailure('invalid_resume');
        }
        final pass = await access.beginPass(_scope!);
        await _guard(epoch);
        _current(epoch);
        _pass = pass;
        _offset = 0;
        _sendSink = hashes.sha256.startChunkedConversion(_sendDigest);
        if (resumed) {
          final prefix = _DigestResult();
          final prefixSink = hashes.sha256.startChunkedConversion(prefix);
          try {
            while (_offset < offset) {
              final length = math.min(context.chunkBytes, offset - _offset);
              final bytes = await access.readPass(pass, _offset, length);
              await _guard(epoch);
              if (bytes.length != length) {
                throw const FileSourceFailure('source_changed');
              }
              prefixSink.add(bytes);
              _sendSink!.add(bytes);
              _offset += bytes.length;
            }
          } finally {
            prefixSink.close();
          }
          if (prefix.value.toString() != prefixSha256) {
            throw const FileSourceFailure('prefix_mismatch');
          }
        }
        _phase = SourcePhase.reading;
      });

  /// One block per pull, with no asynchronous read-ahead or message buffering.
  Future<Uint8List?> readNext({int? maxBytes}) =>
      _run(SourcePhase.reading, (epoch) async {
        final bound = maxBytes ?? context.chunkBytes;
        if (bound < 1 || bound > context.chunkBytes) {
          throw const FileSourceFailure('invalid_chunk');
        }
        if (_offset == file.size) return null;
        final expected = math.min(bound, file.size - _offset);
        final bytes = await access.readPass(_pass!, _offset, expected);
        await _guard(epoch);
        _current(epoch);
        if (bytes.length != expected) {
          throw const FileSourceFailure('source_changed');
        }
        _sendSink!.add(bytes);
        _offset += bytes.length;
        return bytes;
      });

  Future<void> finishSend() => _run(SourcePhase.reading, (epoch) async {
    if (_offset != file.size) {
      throw const FileSourceFailure('source_incomplete');
    }
    await access.finishPass(_pass!);
    await _guard(epoch);
    _current(epoch);
    _closeSendDigest();
    if (_sendDigest.value.toString() != context.sha256) {
      throw const FileSourceFailure('source_changed');
    }
    _phase = SourcePhase.finished;
  });

  void _closeSendDigest() {
    _sendSink?.close();
    _sendSink = null;
  }

  /// Gate locally and dispatch native cancellation without waiting for file I/O.
  /// A failure remains observable through this future and [whenStopped].
  Future<SourceStopState> cancel() {
    _epoch++;
    _phase = SourcePhase.cancelled;
    _closeSendDigest();
    return _authorization.stop(SourceStopMode.cancel);
  }

  /// Set pause intent BEFORE suspending the grant. Keep this owner until a new
  /// source has opened a scope using context.resumeWith; then close the old one.
  /// Reusing this owner cannot reopen stale operation authorization.
  Future<SourceStopState> pause() {
    if (_phase == SourcePhase.cancelled || _phase == SourcePhase.failed) {
      return cancel();
    }
    _epoch++;
    _phase = SourcePhase.paused;
    _closeSendDigest();
    return _authorization.stop(SourceStopMode.pause);
  }

  Future<SourceStopState> get whenStopped => _authorization.whenStopped;

  /// Releases scope metadata, never the selected-file token owned by the queue.
  Future<void> close() {
    _epoch++;
    if (_phase != SourcePhase.finished && _phase != SourcePhase.failed) {
      _phase = SourcePhase.cancelled;
    }
    _closeSendDigest();
    return _authorization.close();
  }
}

final class _DigestResult implements Sink<hashes.Digest> {
  hashes.Digest? value;
  @override
  void add(hashes.Digest data) => value = data;
  @override
  void close() {}
}
