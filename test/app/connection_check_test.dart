import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/connection_check.dart';
import 'package:jellyfin_client/app/notifications.dart';
import 'package:jellyfin_client/core/log/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  late FakeServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppLog.reset();
    NotificationHistory.reset();
    server = FakeServer({
      'https://jellyfin.home.arpa/System/Info/Public': (200, testServerInfo),
      'https://jellyfin.home.arpa/Users/Me': (200, {'Id': 'u1', 'Name': 'sam'}),
      'https://expired.home.arpa/System/Info/Public': (200, testServerInfo),
      'https://expired.home.arpa/Users/Me': (401, null),
      'https://down.home.arpa/System/Info/Public': unreachable,
      'https://seerr.home.arpa/api/v1/status': (200, {'version': '3.5.1'}),
      'https://seerr.home.arpa/api/v1/auth/me': (403, {'message': 'Forbidden'}),
      'https://api.myanimelist.net/v2/anime': (401, {'error': 'invalid_client'}),
    });
  });

  ProviderContainer container() {
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    return c;
  }

  test('Jellyfin: found, an expired sign-in, or unreachable; each in a toast and the log', () async {
    final checks = ConnectionChecks.of(container());
    final ok = await checks.jellyfin([Uri.parse('https://jellyfin.home.arpa')], token: 'tok');
    expect(ok.ok, isTrue);
    expect(ok.message, startsWith('Connected to sam (Jellyfin 10.11.11) as sam'));

    final expired = await checks.jellyfin([Uri.parse('https://expired.home.arpa')], token: 'tok');
    expect((expired.ok, expired.message), (false, 'The server is up, but this sign-in has expired: sign in again.'));

    final down = await checks.jellyfin([Uri.parse('https://down.home.arpa'), Uri.parse('https://jellyfin.home.arpa')]);
    expect(down.ok, isTrue, reason: 'the next address is tried, as when connecting');
    expect(NotificationHistory.items.value.first.message, down.message);
    expect(AppLog.text(), contains('Connection test: The server is up, but this sign-in has expired'));
  });

  test('Seerr: reachable, but the API key is rejected; MyAnimeList: a client ID it refuses', () async {
    final checks = ConnectionChecks.of(container());
    final reachable = await checks.seerr(Uri.parse('https://seerr.home.arpa'));
    expect(reachable.message, startsWith('Seerr 3.5.1 is reachable'));
    final key = await checks.seerr(Uri.parse('https://seerr.home.arpa'), apiKey: 'nope');
    expect((key.ok, key.message), (false, 'Seerr is up, but it rejected this API key.'));
    expect(server.requestsTo('/api/v1/auth/me').single.headers['X-Api-Key'], 'nope');

    final mal = await checks.malClientId('abc');
    expect((mal.ok, mal.message), (false, "MyAnimeList doesn't accept this client ID."));
    expect(server.requestsTo('/v2/anime').single.headers['X-MAL-CLIENT-ID'], 'abc');
  });

  test("MyAnimeList: the link works, or it's no longer accepted", () async {
    final checks = ConnectionChecks.of(container());
    final ok = await checks.malAccount(() async => 'sam');
    expect((ok.ok, ok.message.startsWith('MyAnimeList: connected as sam')), (true, true));
    final refused = await checks.malAccount(() async => throw DioException(
          requestOptions: RequestOptions(path: '/users/@me'),
          response: Response(requestOptions: RequestOptions(path: '/users/@me'), statusCode: 401),
        ));
    expect((refused.ok, refused.message), (false, 'MyAnimeList no longer accepts this link: link the account again.'));
  });

  testWidgets('Check connection on a row: a spinner while it runs, and one press at a time', (tester) async {
    var runs = 0;
    final done = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CheckConnectionButton(check: () async {
        runs++;
        await done.future;
        return null;
      })),
    ));
    await tester.tap(find.text('Check connection'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Check connection'));
    await tester.pump();
    expect(runs, 1, reason: "a second press while it's checking does nothing");
    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Check connection on a phone: the icon only, so the row keeps its width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var runs = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListTile(
          title: const Text('Linked as Ov3R'),
          trailing: CheckConnectionButton(check: () async => runs++),
        ),
      ),
    ));
    expect(find.text('Check connection'), findsNothing);
    expect(tester.getSize(find.text('Linked as Ov3R')).height, lessThan(30), reason: 'one line');
    await tester.tap(find.byTooltip('Check connection'));
    await tester.pump();
    expect(runs, 1);
  });

  testWidgets('the connect screen: Test connection says what it found, without going on', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final c = container();
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://jellyfin.home.arpa');
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connected: sam, Jellyfin 10.11.11'), findsOneWidget);
    expect(find.text('Connect to server'), findsOneWidget, reason: 'still on the connect screen');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('sign-in fields are marked for password managers (username, password, address)', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final c = container();
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    final address = tester.widget<TextField>(find.byType(TextField));
    expect(address.autofillHints, [AutofillHints.url]);

    await tester.enterText(find.byType(TextField), 'https://jellyfin.home.arpa');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.map((f) => f.autofillHints?.single), [AutofillHints.username, AutofillHints.password]);
    expect(find.byType(AutofillGroup), findsOneWidget);
  });
}
