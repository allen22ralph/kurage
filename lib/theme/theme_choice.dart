import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/layout.dart';
import 'theme_spec.dart';
import 'themes/depth.dart';

/// The device the app runs on, for a theme's per-device values.
final themeDeviceProvider = Provider<ThemeDevice>((ref) {
  if (ref.watch(isTvProvider)) return ThemeDevice.tv;
  return Platform.isAndroid || Platform.isIOS ? ThemeDevice.phone : ThemeDevice.desktop;
});

/// Themes imported from a file, kept on this device.
final importedThemesProvider = AsyncNotifierProvider<ImportedThemes, List<Map<String, Object?>>>(ImportedThemes.new);

class ImportedThemes extends AsyncNotifier<List<Map<String, Object?>>> {
  static const _key = 'theme.imported';

  @override
  Future<List<Map<String, Object?>>> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return const [];
    try {
      return [for (final t in jsonDecode(raw) as List) (t as Map).cast<String, Object?>()];
    } on Object {
      return const [];
    }
  }

  Future<void> _save(List<Map<String, Object?>> themes) async {
    state = AsyncData(themes);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(themes));
  }

  /// Adds [theme], replacing one with the same id.
  Future<void> add(Map<String, Object?> theme) async {
    final now = await future;
    await _save([...now.where((t) => t['id'] != theme['id']), theme]);
  }

  Future<void> remove(String id) async {
    final now = await future;
    await _save([...now.where((t) => t['id'] != id)]);
  }
}

/// The themes to choose from, as theme files (JSON): the built-in ones, then
/// those imported.
final availableThemesProvider = Provider<List<Map<String, Object?>>>(
  (ref) => [
    const {'schema': themeSchema, 'id': 'classic', 'name': 'Classic'},
    depthThemeJson,
    ...?ref.watch(importedThemesProvider).value,
  ],
);

/// Settings > Appearance > Theme, and the font chosen over the theme's.
class ThemeChoice {
  const ThemeChoice({this.themeId = 'classic', this.font, this.googleFonts = false});

  final String themeId;

  /// Replaces both of the theme's fonts; null: the theme's own.
  final FontRef? font;

  /// Google fonts may be fetched (from Google's servers). Off (the default:
  /// nothing leaves the device unless asked): they show in the device's own
  /// font, and Google is never contacted for fonts.
  final bool googleFonts;

  ThemeChoice copyWith({String? themeId, FontRef? Function()? font, bool? googleFonts}) => ThemeChoice(
    themeId: themeId ?? this.themeId,
    font: font == null ? this.font : font(),
    googleFonts: googleFonts ?? this.googleFonts,
  );
}

final themeChoiceProvider = AsyncNotifierProvider<ThemeChoiceController, ThemeChoice>(ThemeChoiceController.new);

class ThemeChoiceController extends AsyncNotifier<ThemeChoice> {
  static const _prefix = 'theme.';

  @override
  Future<ThemeChoice> build() async {
    final prefs = await SharedPreferences.getInstance();
    return ThemeChoice(
      themeId: prefs.getString('${_prefix}id') ?? 'classic',
      font: FontRef.fromJson(prefs.getString('${_prefix}font')),
      googleFonts: prefs.getBool('${_prefix}googleFonts') ?? false,
    );
  }

  Future<void> save(ThemeChoice choice) async {
    await future.catchError((Object _) => const ThemeChoice());
    state = AsyncData(choice);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}id', choice.themeId);
    await prefs.setBool('${_prefix}googleFonts', choice.googleFonts);
    final font = choice.font;
    if (font == null) {
      await prefs.remove('${_prefix}font');
    } else {
      await prefs.setString('${_prefix}font', font.family ?? 'system');
    }
  }
}

/// The active theme for this device; Classic until the choice has loaded,
/// or when the chosen theme is gone.
final activeThemeProvider = Provider<ThemeSpec>((ref) {
  final id = ref.watch(themeChoiceProvider.select((c) => c.value?.themeId)) ?? 'classic';
  final json = ref.watch(availableThemesProvider).where((t) => t['id'] == id).firstOrNull;
  if (json == null) return classicTheme;
  return ThemeSpec.fromJson(json, device: ref.watch(themeDeviceProvider));
});
