import 'dart:async';
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
  static Completer<void>? _dialogReady;

  /// Runs [action] while showing a small loading dialog with [message].
  /// Waits until the dialog builder has actually mounted before starting the
  /// action. This prevents a fast action from calling _hide() before the dialog
  /// receives a context, which previously left an orphaned spinner on screen.
  static Future<T> run<T>(
    BuildContext context,
    String message,
    Future<T> Function() action,
  ) async {
    await _show(context, message);
    try {
      return await action();
    } finally {
      _hide();
    }
  }

  static Future<void> _show(
    BuildContext context,
    String message,
  ) async {
    if (_visible) {
      return _dialogReady?.future ?? Future<void>.value();
    }

    _visible = true;
    final ready = Completer<void>();
    _dialogReady = ready;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _dialogContext = ctx;
        if (!ready.isCompleted) {
          ready.complete();
        }
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
      if (!ready.isCompleted) {
        ready.complete();
      }
      _visible = false;
      _dialogContext = null;
      if (identical(_dialogReady, ready)) {
        _dialogReady = null;
      }
    });

    try {
      await ready.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Never block the underlying operation forever because the dialog
      // couldn't mount (for example during route teardown).
    }
  }

  static void _hide() {
    final ctx = _dialogContext;
    _visible = false;
    _dialogContext = null;
    _dialogReady = null;
    if (ctx != null && ctx.mounted) {
      // Use maybePop so it's a no-op if the dialog was already removed by
      // navigation (pushNamedAndRemoveUntil), instead of throwing an error.
      Navigator.of(ctx, rootNavigator: true).maybePop();
    }
  }
}
