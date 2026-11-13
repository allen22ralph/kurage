import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/app/toast.dart';
import 'package:jellyfin_client/core/net/trusted_certificates.dart';
import 'package:jellyfin_client/features/home/home_screen.dart';
import 'package:jellyfin_client/features/auth/quick_connect_screen.dart';

import '../../support/fake_server.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => HttpOverrides.global = null);

  final caPem = File('test/fixtures/test-root-ca.pem').readAsStringSync();
  final fetched = <Uri>[];

  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    FakeServer server, {
    bool tv = false,
  }) async {
    // Signing in lands on Home: an empty one (no libraries yet).
    server.routes.putIfAbsent('/UserViews', () => (200, pageJson([])));
    server.routes.putIfAbsent('/UserItems/Resume', () => (200, pageJson([])));
    server.routes.putIfAbsent('/Shows/NextUp', () => (200, pageJson([])));
    final container = ProviderContainer(
      overrides: [
        ...fakeServerOverrides(server),
        isTvProvider.overrideWithValue(tv),
        quickConnectPollIntervalProvider
            .overrideWithValue(const Duration(milliseconds: 10)),
        certificateFetcherProvider.overrideWithValue((url) async {
          fetched.add(url);
          return caPem;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const JellyfinClientApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> connectTo(WidgetTester tester, String address) async {
    await tester.enterText(find.byType(TextField), address);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
  }

  testWidgets('connect, sign in with password, land on home', (tester) async {
    final server = FakeServer({
      'https://jellyfin.home.arpa/System/Info/Public': (200, testServerInfo),
      '/Users/Public': (200, <Object>[]),
      '/QuickConnect/Enabled': (200, true),
      '/Users/AuthenticateByName': (200, authResponse()),
    });
    final container = await pumpApp(tester, server);

    expect(find.text('Connect to server'), findsOneWidget);
    await connectTo(tester, 'jellyfin.home.arpa');

    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('sam · jellyfin.home.arpa'), findsOneWidget);
    expect(find.text('Use Quick Connect'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'sam');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    final session = container.read(sessionControllerProvider).value!;
    expect(session.baseUrl.toString(), 'https://jellyfin.home.arpa');
    expect(session.accessToken, 'tok');

    final login = server.requestsTo('/Users/AuthenticateByName').single;
    expect(login.data, {'Username': 'sam', 'Pw': 'pw'});
  });

  testWidgets('falls back to http when https is unreachable', (tester) async {
    final server = FakeServer({
      'https://media.lan/System/Info/Public': unreachable,
      'http://media.lan/System/Info/Public': (200, testServerInfo),
    });
    await pumpApp(tester, server);

    await connectTo(tester, 'media.lan');
    expect(find.text('sam · media.lan'), findsOneWidget);
  });

  testWidgets('shows an error for a wrong password', (tester) async {
    final server = FakeServer({
      '/System/Info/Public': (200, testServerInfo),
      '/Users/AuthenticateByName': (401, null),
    });
    await pumpApp(tester, server);
    await connectTo(tester, 'https://jellyfin.home.arpa');

    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'sam');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Wrong username or password'), findsOneWidget);
  });

  testWidgets('shows an error when no server answers', (tester) async {
    await pumpApp(tester, FakeServer({}));
    await connectTo(tester, 'https://nothing.here');
    expect(find.textContaining('Not found'), findsOneWidget);
  });

  testWidgets('quick connect signs in once approved', (tester) async {
    var polls = 0;
    final server = FakeServer({
      '/System/Info/Public': (200, testServerInfo),
      '/QuickConnect/Enabled': (200, true),
      '/QuickConnect/Initiate': (
        200,
        {'Secret': 'sec', 'Code': '424242', 'Authenticated': false},
      ),
      '/QuickConnect/Connect': (_) => (
            200,
            {'Secret': 'sec', 'Code': '424242', 'Authenticated': ++polls >= 2},
          ),
      '/Users/AuthenticateWithQuickConnect': (200, authResponse(token: 'qc')),
    });
    final container = await pumpApp(tester, server);
    await connectTo(tester, 'https://jellyfin.home.arpa');

    await tester.tap(find.text('Use Quick Connect'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(find.text('424242'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 15));
    await tester.pump(const Duration(milliseconds: 15));
    await tester.pumpAndSettle();

    expect(container.read(sessionControllerProvider).value?.accessToken, 'qc');
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('sign out stays on the server and offers its other accounts',
      (tester) async {
    final server = FakeServer({
      '/System/Info/Public': (200, testServerInfo),
      '/Users/AuthenticateByName': (options) {
        final user = (options.data as Map)['Username'] as String;
        return (200, authResponse(user: user, token: 't-$user'));
      },
      '/Sessions/Logout': (204, null),
    });
    final container = await pumpApp(tester, server);

    Future<void> signInAs(String user) async {
      await tester.enterText(find.widgetWithText(TextField, 'Username'), user);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
    }

    await connectTo(tester, 'https://jellyfin.home.arpa');
    await signInAs('sam');
    await tester.tap(find.byTooltip(RegExp('Accounts')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();

    // The server is remembered: no need to type its address.
    expect(find.text('Servers'), findsOneWidget);
    await tester.tap(find.text('jellyfin.home.arpa'));
    await tester.pumpAndSettle();
    await signInAs('guest');
    expect(container.read(sessionControllerProvider).value?.userName, 'guest');

    // Sign out goes to this server's login, listing the other account.
    await tester.tap(find.byTooltip(RegExp('Accounts')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    // Login form for the same server, plus the remaining saved account.
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(find.text('Saved accounts'), findsOneWidget);
    expect(find.text('sam · jellyfin.home.arpa'), findsNWidgets(2));
    expect(server.requestsTo('/Sessions/Logout'), hasLength(1));
    final saved = await container.read(sessionStoreProvider).loadAll();
    expect(saved.map((s) => s.userName), ['sam']);

    // One tap switches to the saved account, no password needed.
    await tester.tap(find.text('sam').first);
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(container.read(sessionControllerProvider).value?.accessToken, 't-sam');
  });

  testWidgets("signing out doesn't wait for a server out of reach", (tester) async {
    final server = _SlowLogout({
      '/System/Info/Public': (200, testServerInfo),
      '/Users/AuthenticateByName': (200, authResponse()),
    });
    await pumpApp(tester, server);
    await connectTo(tester, 'https://jellyfin.home.arpa');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'sam');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(RegExp('Accounts')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    // Signed out, with the server still not answering.
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(server.requestsTo('/Sessions/Logout'), hasLength(1));
    expect(shownToasts, isEmpty);

    // It never does: the device is still listed there, and it says so.
    server.fail();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(shownToasts.single, contains("couldn't be reached"));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a different server can still be entered after sign out',
      (tester) async {
    final server = FakeServer({
      '/System/Info/Public': (200, testServerInfo),
      '/Users/AuthenticateByName': (200, authResponse()),
      '/Sessions/Logout': (204, null),
    });
    await pumpApp(tester, server);
    await connectTo(tester, 'https://jellyfin.home.arpa');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'sam');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(RegExp('Accounts')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use a different server'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to server'), findsOneWidget);
    expect(find.text('jellyfin.home.arpa'), findsOneWidget);

    await tester.tap(find.byTooltip('Forget server'));
    await tester.pumpAndSettle();
    expect(find.text('Servers'), findsNothing);
  });

  testWidgets("a private CA can be trusted from the connect screen", (tester) async {
    var trusted = false;
    final server = FakeServer({
      'https://jellyfin.home.arpa/System/Info/Public': (_) =>
          trusted ? (200, testServerInfo) : untrustedCertificate,
      // Plain HTTP redirects to HTTPS on this server, so it fails the same way.
      'http://jellyfin.home.arpa/System/Info/Public': untrustedCertificate,
    });
    final container = await pumpApp(tester, server);

    await connectTo(tester, 'jellyfin.home.arpa');
    expect(find.textContaining("certificate isn't trusted"), findsOneWidget);

    await tester.tap(find.textContaining("Trust this server's certificate authority"));
    await tester.pumpAndSettle();
    expect(find.text('https://jellyfin.home.arpa/caddy-root.crt'), findsOneWidget);

    await tester.tap(find.text('Load certificate'));
    await tester.pumpAndSettle();
    expect(fetched.single.toString(), 'https://jellyfin.home.arpa/caddy-root.crt');
    expect(find.text('Test Local Authority - ECC Root'), findsOneWidget);
    expect(find.textContaining('24:F7:87:8D'), findsOneWidget);

    trusted = true; // what trusting the CA does to the real connection
    await tester.tap(find.widgetWithText(FilledButton, 'Trust'));
    await tester.pumpAndSettle();

    expect(find.text('sam · jellyfin.home.arpa'), findsOneWidget, reason: 'on to login');
    final saved = container.read(trustedCertificatesProvider).value!;
    expect(saved.single.name, 'Test Local Authority - ECC Root');
  });

  bool focused(WidgetTester tester, Finder field) =>
      tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)))
          .focusNode
          .hasFocus;

  testWidgets('Down leaves a text field (a TV remote has no Tab key)', (tester) async {
    await pumpApp(tester, FakeServer({
      '/System/Info/Public': (200, testServerInfo),
      '/QuickConnect/Enabled': (200, true),
    }));
    await connectTo(tester, 'https://jellyfin.home.arpa');
    final username = find.widgetWithText(TextField, 'Username');
    final password = find.widgetWithText(TextField, 'Password');
    expect(focused(tester, username), isTrue, reason: 'desktop starts typing');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(tester, password), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused(tester, username), isTrue);
  });

  testWidgets('on a TV, login starts on Quick Connect, not the keyboard', (tester) async {
    await pumpApp(
      tester,
      FakeServer({
        '/System/Info/Public': (200, testServerInfo),
        '/QuickConnect/Enabled': (200, true),
      }),
      tv: true,
    );
    await connectTo(tester, 'https://jellyfin.home.arpa');
    expect(focused(tester, find.widgetWithText(TextField, 'Username')), isFalse);
    final quickConnect = tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text('Use Quick Connect'), matching: find.bySubtype<ButtonStyleButton>()).first,
    );
    expect(quickConnect.autofocus, isTrue);
    expect(Focus.of(tester.element(find.text('Use Quick Connect'))).hasFocus, isTrue);
  });
}

/// A server that doesn't answer signing out until told to give up.
class _SlowLogout extends FakeServer {
  _SlowLogout(super.routes);

  final _gate = Completer<void>();

  void fail() => _gate.complete();

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.uri.path != '/Sessions/Logout') return super.fetch(options, requestStream, cancelFuture);
    requests.add(options);
    await _gate.future;
    throw DioException.connectionError(requestOptions: options, reason: 'unreachable');
  }
}
