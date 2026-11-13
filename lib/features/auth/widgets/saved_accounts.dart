import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/storage/session_store.dart';

/// Accounts already signed in on this device; tapping one switches to it
/// without a password. Hidden when there are none.
class SavedAccounts extends ConsumerWidget {
  const SavedAccounts({super.key, this.serverId, this.onPick});

  /// Only show accounts on this server.
  final String? serverId;

  /// Instead of switching to the account picked.
  final void Function(StoredSession session)? onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = (ref.watch(storedSessionsProvider).value ?? const [])
        .where((s) => serverId == null || s.serverId == serverId)
        .toList();
    if (sessions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Saved accounts'),
          for (final session in sessions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                child: Text(session.userName.characters.first.toUpperCase()),
              ),
              title: Text(session.userName),
              subtitle: Text('${session.serverName} · ${session.baseUrl.host}'),
              // The router moves to home once the session changes.
              onTap: () => onPick != null
                  ? onPick!(session)
                  : ref.read(sessionControllerProvider.notifier).switchTo(session),
            ),
        ],
      ),
    );
  }
}

/// Small heading above a group on the sign-in screens.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
