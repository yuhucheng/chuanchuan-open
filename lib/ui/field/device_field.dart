import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../features/devices/device_directory.dart';
import 'tokens.dart';

/// Arrival order is retained, including offline slots, for this field's lifetime.
/// Network updates never change a focused node's slot or identity.
class DeviceField extends StatefulWidget {
  const DeviceField({
    super.key,
    required this.entries,
    required this.localName,
    required this.allowConnections,
    required this.onLocal,
    required this.onDevice,
    this.query = '',
  });
  final List<DirectoryDevice> entries;
  final String localName, query;
  final bool allowConnections;
  final VoidCallback onLocal;
  final Future<void> Function(DirectoryDevice) onDevice;
  @override
  State<DeviceField> createState() => _DeviceFieldState();
}

class _DeviceFieldState extends State<DeviceField> {
  final _known = <String, DirectoryDevice>{};
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
    for (final entry in widget.entries) {
      _known[entry.identityId] = entry;
      _focus.putIfAbsent(
        entry.identityId,
        () => FocusNode(debugLabel: entry.identityId),
      );
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

  /// Discovery, trust, reachability and capability stay four separate facts.
  /// A retained slot that is absent from the current snapshot is not reachable,
  /// and a verified identity stays saved material only.
  static String describe(DirectoryDevice entry, {bool present = true}) {
    if (!present) return entry.verified ? '已保存资料 · 需重新输码' : '已离线';
    if (entry.connected) {
      return entry.capabilities.isEmpty
          ? '${entry.platform} · 已验证连接 · 暂无可用操作'
          : '${entry.platform} · 已验证连接';
    }
    if (!entry.verified) return '${entry.platform} · 未认证发现';
    return entry.online ? '${entry.platform} · 已验证 · 未连接' : '已保存资料 · 需重新输码';
  }

  String _detail(DirectoryDevice entry, bool present) {
    final peers = _known.values.where((d) => d.name == entry.name);
    final status = describe(entry, present: present);
    if (peers.length < 2) return status;
    final suffix = deviceAddressSuffix(entry);
    final collision =
        peers
            .where(
              (d) =>
                  d.platform == entry.platform &&
                  deviceAddressSuffix(d) == suffix,
            )
            .length >
        1;
    return '${entry.platform} · $suffix${collision ? ' · ${deviceIdentitySuffix(entry)}' : ''} · $status';
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.entries
        .where((entry) => entry.online)
        .map((entry) => entry.identityId)
        .toSet();
    final filtered = _known.values
        .where(
          (entry) => entry.name.toLowerCase().contains(
            widget.query.trim().toLowerCase(),
          ),
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
          for (final entry in visible)
            _node(
              context,
              key: ValueKey('device-${entry.identityId}'),
              name: entry.name,
              detail: _detail(entry, online.contains(entry.identityId)),
              icon: Icons.devices,
              focus: _focus[entry.identityId],
              onPressed: online.contains(entry.identityId)
                  ? () async {
                      await widget.onDevice(entry);
                      if (mounted) _focus[entry.identityId]?.requestFocus();
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
                    _focus[filtered[visible.length].identityId]?.requestFocus();
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
        Widget buildRow(int row) {
          final slots = List<Widget?>.filled(columns, null);
          for (
            var i = row * columns;
            i < math.min(items.length, (row + 1) * columns);
            i++
          ) {
            slots[column(i)] = Padding(
              padding: EdgeInsets.only(top: (i % 2) * 24),
              child: items[i],
            );
          }
          // Keep the center-outward field slots and their stagger, while the
          // tallest actual node determines the row's height. Identity/status
          // text must never be clipped to make a fixed-height node fit.
          return Padding(
            padding: const EdgeInsets.only(bottom: 48),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var slot = 0; slot < columns; slot++) ...[
                  if (slot != 0) const SizedBox(width: 48),
                  SizedBox(width: nodeWidth, child: slots[slot]),
                ],
              ],
            ),
          );
        }

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
            for (var row = 0; row < rows; row++) buildRow(row),
            const SizedBox(height: 32),
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
        mainAxisSize: MainAxisSize.min,
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
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
