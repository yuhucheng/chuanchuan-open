import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../platform/client_platform.dart';
import 'tokens.dart';

/// Arrival order is retained, including offline slots, for this field's lifetime.
/// Network updates never change a focused node's position or identity.
class DeviceField extends StatefulWidget {
  const DeviceField({
    super.key,
    required this.devices,
    required this.localName,
    required this.allowConnections,
    required this.onLocal,
    required this.onDevice,
    this.query = '',
    this.verifiedPeers = const {},
  });
  final List<NearbyDevice> devices;
  final Set<String> verifiedPeers;
  final String localName, query;
  final bool allowConnections;
  final VoidCallback onLocal;
  final Future<void> Function(NearbyDevice) onDevice;
  @override
  State<DeviceField> createState() => _DeviceFieldState();
}

class _DeviceFieldState extends State<DeviceField> {
  final _known = <String, NearbyDevice>{};
  final _focus = <String, FocusNode>{};
  final _aggregateFocus = FocusNode(debugLabel: 'aggregate');
  bool _expanded = false;
  @override
  void initState() {
    super.initState();
    _remember();
  }

  @override
  void didUpdateWidget(DeviceField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _remember();
  }

  void _remember() {
    for (final device in widget.devices) {
      _known[device.id] = device;
      _focus.putIfAbsent(device.id, () => FocusNode(debugLabel: device.id));
    }
  }

  @override
  void dispose() {
    for (final node in _focus.values) {
      node.dispose();
    }
    _aggregateFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.devices.map((d) => d.id).toSet();
    final filtered = _known.values
        .where(
          (d) =>
              d.name.toLowerCase().contains(widget.query.trim().toLowerCase()),
        )
        .toList();
    final visible = _expanded ? filtered : filtered.take(5).toList();
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        final nodeWidth = math.min(
          constraints.maxWidth,
          FieldTokens.nodeWidth * math.max<double>(1.0, scale),
        );
        final nodeHeight = 164.0 * math.max<double>(1.0, scale);
        final items = <Widget>[
          _node(
            context,
            key: const ValueKey('local-device'),
            name: widget.localName,
            detail: widget.allowConnections ? '你 · 允许连接已开启' : '你 · 允许连接已关闭',
            icon: Icons.laptop_mac,
            onPressed: widget.onLocal,
            local: true,
          ),
          for (final device in visible)
            _node(
              context,
              key: ValueKey('device-${device.id}'),
              name: device.name,
              detail: online.contains(device.id)
                  ? '${device.platform} · ${widget.verifiedPeers.contains(device.publicKey) ? '已验证连接' : '未认证发现'}'
                  : '已离线',
              icon: Icons.devices,
              focus: _focus[device.id],
              onPressed: online.contains(device.id)
                  ? () async {
                      await widget.onDevice(device);
                      if (mounted) _focus[device.id]?.requestFocus();
                    }
                  : null,
            ),
          if (!_expanded && filtered.length > visible.length)
            _node(
              context,
              key: const ValueKey('aggregate'),
              name: '＋${filtered.length - visible.length} 台设备',
              detail: '在场内展开',
              icon: Icons.more_horiz,
              focus: _aggregateFocus,
              onPressed: () {
                setState(() => _expanded = true);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    _focus[filtered[visible.length].id]?.requestFocus();
                  }
                });
              },
            ),
        ];
        final capacity = math.max(
          1,
          (constraints.maxWidth / (nodeWidth + 48)).floor(),
        );
        final columns = capacity.isEven ? capacity - 1 : capacity;
        int column(int index) {
          final slot = index % columns;
          return columns ~/ 2 + (slot.isOdd ? -(slot + 1) ~/ 2 : slot ~/ 2);
        }

        final rows = (items.length / columns).ceil();
        return Column(
          children: [
            if (_expanded)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _expanded = false);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _aggregateFocus.requestFocus();
                    });
                  },
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回设备场'),
                ),
              ),
            SizedBox(
              height: rows * (nodeHeight + 48) + 32,
              child: Stack(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Positioned(
                      left:
                          (constraints.maxWidth -
                                  columns * nodeWidth -
                                  (columns - 1) * 48) /
                              2 +
                          column(i) * (nodeWidth + 48),
                      top: (i ~/ columns) * (nodeHeight + 48) + (i % 2) * 24,
                      width: nodeWidth,
                      height: nodeHeight,
                      child: items[i],
                    ),
                ],
              ),
            ),
            if (filtered.isEmpty)
              Text(widget.query.isEmpty ? '还没有发现其他设备' : '没有匹配的设备'),
          ],
        );
      },
    );
  }

  Widget _node(
    BuildContext context, {
    required Key key,
    required String name,
    required String detail,
    required IconData icon,
    required VoidCallback? onPressed,
    FocusNode? focus,
    bool local = false,
  }) => RawGestureDetector(
    gestures: onPressed == null
        ? const {}
        : {
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: FieldTokens.holdDuration,
                  ),
                  (recognizer) => recognizer.onLongPress = onPressed,
                ),
          },
    child: OutlinedButton(
      key: key,
      focusNode: focus,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(16),
        backgroundColor: Theme.of(context).colorScheme.surface,
        side: BorderSide(
          color: local
              ? Theme.of(context).colorScheme.secondary
              : Theme.of(context).colorScheme.outline,
          width: local ? 2 : 1,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FieldTokens.nodeRadius),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 32),
          const SizedBox(height: 12),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
