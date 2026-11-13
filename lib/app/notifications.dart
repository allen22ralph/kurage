import 'dart:async';

import 'package:flutter/material.dart';

import '../core/log/app_log.dart';
import '../core/time_ago.dart';

/// A message the app showed (a toast), kept so it can be read again with
/// its action (Open, Play, Retry, Join) after it went (#87).
class AppNotification {
  AppNotification({required this.id, required this.message, required this.at, this.actionLabel, this.onAction});

  final String id;
  final String message;
  final DateTime at;
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// The app's recent messages, newest first, while it runs.
class NotificationHistory {
  NotificationHistory._();

  static const capacity = 50;

  static final items = ValueNotifier<List<AppNotification>>(const []);

  /// Messages since the list was last opened.
  static final unread = ValueNotifier<int>(0);

  /// Called for every toast. A message with the same [id] replaces the
  /// earlier one (one "Downloading…" for a batch).
  static void add(String message, {String? id, String? actionLabel, VoidCallback? onAction}) {
    final key = id ?? 'n-${DateTime.now().microsecondsSinceEpoch}';
    final replacing = items.value.any((n) => n.id == key);
    items.value = [
      AppNotification(id: key, message: message, at: DateTime.now(), actionLabel: actionLabel, onAction: onAction),
      for (final n in items.value)
        if (n.id != key) n,
    ].take(capacity).toList();
    if (!replacing) unread.value++;
    AppLog.info(LogArea.notification, message);
  }

  static void markRead() => unread.value = 0;

  static void clear() {
    items.value = const [];
    unread.value = 0;
  }

  @visibleForTesting
  static void reset() => clear();
}

/// The bell in the top bar: the unread count, and the recent messages.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Notifications',
        icon: const NotificationBellIcon(),
        onPressed: () => showNotifications(context),
      );
}

/// The bell with the unread count, for any button (a theme's top bar).
class NotificationBellIcon extends StatelessWidget {
  const NotificationBellIcon({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: NotificationHistory.unread,
        builder: (context, unread, _) => Badge(
          isLabelVisible: unread > 0,
          label: Text(unread > 9 ? '9+' : '$unread'),
          child: Icon(unread > 0 ? Icons.notifications : Icons.notifications_none),
        ),
      );
}

/// The recent messages in a panel at the top right (full width on phones).
Future<void> showNotifications(BuildContext context) {
  NotificationHistory.markRead();
  return showDialog<void>(context: context, builder: (_) => const _NotificationsPanel());
}

class _NotificationsPanel extends StatelessWidget {
  const _NotificationsPanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      alignment: Alignment.topRight,
      insetPadding: const EdgeInsets.fromLTRB(12, 56, 12, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: ValueListenableBuilder<List<AppNotification>>(
          valueListenable: NotificationHistory.items,
          builder: (context, items, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(child: Text('Notifications', style: theme.textTheme.titleMedium)),
                    if (items.isNotEmpty) TextButton(onPressed: NotificationHistory.clear, child: const Text('Clear all')),
                    IconButton(
                      autofocus: items.isEmpty,
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child: Text('Nothing yet. Messages the app shows (downloads, watch together, requests…) are kept here.'),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 20, endIndent: 20),
                    itemBuilder: (context, i) {
                      final n = items[i];
                      return ListTile(
                        autofocus: i == 0,
                        title: Text(n.message),
                        subtitle: Text(timeAgo(n.at)),
                        onTap: n.onAction == null ? null : () => _run(context, n),
                        trailing: n.actionLabel == null || n.onAction == null
                            ? null
                            : TextButton(onPressed: () => _run(context, n), child: Text(n.actionLabel!)),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _run(BuildContext context, AppNotification n) {
    Navigator.pop(context);
    // After the panel has gone (the action may open a page or a dialog).
    scheduleMicrotask(() => n.onAction?.call());
  }
}
