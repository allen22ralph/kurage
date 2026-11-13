import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/app/router.dart';
import 'package:jellyfin_client/features/auth/login_screen.dart';
import 'package:jellyfin_client/features/home/home_screen.dart';

import '../../support/fake_server.dart';

Map<String, Object?> _session(String userId, String name) => {
      'serverId': 'srv1',
      'serverName': 'sam',
      'baseUrl': 'https://jellyfin.home.arpa',
      'userId': userId,
      'userName': name,
      'accessToken': 'tok-$userId',
    };

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'sessions': jsonEncode([_session('u1', 'sam'), _session('u2', 'guest')]),
      'active_session': 'srv1:u1',
    });
    SharedPreferences.setMockInitialValues({});
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, <Object>[]),
      '/Users/Public': (200, <Object>[]),
      '/QuickConnect/Enabled': (200, false),
    });
    final container = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    return container;
  }

  for (final (label, pick) in [('another account', 'guest'), ('the same account', 'sam')]) {
    testWidgets('Add account, then picking $label on the login screen lands on Home', (tester) async {
      final container = await pumpApp(tester);
      final router = container.read(routerProvider);
      expect(find.byType(HomeScreen), findsOneWidget);

      unawaited(router.push('/accounts'));
      await tester.pumpAndSettle();
      container.read(loginFlowProvider.notifier).startAddingAccount();
      unawaited(router.push('/connect'));
      await tester.pumpAndSettle();
      final session = (await container.read(storedSessionsProvider.future)).first;
      container.read(loginFlowProvider.notifier).selectServer(PendingServer.of(session));
      unawaited(router.push('/connect/login'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      await tester.tap(find.text(pick).first);
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsNothing, reason: 'the login page should be gone');
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(container.read(sessionControllerProvider).value?.userName, pick);
    });
  }
}

