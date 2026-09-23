import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'file_access.dart';

class NativeFileDropRegion extends StatelessWidget {
  const NativeFileDropRegion({
    super.key,
    required this.onDrop,
    required this.child,
  });
  final bool Function(List<SelectedFile>) onDrop;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      MetaData(metaData: this, behavior: HitTestBehavior.opaque, child: child);
}

class NativeFileDropHost extends StatefulWidget {
  const NativeFileDropHost({
    super.key,
    required this.enabled,
    required this.canAccept,
    required this.onError,
    required this.child,
    this.channel = const MethodChannel('dev.sharehub.client/file-drop'),
  });
  final bool enabled;
  final bool Function() canAccept;
  final void Function(String) onError;
  final Widget child;
  final MethodChannel channel;
  @override
  State<NativeFileDropHost> createState() => _NativeFileDropHostState();
}

class _NativeFileDropHostState extends State<NativeFileDropHost> {
  int? _viewId;
  bool _listening = false;
  bool Function(List<SelectedFile>)? _target;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    if (widget.enabled && !_listening) {
      _listening = true;
      widget.channel.setMethodCallHandler(_handle);
      unawaited(_listen());
    }
  }

  Future<void> _listen() async {
    try {
      await widget.channel.invokeMethod<void>('listen');
    } catch (_) {
      if (mounted) widget.onError('文件拖放暂不可用，请使用“选择文件”。');
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (!mounted || !_listening || !widget.enabled || !widget.canAccept()) {
      _target = null;
      return false;
    }
    if (call.method == 'error') {
      _target = null;
      widget.onError('无法加入拖入的文件，请检查文件是否可读及队列容量。');
      return null;
    }
    if (call.method == 'locate') {
      _target = null;
      final args = call.arguments;
      if (args is! Map || args.length != 2) return false;
      final x = args['x'], y = args['y'];
      if (x is! num || y is! num || !x.isFinite || !y.isFinite) return false;
      final hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        hit,
        Offset(x.toDouble(), y.toDouble()),
        _viewId!,
      );
      for (final entry in hit.path) {
        final target = entry.target;
        if (target is RenderMetaData &&
            target.metaData is NativeFileDropRegion) {
          _target = (target.metaData as NativeFileDropRegion).onDrop;
          return true;
        }
      }
      widget.onError('请将文件拖到文件队列或已连接的设备上。');
      return false;
    }
    if (call.method != 'drop') throw MissingPluginException();
    final receiver = _target;
    _target = null;
    if (receiver == null) return false;
    final args = call.arguments;
    if (args is! Map || args.length != 3) return false;
    final x = args['x'], y = args['y'], raw = args['files'];
    if (x is! num ||
        y is! num ||
        !x.isFinite ||
        !y.isFinite ||
        raw is! List ||
        raw.isEmpty ||
        raw.length > 64) {
      return false;
    }
    final files = <SelectedFile>[];
    final tokens = <String>{};
    for (final file in raw) {
      if (file is! Map || file.length != 3) return false;
      final token = file['token'], name = file['name'], size = file['size'];
      if (token is! String ||
          token.isEmpty ||
          token.length > 256 ||
          !tokens.add(token) ||
          name is! String ||
          name.isEmpty ||
          name.length > 4096 ||
          size is! int ||
          size < 0) {
        return false;
      }
      files.add(SelectedFile(token: token, name: name, size: size));
    }
    final accepted = receiver(List.unmodifiable(files));
    if (!accepted) widget.onError('无法加入这批文件，请检查连接和队列容量。');
    return accepted;
  }

  @override
  void dispose() {
    if (_listening) {
      _listening = false;
      widget.channel.setMethodCallHandler(null);
      unawaited(
        widget.channel.invokeMethod<void>('cancel').catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
