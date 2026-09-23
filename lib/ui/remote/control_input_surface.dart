import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import '../../features/remote/remote_session_controller.dart';

/// Maps only the currently presented video's contain rectangle to normalized
/// control coordinates. Authorization and geometry epoch remain SDK-owned.
class ControlInputSurface extends StatefulWidget {
  const ControlInputSurface({
    super.key,
    required this.controller,
    required this.child,
  });
  final RemoteSessionController controller;
  final Widget child;

  @override
  State<ControlInputSurface> createState() => _ControlInputSurfaceState();
}

class _ControlInputSurfaceState extends State<ControlInputSurface>
    with WidgetsBindingObserver {
  final _focusNode = FocusNode(debugLabel: 'control-input');
  final _textFocusNode = FocusNode(debugLabel: 'control-committed-text');
  final _textController = TextEditingController();
  final _buttons = <int, int>{};
  final _forwardedKeys = <int>{};
  Offset? _pendingMove;
  bool _moving = false;
  bool _sendingText = false;
  String? _textError;
  int? _keyEpoch;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _textFocusNode.addListener(_onTextFocusChange);
  }

  void _onTextFocusChange() {
    if (!_textFocusNode.hasFocus) return;
    final keys = _forwardedKeys.toList().reversed;
    _forwardedKeys.clear();
    for (final usage in keys) {
      unawaited(widget.controller.sendControlKey(usage, ControlKeyAction.up));
    }
  }

  void _release() {
    _pendingMove = null;
    _buttons.clear();
    _forwardedKeys.clear();
    _keyEpoch = null;
    unawaited(widget.controller.releaseControlInput());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _release();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    _focusNode.dispose();
    _textFocusNode.removeListener(_onTextFocusChange);
    _textFocusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  Offset? _normalized(Offset local, {bool clamp = false}) {
    final scope = widget.controller.controlInputScope;
    if (scope == null || _size.width <= 0 || _size.height <= 0) return null;
    final scale = math.min(
      _size.width / scope.width,
      _size.height / scope.height,
    );
    if (!scale.isFinite || scale <= 0) return null;
    final width = scope.width * scale;
    final height = scope.height * scale;
    final left = (_size.width - width) / 2;
    final top = (_size.height - height) / 2;
    if (!clamp &&
        (local.dx < left ||
            local.dx > left + width ||
            local.dy < top ||
            local.dy > top + height)) {
      return null;
    }
    return Offset(
      ((local.dx - left) / width).clamp(0.0, 1.0),
      ((local.dy - top) / height).clamp(0.0, 1.0),
    );
  }

  void _move(Offset local) {
    final point = _normalized(local);
    if (point == null) return;
    _pendingMove = point;
    if (_moving) return;
    _moving = true;
    unawaited(() async {
      try {
        while (mounted && _pendingMove != null) {
          final next = _pendingMove!;
          _pendingMove = null;
          if (!await widget.controller.sendControlPointerMove(
            next.dx,
            next.dy,
          )) {
            _pendingMove = null;
            break;
          }
        }
      } finally {
        _moving = false;
      }
    }());
  }

  void _buttonChanges(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    const mapping = <(int, ControlButton)>[
      (kPrimaryMouseButton, ControlButton.primary),
      (kSecondaryMouseButton, ControlButton.secondary),
      (kMiddleMouseButton, ControlButton.middle),
      (kBackMouseButton, ControlButton.back),
      (kForwardMouseButton, ControlButton.forward),
    ];
    final before = _buttons[event.pointer] ?? 0;
    final after = event.buttons;
    _buttons[event.pointer] = after;
    for (final (flag, button) in mapping) {
      if ((before ^ after) & flag == 0) continue;
      final down = (after & flag) != 0;
      final point = _normalized(event.localPosition, clamp: !down);
      if (point == null) {
        if (!down) unawaited(widget.controller.releaseControlInput());
        continue;
      }
      unawaited(
        widget.controller.sendControlPointerButton(
          point.dx,
          point.dy,
          button,
          down,
        ),
      );
    }
    if (after == 0) _buttons.remove(event.pointer);
  }

  void _scroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final point = _normalized(event.localPosition);
    if (point == null) return;
    // Flutter reports scroll direction in viewport pixels; native wheel signs
    // are opposite vertically. Keep each authenticated message bounded.
    final dx = event.scrollDelta.dx.clamp(-120.0, 120.0);
    final dy = (-event.scrollDelta.dy).clamp(-120.0, 120.0);
    if (dx == 0 && dy == 0) return;
    unawaited(widget.controller.sendControlWheel(point.dx, point.dy, dx, dy));
  }

  KeyEventResult _key(KeyEvent event) {
    if (_textFocusNode.hasFocus) return KeyEventResult.ignored;
    final scope = widget.controller.controlInputScope;
    if (scope == null) return KeyEventResult.ignored;
    if (_keyEpoch != scope.inputEpoch) {
      _forwardedKeys.clear();
      _keyEpoch = scope.inputEpoch;
    }
    final hid = event.physicalKey.usbHidUsage;
    if (hid >> 16 != 0x07) return KeyEventResult.ignored;
    final usage = hid & 0xffff;
    if (!((usage >= 0x04 && usage <= 0x65) ||
            (usage >= 0x67 && usage <= 0x73) ||
            (usage >= 0xe0 && usage <= 0xe7)) ||
        const {0x32, 0x46, 0x48}.contains(usage)) {
      return KeyEventResult.ignored;
    }
    final modifier = usage >= 0xe0 && usage <= 0xe7;
    final standalone =
        usage == 0x29 ||
        usage == 0x2a ||
        usage == 0x2b ||
        (usage >= 0x3a && usage <= 0x52) ||
        (usage >= 0x68 && usage <= 0x73);
    if (event is KeyDownEvent) {
      if (!modifier &&
          !standalone &&
          !_forwardedKeys.any((key) => key >= 0xe0 && key <= 0xe7)) {
        return KeyEventResult.ignored;
      }
      if (!_forwardedKeys.add(usage)) return KeyEventResult.handled;
      unawaited(widget.controller.sendControlKey(usage, ControlKeyAction.down));
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent && _forwardedKeys.remove(usage)) {
      unawaited(widget.controller.sendControlKey(usage, ControlKeyAction.up));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _submitText() async {
    final value = _textController.text;
    if (_sendingText || value.isEmpty) return;
    setState(() {
      _sendingText = true;
      _textError = null;
    });
    final sent = await widget.controller.sendControlText(value);
    if (!mounted) return;
    setState(() {
      _sendingText = false;
      if (sent) {
        _textController.clear();
      } else {
        _textError = '文本未送达当前控制操作。';
      }
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onKeyEvent: (_, event) => _key(event),
    onFocusChange: (focused) {
      if (!focused) {
        _release();
      }
    },
    child: Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (_, constraints) {
              _size = Size(constraints.maxWidth, constraints.maxHeight);
              return Listener(
                key: const ValueKey('control-input-surface'),
                behavior: HitTestBehavior.opaque,
                onPointerHover: (event) => _move(event.localPosition),
                onPointerDown: (event) {
                  _focusNode.requestFocus();
                  _buttonChanges(event);
                },
                onPointerMove: (event) {
                  _buttonChanges(event);
                  _move(event.localPosition);
                },
                onPointerUp: _buttonChanges,
                onPointerCancel: (event) {
                  _buttons.remove(event.pointer);
                  _release();
                },
                onPointerSignal: _scroll,
                child: SizedBox.expand(child: widget.child),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('control-committed-text'),
                controller: _textController,
                focusNode: _textFocusNode,
                minLines: 1,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '提交文本到远端',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _sendingText ? null : _submitText,
              child: const Text('发送文本'),
            ),
          ],
        ),
        if (_textError != null) Text(_textError!),
      ],
    ),
  );
}
