import 'package:flutter/material.dart';

/// Issues arrive in severity order. Dismissal is display-only and lasts for the
/// current occurrence; resolving and recurring makes an issue visible again.
class FieldIssue {
  const FieldIssue(this.id, this.message, this.actionLabel, this.action);
  final String id, message, actionLabel;
  final VoidCallback action;
  String get signature => '$id:$message';
}

class IssueBanner extends StatefulWidget {
  const IssueBanner({super.key, required this.issues});
  final List<FieldIssue> issues;
  @override
  State<IssueBanner> createState() => _IssueBannerState();
}

class _IssueBannerState extends State<IssueBanner> {
  final _dismissed = <String>{};
  @override
  void didUpdateWidget(IssueBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = widget.issues.map((issue) => issue.signature).toSet();
    _dismissed.removeWhere((signature) => !current.contains(signature));
  }

  @override
  Widget build(BuildContext context) {
    final issue = widget.issues
        .where((i) => !_dismissed.contains(i.signature))
        .firstOrNull;
    if (issue == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Card(
        key: const ValueKey('global-issue'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(issue.message),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: issue.action,
                    child: Text(issue.actionLabel),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _dismissed.add(issue.signature)),
                    child: const Text('忽略'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
