import 'package:flutter/material.dart';

import '../../features/connections/auxiliary_route_controller.dart';

class AuxiliaryRouteSettings extends StatefulWidget {
  const AuxiliaryRouteSettings({super.key, required this.routes});
  final AuxiliaryRouteController routes;

  @override
  State<AuxiliaryRouteSettings> createState() => _AuxiliaryRouteSettingsState();
}

class _AuxiliaryRouteSettingsState extends State<AuxiliaryRouteSettings> {
  late final TextEditingController origin = TextEditingController(
    text: widget.routes.choice.customOrigin,
  );
  late AuxiliaryRouteMode mode = widget.routes.choice.mode;
  bool saving = false;
  bool edited = false;

  @override
  void initState() {
    super.initState();
    widget.routes.addListener(_syncRoute);
  }

  void _syncRoute() {
    if (!mounted || edited || !widget.routes.loaded) return;
    if (mode == widget.routes.choice.mode &&
        origin.text == widget.routes.choice.customOrigin) {
      return;
    }
    setState(() {
      mode = widget.routes.choice.mode;
      origin.text = widget.routes.choice.customOrigin;
    });
  }

  @override
  void dispose() {
    widget.routes.removeListener(_syncRoute);
    origin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.routes,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('辅助连接', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('局域网直连不等待辅助服务。自定义配置失败时不会转回官方公网服务。'),
        const SizedBox(height: 12),
        DropdownButtonFormField<AuxiliaryRouteMode>(
          key: ValueKey(mode),
          initialValue: mode,
          decoration: const InputDecoration(labelText: '辅助服务来源'),
          items: const [
            DropdownMenuItem(
              value: AuxiliaryRouteMode.official,
              child: Text('官方默认'),
            ),
            DropdownMenuItem(
              value: AuxiliaryRouteMode.custom,
              child: Text('自定义内网'),
            ),
          ],
          onChanged: saving || !widget.routes.loaded
              ? null
              : (value) {
                  if (value != null) {
                    setState(() {
                      edited = true;
                      mode = value;
                    });
                  }
                },
        ),
        if (mode == AuxiliaryRouteMode.custom) ...[
          const SizedBox(height: 12),
          TextField(
            controller: origin,
            onChanged: (_) => edited = true,
            decoration: const InputDecoration(
              labelText: '内网 HTTPS origin',
              hintText: 'https://aux.example.lan:8443',
            ),
            keyboardType: TextInputType.url,
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: saving || !widget.routes.loaded
                ? null
                : () async {
                    setState(() => saving = true);
                    await widget.routes.select(
                      AuxiliaryRouteChoice(mode, origin.text.trim()),
                    );
                    if (mounted) {
                      setState(() {
                        saving = false;
                        edited = false;
                      });
                      _syncRoute();
                    }
                  },
            child: const Text('保存辅助服务'),
          ),
        ),
        if (widget.routes.error case final message?)
          Semantics(
            liveRegion: true,
            child: Text(message, key: const ValueKey('auxiliary-route-error')),
          ),
        if (widget.routes.connectionFailure case final code?) ...[
          Text('所选辅助服务失败（$code），本地直连仍可用。'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: widget.routes.refresh,
              child: const Text('重试辅助服务'),
            ),
          ),
        ],
        if (!widget.routes.loaded) const Text('正在读取辅助服务配置…'),
      ],
    ),
  );
}
