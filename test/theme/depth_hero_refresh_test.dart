import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/features/home/home_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  late ProviderContainer c;
  late List<String> selection;

  Map<String, Object?> show(String id) => itemJson(id, 'Show $id', type: 'Series', extra: {
        'BackdropImageTags': ['b-$id'],
        'LocalTrailerCount': 0,
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'theme.id': 'depth'});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, []),
      '/Genres': (200, pageJson([])),
      '/Items': (RequestOptions _) => (200, pageJson([for (final id in selection) show(id)])),
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c = ProviderContainer(overrides: fakeServerOverrides(server, header: true));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await settle(tester);
    // Past the moment on the artwork, so the header has settled on its show.
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('refreshed to other shows: the old one has gone, paused or not', (tester) async {
    selection = ['s1', 's2'];
    await open(tester);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PAUSED'), findsOneWidget);

    selection = ['s3', 's4'];
    c.invalidate(headerFeaturedProvider);
    await settle(tester);
    expect(find.text('PAUSED'), findsNothing, reason: 'what was paused has gone');
    expect(find.text('FEATURED'), findsOneWidget);
    expect(find.text('Show s3'), findsWidgets);
    expect(find.text('Show s1'), findsNothing);
    await close(tester);
  });

  testWidgets('refreshed with the show on screen still there: it carries on', (tester) async {
    selection = ['s1', 's2'];
    await open(tester);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 300));

    selection = ['s3', 's1'];
    c.invalidate(headerFeaturedProvider);
    await settle(tester);
    expect(find.text('PAUSED'), findsOneWidget, reason: 'the same show, still paused');
    expect(find.text('Show s1'), findsWidgets);
    await close(tester);
  });
}
