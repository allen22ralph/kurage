import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jellyfin/client_info.dart';
import '../core/jellyfin/jellyfin_api.dart';
import '../core/jellyfin/models.dart';
import '../core/jellyfin/server_addresses.dart';
import '../core/jellyfin/server_discovery.dart';
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

/// Fires when the device's network changes (Wi-Fi, mobile data, a VPN).
/// Overridden in tests, which have no network plugin.
final networkChangesProvider = Provider<Stream<void>>(
  (ref) => Connectivity().onConnectivityChanged.skip(1),
);

/// Finds Jellyfin servers on the local network (the connect screen's list).
/// Overridden in tests, which mustn't search a real network.
final serverDiscoveryProvider = Provider<Stream<DiscoveredServer> Function()>((ref) => discoverServers);

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
  Future<StoredSession?> build() async {
    final session = await _store.loadActive();
    if (session == null || session.addresses.length < 2) return session;
    // A server with more than one address: the one that answers now (at
    // home or away), before anything asks it for anything.
    final picked = await _pick(session);
    if (picked == null || picked == session.baseUrl) return session;
    _logSwitch(session, picked);
    await _store.setAddresses(session.serverId, session.addresses, inUse: picked);
    return session.copyWith(baseUrl: picked);
  }

  Future<Uri?> _pick(StoredSession session, {Duration timeout = const Duration(seconds: 4)}) {
    final factory = ref.read(apiFactoryProvider);
    return pickAddress(
      session.addresses,
      session.serverId,
      (address) async => (await factory(address).getPublicSystemInfo()).id,
      timeout: timeout,
    );
  }

  void _logSwitch(StoredSession session, Uri to) => AppLog.info(
        LogArea.network,
        'Using ${to.host} for ${session.serverName} (${isHomeAddress(to) ? 'home network' : 'away'})',
      );

  /// For a server with more than one address: switches to the best one that
  /// answers now (home first), if it isn't the one in use. True when the
  /// address in use answers or another was switched to; false when none
  /// does, or the server has only the one address.
  Future<bool> useAnsweringAddress() async {
    final session = state.value;
    if (session == null || session.addresses.length < 2) return false;
    final picked = await _pick(session);
    final now = state.value;
    if (picked == null || now?.key != session.key) return false;
    if (picked == now!.baseUrl) return true;
    _logSwitch(now, picked);
    await _store.setAddresses(now.serverId, now.addresses, inUse: picked);
    ref.invalidate(storedSessionsProvider);
    ref.invalidate(knownServersProvider);
    state = AsyncData(now.copyWith(baseUrl: picked));
    return true;
  }

  /// Settings: the signed-in server's addresses, after adding or removing
  /// one. The one in use stays unless it was removed.
  Future<void> setAddresses(List<Uri> addresses) async {
    final session = state.value;
    if (session == null || addresses.isEmpty) return;
    final inUse = addresses.contains(session.baseUrl) ? session.baseUrl : rankAddresses(addresses).first;
    await _store.setAddresses(session.serverId, addresses, inUse: inUse);
    ref.invalidate(storedSessionsProvider);
    ref.invalidate(knownServersProvider);
    state = AsyncData(session.copyWith(addresses: addresses, baseUrl: inUse));
    if (addresses.length > 1) unawaited(useAnsweringAddress());
  }

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
    final saved = await _store.save(session);
    ref.invalidate(storedSessionsProvider);
    ref.invalidate(knownServersProvider);
    ref.read(loginFlowProvider.notifier).reset();
    state = AsyncData(saved);
  }

  /// Makes another stored account the active one.
  Future<void> switchTo(StoredSession session) async {
    final saved = await _store.save(session);
    ref.invalidate(knownServersProvider);
    ref.read(loginFlowProvider.notifier).reset();
    state = AsyncData(saved);
    if (saved.addresses.length > 1) unawaited(useAnsweringAddress());
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
        addresses: session.addresses,
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
          addresses: session.addresses,
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
