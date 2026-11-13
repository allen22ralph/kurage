import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/toast.dart';
import '../../core/jellyfin/admin_api.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/log/app_log.dart';
import '../../core/time_ago.dart';
import 'admin_providers.dart';
import 'user_admin.dart';

/// Runs an admin call, saying how it went in a toast.
Future<bool> runAdmin(Future<void> Function() action, {String? done}) async {
  try {
    await action();
    if (done != null) {
      AppLog.info(LogArea.admin, done);
      showToast(done);
    }
    return true;
  } on JellyfinException catch (e) {
    AppLog.warning(LogArea.admin, 'Admin action failed${done == null ? '' : ' ($done)'}', error: e);
    showToast(e.statusCode == 403 ? 'Only server administrators can do that.' : e.message);
  } on Object catch (e, stack) {
    AppLog.error(LogArea.admin, 'Admin action failed${done == null ? '' : ' ($done)'}', error: e, stack: stack);
    showToast("Couldn't do that: $e");
  }
  return false;
}

/// Settings > Server (administrators only): the server, its libraries and
/// tasks, users and devices, restart and shut down (#84).
class ServerAdminSection extends ConsumerWidget {
  const ServerAdminSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return Column(
      children: [
        const _ServerInfoTile(),
        const _ScanLibrariesTile(),
        ListTile(
          leading: const Icon(Icons.schedule),
          title: const Text('Scheduled tasks'),
          subtitle: const Text('See what the server runs, and run a task now'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => open(const ScheduledTasksPage()),
        ),
        ListTile(
          leading: const Icon(Icons.group_outlined),
          title: const Text('Users'),
          subtitle: const Text('Add, rename or remove users; passwords and permissions'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => open(const UsersPage()),
        ),
        ListTile(
          leading: const Icon(Icons.devices_outlined),
          title: const Text('Devices'),
          subtitle: const Text('Every device signed in to the server'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => open(const DevicesPage()),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Restart server'),
          subtitle: const Text('Playback stops for everyone for a moment'),
          onTap: () => restartServer(context, ref),
        ),
        ListTile(
          leading: Icon(Icons.power_settings_new, color: Theme.of(context).colorScheme.error),
          title: const Text('Shut down server'),
          subtitle: const Text('It has to be started again on the server machine'),
          onTap: () => _shutdown(context, ref),
        ),
      ],
    );
  }

  Future<void> _shutdown(BuildContext context, WidgetRef ref) async {
    final server = ref.read(currentSessionProvider).serverName;
    final sure = await confirm(
      context,
      title: 'Shut down $server?',
      message: 'Everyone using it is disconnected, and it stays off until started again on the server machine.',
      action: 'Shut down',
      destructive: true,
    );
    if (!sure) return;
    await runAdmin(() => ref.read(adminApiProvider).shutdown(), done: '$server is shutting down.');
  }
}

/// A yes / no question; true for yes.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  bool destructive = false,
}) async {
  final theme = Theme.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              style: destructive ? FilledButton.styleFrom(backgroundColor: theme.colorScheme.error, foregroundColor: theme.colorScheme.onError) : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}

/// Restarts the server, then waits for it to come back (the app carries
/// on by itself once it answers again).
Future<void> restartServer(BuildContext context, WidgetRef ref) async {
  final server = ref.read(currentSessionProvider).serverName;
  final sure = await confirm(
    context,
    title: 'Restart $server?',
    message: 'Playback stops for everyone while it restarts (usually under a minute).',
    action: 'Restart',
  );
  if (!sure || !context.mounted) return;
  final api = ref.read(signedInApiProvider);
  if (!await runAdmin(() => ref.read(adminApiProvider).restart())) return;
  if (!context.mounted) return;
  final back = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WaitForServer(name: server, ping: api.getPublicSystemInfo),
  );
  if (back == true) {
    ref.invalidate(serverInfoProvider);
    showToast('$server is back.');
  }
}

/// "Restarting…" until the server answers again (after first going away).
class _WaitForServer extends StatefulWidget {
  const _WaitForServer({required this.name, required this.ping});

  final String name;
  final Future<Object?> Function() ping;

  @override
  State<_WaitForServer> createState() => _WaitForServerState();
}

class _WaitForServerState extends State<_WaitForServer> {
  Timer? _timer;
  final _started = DateTime.now();
  bool _wentAway = false;
  bool _gaveUp = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  Future<void> _check() async {
    final waited = DateTime.now().difference(_started);
    try {
      await widget.ping();
      // Answering again: after it went away, or once it had time to (a
      // fast restart can be missed between two checks).
      if ((_wentAway || waited > const Duration(seconds: 10)) && mounted) Navigator.pop(context, true);
    } on Object {
      _wentAway = true;
    }
    if (waited > const Duration(minutes: 3) && mounted && !_gaveUp) setState(() => _gaveUp = true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Restarting ${widget.name}…'),
        content: Row(
          children: [
            if (!_gaveUp) const Padding(padding: EdgeInsets.only(right: 16), child: CircularProgressIndicator()),
            Expanded(
              child: Text(_gaveUp
                  ? "It hasn't come back after 3 minutes. Check the server machine."
                  : 'Waiting for it to come back.'),
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_gaveUp ? 'Close' : 'Stop waiting'))],
      );
}

class _ServerInfoTile extends ConsumerWidget {
  const _ServerInfoTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(serverInfoProvider);
    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: Text(info.value?.name ?? ref.watch(currentSessionProvider).serverName),
      subtitle: Text(switch (info) {
        AsyncData(:final value) => [
            'Jellyfin ${value.version}',
            if (value.os.isNotEmpty) value.os,
            if (value.pendingRestart) 'Restart needed to finish updating',
            if (value.updateAvailable) 'Update available',
          ].join('\n'),
        AsyncError() => "Couldn't load the server's details",
        _ => 'Loading…',
      }),
      isThreeLine: info.value?.os.isNotEmpty ?? false,
    );
  }
}

/// Scan all libraries, with the scan's progress (from its scheduled task).
class _ScanLibrariesTile extends ConsumerStatefulWidget {
  const _ScanLibrariesTile();

  @override
  ConsumerState<_ScanLibrariesTile> createState() => _ScanLibrariesTileState();
}

class _ScanLibrariesTileState extends ConsumerState<_ScanLibrariesTile> {
  Timer? _poll;
  ScheduledTask? _scan;

  @override
  void initState() {
    super.initState();
    _check(); // a scan already running shows its progress too
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final tasks = await ref.read(adminApiProvider).scheduledTasks();
      final scan = tasks.where((t) => t.key == 'RefreshLibrary').firstOrNull;
      if (!mounted) return;
      setState(() => _scan = scan);
      if (scan?.running ?? false) {
        _poll ??= Timer.periodic(const Duration(seconds: 2), (_) => _check());
      } else {
        _poll?.cancel();
        _poll = null;
      }
    } on Object {
      // Not an admin, or the server is away: no progress to show.
    }
  }

  Future<void> _start() async {
    if (await runAdmin(() => ref.read(adminApiProvider).scanAllLibraries(), done: 'Scanning all libraries…')) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _check();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = _scan;
    final running = scan?.running ?? false;
    return ListTile(
      leading: const Icon(Icons.manage_search),
      title: const Text('Scan all libraries'),
      subtitle: running
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: scan!.progress == null ? null : scan.progress! / 100),
                  const SizedBox(height: 4),
                  Text(scan.progress == null ? 'Scanning…' : 'Scanning… ${scan.progress!.round()} %'),
                ],
              ),
            )
          : Text(scan?.lastEnded == null
              ? 'Find new, changed and removed files'
              : 'Last scan ${timeAgo(scan!.lastEnded)}${scan.lastFailed ? ' (failed)' : ''}'),
      onTap: running ? null : _start,
    );
  }
}

/// The server's scheduled tasks by category, with run / stop, refreshed
/// every few seconds while open.
class ScheduledTasksPage extends ConsumerStatefulWidget {
  const ScheduledTasksPage({super.key});

  @override
  ConsumerState<ScheduledTasksPage> createState() => _ScheduledTasksPageState();
}

class _ScheduledTasksPageState extends ConsumerState<ScheduledTasksPage> {
  late final Timer _poll = Timer.periodic(const Duration(seconds: 3), (_) => ref.invalidate(scheduledTasksProvider));

  @override
  void initState() {
    super.initState();
    _poll;
  }

  @override
  void dispose() {
    _poll.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(scheduledTasksProvider);
    final api = ref.read(adminApiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled tasks')),
      body: switch (tasks) {
        AsyncValue(:final value?) => ListView(
            children: [
              for (final category in {for (final t in value) t.category}.toList()..sort()) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(category,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                ),
                for (final t in value.where((t) => t.category == category))
                  ListTile(
                    title: Text(t.name),
                    subtitle: t.running
                        ? Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: LinearProgressIndicator(value: t.progress == null ? null : t.progress! / 100),
                          )
                        : Text(
                            [
                              if (t.description.isNotEmpty) t.description,
                              'Last run ${timeAgo(t.lastEnded)}${t.lastStatus == null || t.lastStatus == 'Completed' ? '' : ' (${t.lastStatus!.toLowerCase()})'}',
                            ].join('\n'),
                            style: t.lastFailed ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                          ),
                    isThreeLine: !t.running && t.description.isNotEmpty,
                    trailing: t.running
                        ? IconButton(
                            tooltip: 'Stop',
                            icon: const Icon(Icons.stop_circle_outlined),
                            onPressed: () async {
                              await runAdmin(() => api.stopTask(t.id));
                              ref.invalidate(scheduledTasksProvider);
                            },
                          )
                        : IconButton(
                            tooltip: 'Run now',
                            icon: const Icon(Icons.play_circle_outline),
                            onPressed: () async {
                              await runAdmin(() => api.startTask(t.id), done: 'Started ${t.name}');
                              ref.invalidate(scheduledTasksProvider);
                            },
                          ),
                  ),
              ],
            ],
          ),
        AsyncError(:final error) => Center(child: Text("Couldn't load the tasks: $error")),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// Devices signed in to the server (one user's, or everyone's), each with
/// Sign out.
class DevicesList extends ConsumerWidget {
  const DevicesList({super.key, this.userId});

  final String? userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(serverDevicesProvider(userId));
    final ownDevice = ref.read(clientInfoProvider).deviceId;
    return switch (devices) {
      AsyncData(:final value) when value.isEmpty => const ListTile(title: Text('No devices.')),
      AsyncData(:final value) => Column(
          children: [
            for (final d in value)
              ListTile(
                leading: const Icon(Icons.devices_other),
                title: Text(d.name),
                subtitle: Text([
                  d.app,
                  if (userId == null && d.userName != null) d.userName!,
                  'Active ${timeAgo(d.lastActive)}',
                ].where((s) => s.isNotEmpty).join(' · ')),
                trailing: d.id == ownDevice
                    ? const Tooltip(message: 'This device', child: Icon(Icons.smartphone))
                    : IconButton(
                        tooltip: 'Sign out',
                        icon: const Icon(Icons.logout),
                        onPressed: () async {
                          final sure = await confirm(
                            context,
                            title: 'Sign out ${d.name}?',
                            message: 'It has to sign in again to use the server.',
                            action: 'Sign out',
                          );
                          if (!sure) return;
                          await runAdmin(() => ref.read(adminApiProvider).signOutDevice(d.id), done: 'Signed out ${d.name}');
                          ref.invalidate(serverDevicesProvider(userId));
                        },
                      ),
              ),
          ],
        ),
      AsyncError(:final error) => ListTile(title: Text("Couldn't load the devices: $error")),
      _ => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
    };
  }
}

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Devices')),
        body: const SingleChildScrollView(child: DevicesList()),
      );
}

/// Admin entries for a card's menu: scan a library, or refresh an item's
/// metadata.
bool isLibrary(BaseItem item) => item.type == ItemType.collectionFolder || item.type == ItemType.userView;

/// Refreshes [item]'s metadata after asking how much to redo.
Future<void> showRefreshMetadata(BuildContext context, BaseItem item) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (isLibrary(item)) {
    await runAdmin(
      () => container.read(adminApiProvider).refreshItem(item.id, mode: RefreshMode.scan),
      done: 'Scanning ${item.name}…',
    );
    return;
  }
  final choice = await showDialog<(RefreshMode, bool)>(context: context, builder: (_) => _RefreshDialog(item: item));
  if (choice == null) return;
  final (mode, images) = choice;
  await runAdmin(
    () => container.read(adminApiProvider).refreshItem(item.id, mode: mode, replaceImages: images),
    done: 'Refreshing ${item.name}…',
  );
}

class _RefreshDialog extends StatefulWidget {
  const _RefreshDialog({required this.item});

  final BaseItem item;

  @override
  State<_RefreshDialog> createState() => _RefreshDialogState();
}

class _RefreshDialogState extends State<_RefreshDialog> {
  RefreshMode _mode = RefreshMode.missing;
  bool _images = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Refresh ${widget.item.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioGroup<RefreshMode>(
              groupValue: _mode,
              onChanged: (m) => setState(() => _mode = m ?? _mode),
              child: Column(
                children: [
                  for (final m in RefreshMode.values)
                    RadioListTile<RefreshMode>(value: m, title: Text(m.label), contentPadding: EdgeInsets.zero),
                ],
              ),
            ),
            CheckboxListTile(
              value: _images,
              onChanged: _mode == RefreshMode.scan ? null : (v) => setState(() => _images = v ?? false),
              title: const Text('Replace existing images'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, (_mode, _images && _mode != RefreshMode.scan)),
            child: const Text('Refresh'),
          ),
        ],
      );
}
