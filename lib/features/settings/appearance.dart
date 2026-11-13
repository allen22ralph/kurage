import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appearance_preview.dart';
import '../../app/app_dropdown.dart';
import '../../theme/theme_choice.dart';
import '../../theme/theme_settings.dart';
import '../../theme/theme_spec.dart';

/// The app's accent colour (#91).
enum AccentColor {
  jellyfin('Jellyfin blue', Color(0xFF00A4DC)),
  purple('Purple', Color(0xFF9B6BDF)),
  teal('Teal', Color(0xFF14B8A6)),
  green('Green', Color(0xFF4CAF50)),
  orange('Orange', Color(0xFFFF9800)),
  pink('Pink', Color(0xFFE91E63)),
  red('Red', Color(0xFFE53935));

  const AccentColor(this.label, this.color);

  final String label;
  final Color color;
}

enum AppBackground {
  dark('Dark'),
  black('Black (OLED)'),

  /// Dark with a hint of the accent colour.
  tinted('Tinted'),

  /// The focused / hovered show's artwork, dimmed and blurred, behind Home
  /// and show pages.
  artwork('Show artwork');

  const AppBackground(this.label);

  final String label;
}

enum CardSize {
  small('Small', 0.85),
  medium('Medium', 1),
  large('Large', 1.18);

  const CardSize(this.label, this.scale);

  final String label;

  /// Card widths are multiplied by this.
  final double scale;
}

/// How Home's rows move.
enum RowStyle {
  classic('Classic', 'Rows scroll sideways freely'),
  paged('Paged', 'Rows move a page at a time with ‹ › by their titles; cards lean as they go');

  const RowStyle(this.label, this.description);

  final String label;
  final String description;
}

/// How much of a theme's motion to draw (Settings > Appearance), for slower
/// devices.
enum EffectsLevel {
  full('Full', "All of the theme's effects"),
  balanced('Balanced', 'No sections rolling in, and no previews in rows'),
  lite('Lite', 'Also no header trailers, no artwork behind the page, and no 3D card motion');

  const EffectsLevel(this.label, this.description);

  final String label;
  final String description;

  /// Home's rows may play previews.
  bool get playsPreviews => this == full;

  /// The header may play trailers.
  bool get playsTrailers => this != lite;
}

class AppearanceSettings {
  const AppearanceSettings({
    this.accent = AccentColor.jellyfin,
    this.background = AppBackground.dark,
    this.cardSize = CardSize.medium,
    this.animations = true,
    this.artworkStrength = 0.35,
    this.rowStyle = RowStyle.classic,
    this.effects = EffectsLevel.full,
  });

  final AccentColor accent;
  final AppBackground background;
  final CardSize cardSize;

  /// Rows sliding in, placeholder pulses, cards growing under the mouse.
  final bool animations;

  /// How much of the show artwork shows through (0.1 faint – 0.6 strong).
  final double artworkStrength;

  final RowStyle rowStyle;
  final EffectsLevel effects;

  AppearanceSettings copyWith({
    AccentColor? accent,
    AppBackground? background,
    CardSize? cardSize,
    bool? animations,
    double? artworkStrength,
    RowStyle? rowStyle,
    EffectsLevel? effects,
  }) =>
      AppearanceSettings(
        accent: accent ?? this.accent,
        background: background ?? this.background,
        cardSize: cardSize ?? this.cardSize,
        animations: animations ?? this.animations,
        artworkStrength: artworkStrength ?? this.artworkStrength,
        rowStyle: rowStyle ?? this.rowStyle,
        effects: effects ?? this.effects,
      );

  /// Changes whenever anything shown changes (the preview replays then).
  String get signature => '${accent.name}/${background.name}/${cardSize.name}/$animations/$artworkStrength/${rowStyle.name}';
}

final appearanceProvider = AsyncNotifierProvider<AppearanceController, AppearanceSettings>(AppearanceController.new);

class AppearanceController extends AsyncNotifier<AppearanceSettings> {
  static const _prefix = 'appearance.';

  static T _parse<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  @override
  Future<AppearanceSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    const d = AppearanceSettings();
    return AppearanceSettings(
      accent: _parse(AccentColor.values, prefs.getString('${_prefix}accent'), d.accent),
      background: _parse(AppBackground.values, prefs.getString('${_prefix}background'), d.background),
      cardSize: _parse(CardSize.values, prefs.getString('${_prefix}cardSize'), d.cardSize),
      animations: prefs.getBool('${_prefix}animations') ?? d.animations,
      artworkStrength: prefs.getDouble('${_prefix}artworkStrength') ?? d.artworkStrength,
      rowStyle: _parse(RowStyle.values, prefs.getString('${_prefix}rowStyle'), d.rowStyle),
      effects: _parse(EffectsLevel.values, prefs.getString('${_prefix}effects'), d.effects),
    );
  }

  Future<void> save(AppearanceSettings settings) async {
    // After the stored settings have loaded (or they'd overwrite this).
    await future.catchError((Object _) => const AppearanceSettings());
    state = AsyncData(settings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}accent', settings.accent.name);
    await prefs.setString('${_prefix}background', settings.background.name);
    await prefs.setString('${_prefix}cardSize', settings.cardSize.name);
    await prefs.setBool('${_prefix}animations', settings.animations);
    await prefs.setDouble('${_prefix}artworkStrength', settings.artworkStrength);
    await prefs.setString('${_prefix}rowStyle', settings.rowStyle.name);
    await prefs.setString('${_prefix}effects', settings.effects.name);
  }
}

/// The effects in use below it: what's chosen, or Lite if the system asks for
/// less motion. So that a change reaches what's already on screen.
class EffectsScope extends InheritedWidget {
  const EffectsScope({super.key, required this.level, required super.child});

  final EffectsLevel level;

  @override
  bool updateShouldNotify(EffectsScope oldWidget) => level != oldWidget.level;
}

/// The effects to draw here.
EffectsLevel effectsOf(BuildContext context) {
  final scope = context.dependOnInheritedWidgetOfExactType<EffectsScope>();
  if (scope != null) return scope.level;
  if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return EffectsLevel.lite;
  return ProviderScope.containerOf(context, listen: false).read(appearanceProvider).value?.effects ?? EffectsLevel.full;
}

/// Multiplies a 3D turn: 0 on Lite, which has none.
double depthOf(BuildContext context) => effectsOf(context) == EffectsLevel.lite ? 0 : 1;

/// Whether to animate here: the setting, unless the system asks for less
/// motion.
bool animationsOn(BuildContext context) {
  if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return false;
  return ProviderScope.containerOf(context, listen: false).read(appearanceProvider).value?.animations ?? true;
}

/// Settings > Appearance.
class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appearanceProvider).value ?? const AppearanceSettings();
    final controller = ref.read(appearanceProvider.notifier);
    final theme = Theme.of(context);
    // Only what the active theme lets people change (Classic: everything).
    final adjustable = ref.watch(activeThemeProvider.select((t) => t.adjustable));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: AppearancePreview(settings: value),
        ),
        const ThemeSection(),
        if (adjustable.contains(Adjustable.accent)) ...[
        ListTile(
          title: const Text('Accent colour'),
          subtitle: Text(value.accent.label),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final a in AccentColor.values)
                Tooltip(
                  message: a.label,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => controller.save(value.copyWith(accent: a)),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: a.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: a == value.accent ? theme.colorScheme.onSurface : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: a == value.accent ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
        ],
        if (adjustable.contains(Adjustable.background)) ...[
        ListTile(
          title: const Text('Background'),
          trailing: AppDropdown<AppBackground>(
            value: value.background,
            underline: const SizedBox.shrink(),
            items: [for (final b in AppBackground.values) DropdownMenuItem(value: b, child: Text(b.label))],
            onChanged: (b) => b == null ? null : controller.save(value.copyWith(background: b)),
          ),
        ),
        if (value.background == AppBackground.artwork)
          ListTile(
            title: const Text('Artwork strength'),
            subtitle: Slider(
              value: value.artworkStrength,
              min: 0.1,
              max: 0.6,
              divisions: 10,
              label: '${(value.artworkStrength * 100).round()} %',
              onChanged: (v) => controller.save(value.copyWith(artworkStrength: v)),
            ),
          ),
        ],
        if (adjustable.contains(Adjustable.cardSize))
        ListTile(
          title: const Text('Card size'),
          subtitle: const Text('Posters and thumbnails on Home and in libraries'),
          trailing: SegmentedButton<CardSize>(
            showSelectedIcon: false,
            segments: [for (final s in CardSize.values) ButtonSegment(value: s, label: Text(s.label))],
            selected: {value.cardSize},
            onSelectionChanged: (s) => controller.save(value.copyWith(cardSize: s.first)),
          ),
        ),
        if (adjustable.contains(Adjustable.rowStyle))
        ListTile(
          title: const Text('Rows'),
          subtitle: Text(value.rowStyle.description),
          trailing: SegmentedButton<RowStyle>(
            showSelectedIcon: false,
            segments: [for (final r in RowStyle.values) ButtonSegment(value: r, label: Text(r.label))],
            selected: {value.rowStyle},
            onSelectionChanged: (r) => controller.save(value.copyWith(rowStyle: r.first)),
          ),
        ),
        SwitchListTile(
          title: const Text('Animations'),
          subtitle: Text(
            'Rows sliding in, loading placeholders, cards growing under the mouse'
            '${ref.watch(activeThemeProvider).components.isNotEmpty ? '. Effects on Lite also removes 3D motion' : ''}',
          ),
          value: value.animations,
          onChanged: (v) => controller.save(value.copyWith(animations: v)),
        ),
        // (Classic has none of these effects.)
        if (ref.watch(activeThemeProvider).id != 'classic')
          ListTile(
            title: const Text('Effects'),
            subtitle: Text(
              MediaQuery.disableAnimationsOf(context)
                  ? 'Lite, as your device asks for less motion'
                  : value.effects.description,
            ),
            trailing: AppDropdown<EffectsLevel>(
              value: value.effects,
              underline: const SizedBox.shrink(),
              items: [for (final e in EffectsLevel.values) DropdownMenuItem(value: e, child: Text(e.label))],
              onChanged: (e) {
                if (e != null) controller.save(value.copyWith(effects: e));
              },
            ),
          ),
      ],
    );
  }
}
