import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'notifications.dart';

/// For messages from outside any screen (e.g. who joined the watch-together
/// group).
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// How long a message stays (hovering a desktop toast keeps it).
const toastDuration = Duration(seconds: 4);

class _Toast {
  _Toast(this.id, this.message, this.actionLabel, this.onAction, this.duration);

  final String id;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
}

final _toasts = ValueNotifier<List<_Toast>>(const []);

/// The desktop toasts showing now (their text), for tests.
@visibleForTesting
List<String> get shownToasts => [for (final t in _toasts.value) t.message];
var _nextId = 0;

bool get _desktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Shows [message]: a toast in the top-right corner on desktop, a message at
/// the bottom on phones and TVs. It goes by itself after [duration], even
/// with an action, and has a close button. A toast with the same [id]
/// replaces the earlier one (e.g. one "Downloading…" for a batch).
void showToast(
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = toastDuration,
  String? id,
}) {
  NotificationHistory.add(message, id: id, actionLabel: actionLabel, onAction: onAction);
  if (_desktop) {
    final toast = _Toast(id ?? 'toast-${_nextId++}', message, actionLabel, onAction, duration);
    _toasts.value = [
      for (final t in _toasts.value)
        if (t.id != toast.id) t,
      toast,
    ].reversed.take(4).toList().reversed.toList();
    return;
  }
  _snackId = id;
  rootMessengerKey.currentState
    ?..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: duration,
      persist: false,
      showCloseIcon: true,
      action: actionLabel == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
    ));
}

/// The id of the message at the bottom (phones, TVs), if it had one.
String? _snackId;

/// Closes the message shown with [id], if it's still showing (e.g. "… is
/// watching, Join in?" once that episode is open anyway).
void dismissToast(String id) {
  _toasts.value = [
    for (final t in _toasts.value)
      if (t.id != id) t,
  ];
  if (_snackId == id) {
    rootMessengerKey.currentState?.hideCurrentSnackBar();
    _snackId = null;
  }
}

/// The desktop toasts, over the app's top-right corner (see MaterialApp's
/// builder).
class ToastHost extends StatefulWidget {
  const ToastHost({super.key, required this.child});

  final Widget child;

  @override
  State<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<ToastHost> {
  @override
  void initState() {
    super.initState();
    // A fresh app (or test) starts without old toasts.
    _toasts.value = const [];
  }

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          widget.child,
          Positioned(
            top: 12,
            right: 12,
            width: 380,
            child: ValueListenableBuilder<List<_Toast>>(
              valueListenable: _toasts,
              builder: (_, toasts, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [for (final t in toasts) _ToastCard(key: ValueKey(t.id), toast: t)],
              ),
            ),
          ),
        ],
      );
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.toast});

  final _Toast toast;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 160))..forward();
  Timer? _timer;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_ToastCard old) {
    super.didUpdateWidget(old);
    // Replaced by a newer toast with the same id: its own time again.
    if (!identical(old.toast, widget.toast)) _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer(widget.toast.duration, () {
      if (!_hovered) _close();
    });
  }

  Future<void> _close() async {
    _timer?.cancel();
    if (mounted) await _fade.reverse();
    _toasts.value = [
      for (final t in _toasts.value)
        if (t.id != widget.toast.id) t,
    ];
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final toast = widget.toast;
    return FadeTransition(
      opacity: _fade,
      child: MouseRegion(
        onEnter: (_) => _hovered = true,
        onExit: (_) {
          _hovered = false;
          _start();
        },
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            elevation: 6,
            color: theme.colorScheme.inverseSurface,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          toast.message,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onInverseSurface),
                        ),
                      ),
                    ),
                    if (toast.actionLabel case final label?)
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: theme.colorScheme.inversePrimary),
                        onPressed: () {
                          _close();
                          toast.onAction?.call();
                        },
                        child: Text(label),
                      ),
                    // No tooltip: the toasts sit above the app's Overlay.
                    IconButton(
                      iconSize: 18,
                      color: theme.colorScheme.onInverseSurface,
                      icon: const Icon(Icons.close, semanticLabel: 'Dismiss'),
                      onPressed: _close,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
