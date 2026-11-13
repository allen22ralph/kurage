import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// The lite entry point: only a map of the fonts, not 1,500 generated
// methods (the full one added about 9 MB to the app).
import 'package:google_fonts/google_fonts_lite.dart';
import 'package:path_provider/path_provider.dart';

import '../core/log/app_log.dart';
import 'theme_spec.dart';

/// Every Google Fonts family, by name (about 1,500): any of them can be a
/// theme's font. Each is downloaded once when first used, then kept.
List<String> get googleFontFamilies => GoogleFontsLite.fontsMap.keys.toList()..sort();

bool isGoogleFont(String family) => GoogleFontsLite.fontsMap.containsKey(family);

/// [base] in [font] (null: unchanged). An added font wins over a Google
/// font of the same name; an unknown name keeps the device's own font, as
/// does a Google font when [google] is off (Settings: nothing is fetched).
TextTheme applyFont(TextTheme base, FontRef font, {Set<String> added = const {}, bool google = true}) {
  final family = font.family;
  if (family == null) return base;
  if (added.contains(family)) return base.apply(fontFamily: family);
  if (google && isGoogleFont(family)) {
    try {
      // Style by style: the lite getTextTheme is the material_ui package's
      // TextTheme, not Flutter's.
      TextStyle? f(TextStyle? s) => s == null ? null : GoogleFontsLite.getFont(family, textStyle: s);
      return base.copyWith(
        displayLarge: f(base.displayLarge),
        displayMedium: f(base.displayMedium),
        displaySmall: f(base.displaySmall),
        headlineLarge: f(base.headlineLarge),
        headlineMedium: f(base.headlineMedium),
        headlineSmall: f(base.headlineSmall),
        titleLarge: f(base.titleLarge),
        titleMedium: f(base.titleMedium),
        titleSmall: f(base.titleSmall),
        bodyLarge: f(base.bodyLarge),
        bodyMedium: f(base.bodyMedium),
        bodySmall: f(base.bodySmall),
        labelLarge: f(base.labelLarge),
        labelMedium: f(base.labelMedium),
        labelSmall: f(base.labelSmall),
      );
    } on Object catch (e) {
      AppLog.warning(LogArea.app, 'Font $family: not available', error: e);
    }
  }
  return base;
}

/// [base] with the display styles (big titles) in [display] and the rest in
/// [ui], as a theme's two fonts.
TextTheme themeFonts(
  TextTheme base, {
  required FontRef display,
  required FontRef ui,
  Set<String> added = const {},
  bool google = true,
}) {
  final u = applyFont(base, ui, added: added, google: google);
  final d = applyFont(base, display, added: added, google: google);
  return u.copyWith(
    displayLarge: d.displayLarge,
    displayMedium: d.displayMedium,
    displaySmall: d.displaySmall,
    headlineLarge: d.headlineLarge,
    headlineMedium: d.headlineMedium,
    headlineSmall: d.headlineSmall,
    titleLarge: d.titleLarge,
  );
}

/// Font files added in Settings > Appearance (`.ttf` / `.otf`), kept in the
/// app's folder and loaded at start. Several files of one family (Regular,
/// Bold…) share its name.
final addedFontsProvider = AsyncNotifierProvider<AddedFonts, Map<String, List<String>>>(AddedFonts.new);

class AddedFonts extends AsyncNotifier<Map<String, List<String>>> {
  /// Overridden in tests.
  @visibleForTesting
  static Future<Directory> Function() folder = () async =>
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}fonts');

  static const _index = 'fonts.json';

  @override
  Future<Map<String, List<String>>> build() async {
    final dir = await folder();
    final index = File('${dir.path}${Platform.pathSeparator}$_index');
    if (!await index.exists()) return const {};
    try {
      final fonts = {
        for (final e in (jsonDecode(await index.readAsString()) as Map<String, dynamic>).entries)
          e.key: [for (final f in e.value as List) f as String],
      };
      for (final e in fonts.entries) {
        await _register(dir, e.key, e.value);
      }
      return fonts;
    } on Object catch (e) {
      AppLog.warning(LogArea.app, "Added fonts: couldn't load them", error: e);
      return const {};
    }
  }

  /// The family name from a file name: `Inter-SemiBold.ttf` → `Inter`.
  static String familyOf(String fileName) {
    var name = fileName.replaceAll(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '');
    name = name.replaceAll(RegExp(r'\[.*\]'), '');
    name = name.replaceAll(
      RegExp(
        r'[-_ ]?(Thin|ExtraLight|Light|Regular|Medium|SemiBold|Bold|ExtraBold|Black|Italic|Variable|VF)+$',
        caseSensitive: false,
      ),
      '',
    );
    return name.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  }

  /// Adds a font file ([fileName], [bytes]) under [family] (default: from
  /// its name). Returns the family.
  Future<String> add({required String fileName, required List<int> bytes, String? family}) async {
    final current = await future.catchError((Object _) => const <String, List<String>>{});
    // Only the name: a picked file's path can't put it anywhere else.
    final safe = fileName.split(RegExp(r'[\\/]')).last;
    final name = (family ?? familyOf(safe)).trim();
    if (name.isEmpty) throw const FormatException('The font needs a name');
    if (!RegExp(r'\.(ttf|otf)$', caseSensitive: false).hasMatch(safe)) {
      throw const FormatException('Fonts are .ttf or .otf files');
    }
    final dir = await folder();
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}$safe').writeAsBytes(bytes);
    final files = {...?current[name], safe}.toList();
    final next = {...current, name: files};
    await _register(dir, name, files);
    await _save(dir, next);
    state = AsyncData(next);
    AppLog.info(LogArea.app, 'Added font: $name');
    return name;
  }

  Future<void> remove(String family) async {
    final current = await future.catchError((Object _) => const <String, List<String>>{});
    final dir = await folder();
    for (final f in current[family] ?? const <String>[]) {
      final file = File('${dir.path}${Platform.pathSeparator}$f');
      if (await file.exists()) await file.delete();
    }
    final next = {...current}..remove(family);
    await _save(dir, next);
    state = AsyncData(next);
    AppLog.info(LogArea.app, 'Removed font: $family');
  }

  static Future<void> _save(Directory dir, Map<String, List<String>> fonts) =>
      File('${dir.path}${Platform.pathSeparator}$_index').writeAsString(jsonEncode(fonts));

  static Future<void> _register(Directory dir, String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File('${dir.path}${Platform.pathSeparator}$f');
      if (await file.exists()) loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
    }
    await loader.load();
  }
}
