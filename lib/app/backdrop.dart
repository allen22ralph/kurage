import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jellyfin/items.dart';
import '../features/library/widgets/item_image.dart';
import '../features/settings/appearance.dart';
import '../theme/app_tokens.dart';
import '../theme/components.dart';
import 'glow_backdrop.dart';

/// The artwork behind Home and show pages when Appearance > Background is
/// "Show artwork": the show last focused or under the mouse (#99).
class BackdropArt {
  BackdropArt._();

  static final current = ValueNotifier<ImageRef?>(null);

  /// [item]'s artwork becomes the background (when that background is on;
  /// otherwise nothing happens).
  static void show(BaseItem item, ProviderContainer container) {
    if (container.read(appearanceProvider).value?.background != AppBackground.artwork &&
        !_themed(container.read(componentStyleProvider(Slots.backdrop)))) {
      return;
    }
    final art = item.backdropImage ?? item.landscapeImage ?? item.posterImage;
    if (art != null) current.value = art;
  }
}

/// The theme draws the page's background itself (Depth's glow).
bool _themed(ComponentStyle style) => style.variant == 'glow';

/// Puts [child] (a page with a transparent [Scaffold], see [pageColor]) over
/// the blurred, dimmed artwork when that background is chosen; otherwise
/// just [child].
class ArtworkBackground extends ConsumerWidget {
  const ArtworkBackground({super.key, required this.child});

  final Widget child;

  /// A page's Scaffold colour: see-through over the artwork, else the
  /// theme's.
  static Color? pageColor(WidgetRef ref) =>
      ref.watch(appearanceProvider).value?.background == AppBackground.artwork ||
          _themed(ref.watch(componentStyleProvider(Slots.backdrop)))
      ? Colors.transparent
      : null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(componentStyleProvider(Slots.backdrop));
    if (_themed(style)) {
      // Pages are see-through under a theme's backdrop: on Lite, plain colour.
      if (effectsOf(context) == EffectsLevel.lite) return ColoredBox(color: context.tokens.background, child: child);
      return GlowBackdrop(style: style, art: BackdropArt.current, child: child);
    }
    final settings = ref.watch(appearanceProvider).value;
    if (settings?.background != AppBackground.artwork) return child;
    final base = context.tokens.background;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        ValueListenableBuilder<ImageRef?>(
          valueListenable: BackdropArt.current,
          builder: (context, art, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 700),
            // Full size while fading (the default lays out at the image's own
            // size: a small picture in the middle).
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              children: [...previous, ?current],
            ),
            child: art == null
                ? const SizedBox.expand()
                : KeyedSubtree(
                    key: ValueKey('${art.itemId}/${art.tag}'),
                    // Small and blurred: cheap, and it's only a mood.
                    child: SizedBox.expand(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28, tileMode: TileMode.clamp),
                        child: ItemImage(image: art, maxWidth: 320),
                      ),
                    ),
                  ),
          ),
        ),
        ColoredBox(color: base.withValues(alpha: 1 - settings!.artworkStrength)),
        child,
      ],
    );
  }
}
