import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../player/open_player.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/jellyfin/syncplay.dart';
import '../library/library_providers.dart';
import 'syncplay_service.dart';

/// Watch together: join or start a group, or (in one) see who's there and
/// leave.
Future<void> showSyncPlaySheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  // Dragged closed by touch; with a mouse, dragging slid it about.
  showDragHandle: _touch,
  enableDrag: _touch,
  isScrollControlled: true,
  builder: (_) => const _SyncPlaySheet(),
);

final _groupsProvider = FutureProvider.autoDispose<List<SyncPlayGroup>>(
  (ref) => ref.watch(syncPlayProvider.notifier).groups(),
  retry: (_, _) => null,
);

class _SyncPlaySheet extends ConsumerStatefulWidget {
  const _SyncPlaySheet();

  @override
  ConsumerState<_SyncPlaySheet> createState() => _SyncPlaySheetState();
}

class _SyncPlaySheetState extends ConsumerState<_SyncPlaySheet> {
  late final _name = TextEditingController(text: "${ref.read(currentSessionProvider).userName}'s group");

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(syncPlayProvider);
    final controller = ref.read(syncPlayProvider.notifier);
    final theme = Theme.of(context);
    final group = state.group;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: Text('Watch together', style: theme.textTheme.titleLarge),
                subtitle: const Text("Play, pause and seek for everyone in the group, in step"),
              ),
              if (state.error case final e?)
                ListTile(
                  title: Text(e, style: TextStyle(color: theme.colorScheme.error)),
                ),
              if (group != null) ...[
                ListTile(
                  title: Text(group.name),
                  subtitle: Text(state.participants.isEmpty ? 'Just you' : state.participants.join(', ')),
                  trailing: TextButton.icon(
                    onPressed: controller.syncNow,
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync now'),
                  ),
                ),
                const _AudioDelay(),
                if (state.queue?.current == null)
                  const ListTile(
                    leading: Icon(Icons.hourglass_empty),
                    title: Text('Waiting for the group…'),
                    subtitle: Text('What the group is watching shows here as soon as someone plays something'),
                  ),
                SwitchListTile(
                  title: const Text('Pause the group when I leave the player'),
                  subtitle: const Text('Off: you step out of the group and the others carry on; rejoin from here'),
                  value: ref.watch(syncPlayPauseOnLeaveProvider),
                  onChanged: (on) => ref.read(syncPlayPauseOnLeaveProvider.notifier).set(on),
                ),
                // What the group is watching, to join in (not opened by
                // itself on joining).
                if (state.queue?.current?.itemId case final item?)
                  if (OpenPlayer.itemId.value != item)
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(switch (ref.watch(itemProvider(item))) {
                        AsyncData(:final value) => [
                          value.seriesName,
                          value.episodeLabel,
                          value.name,
                        ].nonNulls.join(' · '),
                        _ => 'Something is playing',
                      }),
                      subtitle: const Text('The group is watching this'),
                      trailing: FilledButton(
                        onPressed: () {
                          Navigator.pop(context);
                          openGroupItem(ref.read(routerProvider), controller, item, via: 'join');
                        },
                        child: const Text('Join in'),
                      ),
                    ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    autofocus: true,
                    icon: const Icon(Icons.logout),
                    label: const Text('Leave the group'),
                    onPressed: () async {
                      await controller.leave();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ),
              ] else ...[
                if (controller.steppedOut case final g?)
                  ListTile(
                    leading: const Icon(Icons.group_add_outlined),
                    title: Text('Rejoin ${g.name}'),
                    subtitle: const Text('You stepped out when you left the player'),
                    trailing: FilledButton(
                      autofocus: true,
                      onPressed: state.busy ? null : controller.rejoin,
                      child: const Text('Rejoin'),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _name,
                          enabled: !state.busy,
                          decoration: const InputDecoration(labelText: 'New group', border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        autofocus: true,
                        onPressed: state.busy ? null : () => controller.create(_name.text.trim()),
                        child: Text(state.busy ? 'Starting…' : 'Start'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ...switch (ref.watch(_groupsProvider)) {
                  AsyncData(value: final groups) when groups.isEmpty => [
                    const ListTile(subtitle: Text('No groups yet. Start one, then others join it.')),
                  ],
                  AsyncData(value: final groups) => [
                    for (final g in groups)
                      ListTile(
                        leading: const Icon(Icons.group),
                        title: Text(g.name),
                        subtitle: Text([g.participants.join(', '), ?g.state].where((s) => s.isNotEmpty).join(' · ')),
                        trailing: TextButton(
                          onPressed: state.busy ? null : () => controller.join(g.id),
                          child: const Text('Join'),
                        ),
                      ),
                  ],
                  AsyncError(:final error) => [ListTile(subtitle: Text("Couldn't list groups: $error"))],
                  _ => [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ],
                },
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

bool get _touch => Platform.isAndroid || Platform.isIOS;

/// This device's sound delay, to fine-tune when it echoes against the
/// others (e.g. a phone's speaker comes out later).
class _AudioDelay extends ConsumerWidget {
  const _AudioDelay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms = ref.watch(syncPlayAudioDelayProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Text('Audio delay'),
          Expanded(
            child: Slider(
              min: -500,
              max: 500,
              divisions: 40,
              value: ms.toDouble(),
              label: '$ms ms',
              onChanged: (v) => ref.read(syncPlayAudioDelayProvider.notifier).set(v.round()),
            ),
          ),
          SizedBox(width: 64, child: Text('$ms ms', textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}
