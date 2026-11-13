import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../core/jellyfin/week_api.dart';
import '../../../theme/app_tokens.dart';
import '../../settings/appearance.dart';
import '../this_week.dart';
import '../../library/widgets/action_menu.dart' show holdOpensMenu;

/// Depth's This week ("timeline"): the seven days as dots on a line that
/// draws itself in, each day's card standing above or below it in turn and
/// hinging up out of the line: on a PC by where it is on screen, so it follows
/// the scroll both ways; on Android once, as the row comes into view (one
/// after another). A card shows the day's first episode or film, a "+2" for the
/// rest (a tap lists them all; hovering or holding slides them out beside it).
/// Today's dot is lit.
class WeekTimeline extends StatefulWidget {
  const WeekTimeline({super.key, required this.data, this.kicker});

  final WeekRowData data;
  final String? kicker;

  @override
  State<WeekTimeline> createState() => _WeekTimelineState();
}

class _WeekTimelineState extends State<WeekTimeline> with TickerProviderStateMixin {
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));

  /// A day's other cards, sliding out beside its own.
  late final _fan = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  int? _fanDay;
  Timer? _fanClose;
  final _fanEnd = GlobalKey();
  ScrollPosition? _page;
  ScrollController? _days;

  /// How far the timeline's top is above the bottom of the screen, within
  /// the range where anything still moves; what a PC's fold follows.
  final _entered = ValueNotifier<double>(0);
  double _viewport = 0;
  double _enteredMost = 0;
  final _timeline = GlobalKey();

  /// The fold follows the scroll (not Android: there it plays once).
  bool _followsScroll = false;

  static const _gap = 12.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!animationsOn(context) || effectsOf(context) == EffectsLevel.lite) {
      _reveal.value = 1;
      _followsScroll = false;
      return;
    }
    final page = Scrollable.maybeOf(context)?.position;
    if (page != _page) {
      _page?.removeListener(_onPage);
      _page = page?..addListener(_onPage);
    }
    _followsScroll = page != null && defaultTargetPlatform != TargetPlatform.android;
    // Android: played once, as the row comes into view.
    if (!_followsScroll) WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _onPage() => _followsScroll ? _follow() : _check();

  void _follow() {
    if (!mounted || !_followsScroll) return;
    final box = _timeline.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    _entered.value = (_viewport - box.localToGlobal(Offset.zero).dy).clamp(0.0, _enteredMost);
  }

  void _check() {
    if (!mounted || _reveal.isAnimating || _reveal.value == 1) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached || box.size.height == 0) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final screen = MediaQuery.sizeOf(context).height;
    final shown = math.min(top + box.size.height, screen) - math.max(top, 0);
    if (shown >= box.size.height * 0.3) {
      _page?.removeListener(_onPage);
      _reveal.forward();
    }
  }

  @override
  void dispose() {
    _page?.removeListener(_onPage);
    _reveal.dispose();
    _entered.dispose();
    _fan.dispose();
    _fanClose?.cancel();
    _days?.dispose();
    super.dispose();
  }

  /// A day's other cards, each sliding out from behind the one before.
  List<Widget> _fanCards({
    required List<WeekEntry> entries,
    required DateTime day,
    required double left,
    required bool up,
    required double half,
    required double cardWidth,
    required double imageHeight,
    required double timelineWidth,
  }) {
    const gap = 10.0;
    final fan = weekFanFor(others: entries.length, left: left, cardWidth: cardWidth, timelineWidth: timelineWidth, gap: gap);
    return [
      // Furthest first, so each comes from behind the nearer ones.
      for (var k = fan.count - 1; k >= 0; k--)
        Positioned(
          left: left + fan.direction * (k + 1) * (cardWidth + gap),
          width: cardWidth,
          top: up ? null : half + 30,
          bottom: up ? half + 30 : null,
          child: AnimatedBuilder(
            animation: _fan,
            builder: (context, child) {
              final t = Curves.easeOutCubic.transform(Interval(k * 0.15, 1).transform(_fan.value));
              return IgnorePointer(
                ignoring: _fan.value == 0,
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(-fan.direction * (k + 1) * (cardWidth + gap) * (1 - t), 0),
                    child: child,
                  ),
                ),
              );
            },
            child: MouseRegion(
              onEnter: (_) => _fanClose?.cancel(),
              onExit: (_) => _hideFan(),
              child: _Card(
                key: k == fan.count - 1 ? _fanEnd : null,
                day: day,
                entries: [entries[k]],
                imageHeight: imageHeight,
                settled: true,
              ),
            ),
          ),
        ),
    ];
  }

  void _showFan(int day, {bool held = false}) {
    _fanClose?.cancel();
    if (_fanDay != day) {
      _fan.value = 0;
      setState(() => _fanDay = day);
    }
    // Held on a phone: the row scrolls sideways, so bring them into view, once
    // they've reached their places.
    void inView() {
      final end = _fanEnd.currentContext;
      if (!held || end == null || !end.mounted) return;
      Scrollable.ensureVisible(end, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic, alignment: 0.5);
    }

    if (animationsOn(context)) {
      _fan.forward().whenComplete(inView);
    } else {
      _fan.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => inView());
    }
  }

  /// After a moment: the gaps between the cards shouldn't close them.
  void _hideFan({Duration after = const Duration(milliseconds: 140)}) {
    _fanClose?.cancel();
    _fanClose = Timer(after, () {
      if (!mounted) return;
      void clear() {
        if (mounted && _fan.isDismissed) setState(() => _fanDay = null);
      }

      if (animationsOn(context)) {
        _fan.reverse().whenComplete(clear);
      } else {
        _fan.value = 0;
        clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final week = widget.data.week.value;
    if (week != null && weekShowsUnavailable(week)) return WeekUnavailable(title: widget.data.title, week: week);
    if (week == null || week.entries.isEmpty) return const SizedBox.shrink();
    final layout = context.layout;
    final phone = layout.formFactor == FormFactor.phone;
    final tv = layout.formFactor == FormFactor.tv;
    final cardWidth = phone ? 150.0 : (tv ? 230.0 : 180.0);
    final imageHeight = phone ? 56.0 : (tv ? 84.0 : 64.0);
    final scaler = MediaQuery.textScalerOf(context);
    // The card's height (its picture, title and episode line), so the line
    // sits with room for a card on either side.
    final cardHeight = 24 + imageHeight + 10 + scaler.scale(14) * 1.3 + 2 + scaler.scale(12) * 1.4 + 4;
    final half = cardHeight + 30 + 10;
    // Where each side's cards start, from the timeline's top.
    final upTop = half - 30 - cardHeight;
    final downTop = half + 30;
    if (_followsScroll) {
      _viewport = MediaQuery.sizeOf(context).height;
      // Past this nothing moves, so scrolling on doesn't rebuild anything.
      _enteredMost = downTop + weekFoldEnds(height: cardHeight, viewport: _viewport, day: 6);
      // (Also when the page moves without scrolling, or the window changes.)
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: layout.gutter),
            child: KickerHeading(
              kicker: widget.kicker ?? 'On air',
              title: Text(widget.data.title, style: CardLook.headingStyle(context)),
            ),
          ),
          if (week.rowNote case final note?)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: layout.gutter),
              child: WeekNote(note: note),
            ),
          LayoutBuilder(
            builder: (context, box) {
              final room = box.maxWidth - 2 * layout.gutter;
              final column = math.max(cardWidth * 0.78, (room - 6 * _gap) / 7);
              final width = 7 * column + 6 * _gap;
              final today = DateUtils.dateOnly(DateTime.now());
              final todayIndex = today.difference(week.start).inDays.clamp(0, 6);
              final dayCard = math.min(cardWidth, column + _gap);
              final timeline = SizedBox(
                key: _timeline,
                width: width,
                height: half * 2,
                child: TapRegion(
                onTapOutside: (_) {
                  if (_fanDay != null) _hideFan(after: Duration.zero);
                },
                child: AnimatedBuilder(
                  animation: _followsScroll ? _entered : _reveal,
                  builder: (context, _) => Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // The line, drawing itself in from the left.
                      Positioned(
                        left: 0,
                        right: 0,
                        top: half - 1,
                        height: 2,
                        child: Transform(
                          alignment: Alignment.centerLeft,
                          transform: Matrix4.diagonal3Values(
                            _followsScroll
                                ? weekLineDrawn(entered: _entered.value - half, viewport: _viewport)
                                : Curves.easeOutCubic.transform(const Interval(0, 0.4).transform(_reveal.value)),
                            1,
                            1,
                          ),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                stops: [0, 0.1, 0.9, 1],
                                colors: [Color(0x008F84FF), Color(0xFF8F84FF), Color(0xFF8EE6F5), Color(0x008EE6F5)],
                              ),
                            ),
                          ),
                        ),
                      ),
                      for (var i = 0; i < 7; i++)
                        if (DateTime(week.start.year, week.start.month, week.start.day + i) case final day)
                          Positioned(
                            left: i * (column + _gap),
                            width: column,
                            top: 0,
                            bottom: 0,
                            child: _Day(
                              day: day,
                              entries: week.day(i),
                              today: DateUtils.isSameDay(day, today),
                              up: i.isEven,
                              half: half,
                              cardWidth: dayCard,
                              onHover: (over) => over ? _showFan(i) : _hideFan(),
                              onHold: () => _showFan(i, held: true),
                              imageHeight: imageHeight,
                              followsScroll: _followsScroll,
                              // One after another, each quick.
                              t: _followsScroll
                                  ? weekCardFold(
                                      entered: _entered.value - (i.isEven ? upTop : downTop),
                                      height: cardHeight,
                                      viewport: _viewport,
                                      day: i,
                                    )
                                  : Curves.easeOutCubic.transform(
                                      Interval(0.15 + i * 0.07, 0.6 + i * 0.06).transform(_reveal.value),
                                    ),
                            ),
                          ),
                      // Above every day, as the cards pass over the next ones.
                      if (_fanDay case final i?)
                        ..._fanCards(
                          entries: week.day(i).skip(1).toList(),
                          day: DateTime(week.start.year, week.start.month, week.start.day + i),
                          left: i * (column + _gap) + (column - dayCard) / 2,
                          up: i.isEven,
                          half: half,
                          cardWidth: dayCard,
                          imageHeight: imageHeight,
                          timelineWidth: width,
                        ),
                    ],
                  ),
                ),
                ),
              );
              if (width <= room) {
                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: layout.gutter),
                  child: Align(alignment: Alignment.centerLeft, child: timeline),
                );
              }
              // Too wide (a phone): scrolled sideways, today in view.
              _days ??= ScrollController(
                initialScrollOffset: math.max(0, todayIndex * (column + _gap) - (room - column) / 2),
              );
              return SingleChildScrollView(
                controller: _days,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: layout.gutter),
                clipBehavior: Clip.none,
                child: timeline,
              );
            },
          ),
        ],
      ),
    );
  }
}

/// How far a card's top has to be above the bottom of the screen for it to
/// have opened fully. From the design's `animation-range` ("cover 44%" for the
/// first day, later for each one after).
double weekFoldEnds({required double height, required double viewport, required int day}) =>
    (viewport + height) * (0.44 + 0.02 * day);

/// How open a card is, 0 to 1, with its top [entered] pixels above the bottom
/// of the screen. It starts once part of it is in view ("entry 50%" for the
/// first day, later for each one after), so a row opens day by day.
double weekCardFold({required double entered, required double height, required double viewport, required int day}) {
  final start = height * (0.5 + 0.1 * day);
  final end = weekFoldEnds(height: height, viewport: viewport, day: day);
  if (end <= start) return entered >= end ? 1 : 0;
  return ((entered - start) / (end - start)).clamp(0.0, 1.0);
}

/// How much of the line is drawn, 0 to 1, with it [entered] pixels above the
/// bottom of the screen (the design's "cover 40%").
double weekLineDrawn({required double entered, required double viewport}) =>
    viewport <= 0 ? 1 : (entered / (viewport * 0.4)).clamp(0.0, 1.0);

/// How many other cards fit beside a day's, and which way they go: towards the
/// side with more room, three at most (the day's list has them all).
({int count, int direction}) weekFanFor({
  required int others,
  required double left,
  required double cardWidth,
  required double timelineWidth,
  double gap = 10,
}) {
  final rightRoom = timelineWidth - left - cardWidth;
  final toRight = rightRoom >= left;
  final fits = ((toRight ? rightRoom : left) / (cardWidth + gap)).floor();
  return (count: math.min(others, math.min(3, fits)), direction: toRight ? 1 : -1);
}

/// One day: its dot on the line, its name on the far side, and (with
/// anything on) a stem and its card.
class _Day extends StatelessWidget {
  const _Day({
    required this.day,
    required this.entries,
    required this.today,
    required this.up,
    required this.half,
    required this.cardWidth,
    required this.imageHeight,
    required this.t,
    required this.followsScroll,
    required this.onHover,
    required this.onHold,
  });

  final bool followsScroll;
  final DateTime day;
  final List<WeekEntry> entries;
  final bool today;
  final bool up;
  final double half;
  final double cardWidth;
  final double imageHeight;
  final double t;
  final ValueChanged<bool> onHover;
  final VoidCallback onHold;

  @override
  Widget build(BuildContext context) {
    final cyan = context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    final muted = context.tokens.textMuted ?? const Color(0xFF9AA0B2);
    final label = Text(
      (today ? 'Today' : const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][day.weekday - 1]).toUpperCase(),
      maxLines: 1,
      style: (CardLook.headingStyle(context) ?? const TextStyle()).copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.5,
        color: today ? cyan : muted,
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        // The day's name, across the line from its card.
        Positioned(
          left: 0,
          right: 0,
          top: up ? half + 16 : null,
          bottom: up ? null : half + 16,
          child: Center(child: label),
        ),
        if (entries.isNotEmpty) ...[
          Positioned(
            top: up ? half - 30 : half,
            height: 30 * t,
            width: 2,
            child: ColoredBox(color: cyan.withValues(alpha: 0.5)),
          ),
          Positioned(
            top: up ? null : half + 30,
            bottom: up ? half + 30 : null,
            width: cardWidth,
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform(
                // Following the scroll a card can rest part-way open, text
                // and all: drawn whole, then tilted, so that stays clean.
                filterQuality: followsScroll && t < 1 ? FilterQuality.medium : null,
                // Hinged on the line's side, folding up out of it.
                alignment: up ? Alignment.bottomCenter : Alignment.topCenter,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 1 / 900)
                  ..rotateX((up ? 88 : -88) * math.pi / 180 * (1 - t)),
                child: _Card(
                  day: day,
                  entries: entries,
                  imageHeight: imageHeight,
                  settled: followsScroll || t > 0.98,
                  onHover: entries.length > 1 ? onHover : null,
                  onHold: entries.length > 1 ? onHold : null,
                ),
              ),
            ),
          ),
        ],
        // The dot (lit for today).
        Positioned(
          top: half - 8,
          width: 16,
          height: 16,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: today ? cyan : const Color(0xFF06070B),
              border: Border.all(color: cyan, width: 3),
              boxShadow: today ? [BoxShadow(color: cyan.withValues(alpha: 0.6), blurRadius: 14)] : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatefulWidget {
  const _Card({
    super.key,
    required this.day,
    required this.entries,
    required this.imageHeight,
    required this.settled,
    this.onHover,
    this.onHold,
  });

  final DateTime day;
  final List<WeekEntry> entries;
  final double imageHeight;
  final bool settled;
  final ValueChanged<bool>? onHover;
  final VoidCallback? onHold;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entries.first;
    final more = widget.entries.length - 1;
    final cyan = context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    final line = [?e.code, ?weekTime(context, e), if (e.movie) ?e.release].join(' · ');
    return Semantics(
      button: true,
      label: '${weekDayLabel(widget.day)}: ${e.title}${more > 0 ? ', and $more more' : ''}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          setState(() => _hover = true);
          widget.onHover?.call(true);
        },
        onExit: (_) {
          setState(() => _hover = false);
          widget.onHover?.call(false);
        },
        child: GestureDetector(
          onLongPress: holdOpensMenu ? widget.onHold : null,
          onTap: () => more > 0 ? showWeekDay(context, widget.day, widget.entries) : openWeekEntry(context, e),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.tokens.surface ?? const Color(0xFF0E1018),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _hover ? cyan.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.08)),
              boxShadow: [
                if (_hover)
                  BoxShadow(
                    color: cyan.withValues(alpha: 0.35),
                    blurRadius: 40,
                    spreadRadius: -20,
                    offset: const Offset(0, 20),
                  ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: widget.imageHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RepaintBoundary(child: WeekImage(entry: e, width: 230)),
                        if (more > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xCC06070B),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text(
                                  '+$more',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (e.inLibrary)
                          Positioned(
                            left: 6,
                            top: 6,
                            child: Icon(Icons.check_circle, size: 16, color: cyan, semanticLabel: 'In your library'),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // (Text once the card faces you: no letters redrawn at
                // every angle as it folds up.)
                Opacity(
                  opacity: widget.settled ? 1 : 0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        line.isEmpty ? weekStatus(context, e) : line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cyan, fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
