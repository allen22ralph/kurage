import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../library/library_providers.dart';
import '../../library/widgets/item_image.dart';
import '../../settings/appearance.dart';
import '../home_components.dart';

/// One door's colours: the panel's gradient, and the glow behind it.
class _DoorColors {
  const _DoorColors(this.from, this.to, this.glow, this.label);

  final Color from;
  final Color to;
  final Color glow;
  final Color label;
}

const _violet = _DoorColors(Color(0xFF2B2366), Color(0xFF11122A), Color(0x598F84FF), Color(0xFFB9B2FF));
const _cyan = _DoorColors(Color(0xFF0F4A57), Color(0xFF0B1620), Color(0x4D8EE6F5), Color(0xFF8EE6F5));
const _rose = _DoorColors(Color(0xFF5A1F3F), Color(0xFF1A0F1C), Color(0x4DFF8FC0), Color(0xFFFFB3D4));
const _amber = _DoorColors(Color(0xFF5C3A12), Color(0xFF1C1408), Color(0x4DFFC46B), Color(0xFFFFD79A));
const _green = _DoorColors(Color(0xFF1B4F3A), Color(0xFF0C1A14), Color(0x4D7BE8B4), Color(0xFFA8F0CC));
const _palette = [_violet, _cyan, _rose, _amber, _green];

/// Each library's colours: films violet and shows cyan as in the design, and
/// no two doors alike while there are colours left.
List<_DoorColors> _colorsFor(List<BaseItem> libraries) {
  final used = <_DoorColors>{};
  return [
    for (final library in libraries)
      () {
        final start = switch (library.collectionType) {
          'movies' => 0,
          'tvshows' => 1,
          _ => 2,
        };
        final free = [for (var i = 0; i < _palette.length; i++) _palette[(start + i) % _palette.length]]
            .where((c) => !used.contains(c))
            .firstOrNull;
        final colors = free ?? _palette[start];
        used.add(colors);
        return colors;
      }(),
  ];
}

IconData _glyphFor(String? collectionType) => switch (collectionType) {
  'movies' => Icons.local_movies_outlined,
  'tvshows' => Icons.live_tv_outlined,
  'music' => Icons.library_music_outlined,
  'books' => Icons.menu_book_outlined,
  'homevideos' => Icons.video_library_outlined,
  'photos' => Icons.photo_library_outlined,
  _ => Icons.folder_outlined,
};

/// How far a door's panel swings. It turns away from the viewer, further than
/// the design's 42° towards them, which hid most of the label it reveals.
const _swing = 55 * math.pi / 180;

/// The panel's transform at [t] (0 shut, 1 open): hinged on its left edge, seen
/// from the door's centre.
@visibleForTesting
Matrix4 doorLeafMatrix(Size size, double t, double perspective) {
  final cx = size.width / 2;
  final cy = size.height / 2;
  return Matrix4.translationValues(cx, cy, 0)
    ..multiply(Matrix4.identity()..setEntry(3, 2, 1 / perspective))
    ..multiply(Matrix4.translationValues(-cx, 0, 0))
    ..rotateY(-_swing * t)
    ..multiply(Matrix4.translationValues(0, -cy, 0));
}

/// Depth's Libraries ("doors"): a door for each library, whose panel swings
/// open on its left hinge on hover, focus or press, showing the way in.
class LibraryDoors extends StatelessWidget {
  const LibraryDoors({super.key, required this.data, this.kicker});

  final LibraryRowData data;
  final String? kicker;

  @override
  Widget build(BuildContext context) {
    final libraries = data.items.value ?? const <BaseItem>[];
    if (libraries.isEmpty) return const SizedBox.shrink();
    final layout = context.layout;
    final colors = _colorsFor(libraries);
    final gap = layout.formFactor == FormFactor.phone ? 10.0 : 24.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(layout.gutter, 32, layout.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KickerHeading(
            kicker: kicker ?? 'Step inside',
            title: Text(data.title, style: CardLook.headingStyle(context)),
          ),
          SizedBox(height: layout.formFactor == FormFactor.phone ? 14 : 26),
          LayoutBuilder(
            builder: (context, box) {
              // One column in a narrow PC window, as the design; a phone keeps two.
              final columns = layout.formFactor != FormFactor.phone && box.maxWidth < 636 ? 1 : 2;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var start = 0; start < libraries.length; start += columns)
                    Padding(
                      padding: EdgeInsets.only(top: start == 0 ? 0 : gap),
                      child: Row(
                        children: [
                          // An odd last door takes the whole row.
                          for (var i = start; i < math.min(start + columns, libraries.length); i++) ...[
                            if (i > start) SizedBox(width: gap),
                            Expanded(
                              child: _Door(
                                library: libraries[i],
                                colors: colors[i],
                                onOpen: () => data.onItemPressed(libraries[i]),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// How long a door shows one picture.
const _pictureFor = Duration(seconds: 9);

/// A door's panel picture: backdrops from the library's own titles, one after
/// another, under its colour so the name reads. Not the library's own picture
/// while they can be had: on a server that's often a banner with the name on it,
/// which a door's shape crops badly. Without any, the colour and a glyph.
class _DoorArtwork extends ConsumerStatefulWidget {
  const _DoorArtwork({required this.library, required this.colors, required this.maxWidth, required this.glyph});

  final BaseItem library;
  final _DoorColors colors;
  final double maxWidth;
  final bool glyph;

  @override
  ConsumerState<_DoorArtwork> createState() => _DoorArtworkState();
}

class _DoorArtworkState extends ConsumerState<_DoorArtwork> {
  Timer? _start;
  Timer? _timer;
  int _index = 0;
  bool _ticking = false;
  bool _animate = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ticking = TickerMode.valuesOf(context).enabled;
    // (Lite: one picture, loading no others.)
    _animate = animationsOn(context) && effectsOf(context) != EffectsLevel.lite;
    if (!_animate) {
      _stop();
    } else if (_start == null && _timer == null) {
      // The doors change in turn, not all at once.
      _start = Timer(Duration(milliseconds: widget.library.id.hashCode.abs() % 4000), () {
        _start = null;
        _timer = Timer.periodic(_pictureFor, (_) => _next());
      });
    }
  }

  void _stop() {
    _start?.cancel();
    _start = null;
    _timer?.cancel();
    _timer = null;
  }

  /// On screen, in a tab being looked at: otherwise there's no one to see it,
  /// and no reason to load another picture.
  void _next() {
    if (!mounted || !_ticking) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    if (top + box.size.height <= 0 || top >= MediaQuery.sizeOf(context).height) return;
    setState(() => _index++);
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Widget _image(ImageRef image) => ItemImage(
    key: ValueKey('${image.itemId}/${image.type}'),
    image: image,
    maxWidth: widget.maxWidth,
    // A wide door shows a slice of the picture: faces tend to be above the middle.
    alignment: const Alignment(0, -0.25),
    placeholder: const SizedBox.shrink(),
  );

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final backdrops = ref.watch(libraryBackdropsProvider((id: library.id, collectionType: library.collectionType)));
    final own = library.landscapeImage ?? library.posterImage;
    final pictures = switch (backdrops.value) {
      final found? when found.isNotEmpty => found,
      _ when backdrops.isLoading => const <ImageRef>[],
      _ => [?own],
    };
    if (pictures.isEmpty) {
      if (backdrops.isLoading || !widget.glyph) return const SizedBox.shrink();
      return Stack(
        children: [
          Positioned(
            right: -30,
            top: -30,
            child: Icon(_glyphFor(library.collectionType), size: 240, color: Colors.white.withValues(alpha: 0.16)),
          ),
        ],
      );
    }
    final current = pictures[_index % pictures.length];
    final next = pictures[(_index + 1) % pictures.length];
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        // The next one, already underneath, so it's loaded when its turn comes.
        if (next.itemId != current.itemId) _image(next),
        AnimatedSwitcher(
          duration: _animate ? const Duration(milliseconds: 1200) : Duration.zero,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: _image(current),
        ),
        // A little past the picture, for the panel's clip to cut: a picture lands
        // on whole pixels and the tint needn't, which left the picture untinted
        // along an edge when the page stopped between pixels.
        Positioned(
          left: -2,
          top: -2,
          right: -2,
          bottom: -2,
          key: const ValueKey('door-tint'),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [widget.colors.from.withValues(alpha: 0.3), widget.colors.to.withValues(alpha: 0.92)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Door extends StatefulWidget {
  const _Door({required this.library, required this.colors, required this.onOpen});

  final BaseItem library;
  final _DoorColors colors;
  final VoidCallback onOpen;

  @override
  State<_Door> createState() => _DoorState();
}

class _DoorState extends State<_Door> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _open => _hovered || _focused || _pressed;

  @override
  Widget build(BuildContext context) {
    final form = context.layout.formFactor;
    final (height, radius, perspective, titleSize, labelSize) = switch (form) {
      FormFactor.phone => (150.0, 22.0, 900.0, 26.0, 13.0),
      FormFactor.desktop => (320.0, 28.0, 1300.0, 56.0, 22.0),
      FormFactor.tv => (360.0, 34.0, 1600.0, 84.0, 34.0),
    };
    final (leafPadding, insidePadding) = switch (form) {
      FormFactor.phone => (const EdgeInsets.all(16), 16.0),
      FormFactor.desktop => (const EdgeInsets.symmetric(horizontal: 34, vertical: 30), 32.0),
      FormFactor.tv => (const EdgeInsets.symmetric(horizontal: 44, vertical: 40), 56.0),
    };
    final phone = form == FormFactor.phone;
    final colors = widget.colors;
    final name = widget.library.name;
    final display = CardLook.headingStyle(context);
    final borderRadius = BorderRadius.circular(radius);
    final animate = animationsOn(context);
    final lite = effectsOf(context) == EffectsLevel.lite;

    /// What the open panel leaves room for: a narrow door only has room for
    /// the short label, as on a phone.
    Widget inside(double width) {
      final short = phone || width < 540;
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.7, 0),
            radius: 0.8,
            colors: [colors.glow, colors.glow.withValues(alpha: 0)],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: insidePadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!short)
                Text(
                  name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: colors.label, fontWeight: FontWeight.w800, letterSpacing: 2.6),
                ),
              if (!short) const SizedBox(height: 8),
              Text(
                short ? 'Open →' : 'Open the library →',
                maxLines: 1,
                style: display?.copyWith(
                  color: Colors.white,
                  fontSize: labelSize,
                  fontWeight: phone ? FontWeight.w800 : FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final leaf = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.from, colors.to],
        ),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: _DoorArtwork(
                library: widget.library,
                colors: colors,
                maxWidth: phone ? 400 : 1280,
                glyph: form == FormFactor.desktop,
              ),
            ),
            Padding(
              padding: leafPadding,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    name,
                    maxLines: 1,
                    style: display?.copyWith(
                      color: Colors.white,
                      fontSize: titleSize,
                      fontWeight: FontWeight.w800,
                      letterSpacing: titleSize * -0.03,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      button: true,
      label: 'Open $name',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0xFF07080D), borderRadius: borderRadius),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: LayoutBuilder(
              builder: (context, box) => Stack(
                fit: StackFit.expand,
                children: [
                  inside(box.maxWidth),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: _open && !lite ? 1 : 0),
                    duration: animate ? Duration(milliseconds: phone ? 900 : 1000) : Duration.zero,
                    curve: const Cubic(0.2, 0.8, 0.2, 1),
                    child: leaf,
                    builder: (context, t, child) =>
                        // Open: the panel is drawn whole, then tilted as one picture. Tilted
                        // piece by piece, its picture and tint are each smoothed alone along
                        // the slanted edge, and the picture shows through in a bright fringe.
                        Transform(
                          transform: doorLeafMatrix(box.biggest, t, perspective),
                          filterQuality: t > 0 ? FilterQuality.medium : null,
                          child: child,
                        ),
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: borderRadius,
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      focusColor: Colors.transparent,
                      onTap: widget.onOpen,
                      onHover: (v) => setState(() => _hovered = v),
                      onFocusChange: (v) => setState(() => _focused = v),
                      onHighlightChanged: (v) => setState(() => _pressed = v),
                    ),
                  ),
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: borderRadius,
                        border: Border.all(
                          // (Lite: the panel doesn't swing, so this is what answers.)
                          color: _focused || (lite && _open) ? const Color(0xFFF2F0FF) : Colors.white.withValues(alpha: 0.08),
                          width: form == FormFactor.tv ? 2 : 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
