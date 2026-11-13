import 'package:flutter/material.dart';

import '../../app/animations.dart';
import '../../app/theme.dart';
import 'appearance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/app_tokens.dart';
import '../../theme/fonts.dart';
import '../../theme/theme_choice.dart';
import '../../theme/theme_spec.dart';

/// A small Home in Settings > Appearance (#99): a top bar, a row of cards in
/// the chosen size, an accent button and the background, drawn with the
/// chosen settings and played again on every change.
class AppearancePreview extends ConsumerWidget {
  const AppearancePreview({super.key, required this.settings});

  final AppearanceSettings settings;

  static const _card = 64.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = buildTheme(
      settings,
      ref.watch(activeThemeProvider),
      ref.watch(themeChoiceProvider.select((c) => c.value?.font)),
      ref.watch(addedFontsProvider.select((f) => f.value?.keys.toSet() ?? const <String>{})),
    );
    final pageBase = theme.extension<AppTokens>()?.tokens.background ?? classicTheme.tokens.background;
    final colors = theme.colorScheme;
    final cardWidth = _card * settings.cardSize.scale;
    final background = switch (settings.background) {
      AppBackground.artwork => null,
      _ => theme.scaffoldBackgroundColor,
    };
    return Theme(
      data: theme,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 200,
          decoration: BoxDecoration(
            color: background,
            // Show artwork: a stand-in "show" in the accent colour, blurred
            // and dimmed as the real one is.
            gradient: background != null
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(pageBase, settings.accent.color, settings.artworkStrength)!,
                      Color.lerp(pageBase, Colors.deepOrange, settings.artworkStrength * 0.6)!,
                    ],
                  ),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top bar
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Row(
                  children: [
                    Icon(Icons.dns_outlined, size: 16, color: colors.primary),
                    const SizedBox(width: 6),
                    Text('Your server', style: theme.textTheme.labelLarge?.copyWith(color: colors.onSurface)),
                    const Spacer(),
                    for (final icon in const [Icons.search, Icons.notifications_none, Icons.settings_outlined])
                      Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Icon(icon, size: 16, color: colors.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Row(
                  children: [
                    Text('Continue watching', style: theme.textTheme.titleSmall?.copyWith(color: colors.onSurface)),
                    const Spacer(),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () {},
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('Play'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  // Replays the row's entrance whenever a setting changes.
                  key: ValueKey(settings.signature),
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  itemCount: 8,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Entrance(
                    index: i,
                    child: SizedBox(
                      width: cardWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  // Bright enough to read as posters on any background.
                                  colors: [
                                    Color.lerp(colors.primary, colors.tertiary, i / 8)!.withValues(alpha: 0.85),
                                    colors.primaryContainer,
                                  ],
                                ),
                              ),
                              // A DecoratedBox without a child is 0 wide here.
                              child: const SizedBox.expand(),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 6,
                            width: cardWidth * 0.7,
                            decoration: BoxDecoration(
                              color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
