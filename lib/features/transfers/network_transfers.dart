import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import '../connections/connection_controller.dart';
import 'file_transfer_channel.dart';
import 'file_publication_order.dart';
import 'file_access.dart';
import 'incoming_file_transfer.dart';
import 'outgoing_file_transfer.dart';
import 'receive_access.dart';
import 'receive_directories.dart';
import 'source_access.dart';
import 'transfer_queue.dart';
import 'transfer_progress.dart';
import 'verified_file_source.dart';

enum NetworkSendPhase {
  queued,
  verifying,
  sending,
  paused,
  resuming,
  completing,
  completed,
  cancelling,
  cancelled,
  failed,
}

final class NetworkSend {
  NetworkSend._(this.item, this.connection);
  final TransferItem item;
  final TrustedConnection connection;
  late final TransferUse _use;
  OutgoingFileTransfer? _task;
  FilePublication? _publication;
  NetworkSendPhase _phase = NetworkSendPhase.queued;
  bool _stopRequested = false, _running = false, _cancelNotified = false;
  bool _transportPaused = false, _manualPause = false;
  String? _runSessionId;
  final _done = Completer<void>();
  Future<void> get done => _done.future;
  String? error;
  Object? cleanupFailure;
  FileComplete? receipt;
  FileCancellation? _cancellation;
  FileOutgoingRetirement? _retirement;
  bool _retirementRequested = false;
  String? _transferId;
  int? _transferOrdinal;
  int _finalAcknowledged = 0;
  bool get retirementPending => _retirementRequested && !retirementComplete;
  bool get retirementComplete => _retirement?.retired ?? false;
  Object? get retirementFailure => _retirement?.failure;
  bool get cancellationPending => _cancellation?.pending ?? false;
  Object? get cancellationFailure => _cancellation?.failure;
  int get acknowledgedBytes =>
      receipt?.size ?? _task?.acknowledgedOffset ?? _finalAcknowledged;
  bool get canCancel => !_done.isCompleted && !_stopRequested;
  bool get canPause =>
      canCancel &&
      _running &&
      (_task?.phase == OutgoingFilePhase.sending ||
          _task?.phase == OutgoingFilePhase.awaitingAck ||
          _task?.phase == OutgoingFilePhase.awaitingComplete);
  bool get canResume =>
      canCancel &&
      !_running &&
      _phase == NetworkSendPhase.paused &&
      (_task == null || _task?.peerPaused == true || _transportPaused) &&
      connection.isConnected &&
      connection.grant?.phase == GrantPhase.active;
  NetworkSendPhase get phase {
    if (_phase == NetworkSendPhase.queued ||
        _phase == NetworkSendPhase.completed ||
        _phase == NetworkSendPhase.cancelled ||
        _phase == NetworkSendPhase.failed ||
        _phase == NetworkSendPhase.cancelling) {
      return _phase;
    }
    return switch (_task?.phase) {
      OutgoingFilePhase.sending ||
      OutgoingFilePhase.awaitingAck => NetworkSendPhase.sending,
      OutgoingFilePhase.awaitingComplete => NetworkSendPhase.completing,
      OutgoingFilePhase.paused => NetworkSendPhase.paused,
      OutgoingFilePhase.resuming ||
      OutgoingFilePhase.awaitingResumeState => NetworkSendPhase.resuming,
      _ => _phase,
    };
  }
}

typedef NetworkReceive = ({
  TrustedConnection connection,
  FileTransferChannel channel,
  ReceivedTransfer entry,
});

typedef NetworkFileHistory = ({String peerKey, ReceivedFileHistory file});
typedef NetworkRetirement = ({
  String peerKey,
  bool canRetry,
  FileTransferChannel channel,
  FileOutgoingRetirement record,
});

/// App-lifetime owner of file ports, queue uses and receive destinations. File
/// initiation is allowed in both grant directions; media direction rules remain
/// independent. A single outbound worker avoids flooding the connection queue.
final class NetworkTransfers extends ChangeNotifier {
  NetworkTransfers({
    required this.connections,
    required this.queue,
    required this.source,
    required this.receive,
  }) : directories = ReceiveDirectories(receive) {
    connections.addListener(_reconcile);
    queue.addListener(_changed);
    directories.addListener(_changed);
    _reconcile();
  }
  final ConnectionController connections;
  final TransferQueue queue;
  final SourceAccess source;
  final ReceiveAccess receive;
  final ReceiveDirectories directories;
  final _links = <TrustedConnection, _FileLink>{};
  final _sends = <NetworkSend>[];
  final _dropTargets = <TransferItem, TrustedConnection>{};
  bool _drainingDrops = false;
  TransferProgress sendProgress({
    String? peerKey,
  }) => TransferProgress.fromFiles([
    for (final item in sendHistory)
      if (peerKey == null || item.peerKey == peerKey)
        _historyProgress(item.file),
    for (final item in pendingRetirements)
      if (peerKey == null || item.peerKey == peerKey)
        TransferProgressFile(
          size: item.record.size,
          transferred: item.record.receipt?.size ?? 0,
          state: switch (item.record.outcome) {
            FileRetirementOutcome.completed => TransferProgressState.completed,
            FileRetirementOutcome.cancelled => TransferProgressState.cancelled,
            FileRetirementOutcome.failed => TransferProgressState.failed,
          },
        ),
    for (final job in _sends)
      if (peerKey == null || job.connection.peerKey == peerKey)
        TransferProgressFile(
          size: job.item.file.size,
          transferred: job.receipt?.size ?? job.acknowledgedBytes,
          state: job.receipt != null
              ? TransferProgressState.completed
              : switch (job.phase) {
                  NetworkSendPhase.failed => TransferProgressState.failed,
                  NetworkSendPhase.cancelled => TransferProgressState.cancelled,
                  _ => TransferProgressState.active,
                },
        ),
  ]);
  TransferProgress receiveProgress({String? peerKey}) =>
      TransferProgress.fromFiles([
        for (final item in receiveHistory)
          if (peerKey == null || item.peerKey == peerKey)
            _historyProgress(item.file),
        for (final item in received)
          if (peerKey == null || item.connection.peerKey == peerKey)
            TransferProgressFile(
              size: item.entry.offer.size,
              transferred:
                  item.entry.task?.receipt?.size ??
                  item.entry.task?.offset ??
                  0,
              state: item.entry.task?.receipt != null
                  ? TransferProgressState.completed
                  : item.entry.failure != null ||
                        item.entry.task?.phase == IncomingFilePhase.failed
                  ? TransferProgressState.failed
                  : !item.entry.canCancel
                  ? TransferProgressState.cancelled
                  : TransferProgressState.active,
            ),
      ]);
  List<NetworkSend> get sends => List.unmodifiable(_sends);
  List<TrustedConnection> get targets => connections.sessions
      .where((c) => c.isConnected && c.grant?.phase == GrantPhase.active)
      .toList(growable: false);
  List<NetworkReceive> get received => [
    for (final link in _links.values)
      for (final entry in link.channel.received)
        (connection: link.connection, channel: link.channel, entry: entry),
  ];
  List<NetworkFileHistory> get receiveHistory => [
    for (final link in _links.values)
      for (final file in link.channel.receiveHistory)
        (peerKey: link.connection.peerKey, file: file),
  ];
  List<NetworkRetirement> get pendingRetirements => [
    for (final link in _links.values)
      for (final record in link.channel.outgoingRetirements)
        if (!_sends.any((job) => identical(job._retirement, record)))
          (
            peerKey: link.connection.peerKey,
            canRetry: link.connection.isConnected,
            channel: link.channel,
            record: record,
          ),
  ];
  List<NetworkFileHistory> get sendHistory => [
    for (final link in _links.values)
      for (final file in link.channel.sendHistory)
        if (!_sends.any(
          (job) =>
              identical(job.connection, link.connection) &&
              job._transferId == file.transferId &&
              job._transferOrdinal == file.transferOrdinal,
        ))
          (peerKey: link.connection.peerKey, file: file),
  ];
  static TransferProgressFile _historyProgress(ReceivedFileHistory file) =>
      TransferProgressFile(
        size: file.size,
        transferred: file.outcome == FileRetirementOutcome.completed
            ? file.size
            : 0,
        state: switch (file.outcome) {
          FileRetirementOutcome.completed => TransferProgressState.completed,
          FileRetirementOutcome.cancelled => TransferProgressState.cancelled,
          FileRetirementOutcome.failed => TransferProgressState.failed,
        },
      );
  Future<void>? _worker, _closing;
  Timer? _progress;
  bool _closed = false, _disposed = false;
  String? error;

  void _reconcile() {
    if (_closed) return;
    final live = connections.sessions
        .where((c) => !c.isClosed && c.grant != null)
        .toSet();
    for (final connection in live) {
      _links.putIfAbsent(connection, () {
        final link = _FileLink(
          connection,
          FileTransferChannel(
            registry: connections.grants,
            transport: connection.operationTransport({SessionOperation.file}),
            access: receive,
            acquireDirectory: directories.acquire,
            onChanged: _changed,
          ),
        );
        link.suspend = () {
          link.transportEpoch++;
          link.recovering = true;
          for (final job in _sends.where(
            (j) => identical(j.connection, connection),
          )) {
            if (job._done.isCompleted || job._stopRequested) continue;
            job._transportPaused = true;
            if (!job._running) job._phase = NetworkSendPhase.paused;
          }
          unawaited(
            link.channel.suspendTransport().then<void>(
              (_) {},
              onError: (Object e, StackTrace s) {
                // A failed native stop cannot authorize more file I/O. Close
                // the original grant and retain cleanup errors for retry.
                error = '文件暂停失败，连接已停止，请重试清理。';
                connection.close('file_stop_failed');
                _changed();
              },
            ),
          );
        };
        connection.addSuspendingListener(link.suspend!);
        link.phases = connection.phaseChanges.listen((phase) {
          if (phase == ConnectionPhase.active) {
            unawaited(_recoverLink(link));
          }
          _changed();
        });
        return link;
      });
    }
    for (final link in _links.values.toList()) {
      if (!live.contains(link.connection) &&
          link.closing == null &&
          !link.closed) {
        link.closing = link.channel
            .close()
            .then<void>(
              (_) {
                link.closed = true;
                link.detach();
                // Keep at most eight completed connection histories. Their grants are
                // terminal and native resources closed, so they cannot be resumed.
                final history = _links.values.where((v) => v.closed).toList();
                for (final older in history.take(
                  (history.length - 8).clamp(0, 8),
                )) {
                  _links.remove(older.connection);
                }
              },
              onError: (Object e, StackTrace s) {
                error = '文件清理未完成，请重试清理或退出。';
              },
            )
            .whenComplete(() {
              link.closing = null;
              _changed();
            });
      }
    }
    _changed();
  }

  Future<void> _recoverLink(_FileLink link) async {
    final epoch = link.transportEpoch;
    try {
      await link.channel.resumeTransport();
      if (!_closed &&
          epoch == link.transportEpoch &&
          link.connection.isConnected) {
        link.recovering = false;
      }
    } catch (_) {
      error = '文件暂停未完成，请重试清理或断开连接。';
    }
    _changed();
  }

  /// Claims an OS batch and binds its preparation to this exact grant owner.
  /// A later connection to the same peer cannot inherit an automatic send.
  bool acceptDrop(List<SelectedFile> files, TrustedConnection connection) {
    if (_closed ||
        !targets.contains(connection) ||
        _sends.length + _dropTargets.length + files.length >
            TransferQueue.maxFiles) {
      return false;
    }
    final admitted = queue.admitDroppedFiles(files);
    if (admitted == null) return false;
    for (final item in admitted) {
      _dropTargets[item] = connection;
    }
    _changed();
    return true;
  }

  void _dispatchDrops() {
    if (_drainingDrops) return;
    _drainingDrops = true;
    try {
      for (final entry in _dropTargets.entries.toList()) {
        final item = entry.key, connection = entry.value;
        if (!queue.items.contains(item) ||
            item.state == PreparationState.cancelled ||
            item.state == PreparationState.failed) {
          _dropTargets.remove(item);
        } else if (connection.isClosed ||
            !connections.sessions.contains(connection)) {
          _dropTargets.remove(item);
          error = '拖放目标连接已结束，文件准备后请重新选择发送设备。';
        } else if (item.state == PreparationState.ready &&
            targets.contains(connection)) {
          _dropTargets.remove(item);
          try {
            send(item, connection);
          } catch (_) {
            error = '拖入的文件未能自动发送，请检查连接及发送队列。';
          }
        }
      }
    } finally {
      _drainingDrops = false;
    }
  }

  NetworkSend send(TransferItem item, TrustedConnection connection) {
    if (_closed ||
        !targets.contains(connection) ||
        !item.canSend ||
        _sends.length >= TransferQueue.maxFiles) {
      throw StateError('File send is unavailable.');
    }
    final link = _links[connection];
    if (link == null ||
        link.channel.outgoing.length >= FileTransferChannel.maxTransfers) {
      throw StateError('File queue is full.');
    }
    final job = NetworkSend._(item, connection);
    job._use = queue.claim(item, onStop: () => _stop(job));
    _sends.add(job);
    _ensureWorker();
    _changed();
    return job;
  }

  void _ensureWorker() {
    _worker ??= _pump().whenComplete(() {
      _worker = null;
      if (!_closed && _sends.any(_runnable)) {
        _ensureWorker();
      }
      _changed();
    });
  }

  Future<void> _pump() async {
    while (!_closed) {
      final pending = _sends.where(_runnable).firstOrNull;
      if (pending == null) return;
      await _run(pending);
    }
  }

  bool _runnable(NetworkSend job) =>
      job._phase == NetworkSendPhase.queued &&
      job.connection.isConnected &&
      _links[job.connection]?.recovering == false;

  void _current(NetworkSend job) {
    if (_closed ||
        job._stopRequested ||
        !job.connection.isConnected ||
        job._runSessionId != job.connection.sessionId ||
        !connections.sessions.contains(job.connection)) {
      throw StateError('File send stopped.');
    }
  }

  Future<void> _run(NetworkSend job) async {
    job._running = true;
    job._transportPaused = false;
    job._runSessionId = job.connection.sessionId;
    job._phase = NetworkSendPhase.verifying;
    var enteredOwner = false;
    try {
      _current(job);
      final link = _links[job.connection]!;
      final retained = job._task;
      if (retained == null) job._publication ??= link.channel.reserveOutgoing();
      final FileMessage message = retained == null
          ? FileOffer(
              transferId: newTransferId(),
              transferOrdinal: job._publication!.ordinal,
              name: job._use.file.name,
              size: job._use.file.size,
              sha256: job._use.sha256,
              chunkBytes: FileLimits.chunkBytes,
            )
          : FileResume(
              transferId: retained.context.transferId,
              transferOrdinal: retained.context.transferOrdinal,
              name: job._use.file.name,
              size: job._use.file.size,
              sha256: job._use.sha256,
              chunkBytes: retained.context.chunkBytes,
              attemptId: newTransferId(),
            );
      final request = await link.channel.transport.createRequest(
        SessionOperation.file,
        job._publication!.nextOperation(job.connection.grant!.role).encoded,
        FileCodec.encode(message),
      );
      _current(job);
      if (retained != null) {
        final resumed = link.channel.resumeOutgoing(retained, request);
        enteredOwner = retained.phase != OutgoingFilePhase.paused;
        job.receipt = await resumed;
      } else {
        final context = await FileTransferContext.fromRequest(
          connections.grants,
          request,
        );
        _current(job);
        final task = job._task = OutgoingFileTransfer(
          transport: link.channel.transport,
          publication: job._publication,
          onChanged: _changed,
          source: VerifiedFileSource(
            access: source,
            file: job._use.file,
            context: context,
          ),
        );
        link.channel.trackOutgoing(task);
        job._transferId = task.context.transferId;
        job._transferOrdinal = task.context.transferOrdinal;
        _changed();
        enteredOwner = true;
        job.receipt = await task.start();
      }
      job._phase = NetworkSendPhase.completed;
    } catch (failure) {
      if (job._task?.receipt case final receipt?) {
        job.receipt = receipt;
        job._phase = NetworkSendPhase.completed;
      } else if (((enteredOwner &&
                  job._task?.phase == OutgoingFilePhase.paused) ||
              (job._transportPaused &&
                  (job._task == null ||
                      job._task?.phase == OutgoingFilePhase.paused))) &&
          !job._stopRequested) {
        job._phase = NetworkSendPhase.paused;
      } else if (job._task?.phase == OutgoingFilePhase.cancelled) {
        job._phase = NetworkSendPhase.cancelled;
      } else if (job._task?.phase == OutgoingFilePhase.cancelling) {
        job._phase = NetworkSendPhase.cancelling;
      } else if (!job._stopRequested) {
        job._phase = NetworkSendPhase.failed;
        job.error = messageFor(failure);
      }
    } finally {
      if (job._task == null) {
        // No owner or request reached the wire, so no later terminal control
        // can refer to this reservation. Recovery allocates a fresh ordinal.
        job._publication?.abandon();
        job._publication = null;
      }
      if (job._phase != NetworkSendPhase.paused ||
          job._stopRequested ||
          _closed) {
        try {
          await job._use.release();
          job.cleanupFailure = null;
          if (job._phase == NetworkSendPhase.cancelling) {
            job._phase = NetworkSendPhase.cancelled;
          }
        } catch (failure) {
          job.cleanupFailure = failure;
        }
        if (!job._done.isCompleted) job._done.complete();
      }
      job._running = false;
      _changed();
    }
  }

  Future<void> _stop(NetworkSend job) async {
    job._stopRequested = true;
    if (job._phase != NetworkSendPhase.completed &&
        job._phase != NetworkSendPhase.failed) {
      job._phase = NetworkSendPhase.cancelling;
    }
    final task = job._task;
    if (task != null) {
      final stop = task.cancel();
      if (task.receipt == null && !job._cancelNotified) {
        job._cancelNotified = true;
        // The native owner closes immediately. Own this notification separately:
        // owner.close invalidates its own pending control callback generation.
        unawaited(_notifyCancel(job));
      }
      await Future.wait([stop.then<void>((_) {}), task.close()]);
    }
    if (job._phase == NetworkSendPhase.cancelling) {
      job._phase = NetworkSendPhase.cancelled;
    }
    if (!job._running && !job._done.isCompleted) job._done.complete();
    _changed();
  }

  Future<void> _notifyCancel(NetworkSend job) async {
    try {
      if (_closed || job.receipt != null || job._task?.receipt != null) return;
      final link = _links[job.connection];
      if (link == null || job.connection.isClosed) return;
      job._cancellation = link.channel.cancelOutgoing(job._task!);
    } catch (_) {
      if (!_closed && job.receipt == null) {
        job.error ??= '本机已停止，取消通知未送达；可断开连接终止对端任务。';
      }
    } finally {
      _changed();
    }
  }

  Future<void> pause(NetworkSend job) async {
    if (_closed || !_sends.contains(job) || !job.canPause) {
      throw StateError('File is not sending.');
    }
    job._manualPause = true;
    await job._task!.pause();
    _changed();
  }

  /// Queue the retained owner; never create a new selection or a new grant.
  void resume(NetworkSend job) {
    if (_closed ||
        !_sends.contains(job) ||
        !job.canResume ||
        !targets.contains(job.connection)) {
      throw StateError('File cannot resume.');
    }
    job._phase = NetworkSendPhase.queued;
    job._manualPause = false;
    _ensureWorker();
    _changed();
  }

  Future<void> cancel(NetworkSend job) async {
    if (!_sends.contains(job)) return;
    try {
      await job._use.release();
      job.cleanupFailure = null;
    } catch (failure) {
      job.cleanupFailure = failure;
    }
    _changed();
  }

  Future<void> cancelReceive(NetworkReceive item) async {
    try {
      await item.channel.cancelReceived(item.entry);
      if (item.entry.notificationFailure != null) {
        error = '本机已停止接收，取消通知未送达；请重试或断开连接。';
      }
    } catch (_) {
      error = '接收任务尚未完全停止，请重试清理。';
    }
    _changed();
  }

  Future<void> retryReceiveCleanup(NetworkReceive item) async {
    try {
      await item.channel.retryCleanup(item.entry);
    } catch (_) {
      error = '临时文件或目录清理失败，请重试。';
    }
    _changed();
  }

  void retryCancelNotification(NetworkSend job) {
    final record = job._cancellation;
    if (record == null) return;
    try {
      _links[job.connection]?.channel.retryCancellation(record);
    } catch (_) {
      error = '取消通知暂时无法重试，请检查连接。';
    }
    _changed();
  }

  void retryRetirement(NetworkSend job) {
    final record = job._retirement;
    if (record == null) return;
    try {
      _links[job.connection]?.channel.retryOutgoingRetirement(record);
    } catch (_) {
      error = '任务暂时无法收尾，请检查连接。';
    }
    _changed();
  }

  void retryPendingRetirement(NetworkRetirement item) {
    try {
      item.channel.retryOutgoingRetirement(item.record);
    } catch (_) {
      error = '任务暂时无法收尾，请检查连接。';
    }
    _changed();
  }

  Future<void> retryReceiveNotification(NetworkReceive item) async {
    try {
      await item.channel.retryReceivedCancellation(item.entry);
    } catch (_) {
      error = '取消通知暂时无法重试，请检查连接。';
    }
    _changed();
  }

  Future<void> pickDirectory() async {
    try {
      await directories.pick();
    } catch (_) {
      /* Directory owner retains a visible, sanitized error. */
    }
    _changed();
  }

  static String messageFor(Object failure) {
    final code = switch (failure) {
      FileProtocolFailure(:final code) ||
      FileSourceFailure(:final code) ||
      ReceiveAccessFailure(:final code) ||
      SourceAccessFailure(:final code) => code,
      _ => '',
    };
    return switch (code) {
      'source_changed' || 'integrity_mismatch' => '文件内容已变化或校验失败，请重新选择。',
      'permission_denied' || 'disk_full' => '接收目录不可写或空间不足，请在接收设备更改保存位置。',
      'resource_limit' => '本次连接的文件任务数量已达上限，请重新连接后重试。',
      _ => '传送未完成，请检查连接和文件后重新选择。',
    };
  }

  static String historyStatus(
    ReceivedFileHistory file, {
    required bool sending,
  }) => switch (file.outcome) {
    FileRetirementOutcome.completed =>
      '${sending ? '对方已保存' : '已保存'}：${file.actualName}',
    FileRetirementOutcome.cancelled => '已取消',
    FileRetirementOutcome.failed =>
      file.failureCode == null
          ? '传送失败'
          : messageFor(FileProtocolFailure(file.failureCode!)),
  };

  // Paused owners have no active _run future. Peer cancellation, grant
  // revocation or a late authentic receipt must still settle their queue use.
  Future<void> _settleRetained(NetworkSend job) async {
    job._running = true;
    final task = job._task!;
    if (task.receipt case final receipt?) {
      job.receipt = receipt;
      job._phase = NetworkSendPhase.completed;
    } else if (task.phase == OutgoingFilePhase.cancelled ||
        task.phase == OutgoingFilePhase.cancelling) {
      job._phase = NetworkSendPhase.cancelling;
    } else {
      job._phase = NetworkSendPhase.failed;
      job.error ??= '传送未完成，请检查连接和文件后重新选择。';
    }
    try {
      await job._use.release();
      job.cleanupFailure = null;
    } catch (failure) {
      job.cleanupFailure = failure;
    } finally {
      if (!job._done.isCompleted) job._done.complete();
      job._running = false;
      _changed();
    }
  }

  void _changed() {
    if (_closed || _disposed) return;
    _dispatchDrops();
    for (final job in _sends.toList()) {
      final channel = _links[job.connection]?.channel;
      final task = job._task;
      if (task != null && channel != null) {
        job._retirement ??= channel.outgoingRetirementFor(task);
        if (job._done.isCompleted &&
            job.cleanupFailure == null &&
            !job._retirementRequested &&
            !job.connection.isClosed) {
          job._retirementRequested = true;
          unawaited(
            channel
                .forgetOutgoing(task)
                .then<void>(
                  (_) {
                    job._retirement ??= channel.outgoingRetirementFor(task);
                    _changed();
                  },
                  onError: (Object e, StackTrace s) {
                    job.cleanupFailure = e;
                    job._retirementRequested = false;
                    _changed();
                  },
                ),
          );
        }
        if (job._retirement?.receipt case final receipt?) {
          job.receipt = receipt;
          job._phase = NetworkSendPhase.completed;
        }
        if (job._retirement?.retired == true) {
          job._finalAcknowledged = task.acknowledgedOffset;
          job._task = null;
          job._publication = null;
          job._cancellation = null;
        }
      }
      if (job._cancellation?.receipt case final receipt?) {
        job.receipt = receipt;
        job._phase = NetworkSendPhase.completed;
      }
      if (job.connection.isClosed &&
          !job._running &&
          !job._stopRequested &&
          !job._done.isCompleted) {
        unawaited(cancel(job));
      }
      if (job._transportPaused &&
          !job._manualPause &&
          !job._running &&
          !job._stopRequested &&
          !job._done.isCompleted &&
          job._phase == NetworkSendPhase.paused &&
          job.connection.isConnected &&
          _links[job.connection]?.recovering == false) {
        job._phase = NetworkSendPhase.queued;
        _ensureWorker();
      }
      if (!job._running &&
          !job._done.isCompleted &&
          (job._task?.phase == OutgoingFilePhase.cancelled ||
              job._task?.phase == OutgoingFilePhase.cancelling ||
              job._task?.phase == OutgoingFilePhase.failed ||
              job._task?.phase == OutgoingFilePhase.completed)) {
        unawaited(_settleRetained(job));
      }
      if (job._done.isCompleted &&
          job.cleanupFailure == null &&
          !queue.items.contains(job.item) &&
          (job.connection.isClosed ||
              job._task == null ||
              job._retirement != null)) {
        _sends.remove(job);
        final link = _links[job.connection];
        if (link != null && job._task != null) {
          unawaited(
            link.channel
                .forgetOutgoing(job._task!)
                .then<void>(
                  (_) {},
                  onError: (Object e, StackTrace s) {
                    error = '发送任务清理未完成，请重试退出。';
                  },
                ),
          );
        }
      }
    }
    final active =
        _sends.any(
          (job) =>
              !job._done.isCompleted && job.phase != NetworkSendPhase.paused,
        ) ||
        received.any(
          (item) =>
              item.entry.canCancel &&
              item.entry.task?.phase != IncomingFilePhase.paused,
        );
    if (active) {
      _progress ??= Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _changed(),
      );
    } else {
      _progress?.cancel();
      _progress = null;
    }
    notifyListeners();
  }

  Future<void> close() {
    if (!_closed) {
      _closed = true;
      _dropTargets.clear();
      connections.removeListener(_reconcile);
      queue.removeListener(_changed);
      directories.removeListener(_changed);
      for (final link in _links.values) {
        link.detach();
      }
      _progress?.cancel();
      _progress = null;
    }
    return _closing ??= _close().whenComplete(() {
      _closing = null;
    });
  }

  Future<void> _close() async {
    await Future.wait([
      for (final job in _sends) job._use.release(),
      for (final link in _links.values) link.channel.close(),
    ]);
    await _worker;
    await directories.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close().then<void>((_) {}, onError: (Object e, StackTrace s) {}));
    directories.dispose();
    super.dispose();
  }
}

final class _FileLink {
  _FileLink(this.connection, this.channel);
  final TrustedConnection connection;
  final FileTransferChannel channel;
  Future<void>? closing;
  bool closed = false;
  bool recovering = false;
  int transportEpoch = 0;
  void Function()? suspend;
  StreamSubscription<ConnectionPhase>? phases;
  void detach() {
    if (suspend != null) connection.removeSuspendingListener(suspend!);
    unawaited(phases?.cancel() ?? Future.value());
    phases = null;
  }
}
