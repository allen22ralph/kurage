import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/glow_backdrop.dart';
import 'package:jellyfin_client/features/home/depth/drum_section.dart';
import 'package:jellyfin_client/features/home/depth/genre_tiles.dart';
import 'package:jellyfin_client/features/home/depth/library_doors.dart';
import 'package:jellyfin_client/features/home/home_header_settings.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  late ProviderContainer c;

  Finder drums() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Drum');

  Future<void> open(WidgetTester tester, {String effects = 'full', String theme = 'depth'}) async {
    SharedPreferences.setMockInitialValues({'theme.id': theme, 'appearance.effects': effects});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final server = FakeServer({
      '/UserViews': (
        200,
        pageJson([
          itemJson('lib1', 'Movies', type: 'CollectionFolder', extra: {'CollectionType': 'movies'}),
        ]),
      ),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, []),
      '/Genres': (200, pageJson([itemJson('Action', 'Action', type: 'Genre')])),
      '/Items': (200, pageJson([])),
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    // (Not settling: with animations on, the glow never stops.)
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('Full: the drum and the backdrop', (tester) async {
    await open(tester);
    expect(drums(), findsWidgets);
    expect(find.byType(GlowBackdrop), findsOneWidget);
    await close(tester);
  });

  testWidgets('Balanced: no drum, the backdrop stays', (tester) async {
    await open(tester, effects: 'balanced');
    expect(find.byType(DrumSection), findsWidgets);
    expect(drums(), findsNothing);
    expect(find.byType(GlowBackdrop), findsOneWidget);
    await close(tester);
  });

  testWidgets('Lite: no drum, no backdrop, and the page still has its colour', (tester) async {
    await open(tester, effects: 'lite');
    expect(drums(), findsNothing);
    expect(find.byType(GlowBackdrop), findsNothing);
    expect(find.byType(ColoredBox), findsWidgets);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Lite: doors and tiles answer without turning', (tester) async {
    await open(tester, effects: 'lite');
    await tester.scrollUntilVisible(find.byType(LibraryDoors), 300, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 200));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    final door = find.descendant(of: find.byType(LibraryDoors), matching: find.text('Movies'));
    await mouse.moveTo(tester.getCenter(door));
    await tester.pump(const Duration(milliseconds: 1200));
    final leaf = tester.widget<Transform>(
      find.descendant(of: find.byType(LibraryDoors), matching: find.byType(Transform)).first,
    );
    expect(leaf.transform.storage[0], 1, reason: 'not turned');

    await tester.scrollUntilVisible(find.byType(GenreTiles), -200, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 200));
    final tile = find.descendant(of: find.byType(GenreTiles), matching: find.text('Action'));
    await mouse.moveTo(tester.getCenter(tile));
    await tester.pump();
    await tester.pump();
    expect(find.text('Browse Action →'), findsOneWidget, reason: 'the back, at once');
    expect(find.descendant(of: find.byType(GenreTiles), matching: find.byType(Transform)), findsNothing);
    await close(tester);
  });

  testWidgets('a change reaches what is on screen, and is kept', (tester) async {
    await open(tester);
    expect(drums(), findsWidgets);
    final controller = c.read(appearanceProvider.notifier);
    await controller.save(c.read(appearanceProvider).value!.copyWith(effects: EffectsLevel.lite));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(drums(), findsNothing);
    expect(find.byType(GlowBackdrop), findsNothing);
    final saved = await SharedPreferences.getInstance();
    expect(saved.getString('appearance.effects'), 'lite');
    await close(tester);
  });

  testWidgets('a system asking for less motion gets Lite, whatever is chosen', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await open(tester);
    expect(find.byType(GlowBackdrop), findsNothing);
    expect(drums(), findsNothing);
    await close(tester);
  });

  test('previews need Full; only Lite stops trailers', () {
    expect(EffectsLevel.full.playsPreviews, isTrue);
    expect(EffectsLevel.balanced.playsPreviews, isFalse);
    expect(EffectsLevel.lite.playsPreviews, isFalse);
    expect(EffectsLevel.full.playsTrailers, isTrue);
    expect(EffectsLevel.balanced.playsTrailers, isTrue);
    expect(EffectsLevel.lite.playsTrailers, isFalse);
  });

  test('previews in rows are on until turned off, and that is kept', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings = await container.read(homeHeaderSettingsProvider.future);
    expect(settings.previews, isTrue);
    await container.read(homeHeaderSettingsProvider.notifier).save(settings.copyWith(previews: false));
    final saved = await SharedPreferences.getInstance();
    expect(saved.getBool('homeHeader.previews'), isFalse);
  });

  test('anything unknown saved is Full', () async {
    SharedPreferences.setMockInitialValues({'appearance.effects': 'nonsense'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect((await container.read(appearanceProvider.future)).effects, EffectsLevel.full);
  });
}
