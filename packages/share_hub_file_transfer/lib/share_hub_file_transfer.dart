/// Versioned wire primitives only: no networking, file access or commit authority.
library;

import 'dart:convert';
import 'dart:math';

import 'package:share_hub_session_api/share_hub_session_api.dart';

part 'src/file_lifecycle.dart';
part 'src/file_retirement.dart';

/// Authenticated request binding; it performs no file access or publication.
final class FileTransferContext {
  FileTransferContext._(this._registry, this.authorization, this.request);
  final GrantRegistry _registry;
  final SessionAuthorization authorization;
  final FileMessage request;
  String get transferId => request.transferId;
  int get transferOrdinal => switch (request) {
    FileOffer(:final transferOrdinal) ||
    FileResume(:final transferOrdinal) => transferOrdinal,
    _ => throw StateError('request'),
  };
  GrantRole get transferSender => authorization.sender;
  String get transferKey =>
      '${authorization.grant.encodedId}/${base64Url.encode(transferSender == GrantRole.initiator ? authorization.grant.initiatorKey : authorization.grant.receiverKey)}/$transferOrdinal/$transferId';
  int get size => switch (request) {
    FileOffer(:final size) || FileResume(:final size) => size,
    _ => throw StateError('request'),
  };
  String get sha256 => switch (request) {
    FileOffer(:final sha256) || FileResume(:final sha256) => sha256,
    _ => throw StateError('request'),
  };
  int get chunkBytes => switch (request) {
    FileOffer(:final chunkBytes) || FileResume(:final chunkBytes) => chunkBytes,
    _ => throw StateError('request'),
  };
  static Future<FileTransferContext> fromRequest(
    GrantRegistry registry,
    SessionAuthorization authorization,
  ) async {
    final context = await _bind(registry, authorization);
    authorization.requireCurrent();
    if (context.request is! FileOffer) _fail('invalid_state');
    return context;
  }

  static Future<FileTransferContext> _bind(
    GrantRegistry registry,
    SessionAuthorization authorization,
  ) async {
    await registry.verify(authorization);
    authorization.requireCurrent();
    if (authorization.operation != SessionOperation.file) {
      _fail('context_mismatch');
    }
    final request = FileCodec.decode(authorization.body);
    if (request is! FileOffer && request is! FileResume) _fail('invalid_state');
    return FileTransferContext._(registry, authorization, request);
  }

  /// Receiver bootstrap after physical recovery, only when its retained slot
  /// history proves no native file was ever owned for this transfer. A host
  /// must never use this to replace a cancelled/failed/retained file or receipt.
  static Future<FileTransferContext> fromUnstartedResume(
    GrantRegistry registry,
    VerifiedSessionMessage authorization,
  ) async {
    final context = await _bind(registry, authorization);
    authorization.requireCurrent();
    if (context.request is! FileResume ||
        authorization.transportGeneration <= 1) {
      _fail('invalid_state');
    }
    return context;
  }

  /// Rebind only a retained original transfer. Host must also check its live
  /// slot/epoch, unused session ID, source and temporary-prefix checkpoints.
  Future<FileTransferContext> resumeWith(SessionAuthorization next) async {
    final resumed = await _bind(_registry, next);
    next.requireCurrent();
    final metadata = resumed.request;
    final originalName = switch (request) {
      FileOffer(:final name) || FileResume(:final name) => name,
      _ => throw StateError('request'),
    };
    if (metadata is! FileResume ||
        !next.hasSameGrantAs(authorization) ||
        !identical(next.grant, authorization.grant) ||
        next.expiresMicros != authorization.expiresMicros ||
        next.sender != authorization.sender ||
        (next is LocalSessionRequest) !=
            (authorization is LocalSessionRequest) ||
        next.transportGeneration < authorization.transportGeneration ||
        next.sessionId == authorization.sessionId ||
        metadata.transferId != transferId ||
        metadata.transferOrdinal != transferOrdinal ||
        metadata.name != originalName ||
        metadata.size != size ||
        metadata.sha256 != sha256 ||
        metadata.chunkBytes != chunkBytes) {
      _fail('resume_mismatch');
    }
    return resumed;
  }

  Future<void> check() async {
    await _registry.verify(authorization);
    authorization.requireCurrent();
  }

  void requireCurrent() => authorization.requireCurrent();
  Future<FileMessage> decodeSignal(VerifiedSessionSignal signal) async {
    if (!identical(signal.authorization, authorization)) {
      _fail('context_mismatch');
    }
    await check();
    requireCurrent();
    final message = FileCodec.decode(signal.body);
    _validateSignal(message, authorization is VerifiedSessionMessage);
    return message;
  }

  Future<void> validateOutgoing(FileMessage message) async {
    await check();
    requireCurrent();
    FileCodec.encode(message);
    _validateSignal(message, authorization is LocalSessionRequest);
  }

  void _validateSignal(FileMessage message, bool fromSender) {
    if (message.transferId != transferId) _fail('context_mismatch');
    if (message is FileOffer ||
        message is FileResume ||
        message is FileTerminate ||
        message is FileRetire ||
        message is FileRetired) {
      _fail('invalid_state');
    }
    final senderOnly =
        message is FileChunk ||
        message is FileFinish ||
        message is FileResumeAccept;
    final receiverOnly =
        message is FileAccept ||
        message is FileAck ||
        message is FileComplete ||
        message is FileResumeState ||
        message is FileRejected;
    if ((senderOnly && !fromSender) || (receiverOnly && fromSender)) {
      _fail('direction_denied');
    }
    final offset = switch (message) {
      FileChunk(:final offset) => offset,
      FileAck(:final nextOffset) => nextOffset,
      FilePaused(:final offset) => offset,
      FileResumeState(:final offset) => offset,
      FileResumeAccept(:final offset) => offset,
      _ => 0,
    };
    if (offset > size) _fail('invalid_range');
    if (message is FileChunk &&
        (message.data.length > chunkBytes ||
            message.data.length > size - offset)) {
      _fail('invalid_range');
    }
    if (message is FileAccept &&
        (request is FileResume || message.acceptedChunkBytes > chunkBytes)) {
      _fail('invalid_state');
    }
    if (message is FileFinish &&
        (message.size != size || message.sha256 != sha256)) {
      _fail('integrity_mismatch');
    }
    if (message is FileComplete &&
        (message.size != size || message.sha256 != sha256)) {
      _fail('integrity_mismatch');
    }
    final attempt = switch (message) {
      FileResumeState(:final attemptId) => attemptId,
      FileResumeAccept(:final attemptId) => attemptId,
      _ => null,
    };
    if (attempt != null &&
        (request is! FileResume ||
            attempt != (request as FileResume).attemptId)) {
      _fail('context_mismatch');
    }
  }
}

enum FileProgressPhase { transferring, verifying, completed, cancelled }

/// Pure arithmetic only. Caller must verify writes and atomic commit separately.
final class FileProgress {
  factory FileProgress({
    required int size,
    int chunkBytes = FileLimits.chunkBytes,
  }) {
    _range(size);
    if (chunkBytes < 1 || chunkBytes > FileLimits.chunkBytes) {
      _fail('invalid_chunk');
    }
    return FileProgress._(
      size,
      chunkBytes,
      0,
      0,
      FileProgressPhase.transferring,
    );
  }
  const FileProgress._(
    this.size,
    this.chunkBytes,
    this.sentOffset,
    this.acknowledgedOffset,
    this.phase,
  );
  final int size, chunkBytes, sentOffset, acknowledgedOffset;
  final FileProgressPhase phase;
  FileProgress chunk({required int offset, required int length}) {
    if (phase != FileProgressPhase.transferring ||
        sentOffset != acknowledgedOffset) {
      _fail('invalid_state');
    }
    if (offset != sentOffset ||
        length < 1 ||
        length > chunkBytes ||
        length > size - offset) {
      _fail('invalid_range');
    }
    return FileProgress._(
      size,
      chunkBytes,
      offset + length,
      acknowledgedOffset,
      phase,
    );
  }

  FileProgress ack(int nextOffset) {
    if (phase != FileProgressPhase.transferring ||
        sentOffset == acknowledgedOffset ||
        nextOffset != sentOffset) {
      _fail('invalid_state');
    }
    return FileProgress._(size, chunkBytes, sentOffset, nextOffset, phase);
  }

  FileProgress finish() {
    if (phase != FileProgressPhase.transferring || acknowledgedOffset != size) {
      _fail('invalid_state');
    }
    return FileProgress._(
      size,
      chunkBytes,
      sentOffset,
      acknowledgedOffset,
      FileProgressPhase.verifying,
    );
  }

  FileProgress complete() {
    if (phase != FileProgressPhase.verifying) _fail('invalid_state');
    return FileProgress._(
      size,
      chunkBytes,
      sentOffset,
      acknowledgedOffset,
      FileProgressPhase.completed,
    );
  }

  FileProgress cancel() {
    if (phase == FileProgressPhase.completed) return this;
    return FileProgress._(
      size,
      chunkBytes,
      sentOffset,
      acknowledgedOffset,
      FileProgressPhase.cancelled,
    );
  }
}

const fileProtocolVersion = 2;

abstract final class FileLimits {
  static const chunkBytes = 32768;
  static const window = 1;
  static const controlBytes = 4096;
  static const messageBytes = 49152;
  static const nameBytes = 255;
  static const maxOffset = 0x7fffffffffffffff;
}

final class FileProtocolFailure implements Exception {
  const FileProtocolFailure(this.code);
  final String code;
  @override
  String toString() => 'FileProtocolFailure($code)';
}

Never _fail(String code) => throw FileProtocolFailure(code);
String newTransferId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

void _id(String value) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) _fail('invalid_id');
}

void _range(int value) {
  if (value < 0 || value > FileLimits.maxOffset) _fail('invalid_range');
}

int _decimal(Object? value) {
  if (value is! String ||
      value.length > 19 ||
      !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    _fail('invalid_range');
  }
  final result = int.tryParse(value);
  if (result == null) _fail('invalid_range');
  _range(result);
  return result;
}

void validateFileName(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.endsWith('.') ||
      name.endsWith(' ') ||
      utf8.encode(name).length > FileLimits.nameBytes ||
      RegExp(r'[\x00-\x1f\x7f/\\:<>"|?*]').hasMatch(name) ||
      RegExp(
        r'^(CON|CONIN\$|CONOUT\$|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(name)) {
    _fail('invalid_name');
  }
  // Reject unpaired UTF-16 surrogates rather than silently replacing them.
  final units = name.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        _fail('invalid_name');
      }
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      _fail('invalid_name');
    }
  }
}

String _data(List<int> bytes) {
  if (bytes.isEmpty ||
      bytes.length > FileLimits.chunkBytes ||
      bytes.any((b) => b < 0 || b > 255)) {
    _fail('invalid_chunk');
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}

List<int> _decodeData(Object? value) {
  if (value is! String ||
      value.length > 43691 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    _fail('invalid_encoding');
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(value));
    if (_data(bytes) != value) _fail('invalid_encoding');
    return bytes;
  } on FormatException {
    _fail('invalid_encoding');
  }
}

const _errors = {
  'invalid_message',
  'invalid_name',
  'invalid_range',
  'invalid_encoding',
  'invalid_chunk',
  'unsupported_version',
  'context_mismatch',
  'direction_denied',
  'invalid_state',
  'resource_limit',
  'integrity_mismatch',
  'source_changed',
  'permission_denied',
  'disk_full',
  'io_failure',
  'cancelled',
  'expired',
  'stale_authorization',
  'resume_mismatch',
  'unsupported_storage',
  'timeout',
};

sealed class FileMessage {
  FileMessage({required this.transferId}) {
    _id(transferId);
  }
  final String transferId;
  String get type;
  Map<String, Object> toJson();
}

final class FileOffer extends FileMessage {
  FileOffer({
    required super.transferId,
    required this.transferOrdinal,
    required this.name,
    required this.size,
    required this.sha256,
    required this.chunkBytes,
  }) {
    _validate(toJson());
  }
  final String name;
  final int transferOrdinal;
  final int size;
  final String sha256;
  final int chunkBytes;
  @override
  String get type => 'offer';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'transferOrdinal': transferOrdinal.toString(),
    'name': name,
    'size': size.toString(),
    'sha256': sha256,
    'chunkBytes': chunkBytes,
  };
}

/// A fresh operation may terminate only this original directional transfer.
/// It is never an offer or a resume and must not allocate a native file/scope.
final class FileTerminate extends FileMessage {
  FileTerminate({
    required super.transferId,
    required this.transferOrdinal,
    required this.transferSender,
    required this.name,
    required this.size,
    required this.sha256,
    required this.chunkBytes,
  }) {
    _validate(toJson());
  }
  final GrantRole transferSender;
  final int transferOrdinal;
  final String name, sha256;
  final int size, chunkBytes;
  @override
  String get type => 'terminate';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'transferOrdinal': transferOrdinal.toString(),
    'transferSender': transferSender.name,
    'name': name,
    'size': size.toString(),
    'sha256': sha256,
    'chunkBytes': chunkBytes,
  };
}

final class FileAccept extends FileMessage {
  FileAccept({
    required super.transferId,
    required this.acceptedChunkBytes,
    required this.window,
    required this.offset,
  }) {
    _validate(toJson());
  }
  final int acceptedChunkBytes;
  final int window;
  final int offset;
  @override
  String get type => 'accept';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'acceptedChunkBytes': acceptedChunkBytes,
    'window': window,
    'offset': offset.toString(),
  };
}

final class FileChunk extends FileMessage {
  FileChunk({
    required super.transferId,
    required this.offset,
    required List<int> data,
  }) : data = List<int>.unmodifiable(data) {
    _validate(toJson());
  }
  final int offset;
  final List<int> data;
  @override
  String get type => 'chunk';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'offset': offset.toString(),
    'data': _data(data),
  };
}

final class FileAck extends FileMessage {
  FileAck({required super.transferId, required this.nextOffset}) {
    _validate(toJson());
  }
  final int nextOffset;
  @override
  String get type => 'ack';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'nextOffset': nextOffset.toString(),
  };
}

final class FileFinish extends FileMessage {
  FileFinish({
    required super.transferId,
    required this.size,
    required this.sha256,
  }) {
    _validate(toJson());
  }
  final int size;
  final String sha256;
  @override
  String get type => 'finish';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'size': size.toString(),
    'sha256': sha256,
  };
}

final class FileComplete extends FileMessage {
  FileComplete({
    required super.transferId,
    required this.actualName,
    required this.size,
    required this.sha256,
  }) {
    _validate(toJson());
  }
  final String actualName;
  final int size;
  final String sha256;
  @override
  String get type => 'complete';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'actualName': actualName,
    'size': size.toString(),
    'sha256': sha256,
  };
}

final class FilePause extends FileMessage {
  FilePause({required super.transferId}) {
    _validate(toJson());
  }
  @override
  String get type => 'pause';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
  };
}

final class FilePaused extends FileMessage {
  FilePaused({required super.transferId, required this.offset}) {
    _validate(toJson());
  }
  final int offset;
  @override
  String get type => 'paused';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'offset': offset.toString(),
  };
}

final class FileResume extends FileMessage {
  FileResume({
    required super.transferId,
    required this.transferOrdinal,
    required this.name,
    required this.size,
    required this.sha256,
    required this.chunkBytes,
    required this.attemptId,
  }) {
    _validate(toJson());
  }
  final String name;
  final int transferOrdinal;
  final int size;
  final String sha256;
  final int chunkBytes;
  final String attemptId;
  @override
  String get type => 'resume';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'transferOrdinal': transferOrdinal.toString(),
    'name': name,
    'size': size.toString(),
    'sha256': sha256,
    'chunkBytes': chunkBytes,
    'attemptId': attemptId,
  };
}

final class FileResumeState extends FileMessage {
  FileResumeState({
    required super.transferId,
    required this.attemptId,
    required this.offset,
    required this.prefixSha256,
  }) {
    _validate(toJson());
  }
  final String attemptId;
  final int offset;
  final String prefixSha256;
  @override
  String get type => 'resume-state';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'attemptId': attemptId,
    'offset': offset.toString(),
    'prefixSha256': prefixSha256,
  };
}

final class FileResumeAccept extends FileMessage {
  FileResumeAccept({
    required super.transferId,
    required this.attemptId,
    required this.offset,
    required this.prefixSha256,
  }) {
    _validate(toJson());
  }
  final String attemptId;
  final int offset;
  final String prefixSha256;
  @override
  String get type => 'resume-accept';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'attemptId': attemptId,
    'offset': offset.toString(),
    'prefixSha256': prefixSha256,
  };
}

final class FileCancel extends FileMessage {
  FileCancel({required super.transferId}) {
    _validate(toJson());
  }
  @override
  String get type => 'cancel';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
  };
}

final class FileCancelled extends FileMessage {
  FileCancelled({required super.transferId}) {
    _validate(toJson());
  }
  @override
  String get type => 'cancelled';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
  };
}

final class FileFailed extends FileMessage {
  FileFailed({required super.transferId, required this.code}) {
    _validate(toJson());
  }
  final String code;
  @override
  String get type => 'failed';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'code': code,
  };
}

const _fields = <String, Set<String>>{
  'offer': {'transferOrdinal', 'name', 'size', 'sha256', 'chunkBytes'},
  'terminate': {
    'transferOrdinal',
    'transferSender',
    'name',
    'size',
    'sha256',
    'chunkBytes',
  },
  'retire': {
    'transferOrdinal',
    'transferSender',
    'name',
    'size',
    'sha256',
    'chunkBytes',
    'outcome',
  },
  'retired': {'transferOrdinal'},
  'rejected': {'code'},
  'accept': {'acceptedChunkBytes', 'window', 'offset'},
  'chunk': {'offset', 'data'},
  'ack': {'nextOffset'},
  'finish': {'size', 'sha256'},
  'complete': {'actualName', 'size', 'sha256'},
  'pause': {},
  'paused': {'offset'},
  'resume': {
    'transferOrdinal',
    'name',
    'size',
    'sha256',
    'chunkBytes',
    'attemptId',
  },
  'resume-state': {'attemptId', 'offset', 'prefixSha256'},
  'resume-accept': {'attemptId', 'offset', 'prefixSha256'},
  'cancel': {},
  'cancelled': {},
  'failed': {'code'},
};
void _validate(Map<String, Object?> m) {
  if (m['v'] is! int || m['v'] != fileProtocolVersion) {
    _fail('unsupported_version');
  }
  final fields = _fields[m['type']];
  if (fields == null) _fail('invalid_message');
  final retirementFields = m['type'] == 'retire'
      ? switch (m['outcome']) {
          'completed' => {'actualName'},
          'cancelled' => <String>{},
          'failed' => {'failureCode'},
          _ => _fail('invalid_message'),
        }
      : <String>{};
  final expected = {'v', 'type', 'transferId', ...fields, ...retirementFields};
  if (m.length != expected.length || !m.keys.every(expected.contains)) {
    _fail('invalid_message');
  }
  for (final key in expected.difference({
    'v',
    'window',
    'chunkBytes',
    'acceptedChunkBytes',
  })) {
    if (m[key] is! String) _fail('invalid_message');
  }
  _id(m['transferId'] as String);
  if (m.containsKey('transferSender') &&
      m['transferSender'] != 'initiator' &&
      m['transferSender'] != 'receiver') {
    _fail('direction_denied');
  }
  if (m.containsKey('attemptId')) _id(m['attemptId'] as String);
  for (final key in ['name', 'actualName']) {
    if (m.containsKey(key)) validateFileName(m[key] as String);
  }
  for (final key in ['sha256', 'prefixSha256']) {
    if (m.containsKey(key) &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(m[key] as String)) {
      _fail('invalid_digest');
    }
  }
  for (final key in ['size', 'offset', 'nextOffset']) {
    if (m.containsKey(key)) _decimal(m[key]);
  }
  if (m.containsKey('transferOrdinal')) {
    _positiveOrdinal(_decimal(m['transferOrdinal']));
  }
  for (final key in ['chunkBytes', 'acceptedChunkBytes']) {
    if (m.containsKey(key) &&
        (m[key] is! int ||
            (m[key] as int) < 1 ||
            (m[key] as int) > FileLimits.chunkBytes)) {
      _fail('invalid_chunk');
    }
  }
  if (m['type'] == 'accept' &&
      (m['window'] is! int || m['window'] != 1 || m['offset'] != '0')) {
    _fail('invalid_message');
  }
  if (m['type'] == 'chunk') {
    final bytes = _decodeData(m['data']);
    if (_decimal(m['offset']) > FileLimits.maxOffset - bytes.length) {
      _fail('invalid_range');
    }
  }
  if ((m['type'] == 'failed' || m['type'] == 'rejected') &&
      !_errors.contains(m['code'])) {
    _fail('invalid_error');
  }
  if (m.containsKey('failureCode') && !_errors.contains(m['failureCode'])) {
    _fail('invalid_error');
  }
}

abstract final class FileCodec {
  // JSON decoding otherwise silently keeps the last duplicate property. The
  // accepted schema is flat; scan actual string tokens, including escaped keys.
  static void _uniqueKeys(String body) {
    final keys = <String>{};
    for (var i = 0; i < body.length; i++) {
      if (body.codeUnitAt(i) != 34) continue;
      final start = i++;
      while (i < body.length && body.codeUnitAt(i) != 34) {
        if (body.codeUnitAt(i) == 92) i++;
        i++;
      }
      if (i >= body.length) _fail('invalid_message');
      var next = i + 1;
      while (next < body.length && ' \t\r\n'.contains(body[next])) {
        next++;
      }
      if (next < body.length && body[next] == ':') {
        final key = jsonDecode(body.substring(start, i + 1)) as String;
        if (!keys.add(key)) _fail('invalid_message');
      }
    }
  }

  static String encode(FileMessage message) {
    final fields = message.toJson();
    _validate(fields);
    final body = jsonEncode(fields);
    _limit(body, message.type);
    return body;
  }

  static void _limit(String body, String type) {
    final limit = type == 'chunk'
        ? FileLimits.messageBytes
        : FileLimits.controlBytes;
    if (utf8.encode(body).length > limit) _fail('message_limit');
  }

  static FileMessage decode(String body) {
    if (body.length > FileLimits.messageBytes ||
        utf8.encode(body).length > FileLimits.messageBytes) {
      _fail('message_limit');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      _fail('invalid_message');
    }
    if (decoded is! Map<String, dynamic>) _fail('invalid_message');
    _uniqueKeys(body);
    _validate(decoded);
    _limit(body, decoded['type'] as String);
    final m = decoded;
    final id = m['transferId'] as String;
    switch (m['type']) {
      case 'terminate':
        return FileTerminate(
          transferId: id,
          transferOrdinal: _decimal(m['transferOrdinal']),
          transferSender: m['transferSender'] == 'initiator'
              ? GrantRole.initiator
              : GrantRole.receiver,
          name: m['name'] as String,
          size: _decimal(m['size']),
          sha256: m['sha256'] as String,
          chunkBytes: m['chunkBytes'] as int,
        );
      case 'offer':
        return FileOffer(
          transferId: id,
          transferOrdinal: _decimal(m['transferOrdinal']),
          name: m['name'] as String,
          size: _decimal(m['size']),
          sha256: m['sha256'] as String,
          chunkBytes: m['chunkBytes'] as int,
        );
      case 'accept':
        return FileAccept(
          transferId: id,
          acceptedChunkBytes: m['acceptedChunkBytes'] as int,
          window: m['window'] as int,
          offset: _decimal(m['offset']),
        );
      case 'chunk':
        return FileChunk(
          transferId: id,
          offset: _decimal(m['offset']),
          data: _decodeData(m['data']),
        );
      case 'ack':
        return FileAck(transferId: id, nextOffset: _decimal(m['nextOffset']));
      case 'finish':
        return FileFinish(
          transferId: id,
          size: _decimal(m['size']),
          sha256: m['sha256'] as String,
        );
      case 'complete':
        return FileComplete(
          transferId: id,
          actualName: m['actualName'] as String,
          size: _decimal(m['size']),
          sha256: m['sha256'] as String,
        );
      case 'pause':
        return FilePause(transferId: id);
      case 'paused':
        return FilePaused(transferId: id, offset: _decimal(m['offset']));
      case 'resume':
        return FileResume(
          transferId: id,
          transferOrdinal: _decimal(m['transferOrdinal']),
          name: m['name'] as String,
          size: _decimal(m['size']),
          sha256: m['sha256'] as String,
          chunkBytes: m['chunkBytes'] as int,
          attemptId: m['attemptId'] as String,
        );
      case 'resume-state':
        return FileResumeState(
          transferId: id,
          attemptId: m['attemptId'] as String,
          offset: _decimal(m['offset']),
          prefixSha256: m['prefixSha256'] as String,
        );
      case 'resume-accept':
        return FileResumeAccept(
          transferId: id,
          attemptId: m['attemptId'] as String,
          offset: _decimal(m['offset']),
          prefixSha256: m['prefixSha256'] as String,
        );
      case 'cancel':
        return FileCancel(transferId: id);
      case 'cancelled':
        return FileCancelled(transferId: id);
      case 'failed':
        return FileFailed(transferId: id, code: m['code'] as String);
      case 'rejected':
        return FileRejected(transferId: id, code: m['code'] as String);
      case 'retired':
        return FileRetired(
          transferId: id,
          transferOrdinal: _decimal(m['transferOrdinal']),
        );
      case 'retire':
        return FileRetire(
          transferId: id,
          transferOrdinal: _decimal(m['transferOrdinal']),
          transferSender: m['transferSender'] == 'initiator'
              ? GrantRole.initiator
              : GrantRole.receiver,
          name: m['name'] as String,
          size: _decimal(m['size']),
          sha256: m['sha256'] as String,
          chunkBytes: m['chunkBytes'] as int,
          outcome: FileRetirementOutcome.values.byName(m['outcome'] as String),
          actualName: m['actualName'] as String?,
          failureCode: m['failureCode'] as String?,
        );
      default:
        _fail('invalid_message');
    }
  }
}
