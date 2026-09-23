part of '../share_hub_file_transfer.dart';

enum FileRetirementOutcome { completed, cancelled, failed }

/// Original producer's observation of a terminal result. This is not a cancel
/// command or permission to open/rebind any file. A host must verify the exact
/// retained result and finish native cleanup before retiring its owner.
final class FileRetire extends FileMessage {
  FileRetire({
    required super.transferId,
    required this.transferOrdinal,
    required this.transferSender,
    required this.name,
    required this.size,
    required this.sha256,
    required this.chunkBytes,
    required this.outcome,
    this.actualName,
    this.failureCode,
  }) {
    _validate(toJson());
  }
  final int transferOrdinal, size, chunkBytes;
  final GrantRole transferSender;
  final String name, sha256;
  final FileRetirementOutcome outcome;
  final String? actualName, failureCode;
  @override
  String get type => 'retire';
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
    'outcome': outcome.name,
    'actualName': ?actualName,
    'failureCode': ?failureCode,
  };
}

/// Confirmation that this ordinal cannot be reopened. It makes no statement
/// about delivery, cancellation, the saved name or the retire request's outcome.
final class FileRetired extends FileMessage {
  FileRetired({required super.transferId, required this.transferOrdinal}) {
    _validate(toJson());
  }
  final int transferOrdinal;
  @override
  String get type => 'retired';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'transferOrdinal': transferOrdinal.toString(),
  };
}

/// Rejection of a particular request; unlike FileFailed, not proof of a file's
/// terminal state. A sender cannot retire an owner based only on this response.
final class FileRejected extends FileMessage {
  FileRejected({required super.transferId, required this.code}) {
    _validate(toJson());
  }
  final String code;
  @override
  String get type => 'rejected';
  @override
  Map<String, Object> toJson() => {
    'v': fileProtocolVersion,
    'type': type,
    'transferId': transferId,
    'code': code,
  };
}

/// Sealed control binding for retirement. This cannot create a
/// FileTransferContext or native file authority. The host must separately match
/// its endpoint-scoped ledger, all retained metadata, outcome and cleanup state.
final class FileRetirementContext {
  FileRetirementContext._(this._registry, this.authorization, this.request);
  final GrantRegistry _registry;
  final SessionAuthorization authorization;
  final FileRetire request;

  static Future<FileRetirementContext> fromRequest(
    GrantRegistry registry,
    SessionAuthorization authorization,
  ) async {
    await registry.verify(authorization);
    authorization.requireCurrent();
    if (authorization.operation != SessionOperation.file) {
      _fail('context_mismatch');
    }
    final request = FileCodec.decode(authorization.body);
    if (request is! FileRetire) _fail('invalid_state');
    if (request.transferSender != authorization.sender) {
      _fail('direction_denied');
    }
    return FileRetirementContext._(registry, authorization, request);
  }

  Future<void> _check() async {
    await _registry.verify(authorization);
    authorization.requireCurrent();
  }

  Future<FileMessage> decodeSignal(VerifiedSessionSignal signal) async {
    if (authorization is! LocalSessionRequest ||
        !identical(signal.authorization, authorization)) {
      _fail('context_mismatch');
    }
    await _check();
    authorization.requireCurrent();
    final message = FileCodec.decode(signal.body);
    _validateReply(message);
    return message;
  }

  Future<void> validateReply(FileMessage message) async {
    if (authorization is! VerifiedSessionMessage) _fail('direction_denied');
    await _check();
    authorization.requireCurrent();
    FileCodec.encode(message);
    _validateReply(message);
  }

  void _validateReply(FileMessage message) {
    if (message.transferId != request.transferId) _fail('context_mismatch');
    if (message is FileRetired) {
      if (message.transferOrdinal != request.transferOrdinal) {
        _fail('context_mismatch');
      }
    } else if (message is FileComplete) {
      // A commit that won a cancellation race corrects the sender's observation.
      if (message.size != request.size ||
          message.sha256 != request.sha256 ||
          (request.outcome == FileRetirementOutcome.completed &&
              message.actualName != request.actualName)) {
        _fail('integrity_mismatch');
      }
    } else if (message is! FileRejected) {
      _fail('invalid_state');
    }
  }
}
