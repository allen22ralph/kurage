import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../media_engine.dart';

/// Seek bar with chapter marks: gaps split the track at chapter starts
/// (as on YouTube), and hovering shows the time and chapter there.
///
/// Replaces media_kit's seek bar, which can't show markers.
class ChapterSeekBar extends StatefulWidget {
  const ChapterSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.buffer,
    this.initialPosition = Duration.zero,
    this.initialDuration = Duration.zero,
    this.initialBuffer = Duration.zero,
    required this.chapters,
    required this.chapterLabel,
    required this.onSeek,
    this.preview,
  });

  final Stream<Duration> position;
  final Stream<Duration> duration;
  final Stream<Duration> buffer;
  final Duration initialPosition;
  final Duration initialDuration;
  final Duration initialBuffer;
  final List<Chapter> chapters;
  final String Function(int index) chapterLabel;
  final ValueChanged<Duration> onSeek;

  /// A picture of the frame at a time (trickplay), shown above the time
  /// while hovering / dragging.
  final Widget Function(Duration time)? preview;

  @override
  State<ChapterSeekBar> createState() => _ChapterSeekBarState();
}

class _ChapterSeekBarState extends State<ChapterSeekBar> {
  late Duration _position = widget.initialPosition;
  late Duration _duration = widget.initialDuration;
  late Duration _buffer = widget.initialBuffer;
  final _subscriptions = <StreamSubscription<Duration>>[];

  /// Pointer x while hovering, and the fraction being dragged to.
  double? _hoverX;
  double? _dragFraction;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(widget.position.listen((d) => setState(() => _position = d)))
      ..add(widget.duration.listen((d) => setState(() => _duration = d)))
      ..add(widget.buffer.listen((d) => setState(() => _buffer = d)));
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  double _fraction(Duration d) => _duration > Duration.zero
      ? (d.inMicroseconds / _duration.inMicroseconds).clamp(0.0, 1.0)
      : 0.0;

  Duration _at(double fraction) => _duration * fraction.clamp(0.0, 1.0);

  int? _chapterAt(Duration d) {
    for (var i = widget.chapters.length - 1; i >= 0; i--) {
      if (widget.chapters[i].start <= d) return i;
    }
    return null;
  }

  void _seekTo(double fraction) {
    final target = _at(fraction);
    setState(() => _position = target);
    widget.onSeek(target);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final active = _hoverX != null || _dragFraction != null;
      final shown = _dragFraction ?? _fraction(_position);

      Widget? label;
      final labelX = _dragFraction != null ? _dragFraction! * width : _hoverX;
      if (labelX != null && _duration > Duration.zero) {
        final time = _at(labelX / width);
        final chapter = _chapterAt(time);
        final preview = widget.preview?.call(time);
        // Wide enough for a thumbnail when there is one.
        final boxWidth = preview == null ? 160.0 : 220.0;
        label = Positioned(
          left: (labelX - boxWidth / 2).clamp(0.0, (width - boxWidth).clamp(0.0, width)),
          bottom: 30,
          width: boxWidth,
          child: IgnorePointer(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (preview != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ClipRRect(borderRadius: BorderRadius.circular(6), child: preview),
                  ),
                DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    [
                      formatTimestamp(time),
                      if (chapter != null) widget.chapterLabel(chapter),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
              ],
            ),
          ),
        );
      }

      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (e) => setState(() => _hoverX = e.localPosition.dx),
        onExit: (_) => setState(() => _hoverX = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (e) => _seekTo(e.localPosition.dx / width),
          onHorizontalDragStart: (e) =>
              setState(() => _dragFraction = e.localPosition.dx / width),
          onHorizontalDragUpdate: (e) =>
              setState(() => _dragFraction = (e.localPosition.dx / width).clamp(0.0, 1.0)),
          onHorizontalDragEnd: (_) {
            final fraction = _dragFraction;
            setState(() => _dragFraction = null);
            if (fraction != null) _seekTo(fraction);
          },
          child: SizedBox(
            height: 36,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TrackPainter(
                      played: shown,
                      buffered: _fraction(_buffer),
                      chapterStarts: [
                        for (final c in widget.chapters)
                          if (c.start > Duration.zero) _fraction(c.start),
                      ],
                      active: active,
                      color: colors.primary,
                    ),
                  ),
                ),
                ?label,
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.played,
    required this.buffered,
    required this.chapterStarts,
    required this.active,
    required this.color,
  });

  final double played;
  final double buffered;
  final List<double> chapterStarts;
  final bool active;
  final Color color;

  /// Gap between chapter segments, in logical pixels.
  static const gap = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final height = active ? 6.0 : 4.0;
    final top = (size.height - height) / 2;
    final w = size.width;

    // Chapter segments: [0, c1), [c1, c2), ...; each drawn with a gap
    // before it, then filled up to the buffer and played positions.
    final edges = [0.0, ...chapterStarts.where((f) => f > 0 && f < 1), 1.0];
    for (var i = 0; i < edges.length - 1; i++) {
      final left = edges[i] * w + (i == 0 ? 0 : gap / 2);
      final right = edges[i + 1] * w - (i == edges.length - 2 ? 0 : gap / 2);
      if (right <= left) continue;
      final rect = Rect.fromLTRB(left, top, right, top + height);
      void fill(double upTo, Color c) {
        final end = (upTo * w).clamp(left, right);
        if (end > left) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTRB(left, top, end, top + height),
              const Radius.circular(2),
            ),
            Paint()..color = c,
          );
        }
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = Colors.white24,
      );
      fill(buffered, Colors.white38);
      fill(played, color);
    }

    if (active) {
      canvas.drawCircle(Offset(played * w, size.height / 2), 7, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.played != played ||
      old.buffered != buffered ||
      old.active != active ||
      old.color != color ||
      !listEquals(old.chapterStarts, chapterStarts);
}

/// 4:05, or 1:02:03 past an hour.
String formatTimestamp(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
