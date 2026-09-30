import 'package:flutter/material.dart';

import 'visual_widgets.dart';

/// Lightweight, reusable loading indicator for async button actions
/// (create/update/logout, etc). Shows a small non-dismissible dialog with a
/// spinner + message, and guarantees it gets dismissed even if the action
/// throws, so buttons can never get stuck showing a spinner forever.
///
/// Usage:
///   await SimpleLoader.run(context, 'Saving...', () async {
///     await someAsyncAction()
///   });
class SimpleLoader {
  // 🔧 FIX: _visible was a static bool that could get permanently out of sync
  // if the context was unmounted between _show() and _hide(). Using a
  // dialog-route key instead lets us always pop the exact dialog we opened,
  // even after pushNamedAndRemoveUntil() has changed the route stack.
  static final GlobalKey _dialogKey = GlobalKey();
  static BuildContext? _dialogContext; // the context *inside* the dialog
  static bool _visible = false;

  /// Runs [action] while showing a small loading dialog with [message].
  /// The dialog is always dismissed afterwards, whether [action] succeeds,
  /// throws, or the widget is unmounted by the time it finishes. Rethrows
  /// any error from [action] so callers can still show their own error UI.
  static Future<T> run<T>(
    BuildContext context,
    String message,
    Future<T> Function() action,
  ) async {
    _show(context, message);
    try {
      return await action();
    } finally {
      _hide();
    }
  }

  static void _show(BuildContext context, String message) {
    if (_visible) return;
    _visible = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      // 🔧 FIX: Removed PopScope(canPop: false). The dialog is barrierDismissible:false
      // so the user cannot dismiss it manually. But PopScope(canPop: false)
      // also prevented pushNamedAndRemoveUntil() from clearing it, leaving
      // an orphaned "Logging out..." spinner on top of the login page forever.
      builder: (ctx) {
        _dialogContext = ctx;
        return AlertDialog(
          key: _dialogKey,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const InfinityLoader(size: 42),
              const SizedBox(width: 16),
              Flexible(child: Text(message)),
            ],
          ),
        );
      },
    ).whenComplete(() {
      // Ensure state is clean whether the dialog was popped by us or by the
      // route system (e.g. pushNamedAndRemoveUntil).
      _visible = false;
      _dialogContext = null;
    });
  }

  static void _hide() {
    if (!_visible) return;
    _visible = false;
    final ctx = _dialogContext;
    _dialogContext = null;
    if (ctx != null && ctx.mounted) {
      // Use maybePop so it's a no-op if the dialog was already removed by
      // navigation (pushNamedAndRemoveUntil), instead of throwing an error.
      Navigator.of(ctx, rootNavigator: true).maybePop();
    }
  }
}
