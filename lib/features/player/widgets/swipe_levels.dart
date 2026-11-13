import 'dart:async';

import 'package:flutter/material.dart';

/// Swipe up / down on the left side for brightness, on the right side for
/// volume (phones). Sits over the video without taking taps, so the
/// player's own tap / double-tap handling still works.
///
/// The volume level can be pushed in from outside ([volumeChanges], e.g.
/// the phone's volume keys) so a swipe always starts from the real level.
class SwipeLevels extends StatefulWidget {
  const SwipeLevels({
    super.key,
    required this.volume,
    required this.brightness,
    this.volumeChanges,
    this.onVolume,
    this.onBrightness,
    this.atSide = false,
  });

  /// Starting levels, 0.0–1.0.
  final Future<double> Function() volume;
  final Future<double> Function() brightness;
  final Stream<double>? volumeChanges;

  /// Null turns that side's gesture off.
  final ValueChanged<double>? onVolume;
  final ValueChanged<double>? onBrightness;

  /// Just the percentage on the side being swiped, instead of the pill.
  final bool atSide;

  @override
  State<SwipeLevels> createState() => _SwipeLevelsState();
}

enum _Side { brightness, volume }

class _SwipeLevelsState extends State<SwipeLevels> {
  double _volume = 0.5;
  double _brightness = 0.5;
  _Side? _dragging;
  _Side? _shown;
  Timer? _hide;
  StreamSubscription<double>? _changes;

  @override
  void initState() {
    super.initState();
    widget.volume().then((v) {
      if (mounted) _volume = v;
    });
    widget.brightness().then((v) {
      if (mounted) _brightness = v;
    });
    _changes = widget.volumeChanges?.listen((v) {
      // While swiping, the swipe itself is the source of truth.
      if (mounted && _dragging != _Side.volume) setState(() => _volume = v);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    _changes?.cancel();
    super.dispose();
  }

  void _start(DragStartDetails d, double width) {
    final side = d.localPosition.dx < width / 2 ? _Side.brightness : _Side.volume;
    if ((side == _Side.volume ? widget.onVolume : widget.onBrightness) == null) return;
    _hide?.cancel();
    setState(() => _dragging = _shown = side);
  }

  void _update(DragUpdateDetails d, double height) {
    final side = _dragging;
    if (side == null) return;
    // A full-height swipe goes from 0 to 100 %.
    final delta = -d.delta.dy / (height * 0.8);
    setState(() {
      if (side == _Side.volume) {
        _volume = (_volume + delta).clamp(0.0, 1.0);
        widget.onVolume?.call(_volume);
      } else {
        _brightness = (_brightness + delta).clamp(0.0, 1.0);
        widget.onBrightness?.call(_brightness);
      }
    });
  }

  void _end() {
    setState(() => _dragging = null);
    _hide = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _shown = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onVolume == null && widget.onBrightness == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) => Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            // Only vertical drags are claimed; taps fall through to the player.
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (d) => _start(d, box.maxWidth),
            onVerticalDragUpdate: (d) => _update(d, box.maxHeight),
            onVerticalDragEnd: (_) => _end(),
            onVerticalDragCancel: _end,
          ),
          if (_shown case final side? when widget.atSide)
            Align(
              // Brightness on the left, volume on the right; inside the
              // picture, not at its edge.
              alignment: side == _Side.volume ? const Alignment(0.55, 0) : const Alignment(-0.55, 0),
              child: IgnorePointer(
                child: Text(
                  '${((side == _Side.volume ? _volume : _brightness) * 100).round()}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                  ),
                ),
              ),
            )
          else if (_shown case final side?)
            Center(
              child: IgnorePointer(
                child: _Indicator(
                  icon: side == _Side.volume
                      ? (_volume == 0 ? Icons.volume_off : Icons.volume_up)
                      : Icons.brightness_6,
                  value: side == _Side.volume ? _volume : _brightness,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small pill with the icon and the level, e.g. "🔊 64%" (the look of
/// media_kit's own indicator).
class _Indicator extends StatelessWidget {
  const _Indicator({required this.icon, required this.value});

  final IconData icon;
  final double value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(32),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(
              '${(value * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
