import 'package:flutter/widgets.dart';

/// Covers the Navigator, including already-open dialogs, during exit cleanup.
/// Keeps its child mounted so session owners and unfinished input survive a
/// failed exit. The captured focus is borrowed, never owned or disposed here.
class ExitInteractionGuard extends StatefulWidget {
  const ExitInteractionGuard({
    super.key,
    required this.exiting,
    required this.child,
  });

  final bool exiting;
  final Widget child;

  @override
  State<ExitInteractionGuard> createState() => _ExitInteractionGuardState();
}

class _ExitInteractionGuardState extends State<ExitInteractionGuard> {
  FocusNode? _focusBeforeExit;

  @override
  void didUpdateWidget(ExitInteractionGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.exiting && widget.exiting) {
      _focusBeforeExit = FocusManager.instance.primaryFocus;
    } else if (oldWidget.exiting && !widget.exiting) {
      final focus = _focusBeforeExit;
      _focusBeforeExit = null;
      // The ExcludeFocus update must first restore descendant focusability.
      // A new exit or a dialog removed during cleanup cancels this restoration.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !widget.exiting &&
            focus?.context?.mounted == true &&
            focus!.canRequestFocus) {
          focus.requestFocus();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => AbsorbPointer(
    absorbing: widget.exiting,
    child: ExcludeFocus(excluding: widget.exiting, child: widget.child),
  );
}
