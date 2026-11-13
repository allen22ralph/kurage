import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/layout.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/jellyfin/models.dart';
import 'widgets/auth_layout.dart';
import 'widgets/saved_accounts.dart';

/// Second sign-in step: username/password, or switch to Quick Connect.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  late final JellyfinApi _api;
  late final Future<List<JellyfinUser>> _publicUsers;
  late final Future<bool> _quickConnectEnabled;
  bool _busy = false;
  String? _error;

  PendingServer get _server => ref.read(loginFlowProvider).server!;

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiFactoryProvider)(_server.baseUrl);
    _publicUsers = _api.getPublicUsers().catchError((_) => <JellyfinUser>[]);
    _quickConnectEnabled =
        _api.isQuickConnectEnabled().catchError((_) => false);
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _pickUser(JellyfinUser user) {
    _username.text = user.name;
    _passwordFocus.requestFocus();
  }

  Future<void> _signIn() async {
    if (_busy || _username.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth =
          await _api.authenticateByName(_username.text.trim(), _password.text);
      // Signed in: a password manager (Bitwarden…) may offer to save it.
      TextInput.finishAutofillContext();
      await ref.read(sessionControllerProvider.notifier).signIn(
            baseUrl: _server.baseUrl,
            server: _server.info,
            auth: auth,
          );
      // The router redirects to home once the session is set.
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(loginFlowProvider).server;
    // Flow was reset (e.g. sign-in finished); the router is navigating away.
    if (server == null) return const Scaffold();

    return AuthLayout(
      title: 'Sign in',
      subtitle: '${server.info.serverName} · ${server.baseUrl.host}',
      children: [
        SavedAccounts(serverId: server.info.id),
        FutureBuilder(
          future: _publicUsers,
          builder: (context, snapshot) {
            final users = snapshot.data ?? const [];
            if (users.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final user in users)
                    _PublicUserChip(
                      user: user,
                      imageUrl: user.primaryImageTag == null
                          ? null
                          : _api
                              .userImageUrl(user.id, tag: user.primaryImageTag)
                              .toString(),
                      onPressed: () => _pickUser(user),
                    ),
                ],
              ),
            );
          },
        ),
        // Marked for password managers (Android autofill: Bitwarden and
        // others fill these and offer to save them). Only a successful
        // sign-in is offered for saving (see _signIn).
        AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
            children: [
              TextField(
                controller: _username,
                autofillHints: const [AutofillHints.username],
                // On a TV, typing is slow and opens the on-screen keyboard over
                // the form; start on Quick Connect instead (below).
                autofocus: !ref.read(isTvProvider),
                enabled: !_busy,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                focusNode: _passwordFocus,
                enabled: !_busy,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _signIn(),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _signIn,
          child: _busy ? const ButtonSpinner() : const Text('Sign in'),
        ),
        FutureBuilder(
          future: _quickConnectEnabled,
          builder: (context, snapshot) {
            if (snapshot.data != true) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                autofocus: ref.read(isTvProvider),
                onPressed:
                    _busy ? null : () => context.push('/connect/quick-connect'),
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Use Quick Connect'),
              ),
            );
          },
        ),
        if (_error != null) AuthError(_error!),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _busy ? null : () => context.go('/connect'),
          child: const Text('Use a different server'),
        ),
      ],
    );
  }
}

class _PublicUserChip extends StatelessWidget {
  const _PublicUserChip({
    required this.user,
    required this.imageUrl,
    required this.onPressed,
  });

  final JellyfinUser user;
  final String? imageUrl;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      onPressed: onPressed,
      avatar: CircleAvatar(
        backgroundImage:
            imageUrl == null ? null : CachedNetworkImageProvider(imageUrl!),
        child: imageUrl == null ? Text(_initial(user.name)) : null,
      ),
      label: Text(user.name),
    );
  }

  static String _initial(String name) =>
      name.isEmpty ? '?' : name.characters.first.toUpperCase();
}
