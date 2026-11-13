import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/animations.dart';
import 'package:jellyfin_client/features/settings/appearance_preview.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/app/backdrop.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/app/theme.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('appearance choices are kept', () async {
    var c = ProviderContainer();
    final settings = await c.read(appearanceProvider.future);
    expect(settings.accent, AccentColor.jellyfin);
    expect(settings.animations, isTrue);
    await c.read(appearanceProvider.notifier).save(settings.copyWith(
          accent: AccentColor.teal,
          background: AppBackground.black,
          cardSize: CardSize.large,
          animations: false,
        ));
    c.dispose();

    c = ProviderContainer();
    addTearDown(c.dispose);
    final back = await c.read(appearanceProvider.future);
    expect((back.accent, back.background, back.cardSize, back.animations),
        (AccentColor.teal, AppBackground.black, CardSize.large, false));
  });

  test('the theme follows the accent colour; black background for OLED', () {
    final dark = buildTheme();
    final oled = buildTheme(const AppearanceSettings(accent: AccentColor.orange, background: AppBackground.black));
    expect(oled.scaffoldBackgroundColor, Colors.black);
    expect(oled.colorScheme.surface, Colors.black);
    expect(dark.scaffoldBackgroundColor, isNot(Colors.black));
    expect(oled.colorScheme.primary, isNot(dark.colorScheme.primary));
  });

  testWidgets('card size scales the cards', (tester) async {
    late LayoutSpec layout;
    final c = ProviderContainer(overrides: [isTvProvider.overrideWithValue(false)]);
    addTearDown(c.dispose);
    await c.read(appearanceProvider.notifier).save(const AppearanceSettings(cardSize: CardSize.large));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: Builder(builder: (context) {
        layout = context.layout;
        return const SizedBox();
      })),
    ));
    expect(layout.cardScale, CardSize.large.scale);
    expect(layout.posterWidth, closeTo(LayoutSpec(layout.formFactor).posterWidth * 1.18, 0.01));
  });

  testWidgets('with animations off, rows and cards appear without moving', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(appearanceProvider.notifier).save(const AppearanceSettings(animations: false));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Entrance(index: 3, child: Text('card'))),
    ));
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);

    await c.read(appearanceProvider.notifier).save(const AppearanceSettings());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Entrance(key: ValueKey('on'), index: 3, child: Text('card'))),
    ));
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
  });

  test('tinted: a hint of the accent colour, neither plain dark nor black', () {
    final dark = buildTheme();
    final tinted = buildTheme(const AppearanceSettings(accent: AccentColor.pink, background: AppBackground.tinted));
    expect(tinted.scaffoldBackgroundColor, isNot(dark.scaffoldBackgroundColor));
    expect(tinted.scaffoldBackgroundColor, isNot(Colors.black));
    expect(tinted.scaffoldBackgroundColor.r, greaterThan(dark.scaffoldBackgroundColor.r), reason: 'pink shows through');
  });

  test('show artwork: a card hovered / focused becomes the background, only when chosen; strength kept', () async {
    BackdropArt.current.value = null;
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final show = BaseItem.fromJson({
      'Id': 'fr',
      'Name': 'Frieren',
      'Type': 'Series',
      'BackdropImageTags': ['b1'],
    });
    await c.read(appearanceProvider.future);
    BackdropArt.show(show, c);
    expect(BackdropArt.current.value, isNull, reason: 'dark background: nothing to do');

    await c.read(appearanceProvider.notifier).save(const AppearanceSettings(background: AppBackground.artwork, artworkStrength: 0.5));
    BackdropArt.show(show, c);
    expect(BackdropArt.current.value?.itemId, 'fr');
    expect(BackdropArt.current.value?.type, 'Backdrop');

    final again = ProviderContainer();
    addTearDown(again.dispose);
    expect((await again.read(appearanceProvider.future)).artworkStrength, 0.5);
  });

  testWidgets('Settings > Appearance: a live preview that follows every change', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [isTvProvider.overrideWithValue(false)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AppearanceSection()))),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AppearancePreview), findsOneWidget);
    double cardWidth() => tester.getSize(find.descendant(of: find.byType(AppearancePreview), matching: find.byType(Entrance)).first).width;
    final medium = cardWidth();

    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(cardWidth(), greaterThan(medium));
    expect(find.text('Artwork strength'), findsNothing);

    await c.read(appearanceProvider.notifier).save(const AppearanceSettings(background: AppBackground.artwork));
    await tester.pumpAndSettle();
    expect(find.text('Artwork strength'), findsOneWidget);
  });
}
