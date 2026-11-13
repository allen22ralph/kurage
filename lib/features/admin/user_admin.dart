import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/admin_api.dart';
import '../../core/time_ago.dart';
import 'admin_providers.dart';
import 'server_admin.dart';
import '../../app/app_dropdown.dart';

/// The server's users, with Add user (#84).
class UsersPage extends ConsumerWidget {
  const UsersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(adminUsersProvider);
    final me = ref.watch(currentSessionProvider).userId;
    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      body: switch (users) {
        AsyncValue(:final value?) => ListView(
            children: [
              for (final u in value)
                ListTile(
                  leading: CircleAvatar(child: Text(u.name.isEmpty ? '?' : u.name.characters.first.toUpperCase())),
                  title: Text(u.id == me ? '${u.name} (you)' : u.name),
                  subtitle: Text([
                    if (u.policy.isAdministrator) 'Administrator',
                    if (u.policy.isDisabled) 'Disabled',
                    if (!u.hasPassword) 'No password',
                    'Active ${timeAgo(u.lastActivity)}',
                  ].join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => UserPage(userId: u.id))),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.person_add_alt),
                title: const Text('Add user'),
                onTap: () => _add(context, ref),
              ),
            ],
          ),
        AsyncError(:final error) => Center(child: Text("Couldn't load the users: $error")),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<(String, String)>(context: context, builder: (_) => const _NewUserDialog());
    if (result == null) return;
    final (name, password) = result;
    AdminUser? created;
    await runAdmin(() async => created = await ref.read(adminApiProvider).createUser(name, password), done: 'Added $name');
    ref.invalidate(adminUsersProvider);
    if (created != null && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => UserPage(userId: created!.id)));
    }
  }
}

class _NewUserDialog extends StatefulWidget {
  const _NewUserDialog();

  @override
  State<_NewUserDialog> createState() => _NewUserDialogState();
}

class _NewUserDialogState extends State<_NewUserDialog> {
  final _name = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  void _done() {
    if (_name.text.trim().isEmpty) return;
    Navigator.pop(context, (_name.text.trim(), _password.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add user'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password', helperText: 'Can be left empty'),
              onSubmitted: (_) => _done(),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _done, child: const Text('Add')),
        ],
      );
}

/// One user: name, password, permissions, libraries, devices, remove.
/// Permission changes save straight away.
class UserPage extends ConsumerStatefulWidget {
  const UserPage({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<UserPage> createState() => _UserPageState();
}

class _UserPageState extends ConsumerState<UserPage> {
  /// The policy as last changed here (shown before the list reloads).
  UserPolicy? _policy;

  Future<void> _save(AdminUser user, UserPolicy policy) async {
    final before = _policy ?? user.policy;
    setState(() => _policy = policy);
    if (!await runAdmin(() => ref.read(adminApiProvider).savePolicy(user.id, policy))) {
      if (mounted) setState(() => _policy = before);
      return;
    }
    ref.invalidate(adminUsersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider);
    final user = users.value?.where((u) => u.id == widget.userId).firstOrNull;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: users.isLoading ? const CircularProgressIndicator() : const Text('This user is gone.')),
      );
    }
    final me = ref.watch(currentSessionProvider).userId == user.id;
    final policy = _policy ?? user.policy;
    final libraries = ref.watch(serverLibrariesProvider).value ?? const [];
    final ratings = ref.watch(parentalRatingsProvider).value ?? const [];
    final theme = Theme.of(context);
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        );

    return Scaffold(
      appBar: AppBar(title: Text(user.name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          section('Account'),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Name'),
            subtitle: Text(user.name),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _rename(user),
          ),
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('Set password'),
            subtitle: Text(user.hasPassword ? 'Has a password' : 'No password'),
            onTap: () => _password(user),
          ),
          section('Permissions'),
          SwitchListTile(
            title: const Text('Administrator'),
            subtitle: Text(me ? "You can't remove your own administrator rights" : 'Can manage the server and its users'),
            value: policy.isAdministrator,
            onChanged: me ? null : (v) => _save(user, policy.copyWith(isAdministrator: v)),
          ),
          SwitchListTile(
            title: const Text('Account disabled'),
            subtitle: const Text("Can't sign in while disabled"),
            value: policy.isDisabled,
            onChanged: me ? null : (v) => _save(user, policy.copyWith(isDisabled: v)),
          ),
          ListTile(
            title: const Text('Watch together'),
            trailing: AppDropdown<SyncPlayAccess>(
              value: policy.syncPlay,
              underline: const SizedBox.shrink(),
              items: [for (final a in SyncPlayAccess.values) DropdownMenuItem(value: a, child: Text(a.label))],
              onChanged: (a) => a == null ? null : _save(user, policy.copyWith(syncPlay: a)),
            ),
          ),
          SwitchListTile(
            title: const Text('Downloads'),
            subtitle: const Text('Save episodes and movies to watch offline'),
            value: policy.downloads,
            onChanged: (v) => _save(user, policy.copyWith(downloads: v)),
          ),
          SwitchListTile(
            title: const Text('Transcoding'),
            subtitle: const Text('Convert video and audio a device can’t play'),
            value: policy.transcoding,
            onChanged: (v) => _save(user, policy.copyWith(transcoding: v)),
          ),
          SwitchListTile(
            title: const Text('Remuxing'),
            subtitle: const Text('Repackage files without converting them'),
            value: policy.remuxing,
            onChanged: (v) => _save(user, policy.copyWith(remuxing: v)),
          ),
          SwitchListTile(
            title: const Text('Remote access'),
            subtitle: const Text('Use the server from outside the home network'),
            value: policy.remoteAccess,
            onChanged: (v) => _save(user, policy.copyWith(remoteAccess: v)),
          ),
          if (ratings.isNotEmpty)
            ListTile(
              title: const Text('Highest parental rating'),
              trailing: AppDropdown<int?>(
                value: ratings.any((r) => r.value == policy.maxParentalRating) ? policy.maxParentalRating : null,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('No limit')),
                  for (final r in ratings) DropdownMenuItem<int?>(value: r.value, child: Text(r.name)),
                ],
                onChanged: (v) => _save(user, policy.copyWith(maxParentalRating: () => v)),
              ),
            ),
          section('Libraries'),
          SwitchListTile(
            title: const Text('All libraries'),
            value: policy.allLibraries,
            onChanged: (v) => _save(user, policy.copyWith(allLibraries: v)),
          ),
          if (!policy.allLibraries)
            for (final l in libraries)
              CheckboxListTile(
                title: Text(l.name),
                value: policy.libraries.contains(l.id),
                onChanged: (v) => _save(
                  user,
                  policy.copyWith(libraries: [
                    for (final id in policy.libraries)
                      if (id != l.id) id,
                    if (v ?? false) l.id,
                  ]),
                ),
              ),
          section('Devices'),
          DevicesList(userId: user.id),
          if (!me) ...[
            const Divider(height: 32),
            ListTile(
              leading: Icon(Icons.person_remove_outlined, color: theme.colorScheme.error),
              title: Text('Remove ${user.name}', style: TextStyle(color: theme.colorScheme.error)),
              onTap: () => _delete(user),
            ),
          ],
        ],
      ),
    );
  }

  Future<String?> _ask(String title, {String initial = '', bool secret = false, String? helper}) async {
    final text = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
          autofocus: true,
          obscureText: secret,
          decoration: InputDecoration(helperText: helper),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
        ],
      ),
    );
    text.dispose();
    return result;
  }

  Future<void> _rename(AdminUser user) async {
    final name = (await _ask('Name', initial: user.name))?.trim();
    if (name == null || name.isEmpty || name == user.name) return;
    await runAdmin(() => ref.read(adminApiProvider).renameUser(user.id, name), done: 'Renamed to $name');
    ref.invalidate(adminUsersProvider);
  }

  Future<void> _password(AdminUser user) async {
    final password = await _ask('New password for ${user.name}', secret: true, helper: 'Empty: no password');
    if (password == null) return;
    await runAdmin(
      () => ref.read(adminApiProvider).setPassword(user.id, password),
      done: password.isEmpty ? '${user.name} has no password now' : 'Password changed',
    );
    ref.invalidate(adminUsersProvider);
  }

  Future<void> _delete(AdminUser user) async {
    final sure = await confirm(
      context,
      title: 'Remove ${user.name}?',
      message: 'Their account, watch history and settings are deleted from the server. This can’t be undone.',
      action: 'Remove',
      destructive: true,
    );
    if (!sure) return;
    if (await runAdmin(() => ref.read(adminApiProvider).deleteUser(user.id), done: 'Removed ${user.name}')) {
      ref.invalidate(adminUsersProvider);
      if (mounted) Navigator.of(context).pop();
    }
  }
}
