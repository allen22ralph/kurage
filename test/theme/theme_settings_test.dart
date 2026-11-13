import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/theme/fonts.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:jellyfin_client/theme/theme_settings.dart';
import 'package:jellyfin_client/theme/theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory fonts;

  setUp(() async {
    fonts = await Directory.systemTemp.createTemp('theme_settings_test');
    AddedFonts.folder = () async => fonts;
  });

  tearDown(() async {
    if (await fonts.exists()) await fonts.delete(recursive: true);
  });

  Future<ProviderContainer> pump(WidgetTester tester, [Map<String, Object> prefs = const {}]) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [isTvProvider.overrideWithValue(false)]);
    addTearDown(c.dispose);
    await c.read(themeChoiceProvider.future);
    // Files: read for real, before the test's fake clock takes over.
    await tester.runAsync(() => c.read(addedFontsProvider.future));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: ThemeSection())),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('Classic by default, with its own font', (tester) async {
    final c = await pump(tester);
    expect(find.text('Classic'), findsOneWidget);
    expect(find.text("The theme's own (Device's own)"), findsOneWidget);
    expect(c.read(activeThemeProvider).id, 'classic');
  });

  testWidgets('a Google font: searched, chosen, kept; then back to the theme\'s', (tester) async {
    final c = await pump(tester, {'theme.googleFonts': true});
    await tester.tap(find.text('Font'));
    await tester.pumpAndSettle();
    expect(find.text('Add a font file…'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'manro');
    await tester.pumpAndSettle();
    expect(find.text('Add a font file…'), findsNothing, reason: 'searching shows only Google Fonts');
    await tester.tap(find.text('Manrope'));
    await tester.pumpAndSettle();

    expect(c.read(themeChoiceProvider).value?.font, const FontRef('Manrope'));
    expect(find.text('Manrope'), findsOneWidget, reason: 'the row says which');
    expect((await SharedPreferences.getInstance()).getString('theme.font'), 'Manrope');

    await tester.tap(find.text('Font'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("The theme's own"));
    await tester.pumpAndSettle();
    expect(c.read(themeChoiceProvider).value?.font, isNull);
    expect((await SharedPreferences.getInstance()).getString('theme.font'), isNull);
  });

  testWidgets('Google Fonts turned off: not offered, said so, kept', (tester) async {
    final c = await pump(tester, {'theme.font': 'Manrope', 'theme.googleFonts': true});
    expect(find.text('Manrope'), findsOneWidget);
    await tester.tap(find.text('Google Fonts'));
    await tester.pumpAndSettle();

    expect(c.read(themeChoiceProvider).value?.googleFonts, isFalse);
    expect((await SharedPreferences.getInstance()).getBool('theme.googleFonts'), isFalse);
    expect(find.text("Manrope: Google Fonts is off, so the device's own"), findsOneWidget);

    await tester.tap(find.text('Font'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'no Google Fonts to search');
    expect(find.text('Inter'), findsNothing);
    expect(find.textContaining('Off in Settings > Appearance'), findsOneWidget);
    expect(find.text('Add a font file…'), findsOneWidget, reason: 'added fonts stay');
  });

  testWidgets('Google Fonts off by default (nothing fetched unless asked), with what it means', (tester) async {
    final c = await pump(tester);
    expect(c.read(themeChoiceProvider).value?.googleFonts, isFalse);
    await tester.tap(find.text('Google Fonts'));
    await tester.pumpAndSettle();
    expect(c.read(themeChoiceProvider).value?.googleFonts, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('theme.googleFonts'), isTrue);
    expect(find.textContaining("IP address"), findsOneWidget);
  });

  testWidgets("deleting the font in use: back to the theme's own, said so; Font still opens", (tester) async {
    // A font added earlier (as on the last start).
    // (Only its name matters here; a CI machine has no Flutter font cache to
    // copy a real one from, and a font that won't load is simply not used.)
    File('${fonts.path}${Platform.pathSeparator}Mine-Regular.ttf').writeAsBytesSync([0, 1, 0, 0]);
    File('${fonts.path}${Platform.pathSeparator}fonts.json').writeAsStringSync('{"Mine":["Mine-Regular.ttf"]}');
    final c = await pump(tester, {'theme.font': 'Mine'});
    expect(find.text('Mine'), findsOneWidget);

    await tester.tap(find.text('Font'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Remove'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Mine'), findsNothing);
    final selected = tester.widget<ListTile>(find.widgetWithText(ListTile, "The theme's own"));
    expect(selected.selected, isTrue, reason: 'the picker shows what is now in use');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(c.read(themeChoiceProvider).value?.font, isNull);
    expect(find.text("The theme's own (Device's own)"), findsOneWidget);

    await tester.tap(find.text('Font'));
    await tester.pumpAndSettle();
    expect(find.text('Add a font file…'), findsOneWidget, reason: 'Font opens again');
  });

  testWidgets('a font that is gone (not added, not Google) says what shows instead', (tester) async {
    await pump(tester, {'theme.font': 'Long Gone'});
    expect(find.text("Long Gone: not on this device, so the device's own"), findsOneWidget);
  });

  testWidgets('a theme that no longer exists falls back to Classic', (tester) async {
    final c = await pump(tester, {'theme.id': 'gone'});
    expect(c.read(activeThemeProvider).id, 'classic');
    expect(find.text('Classic'), findsOneWidget);
  });

  test('devices: TV, phone or desktop', () {
    final tv = ProviderContainer(overrides: [isTvProvider.overrideWithValue(true)]);
    addTearDown(tv.dispose);
    expect(tv.read(themeDeviceProvider), ThemeDevice.tv);
    final here = ProviderContainer(overrides: [isTvProvider.overrideWithValue(false)]);
    addTearDown(here.dispose);
    expect(here.read(themeDeviceProvider), Platform.isAndroid ? ThemeDevice.phone : ThemeDevice.desktop);
  });
}
