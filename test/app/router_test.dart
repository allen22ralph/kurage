import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/app/router.dart';
import 'package:jellyfin_client/core/jellyfin/models.dart';
import 'package:jellyfin_client/core/storage/session_store.dart';

void main() {
  const signedOut = AsyncData<Object?>(null);
  const signedIn = AsyncData<Object?>('session');
  final server = PendingServer(
    baseUrl: Uri.parse('https://jellyfin.home.arpa'),
    info: const PublicSystemInfo(id: 's', serverName: 'sam', version: ''),
  );

  String? redirect(
    AsyncValue<Object?> session,
    String location, {
    LoginFlowState flow = const LoginFlowState(),
  }) =>
      authRedirect(session: session, loginFlow: flow, location: location);

  test('shows splash while sessions load', () {
    expect(redirect(const AsyncLoading(), '/'), '/splash');
    expect(redirect(const AsyncLoading(), '/splash'), isNull);
  });

  test('storage errors fall back to signed out', () {
    expect(
      redirect(AsyncError<Object?>('boom', StackTrace.empty), '/splash'),
      '/connect',
    );
  });

  test('signed out users go to connect', () {
    expect(redirect(signedOut, '/'), '/connect');
    expect(redirect(signedOut, '/splash'), '/connect');
    expect(redirect(signedOut, '/connect'), isNull);
  });

  test('login steps need a picked server', () {
    expect(redirect(signedOut, '/connect/login'), '/connect');
    expect(
      redirect(
        signedOut,
        '/connect/login',
        flow: LoginFlowState(server: server),
      ),
      isNull,
    );
  });

  test('after sign out, users return to the same server login', () {
    final flow = LoginFlowState(server: server);
    expect(redirect(signedOut, '/', flow: flow), '/connect/login');
    expect(redirect(signedOut, '/connect', flow: flow), isNull);
  });

  test('signed in users leave the sign-in screens', () {
    expect(redirect(signedIn, '/connect'), '/');
    expect(redirect(signedIn, '/splash'), '/');
    expect(redirect(signedIn, '/accounts'), isNull);
  });

  test('a server out of reach keeps signed in users on the connect screen', () {
    final down = LoginFlowState(
      addingAccount: true,
      unreachable: StoredSession(
        serverId: 's',
        serverName: 'sam',
        baseUrl: Uri.parse('https://jellyfin.home.arpa'),
        userId: 'u',
        userName: 'me',
        accessToken: 't',
      ),
    );
    expect(redirect(signedIn, '/connect', flow: down), isNull);
    expect(redirect(signedIn, '/downloads', flow: down), isNull);
    // Once it answers, the flow is reset and Home is back.
    expect(redirect(signedIn, '/connect'), '/');
  });

  test('adding an account keeps signed in users on sign-in screens', () {
    const adding = LoginFlowState(addingAccount: true);
    expect(redirect(signedIn, '/connect', flow: adding), isNull);
    expect(redirect(signedIn, '/connect/login', flow: adding), '/connect');
    expect(redirect(signedIn, '/', flow: adding), isNull);
  });
}
