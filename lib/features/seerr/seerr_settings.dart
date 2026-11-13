import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/server_address.dart';
import '../../core/seerr/seerr_api.dart';
import 'request_window.dart';
import 'seerr_health.dart';
import 'seerr_providers.dart';
import '../../app/connection_check.dart';

/// How to sign in to Seerr.
enum _SignInMode { jellyfin, seerr, apiKey }

/// Settings > Seerr: sign in (Jellyfin account, Seerr account or API key) / out.
/// Opening it asks Seerr whether it answers, so a saved sign-in isn't shown
/// as if all were well while Seerr is down.
class SeerrSettingsSection extends ConsumerStatefulWidget {
  const SeerrSettingsSection({super.key});

  @override
  ConsumerState<SeerrSettingsSection> createState() => _SeerrSettingsSectionState();
}

class _SeerrSettingsSectionState extends ConsumerState<SeerrSettingsSection> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_check);
  }

  Future<void> _check() async {
    final account = await ref.read(seerrAccountProvider.future).catchError((Object _) => null);
    if (account == null || !mounted) return;
    setState(() => _checking = true);
    try {
      // Reports whether Seerr answered (seerrReachableProvider).
      await ref.read(seerrAccountProvider.notifier).refresh();
    } on Object {
      // Shown below as "can't be reached"; the reason is in the log.
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(seerrAccountProvider).value;
    if (account == null) {
      return ListTile(
        leading: const Icon(Icons.add_link),
        title: const Text('Sign in to Seerr'),
        subtitle: const Text("Request shows and movies; see what's trending"),
        onTap: () => showDialog<void>(context: context, builder: (_) => const _SeerrSignInDialog()),
      );
    }
    final reachable = ref.watch(seerrReachableProvider);
    final error = Theme.of(context).colorScheme.error;
    final where = '${account.user.role} · ${account.baseUrl.host}';
    return Column(
      children: [
        ListTile(
          leading: _checking
              ? const SizedBox.square(dimension: 24, child: Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2)))
              : Icon(reachable ? Icons.verified_user_outlined : Icons.cloud_off_outlined, color: reachable ? null : error),
          title: Text(
            _checking
                ? 'Checking Seerr…'
                : reachable
                    ? 'Signed in as ${account.user.displayName}'
                    : "Seerr can't be reached",
            style: !_checking && !reachable ? TextStyle(color: error) : null,
          ),
          // The sign-in is kept: it works again once Seerr can be reached
          // (e.g. back on the home network).
          subtitle: Text(!_checking && !reachable
              ? "${account.user.displayName} stays signed in for when it's back · $where"
              : where),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Whether Seerr answers now and still lets this account in.
              CheckConnectionButton(
                check: () async {
                  final check = await ConnectionChecks.of(ProviderScope.containerOf(context, listen: false))
                      .seerr(account.baseUrl, apiKey: account.apiKey, cookie: account.cookie);
                  ref.read(seerrReachableProvider.notifier).report(ok: check.ok || check.reached);
                  // Up to date with what Seerr now lets the account do.
                  if (check.ok) await ref.read(seerrAccountProvider.notifier).refresh().catchError((Object _) {});
                  return check;
                },
              ),
              TextButton(
                onPressed: () => ref.read(seerrAccountProvider.notifier).signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
        const RequestWindowSetting(),
      ],
    );
  }
}

class _SeerrSignInDialog extends ConsumerStatefulWidget {
  const _SeerrSignInDialog();

  @override
  ConsumerState<_SeerrSignInDialog> createState() => _SeerrSignInDialogState();
}

class _SeerrSignInDialogState extends ConsumerState<_SeerrSignInDialog> {
  final _address = TextEditingController();
  late final _username = TextEditingController(text: ref.read(currentSessionProvider).userName);
  final _secret = TextEditingController();
  var _mode = _SignInMode.jellyfin;
  bool _busy = false;
  String? _error;

  /// The last Test's result, shown in the dialog (a toast sits behind it on
  /// phones).
  ConnectionCheck? _tested;

  @override
  void initState() {
    super.initState();
    // Pre-fill the Seerr found next to the Jellyfin server, if any.
    ref.read(seerrAddressSuggestionProvider.future).then((uri) {
      if (mounted && uri != null && _address.text.isEmpty) _address.text = uri.toString();
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final Uri address;
    try {
      address = serverAddressCandidates(_address.text).first;
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _tested = null;
    });
    final key = _secret.text.trim();
    final result = await ConnectionChecks.of(ProviderScope.containerOf(context, listen: false))
        .seerr(address, apiKey: _mode == _SignInMode.apiKey && key.isNotEmpty ? key : null);
    if (mounted) {
      setState(() {
        _busy = false;
        _tested = result;
      });
    }
  }

  Future<void> _signIn() async {
    final Uri address;
    try {
      address = serverAddressCandidates(_address.text).first;
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = ref.read(seerrAccountProvider.notifier);
      switch (_mode) {
        case _SignInMode.jellyfin:
          await controller.signIn(address, _username.text.trim(), _secret.text);
        case _SignInMode.seerr:
          await controller.signInWithEmail(address, _username.text.trim(), _secret.text);
        case _SignInMode.apiKey:
          await controller.signInWithApiKey(address, _secret.text.trim());
      }
      // Signed in: a password manager may offer to save it (not API keys).
      TextInput.finishAutofillContext(shouldSave: _mode != _SignInMode.apiKey);
      if (mounted) Navigator.pop(context);
    } on SeerrException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sign in to Seerr'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        // Marked for password managers (Android autofill); only a
        // successful sign-in is offered for saving (see _signIn).
        child: AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _address,
                enabled: !_busy,
                autocorrect: false,
                keyboardType: TextInputType.url,
                autofillHints: const [AutofillHints.url],
                decoration: const InputDecoration(
                  labelText: 'Seerr address',
                  hintText: 'seerr.home.arpa',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text('Sign in with', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              // Short labels: longer ones wrapped a letter a line on phones.
              SegmentedButton<_SignInMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _SignInMode.jellyfin, label: Text('Jellyfin')),
                  ButtonSegment(value: _SignInMode.seerr, label: Text('Seerr')),
                  ButtonSegment(value: _SignInMode.apiKey, label: Text('API key')),
                ],
                selected: {_mode},
                onSelectionChanged: _busy
                    ? null
                    : (m) => setState(() {
                        // The Jellyfin name pre-fill doesn't fit an email.
                        if (m.single == _SignInMode.seerr && _mode == _SignInMode.jellyfin) _username.clear();
                        _mode = m.single;
                      }),
              ),
              const SizedBox(height: 12),
              if (_mode != _SignInMode.apiKey) ...[
                TextField(
                  controller: _username,
                  enabled: !_busy,
                  autocorrect: false,
                  keyboardType: _mode == _SignInMode.seerr ? TextInputType.emailAddress : null,
                  autofillHints: [_mode == _SignInMode.seerr ? AutofillHints.email : AutofillHints.username],
                  decoration: InputDecoration(
                    labelText: _mode == _SignInMode.seerr ? 'Email' : 'Jellyfin username',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _secret,
                enabled: !_busy,
                obscureText: true,
                autofillHints: _mode == _SignInMode.apiKey ? null : const [AutofillHints.password],
                onSubmitted: (_) => _signIn(),
                decoration: InputDecoration(
                  labelText: switch (_mode) {
                    _SignInMode.jellyfin => 'Jellyfin password',
                    _SignInMode.seerr => 'Seerr password',
                    _SignInMode.apiKey => 'API key',
                  },
                  helperText: _mode == _SignInMode.apiKey
                      ? 'Seerr > Settings > General; acts as the key\'s owner'
                      : null,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (_tested case final t?) ConnectionCheckNote(t),
            ],
          ),
        ),
      ),
      actions: [
        // The address (and an API key) without signing in.
        TextButton.icon(
          icon: const Icon(Icons.network_check, size: 18),
          label: const Text('Test'),
          onPressed: _busy ? null : _test,
        ),
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _signIn, child: Text(_busy ? 'Signing in…' : 'Sign in')),
      ],
    );
  }
}
