import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/toast.dart';
import '../core/log/app_log.dart';
import '../features/home/home_actions.dart';
import '../features/settings/appearance.dart';
import 'theme_choice.dart';

/// A theme file that can't be used, and why, in words for the person.
class ThemeFileException implements Exception {
  const ThemeFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A theme file: data only, so it can't run code. Past this it isn't one.
const _largestFile = 1024 * 1024;

/// Reads a theme file: the theme, with any settings that came with it under
/// `settings`. What this app doesn't know in it is ignored when it's used.
Map<String, Object?> parseThemeFile(String text) {
  if (text.length > _largestFile) throw const ThemeFileException('That file is too large to be a theme.');
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const ThemeFileException("That file isn't a theme.");
  }
  if (json is! Map) throw const ThemeFileException("That file isn't a theme.");
  final theme = json.cast<String, Object?>();
  final name = theme['name'];
  final id = theme['id'];
  if (theme['schema'] is! int || id is! String || id.trim().isEmpty || name is! String || name.trim().isEmpty) {
    throw const ThemeFileException("That file isn't a theme: it has no schema, id or name.");
  }
  return theme;
}

/// The theme on its own, without the settings that came with it.
Map<String, Object?> _withoutSettings(Map<String, Object?> theme) => {...theme}..remove('settings');

/// Adds [theme] to the themes to choose from, and says which id it has: its
/// own, unless that belongs to a built-in theme or a different imported one.
Future<String> addImportedTheme(ProviderContainer c, Map<String, Object?> theme) async {
  final added = await c.read(importedThemesProvider.future);
  final bare = _withoutSettings(theme);
  final id = theme['id'] as String;
  final same = added.where((t) => t['id'] == id).firstOrNull;
  // The same theme again, or a new version of an imported one: replaced.
  if (same != null) {
    await c.read(importedThemesProvider.notifier).add(bare);
    return id;
  }
  final taken = {for (final t in c.read(availableThemesProvider)) t['id']};
  if (!taken.contains(id)) {
    await c.read(importedThemesProvider.notifier).add(bare);
    return id;
  }
  // A built-in theme's id: a copy, under its own.
  var n = 2;
  while (taken.contains('$id-$n')) {
    n++;
  }
  final copy = '$id-$n';
  await c.read(importedThemesProvider.notifier).add({...bare, 'id': copy, 'name': '${theme['name']} (imported)'});
  return copy;
}

/// What the settings carried in a theme file would change here.
Future<void> applyThemeSettings(ProviderContainer c, Map<String, Object?> theme) async {
  final settings = theme['settings'];
  if (settings is! Map) return;
  final appearance = settings['appearance'];
  if (appearance is Map) {
    T pick<T extends Enum>(List<T> values, String key, T current) =>
        values.where((v) => v.name == appearance[key]).firstOrNull ?? current;
    final now = await c.read(appearanceProvider.future);
    final strength = appearance['artworkStrength'];
    await c.read(appearanceProvider.notifier).save(
          now.copyWith(
            accent: pick(AccentColor.values, 'accent', now.accent),
            background: pick(AppBackground.values, 'background', now.background),
            cardSize: pick(CardSize.values, 'cardSize', now.cardSize),
            rowStyle: pick(RowStyle.values, 'rowStyle', now.rowStyle),
            effects: pick(EffectsLevel.values, 'effects', now.effects),
            animations: appearance['animations'] is bool ? appearance['animations'] as bool : now.animations,
            artworkStrength: strength is num ? strength.toDouble().clamp(0.1, 0.6) : now.artworkStrength,
          ),
        );
  }
  final bar = settings['topBar'];
  if (bar is Map) {
    List<String>? list(Object? v) => v is List ? [for (final e in v) if (e is String) e] : null;
    await c.read(homeBarSettingsProvider.notifier).replaceWith(centre: list(bar['centre']), right: list(bar['right']));
  }
}

/// The active theme as a file, with this device's look and top bar.
Future<String> exportThemeFile(ProviderContainer c) async {
  final id = c.read(activeThemeProvider).id;
  final theme = c.read(availableThemesProvider).firstWhere((t) => t['id'] == id);
  final appearance = await c.read(appearanceProvider.future);
  final bar = await c.read(homeBarSettingsProvider.future);
  return const JsonEncoder.withIndent('  ').convert({
    ...theme,
    'settings': {
      'appearance': {
        'accent': appearance.accent.name,
        'background': appearance.background.name,
        'cardSize': appearance.cardSize.name,
        'rowStyle': appearance.rowStyle.name,
        'effects': appearance.effects.name,
        'animations': appearance.animations,
        'artworkStrength': appearance.artworkStrength,
      },
      'topBar': {'centre': bar.centre, 'right': bar.right},
    },
  });
}

const _device = MethodChannel('jellyfin_client/device');

/// Asks where to save [text], and saves it. False if nothing was saved.
Future<bool> _saveFile(String name, String text) async {
  // file_selector can't choose where to save on Android: the system's own
  // "save as" page, through the app's channel.
  if (Platform.isAndroid) {
    return await _device.invokeMethod<bool>('saveTextFile', {'name': name, 'text': text}) ?? false;
  }
  AppLog.info(LogArea.app, 'Theme export: opening the save picker');
  final location = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: const [_themeFiles],
  );
  if (location == null) return false;
  await File(location.path).writeAsString(text);
  return true;
}

const _themeFiles = XTypeGroup(
  label: 'Theme files',
  extensions: ['json'],
  mimeTypes: ['application/json'],
  uniformTypeIdentifiers: ['public.json'],
);

/// Settings > Appearance: bringing a theme in, taking one out, and removing
/// an imported one. Not on a TV, which has nowhere to pick a file from.
class ThemeFilesSection extends ConsumerWidget {
  const ThemeFilesSection({super.key});

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final id = ref.read(activeThemeProvider).id;
    try {
      if (await _saveFile('$id.theme.json', await exportThemeFile(container))) showToast('Theme saved');
    } on Object catch (e) {
      showToast("Couldn't save the theme: $e");
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context, listen: false);
    // Logged either side, so a picker that never opens shows where it stopped.
    AppLog.info(LogArea.app, 'Theme import: opening the file picker');
    final file = await openFile(acceptedTypeGroups: const [_themeFiles]);
    AppLog.info(LogArea.app, 'Theme import: picker closed, ${file == null ? 'nothing picked' : 'a file picked'}');
    if (file == null) return;
    final Map<String, Object?> theme;
    try {
      theme = parseThemeFile(await file.readAsString());
    } on ThemeFileException catch (e) {
      showToast(e.message);
      return;
    } on Object {
      showToast("Couldn't read that file.");
      return;
    }
    if (!context.mounted) return;
    final answer = await showDialog<_ImportAnswer>(context: context, builder: (_) => _ImportDialog(theme: theme));
    if (answer == null) return;
    await useImportedTheme(container, theme, withSettings: answer.withSettings);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeThemeProvider);
    final imported = ref.watch(importedThemesProvider).value ?? const [];
    final isImported = imported.any((t) => t['id'] == active.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => _import(context, ref),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import a theme'),
          ),
          OutlinedButton.icon(
            onPressed: () => _export(context, ref),
            icon: const Icon(Icons.save_alt),
            label: const Text('Export this theme'),
          ),
          if (isImported)
            OutlinedButton.icon(
              onPressed: () => removeImportedTheme(ProviderScope.containerOf(context, listen: false), active.id),
              icon: const Icon(Icons.delete_outline),
              label: Text('Remove ${active.name}'),
            ),
        ],
      ),
    );
  }
}

/// Adds [theme] and switches to it, offering to go back to the one before.
Future<void> useImportedTheme(ProviderContainer c, Map<String, Object?> theme, {required bool withSettings}) async {
  final choice = await c.read(themeChoiceProvider.future);
  final before = choice.themeId;
  final id = await addImportedTheme(c, theme);
  await c.read(themeChoiceProvider.notifier).save(choice.copyWith(themeId: id));
  if (withSettings) await applyThemeSettings(c, theme);
  showToast(
    'Now using ${theme['name']}',
    actionLabel: 'Undo',
    onAction: () {
      final now = c.read(themeChoiceProvider).value ?? choice;
      c.read(themeChoiceProvider.notifier).save(now.copyWith(themeId: before));
    },
  );
}

/// Removes an imported theme; if it's in use, back to Classic.
Future<void> removeImportedTheme(ProviderContainer c, String id) async {
  AppLog.info(LogArea.app, 'Theme: removing the imported $id');
  final choice = await c.read(themeChoiceProvider.future);
  if (choice.themeId == id) await c.read(themeChoiceProvider.notifier).save(choice.copyWith(themeId: 'classic'));
  await c.read(importedThemesProvider.notifier).remove(id);
}

class _ImportAnswer {
  const _ImportAnswer({required this.withSettings});

  final bool withSettings;
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.theme});

  final Map<String, Object?> theme;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  bool _withSettings = true;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final author = theme['author'];
    final description = theme['description'];
    final hasSettings = theme['settings'] is Map;
    return AlertDialog(
      title: Text('Use ${theme['name']}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (author is String && author.isNotEmpty) Text('By $author'),
          if (description is String && description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(description)),
          if (hasSettings)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also use its look and top bar'),
              subtitle: const Text('Accent, background, card size, Effects and what\'s on the top bar. Off: only the theme.'),
              value: _withSettings,
              onChanged: (v) => setState(() => _withSettings = v ?? false),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ImportAnswer(withSettings: hasSettings && _withSettings)),
          child: const Text('Use it'),
        ),
      ],
    );
  }
}
