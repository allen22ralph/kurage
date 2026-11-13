import 'package:flutter/material.dart';

/// The schema this app reads. A theme for a newer schema still loads: what
/// this app doesn't know is ignored, and anything missing or invalid falls
/// back to Classic's value.
const themeSchema = 1;

/// The device a theme is shown on: a theme can set values for each one on
/// top of its shared values (`devices.phone`, `devices.tv`, `devices.desktop`).
enum ThemeDevice { phone, tv, desktop }

/// The parts of Settings > Appearance a theme lets people change. Classic
/// allows them all; a theme with its own palette might not allow accent.
enum Adjustable { accent, background, cardSize, rowStyle }

/// A theme: data only (colours, fonts, shapes, which component styles and
/// what layout), so a shared theme can't run code. Read from a JSON file:
///
/// ```json
/// {"schema": 1, "id": "depth", "name": "Depth", "author": "…", "version": "1.0.0",
///  "tokens": {"colors": {"background": "#06070b", "accent": "#8f84ff"}, …},
///  "components": {"header": {"variant": "pills"}},
///  "layout": {"home": ["continueWatching", "nextUp"]},
///  "devices": {"tv": {"tokens": {"radius": {"card": 20}}}}}
/// ```
class ThemeSpec {
  const ThemeSpec({
    required this.id,
    required this.name,
    this.author = '',
    this.version = '1.0.0',
    this.description = '',
    required this.tokens,
    this.adjustable = const {...Adjustable.values},
    this.components = const {},
    this.layout = const {},
  });

  final String id;
  final String name;
  final String author;
  final String version;
  final String description;
  final ThemeTokens tokens;
  final Set<Adjustable> adjustable;

  /// Per component: its variant and parameters (`{"variant": "deck", "depth": 150}`).
  /// Components without an entry use their default (Classic's) style.
  final Map<String, Map<String, Object?>> components;

  /// Which sections a screen shows, in order (`{"home": [...]}`).
  final Map<String, List<String>> layout;

  /// The theme for [device]: its shared values with that device's on top.
  /// [fallback] fills in anything the theme leaves out (Classic).
  static ThemeSpec fromJson(Map<String, Object?> json, {required ThemeDevice device, ThemeSpec? fallback}) {
    final merged = deepMerge(json, _map(_map(json['devices'])[device.name]));
    final base = fallback ?? classicTheme;
    final adjustable = merged['adjustable'];
    return ThemeSpec(
      id: _string(merged['id']) ?? base.id,
      name: _string(merged['name']) ?? base.name,
      author: _string(merged['author']) ?? '',
      version: _string(merged['version']) ?? '1.0.0',
      description: _string(merged['description']) ?? '',
      tokens: ThemeTokens.fromJson(_map(merged['tokens']), base.tokens),
      adjustable: adjustable is List
          ? {for (final a in adjustable) ?Adjustable.values.where((v) => v.name == a).firstOrNull}
          : base.adjustable,
      components: {
        for (final e in _map(merged['components']).entries)
          if (e.value is Map) e.key: (e.value as Map).cast<String, Object?>(),
      },
      layout: {
        for (final e in _map(merged['layout']).entries)
          if (e.value is List) e.key: [for (final s in e.value as List) if (s is String) s],
      },
    );
  }

  /// [a] with [b] on top: maps merge key by key, anything else is replaced.
  static Map<String, Object?> deepMerge(Map<String, Object?> a, Map<String, Object?> b) => {
        ...a,
        for (final e in b.entries)
          e.key: e.value is Map && a[e.key] is Map ? deepMerge(_map(a[e.key]), _map(e.value)) : e.value,
      };
}

/// The look: colours, fonts, shapes, glass, motion.
class ThemeTokens {
  const ThemeTokens({
    required this.background,
    this.backgroundGlow,
    this.surface,
    this.text,
    this.textMuted,
    this.accent,
    this.accent2,
    this.star = const Color(0xFFFFC107),
    this.status = const StatusColors(),
    this.displayFont = const FontRef.system(),
    this.uiFont = const FontRef.system(),
    this.radius = const Radii(),
    this.glass = const Glass(),
    this.motionSpeed = 1,
  });

  final Color background;

  /// A soft colour at the top of the page, fading into [background].
  final Color? backgroundGlow;

  /// Cards and panels; null: from the accent (Material's own).
  final Color? surface;
  final Color? text;
  final Color? textMuted;

  /// Null: the accent chosen in Settings > Appearance.
  final Color? accent;

  /// A second accent (Depth's cyan); null: from the accent.
  final Color? accent2;

  /// Rating stars (MyAnimeList scores).
  final Color star;
  final StatusColors status;
  final FontRef displayFont;
  final FontRef uiFont;
  final Radii radius;
  final Glass glass;

  /// Animation speed: 1 normal, 0.5 twice as slow.
  final double motionSpeed;

  factory ThemeTokens.fromJson(Map<String, Object?> json, ThemeTokens base) {
    final colors = _map(json['colors']);
    final fonts = _map(json['fonts']);
    Color? color(String key, Color? fallback) =>
        colors.containsKey(key) ? (colors[key] == null ? null : parseColor(colors[key]) ?? fallback) : fallback;
    return ThemeTokens(
      background: color('background', base.background) ?? base.background,
      backgroundGlow: color('backgroundGlow', base.backgroundGlow),
      surface: color('surface', base.surface),
      text: color('text', base.text),
      textMuted: color('textMuted', base.textMuted),
      accent: color('accent', base.accent),
      accent2: color('accent2', base.accent2),
      star: color('star', base.star) ?? base.star,
      status: StatusColors.fromJson(_map(colors['status']), base.status),
      displayFont: FontRef.fromJson(fonts['display']) ?? base.displayFont,
      uiFont: FontRef.fromJson(fonts['ui']) ?? base.uiFont,
      radius: Radii.fromJson(_map(json['radius']), base.radius),
      glass: Glass.fromJson(_map(json['glass']), base.glass),
      motionSpeed: _number(_map(json['motion'])['speed'])?.clamp(0.25, 4) ?? base.motionSpeed,
    );
  }
}

/// Request and availability colours (Seerr).
class StatusColors {
  const StatusColors({
    this.available = const Color(0xFF2E7D32),
    this.partiallyAvailable = const Color(0xFF558B2F),
    this.processing = const Color(0xFF1565C0),
    this.pending = const Color(0xFFEF6C00),
    this.blocked = const Color(0xFFC62828),
  });

  final Color available;
  final Color partiallyAvailable;
  final Color processing;
  final Color pending;
  final Color blocked;

  factory StatusColors.fromJson(Map<String, Object?> json, StatusColors base) => StatusColors(
        available: parseColor(json['available']) ?? base.available,
        partiallyAvailable: parseColor(json['partiallyAvailable']) ?? base.partiallyAvailable,
        processing: parseColor(json['processing']) ?? base.processing,
        pending: parseColor(json['pending']) ?? base.pending,
        blocked: parseColor(json['blocked']) ?? base.blocked,
      );
}

/// A font by family name: the device's own ("system"), one added in
/// Settings, or any Google Fonts family (downloaded once, then kept).
class FontRef {
  const FontRef(this.family);
  const FontRef.system() : family = null;

  /// Null: the device's own font.
  final String? family;

  bool get isSystem => family == null;

  static FontRef? fromJson(Object? json) {
    final name = json is Map ? json['family'] : json;
    if (name is! String || name.trim().isEmpty) return null;
    return name.trim().toLowerCase() == 'system' ? const FontRef.system() : FontRef(name.trim());
  }

  @override
  bool operator ==(Object other) => other is FontRef && other.family == family;

  @override
  int get hashCode => family.hashCode;
}

class Radii {
  const Radii({this.card = 8, this.panel = 16, this.menu = 12, this.button = 20});

  final double card;
  final double panel;
  final double menu;
  final double button;

  factory Radii.fromJson(Map<String, Object?> json, Radii base) {
    double r(String key, double fallback) => _number(json[key])?.clamp(0, 64) ?? fallback;
    return Radii(
      card: r('card', base.card),
      panel: r('panel', base.panel),
      menu: r('menu', base.menu),
      button: r('button', base.button),
    );
  }
}

/// See-through panels (Depth's "glass"); a blur of 0 is a plain panel.
class Glass {
  const Glass({this.fill = const Color(0x99000000), this.border = const Color(0x1AFFFFFF), this.blur = 0});

  final Color fill;
  final Color border;
  final double blur;

  factory Glass.fromJson(Map<String, Object?> json, Glass base) => Glass(
        fill: parseColor(json['fill']) ?? base.fill,
        border: parseColor(json['border']) ?? base.border,
        blur: _number(json['blur'])?.clamp(0, 60) ?? base.blur,
      );
}

/// `#rgb`, `#rrggbb` or `#rrggbbaa` (CSS order: alpha last), or
/// `rgba(r, g, b, a)`. Null when it isn't a colour.
Color? parseColor(Object? value) {
  if (value is! String) return null;
  final s = value.trim().toLowerCase();
  final rgba = RegExp(r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$').firstMatch(s);
  if (rgba != null) {
    int c(int i) => int.parse(rgba[i]!).clamp(0, 255);
    final a = double.tryParse(rgba[4] ?? '1')?.clamp(0.0, 1.0) ?? 1.0;
    return Color.fromARGB((a * 255).round(), c(1), c(2), c(3));
  }
  if (!s.startsWith('#')) return null;
  var hex = s.substring(1);
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  if (hex.length != 6 && hex.length != 8) return null;
  final v = int.tryParse(hex, radix: 16);
  if (v == null) return null;
  return hex.length == 6 ? Color(0xFF000000 | v) : Color(((v & 0xFF) << 24) | (v >> 8));
}

Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
String? _string(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
double? _number(Object? v) => v is num ? v.toDouble() : null;

/// The built-in look the app has always had. Its values are the fallback for
/// anything another theme leaves out.
const classicTheme = ThemeSpec(
  id: 'classic',
  name: 'Classic',
  author: 'Kurage',
  description: 'The look the app has always had: your accent colour, rows of cards.',
  tokens: ThemeTokens(background: Color(0xFF101114)),
);
