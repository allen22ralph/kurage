import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/theme/fonts.dart';
import 'package:jellyfin_client/theme/theme_spec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("a font's family from its file name", () {
    expect(AddedFonts.familyOf('Inter-SemiBold.ttf'), 'Inter');
    expect(AddedFonts.familyOf('Manrope[wght].ttf'), 'Manrope');
    expect(AddedFonts.familyOf('BricolageGrotesque-ExtraBold.otf'), 'BricolageGrotesque');
    expect(AddedFonts.familyOf('My_Font_Regular.TTF'), 'My Font');
    expect(AddedFonts.familyOf('Lexend.ttf'), 'Lexend');
  });

  test('Google Fonts: the whole list, by name', () {
    final all = googleFontFamilies;
    expect(all.length, greaterThan(1000));
    expect(all, containsAll(['Manrope', 'Bricolage Grotesque', 'Inter']));
    expect(isGoogleFont('Manrope'), isTrue);
    expect(isGoogleFont('Not A Font'), isFalse);
  });

  test("an unknown or the device's font leaves text as it is", () {
    final base = ThemeData(brightness: Brightness.dark).textTheme;
    expect(applyFont(base, const FontRef.system()), same(base));
    expect(applyFont(base, const FontRef('Not A Font')), same(base));
    expect(applyFont(base, const FontRef('My Font'), added: {'My Font'}).bodyMedium?.fontFamily, 'My Font');
  });

  test("Google Fonts off: a Google font isn't fetched, the device's shows; added fonts still work", () {
    final base = ThemeData(brightness: Brightness.dark).textTheme;
    expect(applyFont(base, const FontRef('Manrope'), google: false), same(base));
    expect(applyFont(base, const FontRef('Manrope'), added: {'Manrope'}, google: false).bodyMedium?.fontFamily, 'Manrope');
  });

  group('added fonts', () {
    late Directory dir;
    final realFont = File('${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts/roboto-regular.ttf');

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fonts_test');
      AddedFonts.folder = () async => dir;
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('added, kept for next time, and removed', () async {
      final bytes = await realFont.exists() ? await realFont.readAsBytes() : List<int>.filled(64, 0);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(await c.read(addedFontsProvider.future), isEmpty);

      final family = await c.read(addedFontsProvider.notifier).add(fileName: 'Roboto-Regular.ttf', bytes: bytes);
      expect(family, 'Roboto');
      await c.read(addedFontsProvider.notifier).add(fileName: r'C:\elsewhere\Roboto-Bold.ttf', bytes: bytes);
      expect(c.read(addedFontsProvider).value, {
        'Roboto': ['Roboto-Regular.ttf', 'Roboto-Bold.ttf'],
      }, reason: 'one family, two weights; only the file name is kept');
      expect(File('${dir.path}${Platform.pathSeparator}Roboto-Bold.ttf').existsSync(), isTrue);

      // Next start: read back.
      final next = ProviderContainer();
      addTearDown(next.dispose);
      expect((await next.read(addedFontsProvider.future)).keys, ['Roboto']);

      await next.read(addedFontsProvider.notifier).remove('Roboto');
      expect(next.read(addedFontsProvider).value, isEmpty);
      expect(File('${dir.path}${Platform.pathSeparator}Roboto-Regular.ttf').existsSync(), isFalse);
    });

    test('only .ttf and .otf files', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await expectLater(
        c.read(addedFontsProvider.notifier).add(fileName: 'notes.txt', bytes: [1, 2, 3]),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
