import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/home/home_actions.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:jellyfin_client/theme/theme_files.dart';
import 'package:jellyfin_client/theme/theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const sunset = {
    'schema': 1,
    'id': 'sunset',
    'name': 'Sunset',
    'author': 'A friend',
    'tokens': {
      'colors': {'background': '#201018', 'accent': '#ff8866'},
    },
  };

  late ProviderContainer c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(themeChoiceProvider.future);
    await c.read(importedThemesProvider.future);
  });

  group('reading a file', () {
    test('a theme comes through', () {
      expect(parseThemeFile(jsonEncode(sunset))['name'], 'Sunset');
    });

    test('what isn\'t a theme is refused, in plain words', () {
      for (final bad in ['not json', '[1, 2]', '{}', '{"schema": 1, "id": "x"}', '{"schema": "1", "id": "x", "name": "X"}', '{"schema": 1, "id": " ", "name": "X"}']) {
        expect(() => parseThemeFile(bad), throwsA(isA<ThemeFileException>()), reason: bad);
      }
    });

    test('nor is something far too large', () {
      expect(() => parseThemeFile('{"pad": "${'x' * (1024 * 1024)}"}'), throwsA(isA<ThemeFileException>()));
    });

    test('rubbish inside a theme falls back rather than failing', () {
      final theme = parseThemeFile(jsonEncode({
        'schema': 99,
        'id': 'odd',
        'name': 'Odd',
        'tokens': {'colors': {'background': 'purple', 'accent': 7}, 'radius': 'round', 'motion': {'speed': 1000}},
        'components': {'home.hero': {'variant': 'from-the-future'}, 'home.topBar': 'pill'},
        'layout': 12,
      }));
      final spec = ThemeSpec.fromJson(theme, device: ThemeDevice.desktop);
      expect(spec.tokens.background, classicTheme.tokens.background);
      expect(spec.tokens.motionSpeed, 4, reason: 'held to its limit');
      expect(spec.components.containsKey('home.topBar'), isFalse);
    });
  });

  group('importing', () {
    test('it joins the choices, survives a restart, and can be removed', () async {
      await useImportedTheme(c, sunset, withSettings: false);
      expect(c.read(activeThemeProvider).name, 'Sunset');
      expect(c.read(activeThemeProvider).tokens.accent, const Color(0xFFFF8866));

      final next = ProviderContainer();
      addTearDown(next.dispose);
      await next.read(themeChoiceProvider.future);
      await next.read(importedThemesProvider.future);
      expect(next.read(activeThemeProvider).name, 'Sunset', reason: 'after a restart');

      await removeImportedTheme(c, 'sunset');
      expect(c.read(activeThemeProvider).id, 'classic', reason: 'it was in use');
      expect(c.read(availableThemesProvider).where((t) => t['id'] == 'sunset'), isEmpty);
    });

    test('importing it again replaces it', () async {
      await addImportedTheme(c, sunset);
      await addImportedTheme(c, {...sunset, 'name': 'Sunset 2'});
      final same = c.read(availableThemesProvider).where((t) => t['id'] == 'sunset');
      expect(same, hasLength(1));
      expect(same.single['name'], 'Sunset 2');
    });

    test('a built-in theme\'s id makes a copy, leaving the built-in alone', () async {
      final id = await addImportedTheme(c, {'schema': 1, 'id': 'depth', 'name': 'Depth', 'tokens': <String, Object?>{}});
      expect(id, 'depth-2');
      final themes = c.read(availableThemesProvider);
      expect(themes.where((t) => t['id'] == 'depth').single['tokens'], isNotEmpty);
      expect(themes.where((t) => t['id'] == 'depth-2').single['name'], 'Depth (imported)');
    });

    test('settings that came with it apply only if asked', () async {
      final withSettings = {
        ...sunset,
        'settings': {
          'appearance': {'cardSize': CardSize.large.name, 'effects': 'lite', 'artworkStrength': 5.0, 'accent': 'no-such-colour'},
          'topBar': {'centre': ['shows', 'downloads'], 'right': ['search']},
        },
      };
      await useImportedTheme(c, withSettings, withSettings: false);
      expect((await c.read(appearanceProvider.future)).cardSize, isNot(CardSize.large));
      expect(c.read(availableThemesProvider).firstWhere((t) => t['id'] == 'sunset').containsKey('settings'), isFalse);

      await useImportedTheme(c, withSettings, withSettings: true);
      final look = await c.read(appearanceProvider.future);
      expect(look.cardSize, CardSize.large);
      expect(look.effects, EffectsLevel.lite);
      expect(look.artworkStrength, 0.6, reason: 'held to its limit');
      expect(look.accent, const AppearanceSettings().accent, reason: 'an unknown one is ignored');
      final bar = await c.read(homeBarSettingsProvider.future);
      expect(bar.centre, ['shows', 'downloads']);
      expect(bar.right, ['search']);
    });
  });

  test('exporting and importing brings back the theme and its settings', () async {
    await useImportedTheme(c, sunset, withSettings: false);
    final look = await c.read(appearanceProvider.future);
    await c.read(appearanceProvider.notifier).save(look.copyWith(cardSize: CardSize.small));
    await c.read(homeBarSettingsProvider.notifier).replaceWith(centre: const ['movies'], right: const ['refresh']);

    final text = await exportThemeFile(c);

    SharedPreferences.setMockInitialValues({});
    final other = ProviderContainer();
    addTearDown(other.dispose);
    await other.read(themeChoiceProvider.future);
    await other.read(importedThemesProvider.future);
    await useImportedTheme(other, parseThemeFile(text), withSettings: true);
    expect(other.read(activeThemeProvider).name, 'Sunset');
    expect((await other.read(appearanceProvider.future)).cardSize, CardSize.small);
    expect((await other.read(homeBarSettingsProvider.future)).right, ['refresh']);
  });

  testWidgets('Settings offers import and export, and removing only what was imported', (tester) async {
    Future<void> pump() async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: ThemeFilesSection())),
      ));
      await tester.pump();
    }

    await pump();
    expect(find.text('Import a theme'), findsOneWidget);
    expect(find.text('Export this theme'), findsOneWidget);
    expect(find.textContaining('Remove'), findsNothing);

    await tester.runAsync(() => useImportedTheme(c, sunset, withSettings: false));
    await pump();
    expect(find.text('Remove Sunset'), findsOneWidget);
  });

  test('a built-in theme can be exported too', () async {
    final file = parseThemeFile(await exportThemeFile(c));
    expect(file['id'], 'classic');
    expect(file['settings'], isA<Map<String, Object?>>());
  });
}
