import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jellyfin/client_info.dart';
import '../core/jellyfin/jellyfin_api.dart';
import '../core/jellyfin/models.dart';
import '../core/log/app_log.dart';
import '../core/storage/session_store.dart';
import 'toast.dart';

/// This install's identity. Overridden in `main()` once loaded from disk.
final clientInfoProvider = Provider<ClientInfo>(
  (ref) => throw UnimplementedError('clientInfoProvider must be overridden'),
);

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

/// Creates the Dio instance for API clients. Overridden in tests.
final dioFactoryProvider = Provider<Dio Function()>((ref) => Dio.new);

/// Builds an API client for any server, signed in or not.
final apiFactoryProvider = Provider<ApiFactory>((ref) {
  final clientInfo = ref.watch(clientInfoProvider);
  final dioFactory = ref.watch(dioFactoryProvider);
  return (baseUrl, {token, onUnauthorized}) => JellyfinApi(
        baseUrl: baseUrl,
        clientInfo: clientInfo,
        accessToken: token,
        onUnauthorized: onUnauthorized,
        dio: dioFactory(),
      );
});

typedef ApiFactory = JellyfinApi Function(
  Uri baseUrl, {
  String? token,
  void Function()? onUnauthorized,
});

/// The active signed-in session, or null when signed out.
final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, StoredSession?>(
  SessionController.new,
);

class SessionController extends AsyncNotifier<StoredSession?> {
  SessionStore get _store => ref.read(sessionStoreProvider);

  @override
  Future<StoredSession?> build() => _store.loadActive();

  Future<void> signIn({
    required Uri baseUrl,
    required PublicSystemInfo server,
    required AuthResult auth,
  }) async {
    final session = StoredSession(
      serverId: auth.serverId,
      serverName: server.serverName,
      baseUrl: baseUrl,
      userId: auth.user.id,
      userName: auth.user.name,
      accessToken: auth.accessToken,
    );
    await _store.save(session);
    ref.invalidate(storedSessionsProvider);
    ref.invalidate(knownServersProvider);
    ref.read(loginFlowProvider.notifier).reset();
    state = AsyncData(session);
  }

  /// Makes another stored account the active one.
  Future<void> switchTo(StoredSession session) async {
    await _store.save(session);
    ref.invalidate(knownServersProvider);
    ref.read(loginFlowProvider.notifier).reset();
    state = AsyncData(session);
  }

  /// Forgets the active account here at once, and tells the server without
  /// waiting for it: a server out of reach (on a VPN, say) never holds up
  /// signing out.
  Future<void> signOut() async {
    final session = state.value;
    if (session == null) return;
    // Built directly: apiProvider depends on this notifier.
    final api = ref.read(apiFactoryProvider)(session.baseUrl, token: session.accessToken);
    unawaited(
      api
          .logout()
          .then((reached) {
            if (reached) return;
            AppLog.warning(LogArea.network, "Signed out here; couldn't reach the server to end the session");
            showToast(
              "Signed out here. ${session.serverName} couldn't be reached, so it still lists this device until you remove it there.",
            );
          })
          .catchError((Object e) {
            AppLog.warning(LogArea.network, 'Signing out on the server failed', error: e);
          }),
    );
    await _forget(session);
  }

  /// The server rejected our token: drop the session without calling it.
  Future<void> handleUnauthorized() async {
    final session = state.value;
    if (session != null) await _forget(session);
  }

  Future<void> removeAccount(StoredSession session) async {
    if (session.key == state.value?.key) {
      await signOut();
    } else {
      await _store.remove(session.key);
      ref.invalidate(storedSessionsProvider);
    }
  }

  /// Drops [session] but stays on its server: the router lands on that
  /// server's login screen instead of asking for the address again.
  Future<void> _forget(StoredSession session) async {
    await _store.remove(session.key);
    ref.invalidate(storedSessionsProvider);
    ref.read(loginFlowProvider.notifier).selectServer(PendingServer.of(session));
    state = const AsyncData(null);
  }
}

/// All accounts saved on this device, for the account switcher.
/// Refreshed by [SessionController] whenever the saved accounts change.
final storedSessionsProvider = FutureProvider<List<StoredSession>>(
  (ref) => ref.read(sessionStoreProvider).loadAll(),
);

/// Servers signed in to before, most recent first, for the sign-in screens.
/// Also includes servers of saved accounts from before servers were stored.
final knownServersProvider = FutureProvider<List<KnownServer>>((ref) async {
  final store = ref.read(sessionStoreProvider);
  final servers = await store.loadServers();
  for (final session in await store.loadAll()) {
    if (servers.every((s) => s.id != session.serverId)) {
      servers.add(KnownServer(
        id: session.serverId,
        name: session.serverName,
        baseUrl: session.baseUrl,
      ));
    }
  }
  return servers;
});

/// API client for the active session, or null when signed out.
final apiProvider = Provider<JellyfinApi?>((ref) {
  final session = ref.watch(sessionControllerProvider).value;
  if (session == null) return null;
  return ref.watch(apiFactoryProvider)(
    session.baseUrl,
    token: session.accessToken,
    onUnauthorized: () =>
        ref.read(sessionControllerProvider.notifier).handleUnauthorized(),
  );
});

/// API client for screens that only exist while signed in.
final signedInApiProvider = Provider<JellyfinApi>((ref) {
  final api = ref.watch(apiProvider);
  if (api == null) throw StateError('Not signed in');
  return api;
});

/// The signed-in user as the server knows them now (name, picture, admin);
/// null when signed out or the server can't be asked.
final currentUserProvider = FutureProvider<JellyfinUser?>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return null;
  try {
    return await api.getCurrentUser();
  } on Object {
    return null;
  }
});

/// A saved account's user (for its picture on the Accounts page), asked
/// with that account's own sign-in; null if it can't be.
final savedAccountUserProvider = FutureProvider.autoDispose.family<JellyfinUser?, String>((ref, key) async {
  final sessions = await ref.watch(storedSessionsProvider.future);
  final session = sessions.where((s) => s.key == key).firstOrNull;
  if (session == null) return null;
  try {
    return await ref.read(apiFactoryProvider)(session.baseUrl, token: session.accessToken).getCurrentUser();
  } on Object {
    return null;
  }
});

/// The active session, for screens that only exist while signed in.
final currentSessionProvider = Provider<StoredSession>((ref) {
  final session = ref.watch(sessionControllerProvider).value;
  if (session == null) throw StateError('Not signed in');
  return session;
});

/// Server chosen on the connect screen, waiting for the user to log in.
class PendingServer {
  const PendingServer({required this.baseUrl, required this.info});

  /// A server we already know, from a saved account.
  PendingServer.of(StoredSession session)
      : this.known(KnownServer(
          id: session.serverId,
          name: session.serverName,
          baseUrl: session.baseUrl,
        ));

  /// A remembered server, used without contacting it first.
  PendingServer.known(KnownServer server)
      : baseUrl = server.baseUrl,
        info = PublicSystemInfo(id: server.id, serverName: server.name, version: '');

  final Uri baseUrl;
  final PublicSystemInfo info;
}

class LoginFlowState {
  const LoginFlowState({this.server, this.addingAccount = false, this.unreachable});

  final PendingServer? server;

  /// True when signing in to another account while already signed in.
  final bool addingAccount;

  /// The signed-in account whose server didn't answer: the user was sent to
  /// pick a server, still signed in, and can try it again from there.
  final StoredSession? unreachable;
}

final loginFlowProvider =
    NotifierProvider<LoginFlowController, LoginFlowState>(
  LoginFlowController.new,
);

class LoginFlowController extends Notifier<LoginFlowState> {
  @override
  LoginFlowState build() => const LoginFlowState();

  void startAddingAccount() =>
      state = const LoginFlowState(addingAccount: true);

  /// [session]'s server can't be reached: off to the connect screen, still
  /// signed in, to try it again or pick another.
  void serverUnreachable(StoredSession session) =>
      state = LoginFlowState(addingAccount: true, unreachable: session);

  void selectServer(PendingServer server) => state = LoginFlowState(
        server: server,
        addingAccount: state.addingAccount,
        unreachable: state.unreachable,
      );

  void reset() => state = const LoginFlowState();
}
