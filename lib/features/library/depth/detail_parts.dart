import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../home/depth/deck_hero.dart';
import '../../home/depth/preview.dart';
import '../../settings/appearance.dart';
import '../widgets/item_image.dart';
import '../widgets/side_scroll.dart';

/// The parts Depth's series and episode pages share.

const _pill = Color(0xFFF2F0FF);
const _ink = Color(0xFF0B0C12);
const _violet = Color(0xFF8F84FF);
const _cyan = Color(0xFF8EE6F5);
const _heart = Color(0xFFFF9EC4);
const _ease = Cubic(0.2, 0.8, 0.2, 1);

/// Below this a PC's window lays the page out in one column.
const detailOneColumnBelow = 1100.0;

/// An overview, with a credit and a note told apart when the text has them:
/// "(Source: Viz)" or a "Source: Viz" line, and "Note: …" at the end. Most
/// overviews have neither.
({String body, String? source, String? note}) splitOverview(String text) {
  var body = text.trim();
  String? note;
  final noteAt = RegExp(r'(?:^|\n)\s*\(?Note:\s*', caseSensitive: false).firstMatch(body);
  if (noteAt != null) {
    note = body.substring(noteAt.end).trim();
    if (note.endsWith(')') && !note.contains('(')) note = note.substring(0, note.length - 1);
    body = body.substring(0, noteAt.start).trim();
  }
  String? source;
  final sourced = RegExp(r'[\(\[]\s*Source:\s*([^\)\]\n]+?)\s*[\)\]]|(?:^|\n)\s*Source:\s*([^\n]+?)\s*(?=\n|$)', caseSensitive: false);
  final match = sourced.allMatches(body).lastOrNull;
  if (match != null) {
    source = match[1] ?? match[2];
    body = (body.substring(0, match.start) + body.substring(match.end)).trim();
  }
  return (body: body, source: source, note: note?.isEmpty ?? true ? null : note);
}

/// The whole-show or whole-episode line: "13m left", from where it was left.
String? timeLeft(BaseItem item) {
  final length = item.runTimeTicks;
  if (length == null || !item.userData.hasProgress) return null;
  final left = ticksToDuration(length - item.userData.playbackPositionTicks);
  if (left.isNegative) return null;
  final minutes = left.inMinutes;
  if (minutes >= 60) return '${minutes ~/ 60}h ${minutes % 60}m left';
  return '${math.max(1, minutes)}m left';
}

/// How much of [item] has been watched, 0 to 1.
double watchedFraction(BaseItem item) {
  final length = item.runTimeTicks;
  if (length == null || length <= 0) return 0;
  return (item.userData.playbackPositionTicks / length).clamp(0.0, 1.0);
}

/// "Series · 2 seasons · Specials", from what the server lists.
String seriesLabel(List<BaseItem>? seasons) {
  if (seasons == null) return 'Series';
  final numbered = seasons.where((s) => (s.indexNumber ?? 0) > 0).length;
  final specials = seasons.any((s) => s.indexNumber == 0);
  return [
    'Series',
    if (numbered > 0) '$numbered season${numbered == 1 ? '' : 's'}',
    if (specials) 'Specials',
  ].join(' · ');
}

/// The small uppercase line over a heading.
class Kick extends StatelessWidget {
  const Kick(this.text, {super.key, this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final colour = muted ? (context.tokens.textMuted ?? const Color(0xFF9AA0B2)) : (context.tokens.accent2 ?? _cyan);
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: colour, fontSize: phone ? 11 : 12, fontWeight: FontWeight.w800, letterSpacing: phone ? 2.2 : 2.6),
    );
  }
}

/// A section's kick and heading.
class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.kick, required this.title});

  final String kick;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Kick(kick),
          const SizedBox(height: 6),
          Text(
            title,
            style: (CardLook.headingStyle(context) ?? const TextStyle()).copyWith(fontSize: context.layout.formFactor == FormFactor.phone ? 24 : 30),
          ),
        ],
      );
}

/// The way Depth's pages draw an [OutlinedButton] that lives elsewhere (the
/// download and request buttons), so they match [GhostButton].
class GhostTheme extends StatelessWidget {
  const GhostTheme({super.key, required this.child, this.height = 56});

  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) => OutlinedButtonTheme(
        data: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: Size(0, height),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            shape: const StadiumBorder(),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
            backgroundColor: const Color(0x990A0B12),
            foregroundColor: const Color(0xFFF2F2F6),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
        child: child,
      );
}

/// A glass pill: From start, Mark watched. With [label] null, a round one.
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.icon,
    this.label,
    this.tooltip,
    required this.onPressed,
    this.height = 56,
    this.on = false,
    this.onColour = _cyan,
  });

  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final double height;
  final bool on;
  final Color onColour;

  @override
  Widget build(BuildContext context) {
    final foreground = on ? onColour : const Color(0xFFF2F2F6);
    final style = OutlinedButton.styleFrom(
      minimumSize: Size(label == null ? height : 0, height),
      maximumSize: label == null ? Size(height, height) : null,
      padding: label == null ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 20),
      shape: const StadiumBorder(),
      side: BorderSide(color: on ? onColour.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.22)),
      backgroundColor: const Color(0x990A0B12),
      foregroundColor: foreground,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    );
    final button = label == null
        ? OutlinedButton(onPressed: onPressed, style: style, child: Icon(icon, size: 19))
        : OutlinedButton.icon(onPressed: onPressed, style: style, icon: Icon(icon, size: 17), label: Text(label!));
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The heart.
class FavoriteButton extends StatelessWidget {
  const FavoriteButton({super.key, required this.favorite, required this.onPressed});

  final bool favorite;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => GhostButton(
        icon: favorite ? Icons.favorite : Icons.favorite_border,
        tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
        onPressed: onPressed,
        on: favorite,
        onColour: _heart,
      );
}

/// The main button: a light pill whose background fills softly to [progress].
class ResumePill extends StatelessWidget {
  const ResumePill({
    super.key,
    required this.label,
    this.detail,
    this.progress = 0,
    required this.onPressed,
    this.expand = false,
    this.autofocus = false,
  });

  final String label;

  /// Quieter, after the label: "· 12:50".
  final String? detail;
  final double progress;
  final VoidCallback? onPressed;
  final bool expand;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final animate = animationsOn(context);
    final row = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.play_arrow_rounded, size: 22, color: _ink),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _ink, fontSize: 15, fontWeight: FontWeight.w800),
          ),
        ),
        if (detail != null) ...[
          const SizedBox(width: 8),
          Text(detail!, style: const TextStyle(color: Color(0xFF5B5F72), fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: _violet.withValues(alpha: 0.85), blurRadius: 40, spreadRadius: -10, offset: const Offset(0, 12))],
      ),
      child: Material(
        color: _pill,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          autofocus: autofocus,
          onTap: onPressed,
          child: Stack(
            children: [
              if (progress > 0)
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: animate ? 0 : progress, end: progress),
                    duration: const Duration(milliseconds: 1400),
                    curve: _ease,
                    builder: (context, p, child) => Transform(
                      alignment: Alignment.centerLeft,
                      transform: Matrix4.diagonal3Values(p, 1, 1),
                      child: child,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          stops: const [0, 0.85, 1],
                          colors: [_violet.withValues(alpha: 0.18), _violet.withValues(alpha: 0.34), _violet.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ),
              Container(
                height: 56,
                padding: const EdgeInsets.fromLTRB(20, 0, 26, 0),
                child: row,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A phone's round action with its label under it.
class RoundAction extends StatelessWidget {
  const RoundAction({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.on = false,
    this.onColour = _cyan,
    this.child,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool on;
  final Color onColour;

  /// Instead of [icon] and [onPressed]: a button of its own.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colour = on ? onColour : const Color(0xFFE8E9F0);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 48,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x990A0B12),
                border: Border.all(color: on ? onColour.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.18)),
              ),
              child: child ??
                  IconButton(
                    tooltip: label,
                    padding: EdgeInsets.zero,
                    onPressed: onPressed,
                    icon: Icon(icon, size: 20, color: colour),
                  ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colour, fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// A phone's [RoundAction]s: up to [perRow] in a row, and the rest on a
/// second row below, centred, each the same width as above.
class RoundActions extends StatelessWidget {
  const RoundActions({super.key, required this.children, this.perRow = 5});

  final List<Widget> children;
  final int perRow;

  @override
  Widget build(BuildContext context) {
    if (children.length <= perRow) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
    }
    return LayoutBuilder(
      builder: (context, c) {
        final slot = c.maxWidth / perRow;
        Widget row(Iterable<Widget> some) => Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              // Each in a slot of its own: a RoundAction fills its parent.
              children: [for (final each in some) SizedBox(width: slot, child: Row(children: [each]))],
            );
        return Column(
          children: [
            for (var at = 0; at < children.length; at += perRow) ...[
              if (at > 0) const SizedBox(height: 14),
              row(children.skip(at).take(perRow)),
            ],
          ],
        );
      },
    );
  }
}

/// The hero's picture, zooming and panning slowly (not on Lite, or with
/// animations off).
class KenBurns extends StatefulWidget {
  const KenBurns({super.key, required this.child});

  final Widget child;

  @override
  State<KenBurns> createState() => _KenBurnsState();
}

class _KenBurnsState extends State<KenBurns> with SingleTickerProviderStateMixin {
  late final _drift = AnimationController(vsync: this, duration: const Duration(seconds: 22));

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moving = animationsOn(context) && effectsOf(context) != EffectsLevel.lite;
    if (moving && !_drift.isAnimating) _drift.repeat(reverse: true);
    if (!moving && _drift.isAnimating) _drift.stop();
    if (!moving) return Transform.scale(scale: 1.1, child: widget.child);
    return LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: _drift,
        child: widget.child,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(_drift.value);
          return Transform.translate(
            offset: Offset(-box.maxWidth * 0.02 * t, -box.maxHeight * 0.015 * t),
            child: Transform.scale(scale: 1.1 + 0.11 * t, child: child),
          );
        },
      ),
    );
  }
}

/// Big outlined letters: "S1", "E1".
class BigNumber extends StatelessWidget {
  const BigNumber(this.text, {super.key, required this.size});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ExcludeSemantics(
          child: RiseIn(
            delay: 0,
            child: Text(
              text,
              maxLines: 1,
              style: (CardLook.headingStyle(context) ?? const TextStyle()).copyWith(
                fontSize: size,
                height: 1,
                fontWeight: FontWeight.w800,
                letterSpacing: -size * 0.06,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = size > 200 ? 2 : 1.5
                  ..color = const Color(0xD9F2F0FF),
              ),
            ),
          ),
        ),
      );
}

/// The picture of a Depth page's hero, with what plays over it: [preview]
/// once the mouse has stayed a moment, or on a phone by itself with
/// [playsBySelf]. It goes through the one shared preview player, so Effects
/// and Settings > Home decide as they do on Home.
class HeroPicture extends StatefulWidget {
  const HeroPicture({
    super.key,
    required this.image,
    required this.maxWidth,
    this.preview,
    this.previewLabel = 'Preview',
    this.playsBySelf = false,
    required this.overlay,
    required this.hovering,
    this.chipRight = 64,
    this.chipTop = 22,
  });

  final ImageRef? image;
  final double maxWidth;
  final BaseItem? preview;
  final String previewLabel;
  final bool playsBySelf;
  final bool hovering;
  final Widget overlay;
  final double chipRight;
  final double chipTop;

  @override
  State<HeroPicture> createState() => _HeroPictureState();
}

class _HeroPictureState extends State<HeroPicture> {
  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        RepaintBoundary(
          child: ClipRect(
            child: KenBurns(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ItemImage(image: widget.image, maxWidth: math.min(widget.maxWidth, 1600 / MediaQuery.devicePixelRatioOf(context))),
                  if (preview != null)
                    EpisodePreview(
                      item: preview,
                      active: widget.hovering || widget.playsBySelf,
                      delay: const Duration(milliseconds: 400),
                    ),
                ],
              ),
            ),
          ),
        ),
        IgnorePointer(child: widget.overlay),
        if (preview != null)
          Positioned(
            right: widget.chipRight,
            top: widget.chipTop,
            child: ValueListenableBuilder<String?>(
              valueListenable: Preview.showing,
              builder: (context, showing, _) => showing == preview.id
                  ? NowPlayingChip(trailerLabel: widget.previewLabel)
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}

/// A hero's meta line: pieces with space between, wrapping.
class HeroMeta extends StatelessWidget {
  const HeroMeta({super.key, required this.children, this.small = false});

  final List<Widget> children;
  final bool small;

  @override
  Widget build(BuildContext context) => DefaultTextStyle.merge(
        style: TextStyle(color: const Color(0xFFE8E9F0), fontSize: small ? 12 : 15, fontWeight: FontWeight.w700),
        child: Wrap(
          spacing: small ? 12 : 18,
          runSpacing: small ? 4 : 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      );
}

/// "TV-14", in a box.
class RatingBadge extends StatelessWidget {
  const RatingBadge(this.text, {super.key, this.small = false});

  final String text;
  final bool small;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: 1),
          child: Text(text, style: TextStyle(fontSize: small ? 11 : 13)),
        ),
      );
}

/// "★ 9.7".
class StarScore extends StatelessWidget {
  const StarScore(this.score, {super.key, this.small = false});

  final double score;
  final bool small;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: small ? 14 : 17, color: context.tokens.star),
          const SizedBox(width: 4),
          Text(score.toStringAsFixed(1)),
        ],
      );
}

/// A title that settles into place from wide letter-spacing.
class TrackingTitle extends StatelessWidget {
  const TrackingTitle(this.text, {super.key, required this.style, this.maxLines = 2});

  final String text;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final end = style.letterSpacing ?? 0;
    if (!animationsOn(context) || effectsOf(context) == EffectsLevel.lite) {
      return Text(text, style: style, maxLines: maxLines, overflow: TextOverflow.ellipsis);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1500),
      curve: const Cubic(0.2, 0.7, 0.2, 1),
      builder: (context, t, _) => Opacity(
        opacity: t,
        child: Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(letterSpacing: end + (style.fontSize ?? 40) * 0.24 * (1 - t)),
        ),
      ),
    );
  }
}

/// The overview, clamped with Read more when it runs long, its credit under
/// it and its note in a panel when the text has them.
class DepthOverview extends StatefulWidget {
  const DepthOverview({super.key, required this.text, this.lines = 4});

  final String text;
  final int lines;

  @override
  State<DepthOverview> createState() => _DepthOverviewState();
}

class _DepthOverviewState extends State<DepthOverview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final parts = splitOverview(widget.text);
    final style = TextStyle(fontSize: phone ? 14 : 17, height: phone ? 1.6 : 1.7, color: const Color(0xFFD4D6E0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: LayoutBuilder(
            builder: (context, box) {
              final painter = TextPainter(
                text: TextSpan(text: parts.body, style: style),
                maxLines: widget.lines,
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: box.maxWidth);
              final long = painter.didExceedMaxLines;
              painter.dispose();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    parts.body,
                    style: style,
                    maxLines: _open ? null : widget.lines,
                    overflow: _open ? null : TextOverflow.ellipsis,
                  ),
                  if (long)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        minimumSize: Size.zero,
                        foregroundColor: const Color(0xFFB9B2FF),
                        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                      ),
                      onPressed: () => setState(() => _open = !_open),
                      child: Text(_open ? 'Read less' : 'Read more'),
                    ),
                ],
              );
            },
          ),
        ),
        if (parts.source case final source?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Source: $source', style: const TextStyle(fontSize: 13, color: Color(0xFF7D8396))),
          ),
        if (parts.note case final note?)
          Container(
            margin: const EdgeInsets.only(top: 14),
            constraints: const BoxConstraints(maxWidth: 760),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _cyan.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _cyan.withValues(alpha: 0.18)),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Note', style: TextStyle(color: _cyan, fontWeight: FontWeight.w800)),
                  TextSpan(text: ' · $note'),
                ],
              ),
              style: const TextStyle(fontSize: 13, height: 1.6, color: Color(0xFFB9BDCC)),
            ),
          ),
      ],
    );
  }
}

/// A chip: a genre that opens, or a tag that just says.
class DetailChip extends StatelessWidget {
  const DetailChip(this.text, {super.key, this.onPressed});

  final String text;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final body = Container(
      height: phone ? 34 : 38,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      // (Centred, but only as wide as the words.)
      child: Center(
        widthFactor: 1,
        child: Text(text, style: const TextStyle(color: Color(0xFFD4D6E0), fontSize: 13, fontWeight: FontWeight.w700)),
      ),
    );
    if (onPressed == null) return body;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(borderRadius: BorderRadius.circular(999), onTap: onPressed, child: body),
    );
  }
}

/// A season's episodes, one segment each: cyan when watched, part-filled in
/// progress, faint otherwise.
class SeasonStrip extends StatelessWidget {
  const SeasonStrip({super.key, required this.episodes, this.height = 8});

  final List<BaseItem> episodes;
  final double height;

  /// "12 of 28 watched".
  static String countOf(List<BaseItem> episodes) {
    final real = episodes.where((e) => !e.isVirtual);
    return '${real.where((e) => e.userData.played).length} of ${real.length} watched';
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _StripPainter([
              for (final e in episodes)
                if (!e.isVirtual) e.userData.played ? 1.0 : watchedFraction(e),
            ], context.tokens.accent2 ?? _cyan),
          ),
        ),
      );
}

class _StripPainter extends CustomPainter {
  const _StripPainter(this.values, this.colour);

  final List<double> values;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final gap = values.length > 80 ? 1.0 : 3.0;
    final width = (size.width - gap * (values.length - 1)) / values.length;
    if (width <= 0) return;
    final radius = Radius.circular(math.min(3, width / 2));
    final faint = Paint()..color = Colors.white.withValues(alpha: 0.12);
    final filled = Paint()..color = colour;
    for (final (i, v) in values.indexed) {
      final left = i * (width + gap);
      final whole = RRect.fromLTRBR(left, 0, left + width, size.height, radius);
      canvas.drawRRect(whole, faint);
      if (v > 0) {
        canvas.save();
        canvas.clipRRect(whole);
        canvas.drawRect(Rect.fromLTWH(left, 0, width * v, size.height), filled);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.colour != colour || !_same(old.values, values);

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// People's tiles, cast then crew after a divider.
class DepthCastRow extends StatelessWidget {
  const DepthCastRow({super.key, required this.people});

  final List<PersonInfo> people;

  static bool _acting(PersonInfo p) => const {'Actor', 'GuestStar'}.contains(p.type);

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final width = phone ? 96.0 : 132.0;
    final height = phone ? 124.0 : 172.0;
    final cast = people.where(_acting).toList();
    final crew = people.where((p) => !_acting(p)).toList();
    final count = [
      if (cast.isNotEmpty) '${cast.length} cast',
      if (crew.isNotEmpty) '${crew.length} crew',
    ].join(' · ');
    final showDivider = cast.isNotEmpty && crew.isNotEmpty;
    final total = cast.length + crew.length + (showDivider ? 1 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(child: SectionHeading(kick: 'Voices and makers', title: 'Cast & crew')),
            Text(count, style: const TextStyle(color: Color(0xFF9AA0B2), fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: height + 66,
          child: SideScroll(
            builder: (controller) => ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.only(top: 12),
              itemCount: total,
              itemBuilder: (context, i) {
                if (showDivider && i == cast.length) {
                  return Container(width: 1, margin: const EdgeInsets.fromLTRB(8, 10, 24, 40), color: Colors.white.withValues(alpha: 0.12));
                }
                final person = i < cast.length ? cast[i] : crew[i - cast.length - (showDivider ? 1 : 0)];
                return Padding(
                  padding: EdgeInsets.only(right: phone ? 12 : 16),
                  child: _PersonTile(person: person, width: width, height: height, crew: i >= cast.length),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PersonTile extends StatefulWidget {
  const _PersonTile({required this.person, required this.width, required this.height, required this.crew});

  final PersonInfo person;
  final double width;
  final double height;
  final bool crew;

  @override
  State<_PersonTile> createState() => _PersonTileState();
}

class _PersonTileState extends State<_PersonTile> {
  bool _hover = false;

  /// Up to two initials.
  static String initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    return (words.first[0] + (words.length > 1 ? words.last[0] : '')).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final person = widget.person;
    final hue = (person.name.hashCode % 360).abs().toDouble();
    final top = HSLColor.fromAHSL(1, hue, 0.45, 0.32).toColor();
    final bottom = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.16).toColor();
    final role = person.role?.isNotEmpty == true ? person.role! : person.type ?? '';
    final tilted = _hover && animationsOn(context) && effectsOf(context) != EffectsLevel.lite;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        width: widget.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TiltMotion(
              tilted: tilted,
              child: Container(
                height: widget.height,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withValues(alpha: _hover ? 0.25 : 0.08)),
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [top, bottom]),
                ),
                child: ItemImage(
                  image: person.primaryImageTag == null ? null : ImageRef(person.id, 'Primary', person.primaryImageTag!),
                  maxWidth: widget.width,
                  placeholder: Center(
                    child: Text(
                      initials(person.name),
                      style: (CardLook.headingStyle(context) ?? const TextStyle()).copyWith(
                        fontSize: widget.width / 3,
                        fontWeight: FontWeight.w800,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(person.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFE8E9F0), fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: widget.crew ? (context.tokens.accent2 ?? _cyan) : const Color(0xFF9AA0B2), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
