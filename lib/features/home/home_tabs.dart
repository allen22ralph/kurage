import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../library/library_screen.dart';
import 'home_components.dart';

/// The pages a theme with tabs (Depth) moves between, on Home's screen.
enum HomeTab {
  home('Home', Icons.home_outlined),
  movies('Movies', Icons.local_movies_outlined, ItemType.movie),
  shows('Shows', Icons.live_tv_outlined, ItemType.series);

  const HomeTab(this.label, this.icon, [this.lists]);

  final String label;
  final IconData icon;

  /// What the page lists, across all libraries (null: Home's own rows).
  final ItemType? lists;
}

/// The tab showing. Each account starts on Home.
final homeTabProvider = NotifierProvider<HomeTabController, HomeTab>(HomeTabController.new);

class HomeTabController extends Notifier<HomeTab> {
  /// How far each page had scrolled, for what follows it (the top bar, the
  /// header's deck).
  final _scrolled = <HomeTab, double>{};

  @override
  HomeTab build() {
    ref.watch(sessionControllerProvider.select((s) => s.value?.key));
    return HomeTab.home;
  }

  void select(HomeTab tab) {
    if (tab == state) return;
    _scrolled[state] = HomeComponents.scrolled.value;
    state = tab;
    HomeComponents.scrolled.value = _scrolled[tab] ?? 0;
  }
}

/// Bumped by the top bar's Refresh: the listing pages load again.
final homeTabRefreshProvider = NotifierProvider<HomeTabRefresh, int>(HomeTabRefresh.new);

class HomeTabRefresh extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// The tabs' pages, each kept as it was left (where it had scrolled to, its
/// filters). A page out of sight takes no taps or focus, and its trailers and
/// previews stop as they do under any other page. Movies and Shows load when
/// first opened.
class HomeTabPages extends StatefulWidget {
  const HomeTabPages({super.key, required this.tab, required this.home});

  final HomeTab tab;
  final Widget home;

  @override
  State<HomeTabPages> createState() => _HomeTabPagesState();
}

class _HomeTabPagesState extends State<HomeTabPages> {
  final _opened = <HomeTab>{};

  @override
  Widget build(BuildContext context) {
    _opened.add(widget.tab);
    return IndexedStack(
      index: widget.tab.index,
      children: [
        for (final tab in HomeTab.values)
          ExcludeFocus(
            excluding: tab != widget.tab,
            child: TickerMode(
              enabled: tab == widget.tab,
              child: switch (tab) {
                HomeTab.home => widget.home,
                _ when !_opened.contains(tab) => const SizedBox.shrink(),
                _ => NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    if (tab == widget.tab && n.depth == 0 && n.metrics.axis == Axis.vertical) {
                      HomeComponents.scrolled.value = n.metrics.pixels;
                    }
                    return false;
                  },
                  child: LibraryScreen(viewId: null, allOf: tab.lists, title: tab.label),
                ),
              },
            ),
          ),
      ],
    );
  }
}
