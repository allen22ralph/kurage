import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/toast.dart';
import '../../app/user_avatar.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/storage/session_store.dart';

/// Switch between saved accounts (users and servers), add or remove them.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(storedSessionsProvider);
    final active = ref.watch(sessionControllerProvider).value;
    final controller = ref.read(sessionControllerProvider.notifier);

    final user = ref.watch(currentUserProvider).value;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load accounts: $e')),
        // A centred column on wide windows (it looked empty stretched across
        // a desktop window); full width on phones.
        data: (list) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                if (active != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          UserAvatar(
                            baseUrl: active.baseUrl,
                            userId: active.userId,
                            name: user?.name ?? active.userName,
                            imageTag: user?.primaryImageTag,
                            radius: 36,
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(child: Text(active.userName, style: theme.textTheme.titleLarge)),
                                    const SizedBox(width: 8),
                                    const _SignedInMark(),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                _ServerLine(name: active.serverName, host: active.baseUrl.host),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton.icon(
                                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                                      label: const Text('Change picture'),
                                      onPressed: () => changeProfilePicture(ref),
                                    ),
                                    if (user?.primaryImageTag != null)
                                      TextButton.icon(
                                        icon: const Icon(Icons.hide_image_outlined, size: 18),
                                        label: const Text('Remove picture'),
                                        onPressed: () => removeProfilePicture(ref),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                  child: Text(
                    'Accounts on this device',
                    style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final session in list)
                        ListTile(
                          leading: _SavedAccountAvatar(session: session),
                          title: Text(session.userName),
                          subtitle: _ServerLine(name: session.serverName, host: session.baseUrl.host),
                          trailing: session.key == active?.key
                              ? const _SignedInMark()
                              : IconButton(
                                  tooltip: 'Remove account',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _confirmRemove(context, controller, session),
                                ),
                          onTap: session.key == active?.key
                              ? null
                              : () async {
                                  await controller.switchTo(session);
                                  if (context.mounted) context.go('/');
                                },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      // Sign in a TV (or another device) that shows a Quick
                      // Connect code, without the Jellyfin website.
                      ListTile(
                        leading: const Icon(Icons.phonelink_lock_outlined),
                        title: const Text('Approve a Quick Connect code'),
                        subtitle: active == null ? null : Text('Signs the other device in as ${active.userName}'),
                        onTap: () =>
                            showDialog<void>(context: context, builder: (_) => const _ApproveQuickConnectDialog()),
                      ),
                      ListTile(
                        leading: const Icon(Icons.person_add_alt),
                        title: const Text('Add account'),
                        onTap: () {
                          ref.read(loginFlowProvider.notifier).startAddingAccount();
                          context.push('/connect');
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.logout),
                        title: const Text('Sign out'),
                        onTap: controller.signOut,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    SessionController controller,
    StoredSession session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove account?'),
        content: Text(
          'Sign ${session.userName} out of ${session.serverName} on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.removeAccount(session);
  }
}

class _ApproveQuickConnectDialog extends ConsumerStatefulWidget {
  const _ApproveQuickConnectDialog();

  @override
  ConsumerState<_ApproveQuickConnectDialog> createState() => _ApproveQuickConnectDialogState();
}

class _ApproveQuickConnectDialogState extends ConsumerState<_ApproveQuickConnectDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(signedInApiProvider).authorizeQuickConnect(code);
      if (!mounted) return;
      final user = ref.read(currentSessionProvider).userName;
      Navigator.pop(context);
      showToast('Approved: the other device signs in as $user.');
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.statusCode) {
            404 => 'No device is waiting with that code. Check it, or start Quick Connect again there.',
            401 || 403 => "This account can't approve Quick Connect (or it's turned off on the server).",
            _ => e.message,
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Approve a Quick Connect code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Enter the code shown on the device that wants to sign in.'),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 6,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(letterSpacing: 8),
            decoration: const InputDecoration(labelText: 'Code', counterText: '', border: OutlineInputBorder()),
            onSubmitted: (_) => _approve(),
          ),
          if (_error case final e?) ...[
            const SizedBox(height: 8),
            Text(e, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _approve, child: Text(_busy ? 'Approving…' : 'Approve')),
      ],
    );
  }
}

/// "Signed in", for the account in use.
class _SignedInMark extends StatelessWidget {
  const _SignedInMark();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 14, color: colors.onPrimaryContainer),
          const SizedBox(width: 4),
          Text('Signed in', style: TextStyle(fontSize: 12, color: colors.onPrimaryContainer)),
        ],
      ),
    );
  }
}

/// The server an account is on: a server icon, so its name isn't read as
/// the user's.
class _ServerLine extends StatelessWidget {
  const _ServerLine({required this.name, required this.host});

  final String name;
  final String host;

  @override
  Widget build(BuildContext context) {
    final style =
        Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Row(
      children: [
        Icon(Icons.dns_outlined, size: 14, color: style?.color),
        const SizedBox(width: 4),
        Flexible(child: Text('$name · $host', style: style, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

/// A saved account's picture, asked of the server with its own sign-in.
class _SavedAccountAvatar extends ConsumerWidget {
  const _SavedAccountAvatar({required this.session});

  final StoredSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(savedAccountUserProvider(session.key)).value;
    return UserAvatar(
      baseUrl: session.baseUrl,
      userId: session.userId,
      name: session.userName,
      imageTag: user?.primaryImageTag,
    );
  }
}
