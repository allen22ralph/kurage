import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_dropdown.dart';
import '../app/toast.dart';
import 'fonts.dart';
import 'theme_choice.dart';
import 'theme_files.dart';
import 'theme_spec.dart';

/// Settings > Appearance: the theme, and the font over the theme's.
class ThemeSection extends ConsumerWidget {
  const ThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(themeChoiceProvider).value ?? ThemeChoice();
    final controller = ref.read(themeChoiceProvider.notifier);
    final active = ref.watch(activeThemeProvider);
    final themes = ref.watch(availableThemesProvider);
    final device = ref.watch(themeDeviceProvider);
    final added = ref.watch(addedFontsProvider).value?.keys.toSet();
    String name(FontRef f) => _name(f, google: choice.googleFonts, added: added);
    return Column(
      children: [
        ListTile(
          title: const Text('Theme'),
          subtitle: Text(
            [
              if (active.description.isNotEmpty) active.description,
              if (active.author.isNotEmpty && active.id != 'classic') 'By ${active.author}',
            ].join('\n'),
          ),
          trailing: AppDropdown<String>(
            value: active.id,
            underline: const SizedBox.shrink(),
            items: [
              for (final t in themes)
                DropdownMenuItem(
                  value: t['id'] as String,
                  child: Text(ThemeSpec.fromJson(t, device: device).name),
                ),
            ],
            onChanged: (id) => id == null ? null : controller.save(choice.copyWith(themeId: id)),
          ),
        ),
        if (device != ThemeDevice.tv) const ThemeFilesSection(),
        ListTile(
          title: const Text('Font'),
          subtitle: Text(switch (choice.font) {
            null => "The theme's own (${name(active.tokens.uiFont)})",
            final f => name(f),
          }),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showDialog<_FontPick>(
              context: context,
              builder: (_) => _FontPicker(google: choice.googleFonts),
            );
            if (picked != null) await controller.save(choice.copyWith(font: () => picked.font));
          },
        ),
        SwitchListTile(
          title: const Text('Google Fonts'),
          subtitle: const Text(
            "A font from Google's library is downloaded from Google when it's first used, which shows Google "
            "this device's IP address. Off: Google is never contacted for fonts, and those fonts show in the "
            "device's own.",
          ),
          value: choice.googleFonts,
          onChanged: (on) => controller.save(choice.copyWith(googleFonts: on)),
        ),
      ],
    );
  }
}

/// [f]'s name, or what shows instead: a Google font with Google Fonts off,
/// or a font that's no longer here (an added one deleted). [added] null:
/// not loaded yet.
String _name(FontRef f, {required bool google, Set<String>? added}) => switch (f.family) {
  null => "Device's own",
  final family when added?.contains(family) ?? false => family,
  final family when isGoogleFont(family) => google ? family : "$family: Google Fonts is off, so the device's own",
  final family when added == null => family,
  final family => "$family: not on this device, so the device's own",
};

/// What the font picker returns: null [font] is "the theme's own".
class _FontPick {
  const _FontPick(this.font);

  final FontRef? font;
}

class _FontPicker extends ConsumerStatefulWidget {
  const _FontPicker({required this.google});

  /// Google Fonts is on: they're listed and can be searched.
  final bool google;

  @override
  ConsumerState<_FontPicker> createState() => _FontPickerState();
}

class _FontPickerState extends ConsumerState<_FontPicker> {
  final _search = TextEditingController();
  late final List<String> _google = googleFontFamilies;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _addFile() async {
    const fonts = XTypeGroup(label: 'Fonts', extensions: ['ttf', 'otf']);
    final file = await openFile(acceptedTypeGroups: const [fonts]);
    if (file == null) return;
    try {
      final family = await ref
          .read(addedFontsProvider.notifier)
          .add(fileName: file.name, bytes: await file.readAsBytes());
      if (mounted) Navigator.pop(context, _FontPick(FontRef(family)));
    } on Object catch (e) {
      showToast("Couldn't add that font: ${e is FormatException ? e.message : e}");
    }
  }

  /// Deletes an added font; if it's the one in use, back to the theme's own.
  Future<void> _remove(String family) async {
    await ref.read(addedFontsProvider.notifier).remove(family);
    final choice = ref.read(themeChoiceProvider).value;
    if (choice != null && choice.font == FontRef(family)) {
      await ref.read(themeChoiceProvider.notifier).save(choice.copyWith(font: () => null));
    }
  }

  @override
  Widget build(BuildContext context) {
    final added = ref.watch(addedFontsProvider).value?.keys.toList() ?? const [];
    // Live: deleting the font in use changes it while the picker is open.
    final current = ref.watch(themeChoiceProvider).value?.font;
    final q = _query.toLowerCase();
    final google = [
      if (widget.google)
        for (final f in _google)
          if (q.isEmpty || f.toLowerCase().contains(q)) f,
    ];
    final theme = Theme.of(context);
    Widget option(String label, FontRef? font, {Widget? trailing, String? subtitle}) {
      final selected = font == current;
      return ListTile(
        dense: true,
        selected: selected,
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        title: Text(label),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: trailing,
        onTap: () => Navigator.pop(context, _FontPick(font)),
      );
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );

    return AlertDialog(
      title: const Text('Font'),
      contentPadding: const EdgeInsets.only(top: 8),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          children: [
            if (widget.google)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search Google Fonts'),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  if (q.isEmpty)
                    SliverList.list(
                      children: [
                        option("The theme's own", null),
                        option("Device's own", const FontRef.system()),
                        heading('Added'),
                        for (final f in added)
                          option(
                            f,
                            FontRef(f),
                            trailing: IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _remove(f),
                            ),
                          ),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.add),
                          title: const Text('Add a font file…'),
                          subtitle: const Text('A .ttf or .otf file; add each weight (Regular, Bold…) the same way'),
                          onTap: _addFile,
                        ),
                        heading('Google Fonts'),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                          child: Text(
                            widget.google
                                ? "Downloaded from Google's servers when chosen (Google sees this device's IP "
                                      'address), then kept on this device. Turn Google Fonts off in Appearance.'
                                : 'Off in Settings > Appearance, so Google is never contacted for fonts.',
                          ),
                        ),
                      ],
                    ),
                  SliverList.builder(
                    itemCount: google.length,
                    itemBuilder: (context, i) => option(google[i], FontRef(google[i])),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}
