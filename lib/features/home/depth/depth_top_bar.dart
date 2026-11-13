import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/layout.dart';
import '../../../app/user_avatar.dart';
import '../../../theme/app_tokens.dart';
import '../../../theme/components.dart';
import '../../settings/appearance.dart';
import '../home_components.dart';
import 'tab_nav.dart';

/// Depth's top bar ("pill"): the logo and the server's name in a glass pill
/// on the left; the avatar in one on the right. The tools fold out of the
/// avatar to the left, each swinging in on a vertical hinge, nearest first:
/// under the mouse or focus on a PC or TV, on a tap on a phone. On a PC or TV
/// the tabs sit in the true centre (a phone has them along the bottom). The
/// bar folds away as the page scrolls down and comes back on the way up.
class PillTopBar extends StatefulWidget {
  const PillTopBar({super.key, required this.data, required this.style, required this.scrolled});

  final HomeTopBarData data;
  final ComponentStyle style;

  /// How far the page has scrolled.
  final ValueListenable<double> scrolled;

  @override
  State<PillTopBar> createState() => _PillTopBarState();
}

class _PillTopBarState extends State<PillTopBar> with SingleTickerProviderStateMixin {
  late final _fold = AnimationController(vsync: this, duration: const Duration(milliseconds: 950));
  bool _hover = false;
  bool _focus = false;
  bool _tapped = false;
  bool _hidden = false;
  double _last = 0;

  /// The mouse or focus on the tabs: the bar stays.
  bool _tabsHeld = false;

  bool get _open => _hover || _focus || _tapped;

  @override
  void initState() {
    super.initState();
    widget.scrolled.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(PillTopBar old) {
    super.didUpdateWidget(old);
    if (old.scrolled != widget.scrolled) {
      old.scrolled.removeListener(_onScroll);
      widget.scrolled.addListener(_onScroll);
    }
    // Another tab: the bar shows, and follows that page from where it was.
    if (old.data.tab != widget.data.tab) {
      _hidden = false;
      _last = widget.scrolled.value;
    }
  }

  @override
  void dispose() {
    widget.scrolled.removeListener(_onScroll);
    _fold.dispose();
    super.dispose();
  }

  /// Down: fold away (past the first 60px); up: back. Never while open.
  void _onScroll() {
    final pixels = widget.scrolled.value;
    final delta = pixels - _last;
    _last = pixels;
    final hide = pixels > 60 && delta > 0 && !_open && !_tabsHeld;
    final show = pixels <= 60 || delta < -2;
    if (hide && !_hidden) setState(() => _hidden = true);
    if (show && _hidden) setState(() => _hidden = false);
  }

  void _update() {
    if (_open) {
      _fold.forward();
      if (_hidden) _hidden = false;
    } else {
      _fold.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final tv = context.layout.formFactor == FormFactor.tv;
    final moving = animationsOn(context);
    final avatarSize = phone ? 40.0 : (tv ? 58.0 : 44.0);
    // The account is the avatar itself; the rest are the tools.
    final account = widget.data.actions.lastOrNull;
    final tools = widget.data.actions.length > 1
        ? widget.data.actions.sublist(0, widget.data.actions.length - 1)
        : const <HomeAction>[];
    // The design's sizes, smaller where they wouldn't all fit open.
    final leading = widget.data.leading;
    final leadingRoom = leading == null ? 0.0 : (phone ? 40.0 : 44.0) + 8;
    final room = MediaQuery.sizeOf(context).width - (phone ? 24 : 48) - avatarSize - 12 - leadingRoom;
    final toolSize = math.min(phone ? 38.0 : (tv ? 58.0 : 44.0), tools.isEmpty ? 0.0 : room / tools.length - 2);

    // The tabs. Too narrow for them and the open tools: they fold to the
    // active one and move left, just enough.
    final width = MediaQuery.sizeOf(context).width;
    final tab = widget.data.tab;
    final onTab = widget.data.onTab;
    final tabs = !phone && tab != null && onTab != null && widget.data.tabs.length + widget.data.extras.length > 1;
    final crowded = tabs && _open && width < 1300;
    final foldedHalf = tv ? 70.0 : 52.0;
    final openTools = tools.length * (toolSize + 2) + avatarSize + 12;
    final slide = math.max(0.0, openTools + 24 + foldedHalf + 18 - width / 2);
    // Room for the brand beside them.
    final pillHalf = (widget.data.tabs.length + widget.data.extras.length) * (tv ? 64.0 : 50.0);
    final brandRoom = tabs ? math.max(120.0, width / 2 - pillHalf - 36 - leadingRoom) : double.infinity;
    final brandCovered = phone ? _open : crowded && width / 2 - slide - foldedHalf < 220 + leadingRoom;

    final bar = Padding(
      padding: EdgeInsets.symmetric(horizontal: phone ? 12 : 24, vertical: phone ? 6 : 12),
      child: Row(
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 8)],
          // The brand, under the tools on a phone when they're open.
          Expanded(
            child: AnimatedOpacity(
              opacity: brandCovered ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: brandRoom),
                  child: IgnorePointer(
                    ignoring: brandCovered,
                    child: _Brand(data: widget.data, compact: phone),
                  ),
                ),
              ),
            ),
          ),
          MouseRegion(
            onEnter: (_) => setState(() {
              _hover = true;
              _update();
            }),
            onExit: (_) => setState(() {
              _hover = false;
              _update();
            }),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (f) => setState(() {
                _focus = f;
                _update();
              }),
              child: _Glass(
                padding: const EdgeInsets.all(5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, tool) in tools.indexed)
                      _Tool(
                        action: tool,
                        size: toolSize,
                        fold: _fold,
                        // Nearest the avatar first, 50ms apart (40 on a phone).
                        order: tools.length - 1 - i,
                        stagger: phone ? 40 : 50,
                        moving: moving,
                        onPressed: () {
                          if (phone) setState(() => _tapped = false);
                          _update();
                          tool.onPressed();
                        },
                      ),
                    if (account != null)
                      _Avatar(
                        action: account,
                        size: avatarSize,
                        fold: _fold,
                        moving: moving,
                        // A phone has no hover: a tap opens and closes the
                        // tools; a long press is the account.
                        onPressed: phone
                            ? () => setState(() {
                                _tapped = !_tapped;
                                _update();
                              })
                            : account.onPressed,
                        onLongPress: phone ? account.onPressed : null,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // Folding away: tips back from its top edge, like a page turning up.
    return IgnorePointer(
      ignoring: _hidden,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _hidden ? 1 : 0),
        duration: Duration(milliseconds: moving ? 700 : 0),
        curve: const Cubic(0.2, 0.8, 0.2, 1),
        builder: (context, t, child) => Opacity(
          opacity: (1 - t * 1.4).clamp(0.0, 1.0),
          child: Transform(
            alignment: Alignment.topCenter,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 1 / 900)
              ..rotateX(-t * 96 * math.pi / 180),
            child: child,
          ),
        ),
        child: tabs
            ? Stack(
                children: [
                  Positioned.fill(
                    child: Center(
                      child: TabPill(
                        tabs: widget.data.tabs,
                        extras: widget.data.extras,
                        tab: tab,
                        onTab: onTab,
                        crowded: crowded,
                        slide: slide,
                        tv: tv,
                        onHeld: (held) => setState(() {
                          _tabsHeld = held;
                          if (held) _hidden = false;
                        }),
                      ),
                    ),
                  ),
                  bar,
                ],
              )
            : bar,
      ),
    );
  }
}

/// A round Back button in the bar's glass, before the brand.
class PillBackButton extends StatelessWidget {
  const PillBackButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    return _Glass(
      child: SizedBox.square(
        dimension: phone ? 38 : 42,
        child: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          padding: EdgeInsets.zero,
          color: Colors.white,
          iconSize: phone ? 20 : 22,
          icon: const Icon(Icons.arrow_back),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// A see-through rounded panel: the theme's glass.
class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final glass = context.tokens.glass;
    final shape = BorderRadius.circular(999);
    // No blur behind: re-blurring the moving page every frame stuttered on
    // large screens. A little more solid instead.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(glass.fill, const Color(0x99000000)),
        borderRadius: shape,
        border: Border.all(color: glass.border),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// The logo and "jellyfin · server"; the server's address on hover, and
/// Settings > Account & server on a tap.
class _Brand extends StatelessWidget {
  const _Brand({required this.data, required this.compact});

  final HomeTopBarData data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = context.tokens.textMuted ?? theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: 'Connected to ${data.serverName} · ${data.host}',
      child: _Glass(
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => context.push('/settings?section=account'),
          child: Padding(
            padding: EdgeInsets.fromLTRB(compact ? 10 : 14, 8, compact ? 14 : 20, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: compact ? 22 : 26,
                  child: const CustomPaint(painter: DepthLogoPainter()),
                ),
                SizedBox(width: compact ? 8 : 10),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'jellyfin',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        TextSpan(
                          text: ' · ${data.serverName}',
                          style: theme.textTheme.titleMedium?.copyWith(color: muted),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// One tool: folded flat against the avatar until [fold] opens, then
/// swinging in on its right edge, [order] steps after the first.
class _Tool extends StatelessWidget {
  const _Tool({
    required this.action,
    required this.size,
    required this.fold,
    required this.order,
    required this.stagger,
    required this.moving,
    required this.onPressed,
  });

  final HomeAction action;
  final double size;
  final Animation<double> fold;
  final int order;

  /// Milliseconds between one tool and the next.
  final int stagger;
  final bool moving;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const total = 950.0;
    final start = (order * stagger / total).clamp(0.0, 0.6);
    final swing = CurvedAnimation(
      parent: fold,
      curve: Interval(start, (start + 600 / total).clamp(0.0, 1.0), curve: const Cubic(0.2, 0.8, 0.2, 1.3)),
    );
    final slide = CurvedAnimation(
      parent: fold,
      curve: const Interval(0, 0.63, curve: Cubic(0.2, 0.8, 0.2, 1)),
    );
    return AnimatedBuilder(
      animation: fold,
      builder: (context, child) {
        final open = moving ? swing.value : (fold.value > 0 ? 1.0 : 0.0);
        final width = moving ? slide.value : (fold.value > 0 ? 1.0 : 0.0);
        final shown = fold.value > 0;
        // Folded tools aren't there: no taps, no focus stops.
        return IgnorePointer(
          ignoring: !shown,
          child: ExcludeFocus(
            excluding: !shown,
            child: ClipRect(
              child: Align(
                alignment: Alignment.centerRight,
                widthFactor: width.clamp(0.0, 1.0),
                child: Opacity(
                  opacity: open.clamp(0.0, 1.0),
                  child: Transform(
                    alignment: Alignment.centerRight,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 1 / 600)
                      ..rotateY((1 - open) * 95 * math.pi / 180),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: SizedBox.square(
          dimension: size,
          child: IconButton(
            tooltip: action.tooltip,
            padding: EdgeInsets.zero,
            iconSize: size * 0.5,
            onPressed: onPressed,
            icon: action.icon,
          ),
        ),
      ),
    );
  }
}

/// The avatar: spins once on its vertical axis as the tools open.
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.action,
    required this.size,
    required this.fold,
    required this.moving,
    required this.onPressed,
    this.onLongPress,
  });

  final HomeAction action;
  final double size;
  final Animation<double> fold;
  final bool moving;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final spin = CurvedAnimation(
      parent: fold,
      curve: const Interval(0, 0.74, curve: Cubic(0.2, 0.8, 0.2, 1.2)),
    );
    return Tooltip(
      message: action.tooltip,
      child: InkResponse(
        onTap: onPressed,
        onLongPress: onLongPress,
        radius: size / 2,
        child: AnimatedBuilder(
          animation: spin,
          builder: (context, child) => Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 1 / 600)
              ..rotateY(moving ? spin.value * 2 * math.pi : 0),
            child: child,
          ),
          child: SizedBox.square(
            dimension: size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Theme.of(context).colorScheme.primary,
                    context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary,
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: FittedBox(child: CurrentUserAvatar(radius: size / 2)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Kurage's logo, a jellyfish: a violet bell outline with a cyan glow
/// inside, and four wavy cyan tentacles. Drawn from the app icon's
/// 108-unit art (bell 30..78 wide, 27..86 tall overall), centred.
class DepthLogoPainter extends CustomPainter {
  const DepthLogoPainter({this.violet = const Color(0xFF8F84FF), this.cyan = const Color(0xFF8EE6F5)});

  final Color violet;
  final Color cyan;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 62;
    canvas
      ..save()
      ..translate(size.width / 2 - 54 * k, size.height / 2 - 56.5 * k)
      ..scale(k);
    final bell = Path()
      ..moveTo(30, 58)
      ..cubicTo(30, 38, 41, 27, 54, 27)
      ..cubicTo(67, 27, 78, 38, 78, 58)
      ..quadraticBezierTo(72, 54, 66, 58)
      ..quadraticBezierTo(60, 54, 54, 58)
      ..quadraticBezierTo(48, 54, 42, 58)
      ..quadraticBezierTo(36, 54, 30, 58)
      ..close();
    final glow = Path()
      ..moveTo(42, 52)
      ..cubicTo(42, 42, 47, 36, 54, 36)
      ..cubicTo(61, 36, 66, 42, 66, 52)
      ..close();
    Path tentacle(double x, double turn, double end) => Path()
      ..moveTo(x, 62)
      ..quadraticBezierTo(x + turn, 68, x, 74)
      ..quadraticBezierTo(x - turn, 80, x, end);
    canvas
      ..drawPath(
        bell,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeJoin = StrokeJoin.round
          ..color = violet,
      )
      ..drawPath(glow, Paint()..color = cyan);
    final strand = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..color = cyan;
    for (final t in [tentacle(38, -4, 86), tentacle(48, -4, 84), tentacle(60, 4, 84), tentacle(70, 4, 86)]) {
      canvas.drawPath(t, strand);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DepthLogoPainter old) => old.violet != violet || old.cyan != cyan;
}
