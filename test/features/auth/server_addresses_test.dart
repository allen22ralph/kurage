import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/server_addresses.dart';
import 'package:jellyfin_client/core/jellyfin/server_discovery.dart';
import 'package:jellyfin_client/core/storage/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

final home = Uri.parse('http://10.0.0.28:8096');
final away = Uri.parse('https://jf.example.ts.net');

Map<String, Object?> _session({List<Uri>? addresses, Uri? baseUrl, String user = 'sam'}) => {
      'serverId': 'srv1',
      'serverName': 'sam',
      'baseUrl': (baseUrl ?? home).toString(),
      'userId': 'u-$user',
      'userName': user,
      'accessToken': 'tok',
      'addresses': ?addresses?.map((a) => a.toString()).toList(),
    };

void main() {
  group('which address', () {
    test('home addresses: private IPv4, .local, .home.arpa, bare names; not Tailscale or the internet', () {
      for (final h in ['http://10.0.0.28:8096', 'http://192.168.1.5', 'http://172.20.0.2', 'http://nas.local',
          'https://jellyfin.home.arpa', 'http://nas:8096']) {
        expect(isHomeAddress(Uri.parse(h)), isTrue, reason: h);
      }
      for (final h in ['http://100.101.102.103:8096', 'https://jf.example.ts.net', 'https://media.example.com',
          'http://172.32.0.1']) {
        expect(isHomeAddress(Uri.parse(h)), isFalse, reason: h);
      }
    });

    test('home first, otherwise as saved', () {
      expect(rankAddresses([away, home]), [home, away]);
    });

    Future<String?> Function(Uri) answers(Map<Uri, (Duration, String?)> by) => (address) async {
          final (delay, id) = by[address] ?? (Duration.zero, null);
          await Future<void>.delayed(delay);
          if (id == null) throw Exception('no answer');
          return id;
        };

    test('at home: the home address, even when away answers first', () async {
      final picked = await pickAddress([away, home], 'srv1', answers({
        home: (const Duration(milliseconds: 100), 'srv1'),
        away: (Duration.zero, 'srv1'),
      }));
      expect(picked, home);
    });

    test('away: the away address, once home has had its chance', () async {
      final watch = Stopwatch()..start();
      final picked = await pickAddress([home, away], 'srv1', answers({
        home: (const Duration(seconds: 30), 'srv1'), // never in time
        away: (Duration.zero, 'srv1'),
      }), grace: const Duration(milliseconds: 200));
      expect(picked, away);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)), reason: "doesn't wait out the timeout");
    });

    test('a different server at the home address (another network) is not this one', () async {
      final picked = await pickAddress([home, away], 'srv1', answers({
        home: (Duration.zero, 'someone-elses'),
        away: (Duration.zero, 'srv1'),
      }));
      expect(picked, away);
    });

    test('none answer: null', () async {
      expect(await pickAddress([home, away], 'srv1', answers({})), isNull);
    });
  });

  group('saved addresses', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('saved before addresses were: just the one', () async {
      FlutterSecureStorage.setMockInitialValues({'sessions': jsonEncode([_session()])});
      expect((await SessionStore().loadAll()).single.addresses, [home]);
    });

    test("signing in at a new address adds it, for every account on that server", () async {
      FlutterSecureStorage.setMockInitialValues({
        'sessions': jsonEncode([_session(), _session(user: 'guest')]),
      });
      final store = SessionStore();
      final saved = await store.save(StoredSession.fromJson(_session(baseUrl: away)));
      expect(saved.addresses, [away, home]);
      expect(saved.baseUrl, away);
      for (final s in await store.loadAll()) {
        expect(s.addresses.toSet(), {home, away}, reason: s.userName);
      }
      expect((await store.loadServers()).single.addresses.toSet(), {home, away});
    });

    test('removing one keeps the other in use', () async {
      FlutterSecureStorage.setMockInitialValues({
        'sessions': jsonEncode([_session(addresses: [home, away])]),
      });
      final store = SessionStore();
      await store.setAddresses('srv1', [away]);
      final s = (await store.loadAll()).single;
      expect(s.addresses, [away]);
      expect(s.baseUrl, away);
    });
  });

  group('in the app', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<ProviderContainer> pumpApp(WidgetTester tester, FakeServer server,
        {Stream<DiscoveredServer> Function({bool scan})? discover}) async {
      server.routes.putIfAbsent('/UserViews', () => (200, pageJson([])));
      server.routes.putIfAbsent('/UserItems/Resume', () => (200, pageJson([])));
      server.routes.putIfAbsent('/Shows/NextUp', () => (200, pageJson([])));
      final container = ProviderContainer(overrides: [
        ...fakeServerOverrides(server, discover: discover),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const JellyfinClientApp()));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('away from home: starts on the away address, and Home loads from it', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'sessions': jsonEncode([_session(addresses: [home, away])]),
        'active_session': 'srv1:u-sam',
      });
      final server = FakeServer({
        '$home/System/Info/Public': unreachable,
        '$away/System/Info/Public': (200, testServerInfo),
      });
      final c = await pumpApp(tester, server);
      expect(c.read(sessionControllerProvider).value!.baseUrl, away);
      expect(server.requestsTo('/UserViews').map((r) => r.uri.origin).toSet(), {away.origin});
      expect((await SessionStore().loadAll()).single.baseUrl, away, reason: 'kept for next time');
    });

    testWidgets("back home: refreshing Home switches to the home address", (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'sessions': jsonEncode([_session(addresses: [home, away], baseUrl: away)]),
        'active_session': 'srv1:u-sam',
      });
      final server = FakeServer({
        '$home/System/Info/Public': unreachable,
        '$away/System/Info/Public': (200, testServerInfo),
      });
      final c = await pumpApp(tester, server);
      expect(c.read(sessionControllerProvider).value!.baseUrl, away);

      server.routes['$home/System/Info/Public'] = (200, testServerInfo);
      final switching = c.read(sessionControllerProvider.notifier).useAnsweringAddress();
      // The check's timers run on the test's clock.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await switching, isTrue);
      await tester.pumpAndSettle();
      expect(c.read(sessionControllerProvider).value!.baseUrl, home);
    });

    testWidgets('the connect screen lists servers on this network; one tap goes on to sign in', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final server = FakeServer({
        '$home/System/Info/Public': (200, testServerInfo),
        '/Users/Public': (200, <Object>[]),
        '/QuickConnect/Enabled': (200, true),
      });
      await pumpApp(tester, server,
          discover: ({bool scan = false}) => Stream.value(DiscoveredServer(id: 'srv1', name: 'sam', address: home)));
      expect(find.text('On this network'), findsOneWidget);
      await tester.tap(find.text('10.0.0.28:8096'));
      await tester.pumpAndSettle();
      expect(find.textContaining('10.0.0.28'), findsWidgets);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    });

    testWidgets("on opening, only Jellyfin's own call; the scan only when asked for", (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final looks = <bool>[];
      await pumpApp(tester, FakeServer({}), discover: ({bool scan = false}) {
        looks.add(scan);
        return const Stream.empty();
      });
      expect(looks, [false], reason: 'no scan of a network that may not be ours');
      expect(find.textContaining('None answered'), findsOneWidget);
      await tester.tap(find.text('Scan this network'));
      await tester.pumpAndSettle();
      expect(looks, [false, true]);
      expect(find.text('No servers found on this network.'), findsOneWidget);
    });
  });
}
