import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/features/library/widgets/media_card.dart';
import 'package:jellyfin_client/features/library/widgets/action_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

Map<String, Object?> _episode(String id, String name) => itemJson(id, name, type: 'Episode', extra: {
      'SeriesId': 'ser1',
      'SeriesName': 'Frieren',
      'IndexNumber': 3,
      'ParentIndexNumber': 1,
      'UserData': {'Played': false, 'PlaybackPositionTicks': 6000000000, 'PlayedPercentage': 40},
    });

void main() {
  // These hold cards as on a phone or TV, where a hold opens the menu.
  setUp(() => debugHoldOpensMenu = true);
  tearDown(() => debugHoldOpensMenu = null);

  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([_episode('ep-r', 'Resumed episode')])),
      '/Shows/NextUp': (200, pageJson([_episode('ep-n', 'Next episode')])),
      'POST /UserPlayedItems/ep-r': (200, {}),
      'POST /UserItems/ep-r/UserData': (200, {}),
    });
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
  }

  /// The card's artwork (where the hover buttons are).
  Finder artwork(String name) => find.descendant(
        of: find.ancestor(of: find.textContaining(name), matching: find.byType(MediaCard)),
        matching: find.byType(AspectRatio),
      );

  testWidgets('hovering a card shows ✓ ♥ ⋮; ✓ marks it watched', (tester) async {
    await pumpHome(tester);
    expect(find.byTooltip('Mark watched'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(artwork('Resumed episode')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add to favourites'), findsOneWidget);
    await tester.tap(find.byTooltip('Mark watched'));
    await tester.pumpAndSettle();
    expect(server.requestsTo('/UserPlayedItems/ep-r'), hasLength(1));
    expect(find.text('Marked Resumed episode watched'), findsOneWidget);
  });

  testWidgets('⋮ on hover: the menu still works once the mouse has left the card', (tester) async {
    await pumpHome(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(artwork('Resumed episode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    // The menu covers the card: its hover buttons are gone.
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byTooltip('More'), findsNothing);
    await tester.tap(find.text('Remove from Continue watching'));
    await tester.pumpAndSettle();
    expect(server.requestsTo('/UserItems/ep-r/UserData'), hasLength(1));
    expect(find.text('Removed from Continue watching'), findsOneWidget);
    expect(server.requestsTo('/UserItems/Resume'), hasLength(2), reason: 'the row reloads');
  });

  testWidgets('right-click opens the menu as a popup at the pointer', (tester) async {
    await pumpHome(tester);
    final at = tester.getCenter(artwork('Resumed episode'));
    await tester.tapAt(at, buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    final entry = find.text('Remove from Continue watching');
    expect(entry, findsOneWidget);
    expect((tester.getCenter(entry).dx - at.dx).abs(), lessThan(250), reason: 'opens where the mouse is');
    expect(find.text('Download'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(server.requestsTo('/UserItems/ep-r/UserData'), hasLength(1));
  });

  testWidgets('long press: remove from Continue watching clears the resume point', (tester) async {
    await pumpHome(tester);
    await tester.longPress(find.text('Frieren').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from Continue watching'));
    await tester.pumpAndSettle();
    final r = server.requestsTo('/UserItems/ep-r/UserData').single;
    expect(r.data, {'PlaybackPositionTicks': 0});
  });

  testWidgets('hide from Next up takes the card off, and is remembered', (tester) async {
    await pumpHome(tester);
    expect(find.textContaining('Next episode'), findsOneWidget);
    await tester.longPress(find.textContaining('Next episode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide from Next up'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Next episode'), findsNothing);
    final saved = (await SharedPreferences.getInstance()).getString('home.nextUpHidden.srv1.u1');
    expect(saved, contains('ep-n'));
  });
}
