import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'grant_duration.dart';

/// Reads the existing grant's sleep-inclusive monotonic clock and deadline.
/// It never renews, resumes, revokes or otherwise decides authorization.
class GrantStatusText extends StatefulWidget {
  const GrantStatusText({
    super.key,
    required this.grant,
    this.connectionClosed = false,
  });

  final GrantEndpoint? grant;
  final bool connectionClosed;

  @override
  State<GrantStatusText> createState() => _GrantStatusTextState();
}

class _GrantStatusTextState extends State<GrantStatusText>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _readTimeout;
  StreamSubscription<void>? _invalidated;
  Object? _readToken;
  int _revision = 0;
  int? _now, _lastMicros;
  bool _visible = true, _unavailable = false, _clockInvalid = false;
  bool _readTimedOut = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _visible = _isVisible(WidgetsBinding.instance.lifecycleState);
    _bindGrant();
  }

  static bool _isVisible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  void didUpdateWidget(GrantStatusText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.grant, widget.grant)) {
      _bindGrant();
    } else if (oldWidget.connectionClosed != widget.connectionClosed) {
      _restart();
    }
  }

  void _bindGrant() {
    _revision++;
    _readToken = null;
    _readTimedOut = false;
    _readTimeout?.cancel();
    unawaited(_invalidated?.cancel());
    _now = null;
    _unavailable = _clockInvalid = false;
    final grant = widget.grant;
    _lastMicros = grant == null
        ? null
        : grant.expiresMicros - grant.binding.policy.lifetime.inMicroseconds;
    _invalidated = grant?.invalidated.listen((_) {
      if (!mounted) return;
      setState(() {});
      _restart();
    });
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    if (!_visible ||
        widget.connectionClosed ||
        widget.grant == null ||
        widget.grant!.phase == GrantPhase.revoked ||
        _clockInvalid) {
      return;
    }
    if (_readToken case final token?) {
      if (_readTimedOut) {
        setState(() => _unavailable = true);
      } else {
        _armReadTimeout(token, _revision, widget.grant!);
      }
    } else {
      unawaited(_refresh());
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _isVisible(state);
    if (_visible == visible) return;
    _visible = visible;
    _revision++;
    _readTimeout?.cancel();
    // Never flash a pre-sleep countdown while the fresh native clock is pending.
    setState(() {
      _now = null;
      _unavailable = false;
    });
    _restart();
  }

  Future<void> _refresh() async {
    final grant = widget.grant;
    if (!mounted ||
        !_visible ||
        _readToken != null ||
        grant == null ||
        widget.connectionClosed ||
        grant.phase == GrantPhase.revoked ||
        _clockInvalid) {
      return;
    }
    final token = _readToken = Object();
    final revision = _revision;
    _readTimedOut = false;
    _armReadTimeout(token, revision, grant);
    try {
      final now = await grant.clock();
      if (!_current(token, revision, grant) || _readTimedOut) return;
      setState(() {
        _clockInvalid = now < (_lastMicros ?? now);
        _unavailable = _clockInvalid;
        _now = _clockInvalid ? null : now;
        if (!_clockInvalid) _lastMicros = now;
      });
      if (_clockInvalid || now >= grant.expiresMicros) _timer?.cancel();
    } catch (_) {
      if (_current(token, revision, grant)) {
        setState(() {
          _now = null;
          _unavailable = true;
        });
      }
    } finally {
      // A timeout only hides stale data. Keep one native request in flight until
      // it actually settles; hiding/reopening must not stack more clock reads.
      if (identical(_readToken, token)) {
        _readTimeout?.cancel();
        _readToken = null;
        if (mounted && _visible && revision != _revision) {
          unawaited(_refresh());
        }
      }
    }
  }

  void _armReadTimeout(Object token, int revision, GrantEndpoint grant) {
    _readTimeout?.cancel();
    _readTimeout = Timer(const Duration(seconds: 3), () {
      if (_current(token, revision, grant)) {
        _readTimedOut = true;
        setState(() {
          _now = null;
          _unavailable = true;
        });
      }
    });
  }

  bool _current(Object token, int revision, GrantEndpoint grant) =>
      mounted &&
      _visible &&
      identical(_readToken, token) &&
      revision == _revision &&
      identical(widget.grant, grant) &&
      !widget.connectionClosed;

  String _status(GrantEndpoint grant) {
    final now = _now;
    if (now != null && now >= grant.expiresMicros) {
      return '授权已到期，请重新连接';
    }
    if (grant.phase == GrantPhase.revoked) return '授权已撤销或到期';
    if (_unavailable || _clockInvalid) return '授权剩余时间不可用';
    if (now == null) return '正在读取授权剩余时间…';
    final remaining = formatGrantDuration(
      Duration(microseconds: grant.expiresMicros - now),
    );
    return switch (grant.phase) {
      GrantPhase.active => '授权剩余 $remaining',
      GrantPhase.suspended => '授权已暂停 · 剩余 $remaining（恢复不续期）',
      GrantPhase.negotiating => '正在核验授权 · 剩余 $remaining',
      GrantPhase.revoked => '授权已撤销或到期',
    };
  }

  @override
  Widget build(BuildContext context) {
    final grant = widget.grant;
    if (grant == null) return const Text('授权期限未提供');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(formatGrantPolicy(grant)),
        Text(widget.connectionClosed ? '连接已结束' : _status(grant)),
      ],
    );
  }

  @override
  void dispose() {
    _revision++;
    _timer?.cancel();
    _readTimeout?.cancel();
    unawaited(_invalidated?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
