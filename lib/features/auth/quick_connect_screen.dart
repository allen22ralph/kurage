import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import 'widgets/auth_layout.dart';

/// How often to ask the server whether the code was approved.
final quickConnectPollIntervalProvider =
    Provider<Duration>((ref) => const Duration(seconds: 3));

/// Shows a Quick Connect code and waits for the user to approve it from
/// another signed-in device. The main way to sign in on a TV.
class QuickConnectScreen extends ConsumerStatefulWidget {
  const QuickConnectScreen({super.key});

  @override
  ConsumerState<QuickConnectScreen> createState() => _QuickConnectScreenState();
}

class _QuickConnectScreenState extends ConsumerState<QuickConnectScreen> {
  late final JellyfinApi _api;
  late final PendingServer _server;
  Timer? _poll;
  String? _secret;
  String? _code;
  String? _error;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _server = ref.read(loginFlowProvider).server!;
    _api = ref.read(apiFactoryProvider)(_server.baseUrl);
    _start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _poll?.cancel();
    setState(() {
      _code = null;
      _error = null;
    });
    try {
      final state = await _api.initiateQuickConnect();
      if (!mounted) return;
      setState(() {
        _secret = state.secret;
        _code = state.code;
      });
      _poll = Timer.periodic(
        ref.read(quickConnectPollIntervalProvider),
        (_) => _check(),
      );
    } on JellyfinException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _check() async {
    final secret = _secret;
    if (secret == null || _finishing) return;
    try {
      final state = await _api.getQuickConnectState(secret);
      if (!state.authenticated || !mounted) return;
      _finishing = true;
      _poll?.cancel();
      final auth = await _api.authenticateWithQuickConnect(secret);
      await ref.read(sessionControllerProvider.notifier).signIn(
            baseUrl: _server.baseUrl,
            server: _server.info,
            auth: auth,
          );
    } on JellyfinException catch (e) {
      _poll?.cancel();
      // Codes expire after a few minutes; the server then forgets the secret.
      if (mounted) {
        setState(() {
          _finishing = false;
          _error = e.statusCode == 404
              ? 'This code has expired. Get a new one.'
              : e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AuthLayout(
      title: 'Quick Connect',
      subtitle: 'On a device that is already signed in, open '
          'Settings → Quick Connect and enter this code.',
      children: [
        if (_code != null)
          SelectableText(
            _code!,
            textAlign: TextAlign.center,
            style: theme.textTheme.displayMedium?.copyWith(
              letterSpacing: 8,
              fontWeight: FontWeight.w600,
            ),
          )
        else if (_error == null)
          const Center(child: CircularProgressIndicator()),
        if (_code != null && _error == null) ...[
          const SizedBox(height: 24),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ButtonSpinner(),
              SizedBox(width: 12),
              Text('Waiting for approval…'),
            ],
          ),
        ],
        if (_error != null) ...[
          AuthError(_error!),
          const SizedBox(height: 16),
          FilledButton(
            autofocus: true,
            onPressed: _start,
            child: const Text('Get a new code'),
          ),
        ],
      ],
    );
  }
}
