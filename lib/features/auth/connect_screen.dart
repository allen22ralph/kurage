import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/jellyfin/server_address.dart';
import '../../core/storage/session_store.dart';
import '../home/home_screen.dart';
import 'widgets/auth_layout.dart';
import 'widgets/trust_certificate_dialog.dart';
import 'widgets/saved_accounts.dart';
import '../../app/connection_check.dart';

/// First sign-in step: find the Jellyfin server.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _address = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Set when the server's certificate isn't trusted: offer to trust it.
  Uri? _untrusted;

  /// Sent here because the signed-in server didn't answer: it's tried again
  /// every 30 seconds, and Home comes back once it answers.
  Timer? _retryTimer;
  bool _retrying = false;
  bool _stillDown = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(loginFlowProvider).unreachable != null) {
      _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) => _tryAgain(quiet: true));
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _address.dispose();
    super.dispose();
  }

  /// Tries the unreachable server again; back to Home if it answers.
  Future<void> _tryAgain({bool quiet = false}) async {
    if (_retrying) return;
    setState(() {
      _retrying = !quiet;
      _stillDown = false;
    });
    try {
      await refreshHome(ref);
      if (!mounted) return;
      _retryTimer?.cancel();
      // The router takes the user back to Home.
      ref.read(loginFlowProvider.notifier).reset();
    } on Object {
      if (mounted) {
        setState(() {
          _retrying = false;
          _stillDown = !quiet;
        });
      }
    }
  }

  void _pickAccount(StoredSession session) {
    if (session.key == ref.read(loginFlowProvider).unreachable?.key) {
      _tryAgain();
    } else {
      ref.read(sessionControllerProvider.notifier).switchTo(session);
    }
  }

  Future<void> _connectTyped() async {
    final List<Uri> candidates;
    try {
      candidates = serverAddressCandidates(_address.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    await _connect(candidates);
  }

  Future<void> _test() async {
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
    });
    await ConnectionChecks.of(ProviderScope.containerOf(context, listen: false))
        .jellyfin(candidates);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _connect(List<Uri> candidates) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _untrusted = null;
    });

    final apiFactory = ref.read(apiFactoryProvider);
    String? lastError;
    Uri? untrusted;
    for (final baseUrl in candidates) {
      try {
        final info = await apiFactory(baseUrl).getPublicSystemInfo();
        if (!mounted) return;
        ref
            .read(loginFlowProvider.notifier)
            .selectServer(PendingServer(baseUrl: baseUrl, info: info));
        setState(() => _busy = false);
        context.push('/connect/login');
        return;
      } on JellyfinException catch (e) {
        lastError = e.message;
        if (e.untrustedCertificate) untrusted ??= baseUrl;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = lastError;
      _untrusted = untrusted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(knownServersProvider).value ?? const [];
    final unreachable = ref.watch(loginFlowProvider.select((f) => f.unreachable));
    return AuthLayout(
      title: 'Connect to server',
      subtitle: servers.isEmpty
          ? 'Enter the address of your Jellyfin server.'
          : 'Pick an account or server, or enter a new address.',
      children: [
        if (unreachable != null)
          _Unreachable(
            session: unreachable,
            retrying: _retrying,
            stillDown: _stillDown,
            onTryAgain: _tryAgain,
            onDownloads: () => context.push('/downloads'),
          ),
        SavedAccounts(onPick: unreachable == null ? null : _pickAccount),
        if (servers.isNotEmpty) ...[
          const SectionLabel('Servers'),
          for (final server in servers)
            _KnownServerTile(
              server: server,
              enabled: !_busy,
              onTap: () => _connect([server.baseUrl]),
              onForget: () async {
                await ref.read(sessionStoreProvider).forgetServer(server.id);
                ref.invalidate(knownServersProvider);
              },
            ),
          const SizedBox(height: 24),
        ],
        TextField(
          controller: _address,
          autofocus: servers.isEmpty,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autofillHints: const [AutofillHints.url],
          autocorrect: false,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _connectTyped(),
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'jellyfin.home.arpa or 192.168.1.10:8096',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _connectTyped,
          child: _busy ? const ButtonSpinner() : const Text('Connect'),
        ),
        const SizedBox(height: 8),
        // Checks the address without going on to sign in.
        OutlinedButton.icon(
          icon: const Icon(Icons.network_check),
          label: const Text('Test connection'),
          onPressed: _busy ? null : _test,
        ),
        if (_error != null) AuthError(_error!),
        if (_untrusted case final server?) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            autofocus: true,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text("Trust this server's certificate authority…"),
            onPressed: () async {
              if (await showTrustCertificateDialog(context, server: server)) {
                await _connect([server]);
              }
            },
          ),
        ],
      ],
    );
  }
}

/// The signed-in server didn't answer: say so, offer to try it again, and
/// the downloads, which play without it.
class _Unreachable extends StatelessWidget {
  const _Unreachable({
    required this.session,
    required this.retrying,
    required this.stillDown,
    required this.onTryAgain,
    required this.onDownloads,
  });

  final StoredSession session;
  final bool retrying;
  final bool stillDown;
  final VoidCallback onTryAgain;
  final VoidCallback onDownloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.cloud_off_outlined, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text("Can't reach ${session.serverName}", style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                stillDown
                    ? '${session.baseUrl.host} still isn\'t answering. Trying again every 30 seconds.'
                    : '${session.baseUrl.host} isn\'t answering. You\'re still signed in; '
                        'trying again every 30 seconds, or pick another server below.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    autofocus: true,
                    onPressed: retrying ? null : onTryAgain,
                    child: retrying ? const ButtonSpinner() : const Text('Try again'),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.download_done_outlined),
                    label: const Text('Downloads'),
                    onPressed: onDownloads,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KnownServerTile extends StatelessWidget {
  const _KnownServerTile({
    required this.server,
    required this.enabled,
    required this.onTap,
    required this.onForget,
  });

  final KnownServer server;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: const CircleAvatar(child: Icon(Icons.dns_outlined)),
      title: Text(server.name),
      subtitle: Text(server.baseUrl.host),
      onTap: onTap,
      trailing: IconButton(
        tooltip: 'Forget server',
        icon: const Icon(Icons.close),
        onPressed: enabled ? onForget : null,
      ),
    );
  }
}
