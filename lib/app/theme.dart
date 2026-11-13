import 'package:flutter/material.dart';
import '../features/settings/appearance.dart';
import '../theme/app_tokens.dart';
import '../theme/fonts.dart';
import '../theme/theme_spec.dart';

/// Jellyfin's brand blue.
const brandColor = Color(0xFF00A4DC);

/// Dark-only theme: this is a media app, mostly used in dim rooms and on TVs.
/// The look comes from [theme] (Classic unless another is chosen), adjusted
/// by Settings > Appearance where the theme allows it (accent, background).
/// [font] replaces the theme's fonts; [addedFonts] are font files added in
/// Settings; [googleFonts] off keeps Google fonts from being fetched.
ThemeData buildTheme([
  AppearanceSettings appearance = const AppearanceSettings(),
  ThemeSpec theme = classicTheme,
  FontRef? font,
  Set<String> addedFonts = const {},
  bool googleFonts = true,
]) {
  final t = theme.tokens;
  final accent = theme.adjustable.contains(Adjustable.accent) || t.accent == null ? appearance.accent.color : t.accent!;
  final background = theme.adjustable.contains(Adjustable.background) ? appearance.background : AppBackground.dark;
  final black = background == AppBackground.black;
  var colors = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark);
  colors = colors.copyWith(
    surface: t.surface,
    onSurface: t.text,
    onSurfaceVariant: t.textMuted,
    secondary: t.accent2,
  );
  // OLED: true black behind everything, so the screen's pixels are off.
  if (black) colors = colors.copyWith(surface: Colors.black, surfaceContainerLowest: Colors.black);
  // Tinted: the dark background with a hint of the accent colour.
  final tint = background == AppBackground.tinted ? Color.alphaBlend(accent.withValues(alpha: 0.09), t.background) : null;
  if (tint != null) colors = colors.copyWith(surface: tint);
  final page = black ? Colors.black : (tint ?? t.background);
  final base = ThemeData(colorScheme: colors, brightness: Brightness.dark).textTheme;
  return ThemeData(
    colorScheme: colors,
    scaffoldBackgroundColor: page,
    textTheme: themeFonts(
      base,
      display: font ?? t.displayFont,
      ui: font ?? t.uiFont,
      added: addedFonts,
      google: googleFonts,
    ),
    // Focus must be obvious from across the room when using a TV remote.
    focusColor: colors.primary.withValues(alpha: 0.24),
    visualDensity: VisualDensity.standard,
    // Rounded like the cards and dialogs: right-click menus, dropdowns.
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius.menu)),
      color: colors.surfaceContainerHigh,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius.menu))),
      ),
    ),
    extensions: [
      AppTokens(ThemeTokens(
        background: page,
        backgroundGlow: t.backgroundGlow,
        surface: t.surface,
        text: t.text,
        textMuted: t.textMuted,
        accent: accent,
        accent2: t.accent2 ?? colors.secondary,
        star: t.star,
        status: t.status,
        displayFont: font ?? t.displayFont,
        uiFont: font ?? t.uiFont,
        radius: t.radius,
        glass: t.glass,
        motionSpeed: t.motionSpeed,
      )),
    ],
  );
}
