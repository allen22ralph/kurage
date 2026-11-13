import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../settings/appearance.dart';
import '../home_components.dart';

const _colors = [
  Color(0xFF8EE6F5),
  Color(0xFF8F84FF),
  Color(0xFFFFB3E1),
  Color(0xFFFFC94D),
  Color(0xFFE3F3B0),
  Color(0xFFFF9F7A),
  Color(0xFFA8DCFF),
  Color(0xFFFFD27A),
];

/// Which genres to show, [count] of them: a different selection each day, as
/// there can be many more than fit, and alphabetical would only ever show the
/// first few.
@visibleForTesting
List<String> genresOfTheDay(List<String> genres, int count, DateTime day) {
  final shuffled = [...genres]..shuffle(math.Random(day.year * 1000 + day.month * 50 + day.day));
  return shuffled.take(count).toList();
}

/// Depth's Browse by genre ("flips"): tiles with the genre in outline and a
/// colour dot, which flip on hover, focus or press to a coloured back.
class GenreTiles extends StatelessWidget {
  const GenreTiles({super.key, required this.data, this.kicker});

  final GenreRowData data;
  final String? kicker;

  @override
  Widget build(BuildContext context) {
    final genres = data.genres.value ?? const <String>[];
    if (genres.isEmpty) return const SizedBox.shrink();
    final layout = context.layout;
    final form = layout.formFactor;
    final gap = switch (form) {
      FormFactor.phone => 10.0,
      FormFactor.desktop => 16.0,
      FormFactor.tv => 24.0,
    };
    final now = DateTime.now();
    return Padding(
      padding: EdgeInsets.fromLTRB(layout.gutter, 32, layout.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KickerHeading(
            kicker: kicker ?? 'Find a mood',
            title: Text(data.title, style: CardLook.headingStyle(context)),
          ),
          SizedBox(height: form == FormFactor.phone ? 14 : 26),
          LayoutBuilder(
            builder: (context, box) {
              final columns = switch (form) {
                FormFactor.phone => 2,
                FormFactor.tv => 4,
                // As many as fit at 210 wide or more.
                FormFactor.desktop => math.max(1, ((box.maxWidth + gap) / (210 + gap)).floor()),
              };
              final rows = form == FormFactor.phone ? 3 : 2;
              final shown = genresOfTheDay(genres, columns * rows, now);
              final width = (box.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < shown.length; i++)
                    SizedBox(
                      width: width,
                      child: _FlipTile(
                        genre: shown[i],
                        color: _colors[i % _colors.length],
                        onOpen: () => data.onGenrePressed(shown[i]),
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

class _FlipTile extends StatefulWidget {
  const _FlipTile({required this.genre, required this.color, required this.onOpen});

  final String genre;
  final Color color;
  final VoidCallback onOpen;

  @override
  State<_FlipTile> createState() => _FlipTileState();
}

class _FlipTileState extends State<_FlipTile> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _flipped => _hovered || _focused || _pressed;

  @override
  Widget build(BuildContext context) {
    final form = context.layout.formFactor;
    final (height, radius, perspective, wordSize, stroke, dot, duration) = switch (form) {
      FormFactor.phone => (96.0, 16.0, 700.0, 24.0, 1.1, 8.0, 700),
      FormFactor.desktop => (130.0, 18.0, 900.0, 34.0, 1.3, 10.0, 800),
      FormFactor.tv => (170.0, 24.0, 1100.0, 48.0, 1.5, 14.0, 800),
    };
    final borderRadius = BorderRadius.circular(radius);
    final display = CardLook.headingStyle(context);
    // Lite: the back shows, with no turn.
    final lite = effectsOf(context) == EffectsLevel.lite;
    final inset = form == FormFactor.phone ? 12.0 : 16.0;

    final front = DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1018),
        borderRadius: borderRadius,
        border: Border.all(
          color: _focused ? const Color(0xFFF2F0FF) : Colors.white.withValues(alpha: 0.08),
          width: form == FormFactor.tv ? 2 : 1,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: inset,
            top: inset,
            child: DecoratedBox(
              decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
              child: SizedBox.square(dimension: dot),
            ),
          ),
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.genre,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: display?.fontFamily,
                    fontFamilyFallback: display?.fontFamilyFallback,
                    fontSize: wordSize,
                    fontWeight: FontWeight.w800,
                    letterSpacing: wordSize * -0.02,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = stroke
                      ..color = const Color(0xB3E8E9F0),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final back = DecoratedBox(
      decoration: BoxDecoration(color: widget.color, borderRadius: borderRadius),
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Browse ${widget.genre} →',
              maxLines: 1,
              style: const TextStyle(color: Color(0xFF0B0C12), fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: 'Browse ${widget.genre}',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: _flipped ? 1 : 0),
              duration: animationsOn(context) && !lite ? Duration(milliseconds: duration) : Duration.zero,
              curve: const Cubic(0.2, 0.8, 0.2, 1.15),
              builder: (context, t, _) {
                final turning = t > 0 && t < 1;
                final showBack = t > 0.5;
                if (lite) return showBack ? back : front;
                return Transform(
                  alignment: Alignment.center,
                  // (Drawn whole while turning, for a clean slanted edge.)
                  filterQuality: turning ? FilterQuality.medium : null,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 1 / perspective)
                    ..rotateY(-math.pi * t),
                  child: showBack
                      ? Transform(alignment: Alignment.center, transform: Matrix4.rotationY(math.pi), child: back)
                      : front,
                );
              },
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
          ],
        ),
      ),
    );
  }
}
