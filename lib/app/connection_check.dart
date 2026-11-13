import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jellyfin/jellyfin_api.dart';
import '../core/log/app_log.dart';
import '../core/net/reach_error.dart';
import '../core/seerr/seerr_api.dart';
import 'providers.dart';
import 'toast.dart';

/// What a connection test found: [ok], and what to tell the user.
class ConnectionCheck {
  const ConnectionCheck(this.ok, this.message, {bool? reached}) : reached = reached ?? ok;

  final bool ok;
  final String message;

  /// The server answered, even if it said no (e.g. a sign-in it refuses).
  final bool reached;
}

/// "Test connection" buttons: checks a server (and, given one, an account or
/// key) without signing in or saving anything, and says how it went in a
/// toast. Each check also goes in the app log.
class ConnectionChecks {
  ConnectionChecks(this._container);

  /// From a widget: `ConnectionChecks.of(ref.container)`.
  factory ConnectionChecks.of(ProviderContainer container) => ConnectionChecks(container);

  final ProviderContainer _container;

  static String _ms(Stopwatch w) => '${w.elapsedMilliseconds} ms';

  /// Shows [check]'s result in a toast and logs it under [area].
  static ConnectionCheck report(LogArea area, ConnectionCheck check) {
    AppLog.add(area, check.ok ? LogLevel.info : LogLevel.warning, 'Connection test: ${check.message}');
    showToast(check.message, id: 'connection-check');
    return check;
  }

  /// A Jellyfin server at the first of [candidates] that answers; with a
  /// [token], also that the account is still signed in.
  Future<ConnectionCheck> jellyfin(List<Uri> candidates, {String? token}) async {
    final factory = _container.read(apiFactoryProvider);
    final watch = Stopwatch()..start();
    String? lastError;
    for (final url in candidates) {
      final api = factory(url, token: token);
      try {
        final info = await api.getPublicSystemInfo();
        if (token == null) {
          return report(
            LogArea.network,
            ConnectionCheck(true, 'Connected: ${info.serverName}, Jellyfin ${info.version} (${_ms(watch)})'),
          );
        }
        final user = await api.getCurrentUser();
        return report(
          LogArea.network,
          ConnectionCheck(
            true,
            'Connected to ${info.serverName} (Jellyfin ${info.version}) as ${user.name} (${_ms(watch)})',
          ),
        );
      } on JellyfinException catch (e) {
        lastError = e.statusCode == 401 ? 'The server is up, but this sign-in has expired: sign in again.' : e.message;
        if (e.statusCode == 401) break;
      }
    }
    return report(LogArea.network, ConnectionCheck(false, lastError ?? "Couldn't reach the server."));
  }

  /// A Seerr server at [address]; with an [apiKey] or session [cookie], also
  /// that it lets that account in.
  Future<ConnectionCheck> seerr(Uri address, {String? apiKey, String? cookie}) async {
    final watch = Stopwatch()..start();
    final api = SeerrApi(baseUrl: address, dio: _container.read(dioFactoryProvider)(), apiKey: apiKey, cookie: cookie);
    final String version;
    try {
      version = await api.version();
    } on SeerrException catch (e) {
      return report(
        LogArea.seerr,
        ConnectionCheck(false, e.message, reached: e.statusCode != null),
      );
    }
    if (apiKey == null && cookie == null) {
      return report(LogArea.seerr, ConnectionCheck(true, 'Seerr $version is reachable (${_ms(watch)})'));
    }
    try {
      final me = await api.me();
      return report(
        LogArea.seerr,
        ConnectionCheck(true, 'Seerr $version: connected as ${me.displayName} (${_ms(watch)})'),
      );
    } on SeerrException catch (e) {
      final rejected = e.statusCode == 401 || e.statusCode == 403;
      return report(
        LogArea.seerr,
        ConnectionCheck(
          false,
          rejected
              ? (apiKey != null
                    ? 'Seerr is up, but it rejected this API key.'
                    : 'Seerr is up, but this sign-in has expired: sign in again.')
              : e.message,
          // It answered /status just now.
          reached: true,
        ),
      );
    }
  }

  /// Whether the linked MyAnimeList account still lets the app in.
  Future<ConnectionCheck> malAccount(Future<String> Function() username) async {
    final watch = Stopwatch()..start();
    try {
      final name = await username();
      return report(LogArea.anime, ConnectionCheck(true, 'MyAnimeList: connected as $name (${_ms(watch)})'));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      return report(
        LogArea.anime,
        ConnectionCheck(false, switch (status) {
          401 || 403 => 'MyAnimeList no longer accepts this link: link the account again.',
          null => "Couldn't reach MyAnimeList: ${unreachableReason(e) ?? 'check your network.'}",
          _ => 'MyAnimeList answered $status.',
        }),
      );
    } on Object catch (e) {
      return report(LogArea.anime, ConnectionCheck(false, 'MyAnimeList: $e'));
    }
  }

  /// Whether MyAnimeList accepts [clientId] (a search, which needs only it).
  Future<ConnectionCheck> malClientId(String clientId) async {
    final id = clientId.trim();
    if (id.isEmpty) return report(LogArea.anime, const ConnectionCheck(false, 'Enter a client ID first.'));
    final dio = _container.read(dioFactoryProvider)();
    try {
      await dio.get<Object?>(
        'https://api.myanimelist.net/v2/anime',
        queryParameters: {'q': 'frieren', 'limit': 1},
        options: Options(headers: {'X-MAL-CLIENT-ID': id}),
      );
      return report(LogArea.anime, const ConnectionCheck(true, 'MyAnimeList accepts this client ID.'));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      return report(
        LogArea.anime,
        ConnectionCheck(false, switch (status) {
          400 || 401 || 403 => "MyAnimeList doesn't accept this client ID.",
          null => "Couldn't reach MyAnimeList: ${unreachableReason(e) ?? 'check your network.'}",
          _ => 'MyAnimeList answered $status.',
        }),
      );
    }
  }
}

/// A test's result inside a dialog: green tick or red cross, and the message.
class ConnectionCheckNote extends StatelessWidget {
  const ConnectionCheckNote(this.check, {super.key});

  final ConnectionCheck check;

  @override
  Widget build(BuildContext context) {
    final color = check.ok ? Colors.green : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(check.ok ? Icons.check_circle_outline : Icons.error_outline, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(check.message, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

/// "Check connection" on an account's row: runs [check] (which says how it
/// went in a toast), with a spinner meanwhile and no second press.
class CheckConnectionButton extends StatefulWidget {
  const CheckConnectionButton({super.key, required this.check});

  final Future<Object?> Function() check;

  @override
  State<CheckConnectionButton> createState() => _CheckConnectionButtonState();
}

class _CheckConnectionButtonState extends State<CheckConnectionButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.check();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _busy
        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.network_check, size: 18);
    // Phones: the icon only, or the row's own text is squeezed into a
    // column a few letters wide.
    if (MediaQuery.sizeOf(context).width < 600) {
      return IconButton(tooltip: 'Check connection', onPressed: _busy ? null : _run, icon: icon);
    }
    return TextButton.icon(onPressed: _busy ? null : _run, icon: icon, label: const Text('Check connection'));
  }
}
