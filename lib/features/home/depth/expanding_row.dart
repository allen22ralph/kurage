import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/backdrop.dart';
import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../app/toast.dart';
import '../../../core/jellyfin/items.dart';
import '../../../core/jellyfin/jellyfin_api.dart';
import '../../../theme/app_tokens.dart';
import '../../library/library_providers.dart';
import '../../library/navigation.dart';
import '../../library/widgets/item_image.dart';
import '../../settings/appearance.dart';
import '../home_components.dart';
import 'deck_hero.dart';
import 'preview.dart';

/// Depth's expanding cards ("expanding"): stills with the episode and show
/// along their foot. The one pointed at opens wide (on a phone: tapped) to
/// its description: the episode, its title, the show, four lines of
/// overview and a play button, its preview playing in the still. The cards
/// after it turn away to the left, the ones before it to the right, both a
/// little smaller and dimmer.
class ExpandingRow extends StatefulWidget {
  const ExpandingRow({super.key, required this.data, this.kicker, this.currentId, this.actionLabel, this.onPlay, this.gutter, this.topGap = 32});

  final LibraryRowData data;
  final String? kicker;

  /// The item whose page this is on, marked "Now viewing".
  final String? currentId;

  /// Beside the open card's play button.
  final String Function(BaseItem item)? actionLabel;

  /// The open card's picture; by default it plays.
  final void Function(BaseItem item)? onPlay;

  /// The page's margin, when it has its own.
  final double? gutter;
  final double topGap;

  @override
  State<ExpandingRow> createState() => _ExpandingRowState();
}

/// Plays what a card shows: an episode or a film itself, a show where it's up
/// to. What has nothing to play opens its page.
Future<void> _play(BuildContext context, BaseItem item) async {
  if (item.type.isPlayable) return openItem(context, item, play: true);
  if (item.type != ItemType.series) return openItem(context, item);
  final api = ProviderScope.containerOf(context, listen: false).read(libraryApiProvider);
  try {
    final next = (await api.getNextUp(seriesId: item.id, limit: 1)).firstOrNull ?? await firstEpisodeOf(api, item.id);
    if (!context.mounted) return;
    openItem(context, next ?? item, play: next != null);
  } on JellyfinException catch (e) {
    showToast(e.message);
  }
}

class _ExpandingRowState extends State<ExpandingRow> {
  int? _open;

  @override
  Widget build(BuildContext context) {
    final items = widget.data.items.value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    final layout = context.layout;
    final phone = layout.formFactor == FormFactor.phone;
    final tv = layout.formFactor == FormFactor.tv;
    // The design's sizes: 200 opening to 560 (a phone 118 → 300, a TV
    // 260 → 820), 270 tall.
    final closed = phone ? 118.0 : (tv ? 260.0 : 200.0);
    final open = phone ? 300.0 : (tv ? 820.0 : 560.0);
    final height = phone ? 200.0 : (tv ? 360.0 : 270.0);
    final still = phone ? 118.0 : (tv ? 300.0 : 220.0);
    final gutter = widget.gutter ?? layout.gutter;
    return Padding(
      padding: EdgeInsets.only(top: widget.topGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: KickerHeading(
              kicker: widget.kicker ?? 'Just landed',
              title: Text(widget.data.title, style: CardLook.headingStyle(context)),
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            height: height,
            child: MouseRegion(
              onExit: (_) => phone ? null : setState(() => _open = null),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: gutter),
                clipBehavior: Clip.none,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, i) => _Card(
                  item: items[i],
                  current: items[i].id == widget.currentId,
                  actionLabel: widget.actionLabel?.call(items[i]),
                  onPlay: () => widget.onPlay == null ? _play(context, items[i]) : widget.onPlay!(items[i]),
                  open: _open == i,
                  // Which side of the open one: -1 before, 1 after, 0 none.
                  side: _open == null || _open == i ? 0 : (i < _open! ? -1 : 1),
                  closedWidth: closed,
                  openWidth: open,
                  stillWidth: still,
                  phone: phone,
                  onPoint: (on) {
                    if (on) setState(() => _open = i);
                  },
                  onTap: () {
                    if (phone && _open != i) {
                      setState(() => _open = i);
                    } else {
                      widget.data.onItemPressed(items[i]);
                    }
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatefulWidget {
  const _Card({
    required this.item,
    this.current = false,
    this.actionLabel,
    required this.onPlay,
    required this.open,
    required this.side,
    required this.closedWidth,
    required this.openWidth,
    required this.stillWidth,
    required this.phone,
    required this.onPoint,
    required this.onTap,
  });

  final BaseItem item;
  final bool current;
  final String? actionLabel;
  final VoidCallback onPlay;
  final bool open;
  final int side;
  final double closedWidth;
  final double openWidth;
  final double stillWidth;
  final bool phone;
  final void Function(bool on) onPoint;
  final VoidCallback onTap;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final moving = animationsOn(context);
    final item = widget.item;
    final cyan = context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    final duration = Duration(milliseconds: moving ? 750 : 0);
    const curve = Cubic(0.2, 0.8, 0.2, 1);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onPoint(true);
        BackdropArt.show(item, ProviderScope.containerOf(context, listen: false));
      },
      onExit: (_) => setState(() => _hover = false),
      child: Focus(
        onFocusChange: (f) => widget.onPoint(f),
        child: GestureDetector(
          onTap: widget.onTap,
          child: TweenAnimationBuilder<double>(
            // The turn of the ones beside the open card.
            tween: Tween(end: widget.side.toDouble()),
            duration: duration,
            curve: curve,
            builder: (context, side, child) => side == 0
                ? child!
                : Transform(
                    alignment: side < 0 ? Alignment.centerRight : Alignment.centerLeft,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 1 / 1100)
                      ..rotateY(-side * 16 * math.pi / 180)
                      ..scaleByDouble(1 - 0.05 * side.abs(), 1 - 0.05 * side.abs(), 1, 1),
                    child: child,
                  ),
            child: AnimatedContainer(
              duration: duration,
              curve: curve,
              width: widget.open ? widget.openWidth : widget.closedWidth,
              decoration: BoxDecoration(
                color: context.tokens.surface ?? const Color(0xFF0E1018),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: widget.open
                      ? cyan.withValues(alpha: 0.55)
                      : (widget.current ? const Color(0x998F84FF) : Colors.white.withValues(alpha: 0.08)),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: math.max(widget.stillWidth, widget.closedWidth),
                      // On a show's own page: the episode's title, not the show.
                      child: GestureDetector(
                        // Open, the picture plays; closed, the tap is the card's.
                        onTap: widget.open ? widget.onPlay : null,
                        child: _Still(
                          item: item,
                          preview: widget.open && _hover && !widget.phone,
                          ownTitle: widget.actionLabel != null,
                          // The still can be wider than a closed card: the words
                          // stay within what shows.
                          hidden: math.max(0, widget.stillWidth - widget.closedWidth),
                        ),
                      ),
                    ),
                    // The play button, in the middle of the picture.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: math.max(widget.stillWidth, widget.closedWidth),
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: widget.open ? 1 : 0,
                          duration: Duration(milliseconds: moving ? 250 : 0),
                          child: Center(
                            child: Semantics(
                              button: true,
                              label: '${widget.actionLabel ?? 'Play'} ${item.name}',
                              child: Container(
                                width: widget.phone ? 38 : 48,
                                height: widget.phone ? 38 : 48,
                                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xF2F2F0FF)),
                                child: const Icon(Icons.play_arrow_rounded, color: Color(0xFF0B0C12)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.current)
                      Positioned(
                        left: 10,
                        top: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: const Color(0xFFF2F0FF), borderRadius: BorderRadius.circular(999)),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            child: Text(
                              'NOW VIEWING',
                              style: TextStyle(color: Color(0xFF0B0C12), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                            ),
                          ),
                        ),
                      ),
                    // The description, sliding in once the card has opened.
                    Positioned(
                      left: widget.stillWidth,
                      top: 0,
                      bottom: 0,
                      width: widget.openWidth - widget.stillWidth,
                      child: _Delayed(
                        show: widget.open,
                        after: Duration(milliseconds: moving ? 280 : 0),
                        child: _Description(item: item, phone: widget.phone, ownTitle: widget.actionLabel != null),
                      ),
                    ),
                    // Dimmed while another is open.
                    IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        color: Colors.black.withValues(alpha: widget.side != 0 ? 0.4 : 0),
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

/// The still, the episode playing over it when opened, and the episode and
/// show along its foot.
class _Still extends StatelessWidget {
  const _Still({required this.item, required this.preview, this.ownTitle = false, this.hidden = 0});

  final BaseItem item;
  final bool preview;
  final bool ownTitle;

  /// How much of its right side a closed card cuts off.
  final double hidden;

  @override
  Widget build(BuildContext context) {
    final cyan = context.tokens.accent2 ?? Theme.of(context).colorScheme.secondary;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF111111)),
        RepaintBoundary(child: ItemImage(image: item.landscapeImage ?? item.posterImage, maxWidth: 300)),
        EpisodePreview(item: item, active: preview),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x0006070B), Color(0xE606070B)],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 14, 14 + hidden, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_code(item) case final code?)
                    Text(code, style: TextStyle(color: cyan, fontSize: 12, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(
                    ownTitle ? item.name : _show(item),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, height: 1.2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Description extends StatelessWidget {
  const _Description({required this.item, required this.phone, this.ownTitle = false});

  final BaseItem item;
  final bool phone;
  final bool ownTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = context.tokens.textMuted ?? const Color(0xFF9AA0B2);
    final cyan = context.tokens.accent2 ?? theme.colorScheme.secondary;
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? 14 : 24, phone ? 14 : 22, phone ? 14 : 24, phone ? 14 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_code(item) case final code?)
            Text(
              code.toUpperCase(),
              style: TextStyle(color: cyan, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 2.4),
            ),
          const SizedBox(height: 8),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontSize: phone ? 18 : 24,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          if (item.type == ItemType.episode && !ownTitle) ...[
            const SizedBox(height: 8),
            Text(
              _show(item),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
          if (item.overview case final overview? when overview.isNotEmpty && !phone) ...[
            const SizedBox(height: 8),
            Text(
              overview,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFC4C7D4), fontSize: 14, height: 1.55),
            ),
          ],
        ],
      ),
    );
  }
}

/// [child] appears [after] a moment once [show], sliding in from the left;
/// gone at once otherwise.
class _Delayed extends StatefulWidget {
  const _Delayed({required this.show, required this.after, required this.child});

  final bool show;
  final Duration after;
  final Widget child;

  @override
  State<_Delayed> createState() => _DelayedState();
}

class _DelayedState extends State<_Delayed> {
  bool _shown = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(_Delayed old) {
    super.didUpdateWidget(old);
    if (old.show != widget.show) _update();
  }

  void _update() {
    final generation = ++_generation;
    if (!widget.show) {
      if (_shown) setState(() => _shown = false);
      return;
    }
    Future<void>.delayed(widget.after, () {
      if (mounted && generation == _generation) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) =>
      _shown ? RiseIn(delay: 0, child: widget.child) : const SizedBox.shrink();
}

/// An episode's "S1:E5"; else the year.
String? _code(BaseItem item) => item.episodeLabel ?? item.productionYear?.toString();

/// The show an episode is from; else the item's name.
String _show(BaseItem item) => item.type == ItemType.episode ? item.seriesName ?? item.name : item.name;
