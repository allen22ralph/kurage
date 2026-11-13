import 'package:flutter/material.dart';

import '../../../theme/app_tokens.dart';
import '../../settings/appearance.dart';
import '../home_components.dart';
import '../home_tabs.dart';

const _lit = Color(0xFFF2F0FF);
const _ink = Color(0xFF0B0C12);
const _quiet = Color(0xFFA8ADBD);

/// Depth's tabs on a PC or TV: a glass pill. Under [crowded] (the tools open
/// in a narrow window) it folds to the active tab and a "···", and moves
/// [slide] to the left, out of their way.
class TabPill extends StatelessWidget {
  const TabPill({
    super.key,
    required this.tab,
    required this.onTab,
    required this.crowded,
    required this.slide,
    required this.tv,
    required this.onHeld,
    this.tabs = HomeTab.values,
    this.extras = const [],
  });

  /// The ones shown, and what's been added after them.
  final List<HomeTab> tabs;
  final List<HomeAction> extras;
  final HomeTab tab;
  final ValueChanged<HomeTab> onTab;
  final bool crowded;
  final double slide;
  final bool tv;

  /// The mouse or focus is on it, or no longer: the bar stays while it is.
  final ValueChanged<bool> onHeld;

  @override
  Widget build(BuildContext context) {
    final glass = context.tokens.glass;
    return MouseRegion(
      onEnter: (_) => onHeld(true),
      onExit: (_) => onHeld(false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: onHeld,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: crowded ? 1 : 0),
          duration: Duration(milliseconds: animationsOn(context) ? 400 : 0),
          curve: const Cubic(0.2, 0.8, 0.2, 1),
          builder: (context, t, _) => Transform.translate(
            offset: Offset(-slide * t, 0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color.alphaBlend(glass.fill, const Color(0x99000000)),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: glass.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final each in tabs)
                      _Folding(
                        // (The active one never folds.)
                        shown: each == tab ? 1 : 1 - t,
                        child: _TabButton(label: each.label, on: each == tab, tv: tv, onPressed: () => onTab(each)),
                      ),
                    for (final extra in extras)
                      _Folding(
                        shown: 1 - t,
                        child: _TabButton(label: extra.label, on: false, tv: tv, onPressed: extra.onPressed),
                      ),
                    _Folding(
                      shown: t,
                      child: const ExcludeSemantics(
                        child: Padding(
                          padding: EdgeInsets.only(left: 6, right: 12),
                          child: Text('···', style: TextStyle(color: _quiet, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [child] at a [shown] share of its width, gone (no taps, no focus) at 0.
class _Folding extends StatelessWidget {
  const _Folding({required this.shown, required this.child});

  final double shown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gone = shown <= 0.5;
    return IgnorePointer(
      ignoring: gone,
      child: ExcludeFocus(
        excluding: gone,
        child: ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: shown.clamp(0.0, 1.0),
            // (No taller than the tab: without this it fills the whole bar.)
            heightFactor: 1,
            child: Opacity(opacity: shown.clamp(0.0, 1.0), child: child),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatefulWidget {
  const _TabButton({required this.label, required this.on, required this.tv, required this.onPressed});

  final String label;
  final bool on;
  final bool tv;
  final VoidCallback onPressed;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final tv = widget.tv;
    // Focus is the remote's hover: the light fill, slightly bigger. The tab
    // that's on is the light one on a PC; quieter on a TV, so focus stands out.
    final lit = _focus || (widget.on && !tv);
    final fill = lit
        ? _lit
        : widget.on
        ? Colors.white.withValues(alpha: 0.1)
        : _hover
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.transparent;
    final ink = lit ? _ink : (widget.on || _hover ? Colors.white : _quiet);
    final moving = animationsOn(context);
    final time = Duration(milliseconds: moving ? 200 : 0);
    return Semantics(
      selected: widget.on,
      child: AnimatedScale(
        scale: tv && _focus ? 1.06 : 1,
        duration: time,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: widget.onPressed,
          onHover: (h) => setState(() => _hover = h),
          onFocusChange: (f) => setState(() => _focus = f),
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: AnimatedContainer(
            duration: time,
            padding: EdgeInsets.symmetric(horizontal: tv ? 26 : 22, vertical: tv ? 11 : 10),
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(999)),
            child: AnimatedDefaultTextStyle(
              duration: time,
              style: TextStyle(color: ink, fontSize: tv ? 18 : 14, fontWeight: FontWeight.w700),
              child: Text(widget.label),
            ),
          ),
        ),
      ),
    );
  }
}

/// Classic's tabs in its top bar: one plain box with softly rounded corners
/// and a line between the tabs, in the colour of the bar. Over the header's
/// artwork, a dark see-through fill keeps them readable.
class ClassicTabBar extends StatelessWidget {
  const ClassicTabBar({super.key, required this.tabs, required this.tab, required this.onTab, this.extras = const [], this.overArtwork = false});

  final List<HomeTab> tabs;
  final List<HomeAction> extras;
  final HomeTab tab;
  final ValueChanged<HomeTab> onTab;
  final bool overArtwork;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = overArtwork ? Colors.white38 : scheme.outlineVariant;
    final ink = overArtwork ? Colors.white : scheme.onSurface;
    final shape = BorderRadius.circular(8);
    final entries = [
      for (final each in tabs) (label: each.label, on: each == tab, onTap: () => onTab(each)),
      for (final extra in extras) (label: extra.label, on: false, onTap: extra.onPressed),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: overArtwork ? Colors.black38 : Colors.transparent,
        borderRadius: shape,
        border: Border.all(color: line),
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, each) in entries.indexed) ...[
                if (i > 0) VerticalDivider(width: 1, thickness: 1, color: line),
                Semantics(
                  selected: each.on,
                  button: true,
                  child: Material(
                    color: each.on ? ink.withValues(alpha: 0.14) : Colors.transparent,
                    child: InkWell(
                      onTap: each.onTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                        child: Text(
                          each.label,
                          style: TextStyle(
                            color: each.on ? ink : ink.withValues(alpha: 0.72),
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Depth's tabs on a phone: along the bottom, with a pill behind the active
/// one's icon.
class HomeBottomNav extends StatelessWidget {
  const HomeBottomNav({super.key, required this.tab, required this.onTab, this.tabs = HomeTab.values, this.extras = const []});

  /// The ones shown, and what's been added after them.
  final List<HomeTab> tabs;
  final List<HomeAction> extras;

  /// The tab showing; null on a page that's none of them (the watchlist).
  final HomeTab? tab;
  final ValueChanged<HomeTab> onTab;

  /// As many as fit evenly; more than that slide sideways.
  static const _fits = 5;

  @override
  Widget build(BuildContext context) {
    final entries = <Widget>[
      for (final each in tabs) _BottomTab(label: each.label, icon: Icon(each.icon), on: each == tab, onPressed: () => onTab(each)),
      for (final extra in extras) _BottomTab(label: extra.label, icon: extra.icon, on: false, onPressed: extra.onPressed),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xE60C0D14),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 74,
          child: entries.length > _fits
              // Exactly as five share the width, the rest further along.
              ? LayoutBuilder(
                  builder: (context, box) => ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    children: [
                      for (final entry in entries) SizedBox(width: (box.maxWidth - 8) / _fits, child: Center(child: entry)),
                    ],
                  ),
                )
              : Padding(
                  padding: EdgeInsets.symmetric(horizontal: entries.length > 3 ? 4 : 40),
                  child: Row(children: [for (final entry in entries) Expanded(child: entry)]),
                ),
        ),
      ),
    );
  }
}

class _BottomTab extends StatelessWidget {
  const _BottomTab({required this.label, required this.icon, required this.on, required this.onPressed});

  final String label;
  final Widget icon;
  final bool on;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final time = Duration(milliseconds: animationsOn(context) ? 300 : 0);
    return Semantics(
      selected: on,
      button: true,
      child: InkResponse(
        onTap: onPressed,
        radius: 48,
        child: Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: time,
                width: 62,
                height: 32,
                decoration: BoxDecoration(
                  color: on ? _lit : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: IconTheme.merge(data: IconThemeData(size: 20, color: on ? _ink : _quiet), child: icon),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(color: on ? Colors.white : _quiet, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
