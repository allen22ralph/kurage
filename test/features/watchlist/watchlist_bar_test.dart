import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/features/home/depth/depth_top_bar.dart';
import 'package:jellyfin_client/features/watchlist/watchlist_screen.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  testWidgets('Depth: the watchlist has the top bar, with Back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'flutter.theme.id': 'depth'});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final server = FakeServer({'/Items': (200, pageJson([]))});
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.read(sessionControllerProvider.future);
      await c.read(themeChoiceProvider.future);
    });
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(navigatorKey: nav, home: const Scaffold(body: Text('Home'))),
    ));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const WatchlistScreen()));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PillTopBar), findsOneWidget);
    expect(find.byType(PillBackButton), findsOneWidget);
    final box = tester.getRect(find.byType(PillTopBar));
    expect(box.top, lessThan(100), reason: 'at the top: $box');
    expect(box.height, greaterThan(20), reason: 'it has a size: $box');
  });
}
