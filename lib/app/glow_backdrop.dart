import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jellyfin/items.dart';
import '../features/library/widgets/item_image.dart';
import '../features/settings/appearance.dart';
import '../theme/app_tokens.dart';
import '../theme/components.dart';
import 'providers.dart';

/// The main colour of [image]: from a small copy, weighting saturated,
/// mid-bright pixels, its lightness kept between .45 and .60 (so the glow
/// is never black or white). Null when it can't be read.
final artColorProvider = FutureProvider.family<Color?, ImageRef>((ref, image) async {
  final url = ref.watch(signedInApiProvider).imageUrl(image.itemId, image.type, tag: image.tag, maxWidth: 48);
  try {
    final pixels = await ref.watch(imagePixelsProvider)(url.toString());
    return pixels == null ? null : mainColor(pixels);
  } on Object {
    return null;
  }
});

/// Loads an image URL as RGBA bytes (overridden in tests, which have no
/// network images).
final imagePixelsProvider = Provider<Future<List<int>?> Function(String url)>((ref) => (url) async {
      final stream = CachedNetworkImageProvider(url).resolve(ImageConfiguration.empty);
      final done = Completer<ui.Image?>();
      final listener = ImageStreamListener(
        (info, _) => done.complete(info.image),
        onError: (_, _) => done.complete(null),
      );
      stream.addListener(listener);
      final image = await done.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
      stream.removeListener(listener);
      final data = await image?.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data?.buffer.asUint8List();
    });

/// [rgba]'s main colour (see [artColorProvider]).
@visibleForTesting
Color? mainColor(List<int> rgba) {
  double r = 0, g = 0, b = 0, total = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final c = HSLColor.fromColor(Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]));
    // Colourful, neither near black nor near white.
    final weight = c.saturation * (1 - (c.lightness - 0.5).abs() * 2) + 0.01;
    r += rgba[i] * weight;
    g += rgba[i + 1] * weight;
    b += rgba[i + 2] * weight;
    total += weight;
  }
  if (total == 0) return null;
  final hsl = HSLColor.fromColor(Color.fromARGB(255, r ~/ total, g ~/ total, b ~/ total));
  return hsl.withLightness(hsl.lightness.clamp(0.45, 0.60)).toColor();
}

/// Depth's page background ("glow"): the theme's dark page with a soft
/// colour at the top; the focused artwork, heavily blurred; its main colour
/// glowing in from the left, right and bottom, slowly breathing; and a
/// vignette over all of it. The strengths are the style's `glow` and `art`.
class GlowBackdrop extends ConsumerStatefulWidget {
  const GlowBackdrop({super.key, required this.style, required this.art, required this.child});

  final ComponentStyle style;

  /// The focused artwork (BackdropArt.current).
  final ValueNotifier<ImageRef?> art;
  final Widget child;

  @override
  ConsumerState<GlowBackdrop> createState() => _GlowBackdropState();
}

class _GlowBackdropState extends ConsumerState<GlowBackdrop> with SingleTickerProviderStateMixin {
  late final _breath = AnimationController(vsync: this, duration: const Duration(seconds: 14));

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final glow = widget.style.param('glow', 0.18).clamp(0.0, 1.0);
    final artStrength = widget.style.param('art', 0.16).clamp(0.0, 1.0);
    final moving = animationsOn(context);
    if (moving && glow > 0 && !_breath.isAnimating) _breath.repeat(reverse: true);
    if (!moving && _breath.isAnimating) _breath.stop();
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: tokens.background),
        ValueListenableBuilder<ImageRef?>(
          valueListenable: widget.art,
          builder: (context, art, _) {
            // No glow (a PC): the colour isn't worked out at all.
            final color = art == null || glow == 0 ? null : ref.watch(artColorProvider(art)).value;
            return Stack(
              fit: StackFit.expand,
              children: [
                // The artwork itself: only a mood. A small copy the server
                // has already blurred, stretched to fill the page.
                IgnorePointer(child: _ArtLayer(art: art, strength: artStrength, page: tokens.background)),
                if (color != null) _Glow(color: color, strength: glow, breath: _breath),
              ],
            );
          },
        ),
        // The theme's soft colour at the top.
        if (tokens.backgroundGlow case final top?)
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -1.1),
                  radius: 1.2,
                  colors: [top.withValues(alpha: 0.85), top.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        // The vignette: the edges darken back to the page.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.95,
                colors: [tokens.background.withValues(alpha: 0), tokens.background.withValues(alpha: 0.75)],
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// The blurred artwork at [strength]: drawn fully, under a cover in the
/// page's colour (no transparency layers: a full-screen one per frame, and
/// two while crossfading, stuttered on large screens). A new artwork: the
/// cover closes, the picture changes, the cover opens again.
class _ArtLayer extends ConsumerStatefulWidget {
  const _ArtLayer({required this.art, required this.strength, required this.page});

  final ImageRef? art;
  final double strength;
  final Color page;

  @override
  ConsumerState<_ArtLayer> createState() => _ArtLayerState();
}

class _ArtLayerState extends ConsumerState<_ArtLayer> with SingleTickerProviderStateMixin {
  late final _cover = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600), value: 1);
  ImageRef? _shown;

  @override
  void initState() {
    super.initState();
    _change();
  }

  @override
  void didUpdateWidget(_ArtLayer old) {
    super.didUpdateWidget(old);
    if (old.art != widget.art) _change();
  }

  Future<void> _change() async {
    final next = widget.art;
    if (_shown != null) {
      await _cover.animateTo(1, duration: const Duration(milliseconds: 600), curve: Curves.easeIn);
    }
    if (!mounted || widget.art != next) return;
    setState(() => _shown = next);
    if (next != null) await _cover.animateTo(0, duration: const Duration(milliseconds: 1000), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _cover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final art = _shown;
    if (art == null) return const SizedBox.expand();
    return Stack(
      fit: StackFit.expand,
      children: [
        ref.watch(networkImageBuilderProvider)(
          ref
              .watch(signedInApiProvider)
              .imageUrl(art.itemId, art.type, tag: art.tag, maxWidth: 320, quality: 60, blur: 24)
              .toString(),
          fit: BoxFit.cover,
          alignment: Alignment.center,
          fallback: const SizedBox.expand(),
        ),
        AnimatedBuilder(
          animation: _cover,
          builder: (context, _) => ColoredBox(
            // Strength .16: 84% page over the picture, up to all of it.
            color: widget.page.withValues(alpha: 1 - widget.strength * (1 - _cover.value)),
          ),
        ),
      ],
    );
  }
}

/// Three soft blobs of [color]: left, right and bottom, drifting slowly.
class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.strength, required this.breath});

  final Color color;
  final double strength;
  final Animation<double> breath;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    Widget blob(Color c) => TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: c),
          duration: const Duration(milliseconds: 1800),
          builder: (context, c, _) => DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(colors: [c ?? color, (c ?? color).withValues(alpha: 0)]),
            ),
          ),
        );
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: breath,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(breath.value);
          final h = size.height;
          return Stack(
            children: [
              Positioned(
                left: -size.width * 0.32,
                top: h * 0.08 - h * 0.04 * t,
                width: size.width * 0.62,
                height: h * 0.84,
                child: Transform.scale(scale: 1 + 0.08 * t, child: blob(color.withValues(alpha: strength))),
              ),
              Positioned(
                right: -size.width * 0.32,
                top: h * 0.14 + h * 0.03 * t,
                width: size.width * 0.62,
                height: h * 0.8,
                child: Transform.scale(scale: 1.06 - 0.1 * t, child: blob(color.withValues(alpha: strength))),
              ),
              Positioned(
                left: size.width * 0.12,
                right: size.width * 0.12,
                bottom: -h * 0.3 - h * 0.03 * (1 - t),
                height: h * 0.55,
                child: blob(color.withValues(alpha: strength * 0.7)),
              ),
            ],
          );
        },
      ),
    );
  }
}
