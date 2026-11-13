import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/features/home/depth/deck_hero.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  late ProviderContainer c;

  Future<void> open(WidgetTester tester, String effects) async {
    SharedPreferences.setMockInitialValues({'theme.id': 'depth', 'appearance.effects': effects});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    Map<String, Object?> show(String id) => itemJson(id, 'Show $id', type: 'Series', extra: {
          'BackdropImageTags': ['b-$id'],
          'LocalTrailerCount': 0,
        });
    final server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, []),
      '/Genres': (200, pageJson([])),
      '/Items': (200, pageJson([show('s1'), show('s2')])),
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c = ProviderContainer(overrides: fakeServerOverrides(server, header: true));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('with no trailer playing the chip has no equaliser, on any level', (tester) async {
    await open(tester, 'full');
    expect(find.text('FEATURED'), findsOneWidget);
    expect(find.byType(Equaliser), findsNothing);
    expect(find.byTooltip('Pause'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a playing trailer still has its equaliser', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: Scaffold(body: NowPlayingChip(trailerLabel: 'Now playing · Trailer')))),
    );
    expect(find.byType(Equaliser), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Lite: no pause or mute, as there is nothing to pause or mute', (tester) async {
    await open(tester, 'lite');
    expect(find.text('FEATURED'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsNothing);
    expect(find.byTooltip('Mute'), findsNothing);
    expect(find.byTooltip('Unmute'), findsNothing);
    await close(tester);
  });

  testWidgets('paused, then Lite: not stuck paused with no button to resume', (tester) async {
    await open(tester, 'balanced');
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PAUSED'), findsOneWidget);

    await c.read(appearanceProvider.notifier).save(c.read(appearanceProvider).value!.copyWith(effects: EffectsLevel.lite));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PAUSED'), findsNothing);
    expect(find.text('FEATURED'), findsOneWidget);
    await close(tester);
  });
}
