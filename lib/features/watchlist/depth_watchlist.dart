part of 'watchlist_screen.dart';

// Depth's watchlist page ("Watchlist · desktop" in the design, with the
// phone version as its handoff describes): a title, a toolbar and the items,
// with no hero. Shows, episodes and movies stay apart, as everywhere else.

const _light = Color(0xFFF2F0FF);
const _ink = Color(0xFF0B0C12);
const _violet = Color(0xFF8F84FF);
const _cyan = Color(0xFF8EE6F5);
const _text = Color(0xFFE8E9F0);
const _muted = Color(0xFF9AA0B2);
const _faint = Color(0xFF7D8396);
const _surface = Color(0xFF0E1018);
const _glassFill = Color(0xC00A0B12);
const _glassBorder = Color(0x1AFFFFFF);
const _ease = Cubic(0.2, 0.8, 0.2, 1);

extension _Depth on _WatchlistScreenState {
  bool get _phone => context.layout.formFactor == FormFactor.phone;

  /// Home's bar over the page, with Back, and the tabs along the bottom on
  /// a phone; none of them is this page.
  Widget _depthFrame(BuildContext context, AsyncValue<List<BaseItem>> items, List<BaseItem> all, List<BaseItem> shown) {
    final session = ref.watch(currentSessionProvider);
    final tabs = (ref.watch(homeBarSettingsProvider).value ?? const HomeBarSettings()).tabs;
    void refresh() => ref.invalidate(watchlistProvider);
    final extras = homeTabExtras(context, ref, onRefresh: refresh);
    void onTab(HomeTab to) {
      ref.read(homeTabProvider.notifier).select(to);
      context.go('/');
    }

    final statusBar = statusBarHeight(context);
    final bar = HomeComponents.topBarActions.build(
      context,
      HomeTopBarData(
        onTab: onTab,
        tabs: tabs,
        extras: extras,
        serverName: session.serverName,
        host: session.baseUrl.host,
        title: Text(session.serverName),
        leading: Navigator.canPop(context) ? PillBackButton(onPressed: () => Navigator.maybePop(context)) : null,
        actions: homeActions(context, ref, onRefresh: refresh),
        scrolled: _scrolled,
      ),
      ref.watch(componentStyleProvider(Slots.homeTopBar)),
    );
    final body = switch (items) {
      AsyncError(:final error) when items.value == null => _DepthEmpty(
          title: "Couldn't load your watchlist",
          line: '$error',
          action: GhostButton(icon: Icons.refresh, label: 'Retry', height: 44, onPressed: refresh),
        ),
      _ when items.value == null => const Center(child: CircularProgressIndicator()),
      _ => _depthPage(context, all, shown, session.userName),
    };
    return ArtworkBackground(
      child: Scaffold(
        backgroundColor: ArtworkBackground.pageColor(ref),
        bottomNavigationBar: _phone && tabs.length + extras.length > 1
            ? HomeBottomNav(tab: null, onTab: onTab, tabs: tabs, extras: extras)
            : null,
        body: HidesStatusBar(
          child: Stack(
            children: [
              Positioned.fill(
                // Scrolling, and the page changing size (it can jump back to
                // the top without a scroll): the bar follows both.
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: (n) {
                    if (n.depth == 0) _scrolled.value = n.metrics.pixels;
                    return false;
                  },
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: (n) {
                      if (n.depth == 0) _scrolled.value = n.metrics.pixels;
                      return false;
                    },
                    child: FloatingSelectionBar(
                      selection: _selection,
                      controller: _scroll,
                      label: '${_selection.ids.length} selected',
                      actions: _bulkActions(all),
                      child: body,
                    ),
                  ),
                ),
              ),
              Positioned(top: statusBar, left: 0, right: 0, child: bar),
            ],
          ),
        ),
      ),
    );
  }

  Widget _depthPage(BuildContext context, List<BaseItem> all, List<BaseItem> shown, String user) {
    final width = MediaQuery.sizeOf(context).width;
    final phone = _phone;
    final side = phone ? 16.0 : math.max(context.layout.gutter, (width - 1400) / 2);
    final order = [for (final i in shown) i.id];
    final sections = _sections(shown);
    // The first title is behind the page until the mouse picks another.
    if (_artFor == null && shown.isNotEmpty) {
      _artFor = shown.first.id;
      final container = ProviderScope.containerOf(context, listen: false);
      final first = shown.first;
      WidgetsBinding.instance.addPostFrameCallback((_) => BackdropArt.show(first, container));
    }
    // A new filter, sort or view replays the items' entrance.
    final run = '${_filter.name}-${_sort.name}-$_list';

    return SelectionShortcuts(
      selection: _selection,
      selectAll: () => _selection.setAll(order),
      autofocus: true,
      child: RefreshIndicator(
        onRefresh: () => ref.refresh(watchlistProvider.future),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, phone ? statusBarHeight(context) + 78 : 132, side, 0),
              sliver: SliverToBoxAdapter(child: _titleBlock(context, all, user)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, phone ? 26 : 56, side, 0),
              sliver: SliverToBoxAdapter(child: phone ? _phoneToolbar(context, all, shown) : _pcToolbar(context, all, shown)),
            ),
            if (shown.isEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 32, side, 0),
                sliver: SliverToBoxAdapter(
                  child: _DepthEmpty(
                    title: 'Nothing here yet',
                    line: all.isEmpty
                        ? 'Use the bookmark on any title to add it to your watchlist.'
                        : 'No ${_filter.label.toLowerCase()} on your watchlist yet.',
                  ),
                ),
              )
            else
              for (final (kind, items) in sections) ...[
                if (_filter == WatchlistFilter.all)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(side, phone ? 26 : 44, side, 0),
                    sliver: SliverToBoxAdapter(child: Kick('${kind.label} · ${items.length}')),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, phone ? 14 : 22, side, 0),
                  sliver: _list
                      ? _depthList(context, items, order, run)
                      : _depthGrid(context, items, order, run, landscape: kind == WatchlistFilter.episodes),
                ),
              ],
            SliverToBoxAdapter(child: SizedBox(height: phone ? 120 : 140)),
          ],
        ),
      ),
    );
  }

  /// "All" keeps each kind in its own section; one kind is one run.
  List<(WatchlistFilter, List<BaseItem>)> _sections(List<BaseItem> shown) => _filter == WatchlistFilter.all
      ? [
          for (final f in const [WatchlistFilter.shows, WatchlistFilter.episodes, WatchlistFilter.movies])
            (f, [for (final i in shown) if (f.keeps(i)) i]),
        ].where((s) => s.$2.isNotEmpty).toList()
      : [(_filter, shown)];

  Widget _titleBlock(BuildContext context, List<BaseItem> all, String user) {
    final phone = _phone;
    final width = MediaQuery.sizeOf(context).width;
    final heading = CardLook.headingStyle(context) ?? const TextStyle();
    int count(WatchlistFilter f) => all.where(f.keeps).length;
    final counts = <(int, String)>[
      (all.length, all.length == 1 ? 'title' : 'titles'),
      for (final (f, one, many) in const [
        (WatchlistFilter.shows, 'show', 'shows'),
        (WatchlistFilter.episodes, 'episode', 'episodes'),
        (WatchlistFilter.movies, 'movie', 'movies'),
      ])
        if (count(f) > 0) (count(f), count(f) == 1 ? one : many),
    ];
    final countStyle = TextStyle(color: _muted, fontSize: phone ? 14 : 16, fontWeight: FontWeight.w600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RiseIn(delay: 0, child: Kick('Your list · $user')),
        SizedBox(height: phone ? 6 : 10),
        RiseIn(
          delay: 80,
          child: Text(
            'Watchlist',
            style: heading.copyWith(
              color: _text,
              fontSize: phone ? 48 : (width * 0.07).clamp(64.0, 104.0),
              fontWeight: FontWeight.w800,
              height: 1,
              letterSpacing: phone ? -1 : -2,
            ),
          ),
        ),
        SizedBox(height: phone ? 10 : 16),
        RiseIn(
          delay: 160,
          child: Text.rich(
            TextSpan(
              children: [
                for (final (i, (n, what)) in counts.indexed) ...[
                  if (i > 0) const TextSpan(text: '  ·  '),
                  TextSpan(text: '$n', style: const TextStyle(color: _text, fontWeight: FontWeight.w800)),
                  TextSpan(text: ' $what'),
                ],
              ],
            ),
            style: countStyle,
          ),
        ),
      ],
    );
  }

  int _count(List<BaseItem> all, WatchlistFilter f) => all.where(f.keeps).length;

  Widget _pcToolbar(BuildContext context, List<BaseItem> all, List<BaseItem> shown) {
    final label = _filter == WatchlistFilter.all
        ? '${shown.length} ${shown.length == 1 ? 'title' : 'titles'}'
        : '${_filter.label} · ${shown.length}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: SectionHeading(kick: label, title: 'On your list')),
            _GlassSegments<WatchlistSort>(
              slot: 116,
              value: _sort,
              options: [for (final s in WatchlistSort.values) (s, Text(s.short), s.label)],
              onChanged: (s) => _update(() => _sort = s),
            ),
            const SizedBox(width: 12),
            _GlassSegments<bool>(
              slot: 52,
              value: _list,
              options: const [
                (false, Icon(Icons.grid_view_rounded, size: 18), 'Grid'),
                (true, Icon(Icons.view_agenda_outlined, size: 18), 'List'),
              ],
              onChanged: (v) => _update(() => _list = v),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _GlassSegments<WatchlistFilter>(
          slot: 136,
          height: 48,
          value: _filter,
          options: [for (final f in WatchlistFilter.values) (f, _FilterLabel(f.label, _count(all, f)), f.label)],
          onChanged: (f) => _update(() => _filter = f),
        ),
        if (_sort != WatchlistSort.yours && _list) ...[
          const SizedBox(height: 12),
          const Text('Switch to Your order to reorder.', style: TextStyle(color: _faint, fontSize: 13, fontWeight: FontWeight.w600)),
        ] else if (_sort == WatchlistSort.yours && !_list) ...[
          const SizedBox(height: 12),
          const Text('List view lets you move them up and down.', style: TextStyle(color: _faint, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ],
    );
  }

  Widget _phoneToolbar(BuildContext context, List<BaseItem> all, List<BaseItem> shown) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, c) => _GlassSegments<WatchlistFilter>(
            slot: (c.maxWidth - 8) / WatchlistFilter.values.length,
            height: 44,
            value: _filter,
            options: [for (final f in WatchlistFilter.values) (f, _FilterLabel(f.label, _count(all, f), small: true), f.label)],
            onChanged: (f) => _update(() => _filter = f),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _GlassChip(
              icon: Icons.sort_rounded,
              label: _sort.label,
              onPressed: () => _sortSheet(context),
            ),
            const Spacer(),
            _GlassIcon(tooltip: 'Grid', icon: Icons.grid_view_rounded, on: !_list, onPressed: () => _update(() => _list = false)),
            const SizedBox(width: 8),
            _GlassIcon(tooltip: 'List', icon: Icons.view_agenda_outlined, on: _list, onPressed: () => _update(() => _list = true)),
          ],
        ),
      ],
    );
  }

  Future<void> _sortSheet(BuildContext context) async {
    final picked = await showModalBottomSheet<WatchlistSort>(
      context: context,
      backgroundColor: _surface,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.fromLTRB(20, 18, 20, 6), child: Align(alignment: Alignment.centerLeft, child: Kick('Sort'))),
            for (final s in WatchlistSort.values)
              ListTile(
                title: Text(s.label, style: const TextStyle(color: _text, fontWeight: FontWeight.w700)),
                trailing: s == _sort ? const Icon(Icons.check_rounded, color: _cyan) : null,
                onTap: () => Navigator.pop(sheet, s),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _update(() => _sort = picked);
  }

  /// A tap plays (a show opens its page), unless it's picking.
  void _open(BaseItem item, List<String> order) {
    if (_picking && !_selection.active) return _selection.toggle(item.id);
    if (_selection.tap(order, item.id)) return;
    openItem(context, item, play: item.type.isPlayable);
  }

  void _focus(BaseItem item) {
    if (_artFor == item.id) return;
    _artFor = item.id;
    BackdropArt.show(item, ProviderScope.containerOf(context, listen: false));
  }

  /// Phone: what a long press offers.
  Future<void> _itemSheet(BuildContext context, BaseItem item, List<BaseItem> section) async {
    final all = ref.read(watchlistProvider).value ?? section;
    final first = section.isEmpty ? null : section.first;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface,
      builder: (sheet) {
        void go(VoidCallback action) {
          Navigator.pop(sheet);
          action();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Align(alignment: Alignment.centerLeft, child: Kick(_titleOf(item))),
              ),
              if (item.type.isPlayable)
                _SheetTile(
                  icon: Icons.play_arrow_rounded,
                  label: item.userData.hasProgress ? 'Resume' : 'Play',
                  onTap: () => go(() => openItem(context, item, play: true)),
                ),
              _SheetTile(icon: Icons.info_outline_rounded, label: 'Details', onTap: () => go(() => openItem(context, item))),
              if (_sort == WatchlistSort.yours && first != null && first.id != item.id)
                _SheetTile(
                  icon: Icons.vertical_align_top_rounded,
                  label: 'Move to top',
                  onTap: () => go(() => ref.read(watchlistOrderProvider.notifier).move(all, item.id, before: first.id)),
                ),
              _SheetTile(
                icon: Icons.checklist_rounded,
                label: 'Select',
                onTap: () => go(() => _selection.toggle(item.id)),
              ),
              _SheetTile(
                icon: Icons.bookmark_remove_outlined,
                label: 'Remove from watchlist',
                onTap: () => go(() => CardActions(context).setWatchlisted([item], false)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _depthGrid(BuildContext context, List<BaseItem> items, List<String> order, String run, {required bool landscape}) {
    final phone = _phone;
    final ratio = landscape ? 16 / 9 : 2 / 3;
    // Room under the picture for the title and its line.
    const caption = 52.0;
    return SliverLayoutBuilder(
      builder: (context, c) {
        final columns = phone
            ? (landscape ? 2 : 3)
            : math.max(1, ((c.crossAxisExtent + 24) / ((landscape ? 300 : 184) + 24)).floor());
        final gap = phone ? 12.0 : 24.0;
        final tile = (c.crossAxisExtent - gap * (columns - 1)) / columns;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: phone ? 18 : 34,
            mainAxisExtent: tile / ratio + caption + (phone ? 0 : 6),
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            return RiseIn(
              key: ValueKey('$run-${item.id}'),
              delay: math.min(i * 30, 240),
              child: _DepthTile(
                item: item,
                width: tile,
                ratio: ratio,
                phone: phone,
                selected: _selection.contains(item.id),
                onPressed: () => _open(item, order),
                onFocus: () => _focus(item),
                onRemove: () => CardActions(context).setWatchlisted([item], false),
                onMenu: (at) => phone ? _itemSheet(context, item, items) : showCardMenu(context, item, at: at),
                onHold: () => _selection.toggle(item.id),
              ),
            );
          },
        );
      },
    );
  }

  Widget _depthList(BuildContext context, List<BaseItem> items, List<String> order, String run) {
    final phone = _phone;
    final reorder = _sort == WatchlistSort.yours && !_picking && items.length > 1;
    final all = ref.read(watchlistProvider).value ?? items;
    final mover = ref.read(watchlistOrderProvider.notifier);

    Widget row(BuildContext context, int i) {
      final item = items[i];
      final tile = _DepthRow(
        key: ValueKey(item.id),
        item: item,
        rank: i + 1,
        phone: phone,
        selected: _selection.contains(item.id),
        onPressed: () => _open(item, order),
        onFocus: () => _focus(item),
        onMenu: (at) => phone ? _itemSheet(context, item, items) : showCardMenu(context, item, at: at),
        onHold: () => _selection.toggle(item.id),
        onUp: reorder && i > 0 ? () => mover.move(all, item.id, before: items[i - 1].id) : null,
        onDown: reorder && i < items.length - 1 ? () => mover.move(all, item.id, after: items[i + 1].id) : null,
        onRemove: _picking ? null : () => CardActions(context).setWatchlisted([item], false),
        handle: phone && reorder ? ReorderableDragStartListener(index: i, child: const _Handle()) : null,
      );
      final rise = RiseIn(key: ValueKey('$run-${item.id}'), delay: math.min(i * 30, 240), child: tile);
      if (!phone || _picking) return KeyedSubtree(key: ValueKey(item.id), child: rise);
      // Phone: a swipe to the left removes it.
      return Dismissible(
        key: ValueKey(item.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: const Icon(Icons.bookmark_remove_outlined, color: _cyan),
        ),
        onDismissed: (_) => CardActions(context).setWatchlisted([item], false),
        child: rise,
      );
    }

    if (phone && reorder) {
      return SliverReorderableList(
        itemCount: items.length,
        itemBuilder: row,
        onReorderItem: (from, to) => _moved(items, from, to),
      );
    }
    return SliverList.builder(itemCount: items.length, itemBuilder: row);
  }
}

/// "Shows" with its count in a small badge.
class _FilterLabel extends StatelessWidget {
  const _FilterLabel(this.label, this.count, {this.small = false});

  final String label;
  final int count;
  final bool small;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false)),
          SizedBox(width: small ? 4 : 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: small ? 5 : 7, vertical: 1),
            decoration: BoxDecoration(color: const Color(0x26FFFFFF), borderRadius: BorderRadius.circular(999)),
            child: Text('$count', style: TextStyle(fontSize: small ? 10 : 11, fontWeight: FontWeight.w800)),
          ),
        ],
      );
}

/// A glass pill of equal slots with a light indicator sliding to the one
/// chosen: the filter tabs, sort and view.
class _GlassSegments<T> extends StatelessWidget {
  const _GlassSegments({
    required this.value,
    required this.options,
    required this.onChanged,
    required this.slot,
    this.height = 44,
  });

  final T value;

  /// Each option: its value, what it shows, and its name (tooltip, reader).
  final List<(T, Widget, String)> options;
  final ValueChanged<T> onChanged;
  final double slot;
  final double height;

  @override
  Widget build(BuildContext context) {
    final at = options.indexWhere((o) => o.$1 == value);
    final animate = animationsOn(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _glassFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _glassBorder),
      ),
      child: SizedBox(
        width: slot * options.length,
        height: height - 8,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: Duration(milliseconds: animate ? 380 : 0),
              curve: _ease,
              left: slot * math.max(0, at),
              top: 0,
              bottom: 0,
              width: slot,
              child: const DecoratedBox(decoration: BoxDecoration(color: _light, borderRadius: BorderRadius.all(Radius.circular(999)))),
            ),
            Row(
              children: [
                for (final (i, (v, child, name)) in options.indexed)
                  SizedBox(
                    width: slot,
                    child: Semantics(
                      selected: i == at,
                      button: true,
                      label: name,
                      child: Tooltip(
                        message: name,
                        waitDuration: const Duration(milliseconds: 600),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => onChanged(v),
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 200),
                              style: TextStyle(
                                color: i == at ? _ink : _muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                fontFamily: DefaultTextStyle.of(context).style.fontFamily,
                              ),
                              child: IconTheme.merge(
                                data: IconThemeData(color: i == at ? _ink : _muted),
                                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: child),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          backgroundColor: _glassFill,
          foregroundColor: _text,
          side: const BorderSide(color: _glassBorder),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        icon: Icon(icon, size: 17),
        label: Text(label),
        onPressed: onPressed,
      );
}

class _GlassIcon extends StatelessWidget {
  const _GlassIcon({required this.tooltip, required this.icon, required this.onPressed, this.on = false});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool on;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 40,
        child: IconButton(
          tooltip: tooltip,
          isSelected: on,
          style: IconButton.styleFrom(
            backgroundColor: on ? _light : _glassFill,
            foregroundColor: on ? _ink : _text,
            side: const BorderSide(color: _glassBorder),
            padding: EdgeInsets.zero,
          ),
          iconSize: 18,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      );
}

class _SheetTile extends StatelessWidget {
  const _SheetTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: _text),
        title: Text(label, style: const TextStyle(color: _text, fontWeight: FontWeight.w700)),
        onTap: onTap,
      );
}

/// The status pill on a poster: what's new about it, if anything.
(String, Color)? _pill(BaseItem item) {
  if (isShow(item)) {
    final left = item.userData.unplayedItemCount ?? 0;
    final started = (item.userData.playedPercentage ?? 0) > 0;
    if (left > 0 && started) return ('$left to watch', _light);
    return null;
  }
  if (item.userData.hasProgress) return ('In progress', _cyan);
  return null;
}

/// The line under a title, with the time left in cyan when it's started.
Widget _subline(BaseItem item, {double size = 12}) {
  final line = watchlistSubline(item);
  return Text(
    line,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: timeLeft(item) != null ? _cyan : _muted,
      fontSize: size,
      fontWeight: FontWeight.w600,
    ),
  );
}

/// A poster (or an episode's still) that lifts and tilts under the mouse,
/// with a shine, a play button and a remove button.
class _DepthTile extends StatefulWidget {
  const _DepthTile({
    required this.item,
    required this.width,
    required this.ratio,
    required this.phone,
    required this.selected,
    required this.onPressed,
    required this.onFocus,
    required this.onRemove,
    required this.onMenu,
    required this.onHold,
  });

  final BaseItem item;
  final double width;
  final double ratio;
  final bool phone;
  final bool selected;
  final VoidCallback onPressed;
  final VoidCallback onFocus;
  final VoidCallback onRemove;
  final ValueChanged<Offset?> onMenu;

  /// A hold: picks it for a batch action.
  final VoidCallback onHold;

  @override
  State<_DepthTile> createState() => _DepthTileState();
}

class _DepthTileState extends State<_DepthTile> {
  bool _hot = false;
  bool _down = false;

  void _setHot(bool hot) {
    if (hot == _hot) return;
    setState(() => _hot = hot);
    if (hot) widget.onFocus();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final lite = effectsOf(context) == EffectsLevel.lite;
    final tilt = depthOf(context);
    final landscape = widget.ratio > 1;
    final image = landscape ? (item.landscapeImage ?? item.backdropImage ?? item.posterImage) : (item.posterImage ?? item.landscapeImage);
    final fraction = isShow(item) ? 0.0 : watchedFraction(item);
    final pill = _pill(item);
    final picture = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: _surface),
          ItemImage(image: image, maxWidth: widget.width),
          if (fraction > 0) ...[
            // A faint cyan wash over the bottom, fading out to the right.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 64,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0x408EE6F5), Color(0x008EE6F5)],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 4,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Transform(
                  alignment: Alignment.centerLeft,
                  transform: Matrix4.diagonal3Values(fraction, 1, 1),
                  child: const SizedBox.expand(child: ColoredBox(color: _cyan)),
                ),
              ),
            ),
          ],
          if (!lite && !widget.phone)
            IgnorePointer(
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _hot ? 1 : 0),
                duration: Duration(milliseconds: _hot ? 900 : 0),
                curve: _ease,
                builder: (context, t, _) => t == 0 || t == 1
                    ? const SizedBox.shrink()
                    : FractionalTranslation(
                        translation: Offset(-1.2 + 2.4 * t, 0),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              stops: [0.35, 0.5, 0.65],
                              colors: [Color(0x00FFFFFF), Color(0x33FFFFFF), Color(0x00FFFFFF)],
                            ),
                          ),
                          child: SizedBox.expand(),
                        ),
                      ),
              ),
            ),
          if (pill != null)
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: pill.$2, borderRadius: BorderRadius.circular(999)),
                child: Text(
                  pill.$1.toUpperCase(),
                  style: const TextStyle(color: _ink, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                ),
              ),
            ),
          if (!widget.phone)
            AnimatedOpacity(
              opacity: _hot ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: !_hot,
                child: Stack(
                  children: [
                    Center(
                      child: Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: _light,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: _violet.withValues(alpha: 0.6), blurRadius: 24)],
                        ),
                        child: Icon(item.type.isPlayable ? Icons.play_arrow_rounded : Icons.arrow_forward_rounded, color: _ink, size: 30),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: GlassRound(
                        tooltip: 'Remove from watchlist',
                        size: 34,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: widget.onRemove,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (widget.selected)
            const DecoratedBox(
              decoration: BoxDecoration(
                border: Border.fromBorderSide(BorderSide(color: _cyan, width: 3)),
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              child: SizedBox.expand(),
            ),
          // Phone: the menu, as a hold picks.
          if (widget.phone)
            Positioned(
              right: 4,
              top: 4,
              child: GlassRound(
                tooltip: 'More',
                size: 30,
                icon: const Icon(Icons.more_vert),
                onPressed: () => widget.onMenu(null),
              ),
            ),
        ],
      ),
    );

    final lifted = TweenAnimationBuilder<double>(
      tween: Tween(end: _hot && !widget.phone ? 1 : 0),
      duration: Duration(milliseconds: animationsOn(context) ? 420 : 0),
      curve: _ease,
      child: picture,
      builder: (context, t, child) => Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..translateByDouble(0, -10 * t, 0, 1)
          ..rotateX(6 * math.pi / 180 * t * tilt)
          ..rotateY(-8 * math.pi / 180 * t * tilt),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _violet.withValues(alpha: 0.45 * t),
                blurRadius: 40,
                spreadRadius: -8,
                offset: const Offset(0, 22),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => _setHot(true),
      onExit: (_) => _setHot(false),
      child: GestureDetector(
        onSecondaryTapUp: (e) => widget.onMenu(e.globalPosition),
        child: InkWell(
          onTap: widget.onPressed,
          onLongPress: widget.onHold,
          onFocusChange: _setHot,
          onHighlightChanged: (down) => setState(() => _down = down),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedScale(
            scale: widget.phone && _down ? 0.97 : 1,
            duration: const Duration(milliseconds: 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(aspectRatio: widget.ratio, child: lifted),
                SizedBox(height: widget.phone ? 8 : 12),
                Text(
                  _titleOf(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _text, fontSize: widget.phone ? 13 : 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                _subline(item, size: widget.phone ? 11 : 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A ranked row: number, still, title and overview, and its moves.
class _DepthRow extends StatefulWidget {
  const _DepthRow({
    super.key,
    required this.item,
    required this.rank,
    required this.phone,
    required this.selected,
    required this.onPressed,
    required this.onFocus,
    required this.onMenu,
    required this.onHold,
    this.onUp,
    this.onDown,
    this.onRemove,
    this.handle,
  });

  final BaseItem item;
  final int rank;
  final bool phone;
  final bool selected;
  final VoidCallback onPressed;
  final VoidCallback onFocus;
  final ValueChanged<Offset?> onMenu;

  /// A hold: picks it for a batch action.
  final VoidCallback onHold;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onRemove;

  /// Phone: the drag handle, when it can be moved.
  final Widget? handle;

  @override
  State<_DepthRow> createState() => _DepthRowState();
}

class _DepthRowState extends State<_DepthRow> {
  bool _hot = false;

  void _setHot(bool hot) {
    if (hot == _hot) return;
    setState(() => _hot = hot);
    if (hot) widget.onFocus();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final phone = widget.phone;
    final heading = CardLook.headingStyle(context) ?? const TextStyle();
    final thumbWidth = phone ? 120.0 : 220.0;
    final fraction = isShow(item) ? 0.0 : watchedFraction(item);
    final kind = switch (item.type) {
      ItemType.series => 'Show',
      ItemType.season => 'Season',
      ItemType.episode => 'Episode',
      _ => 'Movie',
    };
    final second = item.type == ItemType.episode || item.type == ItemType.season ? item.name : null;

    final rank = Text(
      '${widget.rank}',
      textAlign: TextAlign.center,
      style: heading.copyWith(
        fontSize: phone ? 22 : 34,
        fontWeight: FontWeight.w800,
        height: 1,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = _hot ? _cyan : const Color(0x80E8E9F0),
      ),
    );
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(phone ? 10 : 14),
      child: SizedBox(
        width: thumbWidth,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: _surface),
              ItemImage(image: item.landscapeImage ?? item.backdropImage ?? item.posterImage, maxWidth: thumbWidth),
              if (fraction > 0)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Transform(
                    alignment: Alignment.centerLeft,
                    transform: Matrix4.diagonal3Values(fraction, 1, 1),
                    child: const SizedBox(height: 4, width: double.infinity, child: ColoredBox(color: _cyan)),
                  ),
                ),
              if (!phone)
                AnimatedOpacity(
                  opacity: _hot ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Center(
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(color: _light, shape: BoxShape.circle),
                      child: Icon(item.type.isPlayable ? Icons.play_arrow_rounded : Icons.arrow_forward_rounded, color: _ink),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final tilted = TweenAnimationBuilder<double>(
      tween: Tween(end: _hot && !phone ? 1 : 0),
      duration: Duration(milliseconds: animationsOn(context) ? 360 : 0),
      curve: _ease,
      child: thumb,
      builder: (context, t, child) => Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(8 * math.pi / 180 * t * depthOf(context))
          ..scaleByDouble(1 + 0.03 * t, 1 + 0.03 * t, 1, 1),
        child: child,
      ),
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _titleOf(item),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: heading.copyWith(color: _text, fontSize: phone ? 16 : 22, fontWeight: FontWeight.w700, height: 1.15),
        ),
        if (second != null)
          Text(second, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _text, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Row(
          children: [
            Text('$kind · ', style: TextStyle(color: _faint, fontSize: phone ? 11 : 13, fontWeight: FontWeight.w600)),
            Flexible(child: _subline(item, size: phone ? 11 : 13)),
          ],
        ),
        if (item.overview case final overview? when !phone) ...[
          const SizedBox(height: 8),
          Text(overview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 13, height: 1.4)),
        ],
      ],
    );

    final actions = <Widget>[
      if (!phone && widget.onUp != null || !phone && widget.onDown != null) ...[
        GlassRound(tooltip: 'Move up', size: 44, icon: const Icon(Icons.keyboard_arrow_up_rounded), onPressed: widget.onUp),
        const SizedBox(width: 8),
        GlassRound(tooltip: 'Move down', size: 44, icon: const Icon(Icons.keyboard_arrow_down_rounded), onPressed: widget.onDown),
        const SizedBox(width: 8),
      ],
      if (!phone && widget.onRemove != null)
        GlassRound(tooltip: 'Remove from watchlist', size: 44, icon: const Icon(Icons.close_rounded), onPressed: widget.onRemove),
      // Phone: the menu, as a hold picks.
      if (phone)
        IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, color: _muted),
          onPressed: () => widget.onMenu(null),
        ),
      ?widget.handle,
    ];

    return MouseRegion(
      onEnter: (_) => _setHot(true),
      onExit: (_) => _setHot(false),
      child: GestureDetector(
        onSecondaryTapUp: (e) => widget.onMenu(e.globalPosition),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: _hot && !phone ? 1 : 0),
          duration: Duration(milliseconds: animationsOn(context) ? 300 : 0),
          curve: _ease,
          builder: (context, t, child) => Transform.translate(offset: Offset(8 * t, 0), child: child),
          child: Container(
            margin: EdgeInsets.symmetric(vertical: phone ? 6 : 8),
            decoration: BoxDecoration(
              color: widget.selected ? _cyan.withValues(alpha: 0.10) : null,
              borderRadius: BorderRadius.circular(18),
              border: widget.selected ? Border.all(color: _cyan, width: 2) : null,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: widget.onPressed,
              onLongPress: widget.onHold,
              onFocusChange: _setHot,
              child: Padding(
                padding: EdgeInsets.all(phone ? 6 : 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: phone ? 28 : 56, child: rank),
                    SizedBox(width: phone ? 8 : 14),
                    tilted,
                    SizedBox(width: phone ? 12 : 22),
                    Expanded(child: text),
                    if (actions.isNotEmpty) ...[const SizedBox(width: 12), ...actions],
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

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) => const Tooltip(
        message: 'Drag to move',
        child: Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.drag_indicator_rounded, color: _muted),
        ),
      );
}

/// A dashed rounded box with a heading and a line.
class _DepthEmpty extends StatelessWidget {
  const _DepthEmpty({required this.title, required this.line, this.action});

  final String title;
  final String line;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final heading = CardLook.headingStyle(context) ?? const TextStyle();
    return CustomPaint(
      painter: const _Dashes(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, textAlign: TextAlign.center, style: heading.copyWith(color: _text, fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(line, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 14, height: 1.4)),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

class _Dashes extends CustomPainter {
  const _Dashes();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(22)));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x33FFFFFF);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 14) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 7, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => false;
}
