import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/jellyfin/server_address.dart';
import '../../core/jellyfin/server_addresses.dart';

/// Settings > Account & server: the addresses the signed-in server is
/// reached at (at home, over Tailscale or the internet). The app uses
/// whichever answers, home ones first.
class ServerAddressesSection extends ConsumerWidget {
  const ServerAddressesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider).value;
    if (session == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final addresses = rankAddresses(session.addresses);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            addresses.length < 2
                ? 'Add the address you use away from home (Tailscale, say), and the app switches '
                    'to whichever answers.'
                : 'The app uses whichever answers, home addresses first: when it starts, when you '
                    'refresh Home, and when the network changes.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final address in addresses)
          ListTile(
            leading: Icon(isHomeAddress(address) ? Icons.home_outlined : Icons.public),
            title: Text(address.toString()),
            subtitle: Text([
              isHomeAddress(address) ? 'Home network' : 'Away',
              if (address == session.baseUrl) 'in use',
            ].join(' · ')),
            trailing: addresses.length < 2
                ? null
                : IconButton(
                    tooltip: 'Remove address',
                    icon: const Icon(Icons.close),
                    onPressed: () => ref
                        .read(sessionControllerProvider.notifier)
                        .setAddresses([for (final a in session.addresses) if (a != address) a]),
                  ),
          ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Add address'),
          onTap: () => showDialog<void>(context: context, builder: (_) => const _AddAddressDialog()),
        ),
      ],
    );
  }
}

class _AddAddressDialog extends ConsumerStatefulWidget {
  const _AddAddressDialog();

  @override
  ConsumerState<_AddAddressDialog> createState() => _AddAddressDialogState();
}

class _AddAddressDialogState extends ConsumerState<_AddAddressDialog> {
  final _address = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Set when the address didn't answer: it can still be added, for a
  /// network the device isn't on now.
  Uri? _unchecked;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _add(List<Uri> addresses) async {
    final session = ref.read(sessionControllerProvider).value;
    if (session == null) return;
    await ref.read(sessionControllerProvider.notifier).setAddresses(withAddresses(session.addresses, addresses));
    if (mounted) Navigator.pop(context);
  }

  static List<Uri> withAddresses(List<Uri> to, List<Uri> add) => add.fold(to, withAddress);

  /// Checks it's this server (not another one at that address), then adds it.
  Future<void> _check() async {
    final session = ref.read(sessionControllerProvider).value;
    if (session == null) return;
    final List<Uri> candidates;
    try {
      candidates = serverAddressCandidates(_address.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _unchecked = null;
    });
    final factory = ref.read(apiFactoryProvider);
    String? error;
    for (final address in candidates) {
      try {
        final info = await factory(address).getPublicSystemInfo().timeout(const Duration(seconds: 8));
        if (info.id == session.serverId) {
          await _add([address]);
          return;
        }
        error = "That's a different server (${info.serverName}), not ${session.serverName}.";
        break;
      } on JellyfinException catch (e) {
        error ??= e.message;
      } on Object {
        error ??= "It didn't answer.";
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error != null && !error.startsWith("That's a different server")) {
        // Typed without http(s)://: an address with a port is most likely
        // Jellyfin's own (http); a name alone, a proxy's (https).
        _unchecked = candidates.length > 1 && candidates.first.hasPort ? candidates.last : candidates.first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Add address'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _address,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onSubmitted: (_) => _check(),
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: 'jellyfin.example.ts.net or 100.64.0.5:8096',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (_unchecked != null) ...[
              const SizedBox(height: 4),
              Text(
                "If it's for another network (away from home, say), add it anyway: it's checked when used.",
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (_unchecked case final address?)
          TextButton(onPressed: _busy ? null : () => _add([address]), child: const Text('Add anyway')),
        FilledButton(
          onPressed: _busy ? null : _check,
          child: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}
