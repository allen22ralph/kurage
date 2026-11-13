import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/theme.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:jellyfin_client/theme/app_tokens.dart';
import 'package:jellyfin_client/theme/theme_spec.dart';

/// Depth's values, as its theme file will give them.
const _depth = {
  'schema': 1,
  'id': 'depth',
  'name': 'Depth',
  'author': 'sam',
  'adjustable': ['cardSize'],
  'tokens': {
    'colors': {
      'background': '#06070b',
      'backgroundGlow': '#12142a',
      'surface': '#0e1018',
      'text': '#e8e9f0',
      'textMuted': '#9aa0b2',
      'accent': '#8f84ff',
      'accent2': '#8ee6f5',
      'star': '#ffc94d',
      'status': {'available': '#8ee6f5', 'pending': '#ffc94d'},
    },
    'fonts': {'display': 'Bricolage Grotesque', 'ui': {'family': 'Manrope'}},
    'radius': {'card': 20, 'panel': 30},
    'glass': {'fill': 'rgba(10,11,18,.5)', 'border': 'rgba(255,255,255,.1)', 'blur': 18},
  },
  'components': {
    'hero': {'variant': 'deck', 'depth': 150, 'interval': 9},
  },
  'layout': {
    'home': ['continueWatching', 'nextUp', 'newEpisodes'],
  },
  'devices': {
    'tv': {
      'tokens': {'radius': {'panel': 36}},
      'components': {
        'hero': {'interval': 12},
      },
    },
  },
};

void main() {
  test('colours: hex in CSS order (alpha last) and rgba()', () {
    expect(parseColor('#06070b'), const Color(0xFF06070B));
    expect(parseColor('#fff'), const Color(0xFFFFFFFF));
    expect(parseColor('#ffffff1a'), const Color(0x1AFFFFFF));
    expect(parseColor('rgba(10,11,18,.5)'), const Color.fromARGB(128, 10, 11, 18));
    expect(parseColor('rgb(255, 0, 0)'), const Color(0xFFFF0000));
    expect(parseColor('blue'), isNull);
    expect(parseColor('#12'), isNull);
    expect(parseColor(42), isNull);
  });

  test('a theme file: its values, and its per-device values on top', () {
    final desktop = ThemeSpec.fromJson(_depth, device: ThemeDevice.desktop);
    expect(desktop.name, 'Depth');
    expect(desktop.tokens.background, const Color(0xFF06070B));
    expect(desktop.tokens.accent2, const Color(0xFF8EE6F5));
    expect(desktop.tokens.displayFont.family, 'Bricolage Grotesque');
    expect(desktop.tokens.uiFont.family, 'Manrope');
    expect(desktop.tokens.status.available, const Color(0xFF8EE6F5));
    expect(desktop.tokens.status.blocked, classicTheme.tokens.status.blocked, reason: "Classic's where it's left out");
    expect(desktop.tokens.glass.blur, 18);
    expect(desktop.tokens.radius.panel, 30);
    expect(desktop.components['hero'], {'variant': 'deck', 'depth': 150, 'interval': 9});
    expect(desktop.layout['home'], ['continueWatching', 'nextUp', 'newEpisodes']);
    expect(desktop.adjustable, {Adjustable.cardSize});

    final tv = ThemeSpec.fromJson(_depth, device: ThemeDevice.tv);
    expect(tv.tokens.radius.panel, 36);
    expect(tv.tokens.radius.card, 20, reason: 'shared values stay');
    expect(tv.components['hero'], {'variant': 'deck', 'depth': 150, 'interval': 12});
  });

  test("lenient: wrong or unknown values don't break a theme", () {
    final odd = ThemeSpec.fromJson({
      'id': 'odd',
      'name': 'Odd',
      'futureFeature': {'x': 1},
      'adjustable': ['accent', 'sparkles'],
      'tokens': {
        'colors': {'background': 'not a colour', 'accent': '#ff0000'},
        'fonts': {'display': ''},
        'radius': {'card': 'big', 'menu': 500},
        'motion': {'speed': 99},
      },
      'components': {'hero': 'deck'},
      'layout': {'home': ['nextUp', 3]},
    }, device: ThemeDevice.phone);
    expect(odd.tokens.background, classicTheme.tokens.background);
    expect(odd.tokens.accent, const Color(0xFFFF0000));
    expect(odd.tokens.displayFont.isSystem, isTrue);
    expect(odd.tokens.radius.card, classicTheme.tokens.radius.card);
    expect(odd.tokens.radius.menu, 64, reason: 'clamped');
    expect(odd.tokens.motionSpeed, 4, reason: 'clamped');
    expect(odd.adjustable, {Adjustable.accent});
    expect(odd.components, isEmpty, reason: 'not a map: ignored');
    expect(odd.layout['home'], ['nextUp']);
  });

  test("Classic gives the look the app has always had", () {
    final classic = buildTheme();
    expect(classic.scaffoldBackgroundColor, const Color(0xFF101114));
    expect(classic.colorScheme.primary, ColorScheme.fromSeed(seedColor: AccentColor.jellyfin.color, brightness: Brightness.dark).primary);
    expect(classic.extension<AppTokens>()!.tokens.star, const Color(0xFFFFC107));
    expect(classic.textTheme.bodyMedium?.fontFamily, ThemeData(brightness: Brightness.dark).textTheme.bodyMedium?.fontFamily);
    final menu = classic.popupMenuTheme.shape as RoundedRectangleBorder;
    expect(menu.borderRadius, BorderRadius.circular(12));
  });

  test("a theme's own palette, and what it lets Settings change", () {
    final depth = ThemeSpec.fromJson(_depth, device: ThemeDevice.desktop);
    // Settings say orange and OLED black, but Depth doesn't let them change those.
    final theme = buildTheme(
      const AppearanceSettings(accent: AccentColor.orange, background: AppBackground.black),
      depth,
      // The device's own font here: tests can't download Depth's.
      const FontRef.system(),
    );
    expect(theme.scaffoldBackgroundColor, const Color(0xFF06070B));
    expect(theme.colorScheme.surface, const Color(0xFF0E1018));
    expect(theme.colorScheme.onSurface, const Color(0xFFE8E9F0));
    final tokens = theme.extension<AppTokens>()!.tokens;
    expect(tokens.accent, const Color(0xFF8F84FF));
    expect(tokens.star, const Color(0xFFFFC94D));

    // Classic lets them.
    final classic = buildTheme(const AppearanceSettings(accent: AccentColor.orange, background: AppBackground.black));
    expect(classic.scaffoldBackgroundColor, Colors.black);
    expect(classic.extension<AppTokens>()!.tokens.accent, AccentColor.orange.color);
  });
}
