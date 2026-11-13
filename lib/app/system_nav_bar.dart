import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/player/open_player.dart';
import 'layout.dart';

/// Android phones: the system navigation bar (◁ ○ ☰) goes as a page is
/// scrolled down and comes back on scrolling up, as in Chrome. On a page
/// that can't scroll it stays, the page's own colour running behind it
/// (as in Play Store) rather than Android's see-through grey strip.
/// The player sets the bar itself; TVs and desktops have none.
class SystemNavBar extends ConsumerStatefulWidget {
  const SystemNavBar({super.key, required this.child});

  final Widget child;

  /// Tests: as on Android (or not).
  @visibleForTesting
  static bool? debugAndroid;

  /// The page (or dialog) in front.
  static final front = ValueNotifier<Route<dynamic>?>(null);

  /// For the router's observers: keeps [front] up to date (a new one per
  /// router: an observer belongs to one navigator).
  static NavigatorObserver observer() => _PagesObserver();

  @override
  ConsumerState<SystemNavBar> createState() => _SystemNavBarState();
}

/// On a page that lays itself out under the status bar: scrolling down hides
/// that bar too, not just the navigation bar.
class HidesStatusBar extends StatelessWidget {
  const HidesStatusBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _PagesObserver extends NavigatorObserver {
  ValueNotifier<Route<dynamic>?> get front => SystemNavBar.front;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => front.value = route;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => front.value = previousRoute;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (front.value == route) front.value = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (front.value == oldRoute) front.value = newRoute;
  }
}

class _SystemNavBarState extends ConsumerState<SystemNavBar> {
  bool _hidden = false;
  bool _statusBarHidden = false;

  /// Pages seen to scroll (vertically, with more than fits).
  final _scrolls = Expando<bool>();

  bool get _on => (SystemNavBar.debugAndroid ?? Platform.isAndroid) && !ref.read(isTvProvider);

  Route<dynamic>? get _front => SystemNavBar.front.value;

  @override
  void initState() {
    super.initState();
    SystemNavBar.front.addListener(_pageChanged);
    // Drawn behind the bar, so a page can show through it (Android 15 does
    // this anyway; earlier versions need asking).
    if (_on) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    SystemNavBar.front.removeListener(_pageChanged);
    super.dispose();
  }

  /// Another page: the bar is back, in that page's style.
  void _pageChanged() {
    _show();
    _rebuild();
  }

  /// After this frame: page changes and scrolling are told mid-build.
  void _rebuild() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });

  void _show() {
    if (!_hidden) return;
    _hidden = false;
    _statusBarHidden = false;
    if (_on && OpenPlayer.itemId.value == null) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _hide({required bool statusBar}) {
    if (!_on || OpenPlayer.itemId.value != null) return;
    if (_hidden && _statusBarHidden == statusBar) return;
    _hidden = true;
    _statusBarHidden = statusBar;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: statusBar ? const [] : const [SystemUiOverlay.top],
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final page = _front;
    if (page != null && n.metrics.maxScrollExtent > 0 && _scrolls[page] != true) {
      _scrolls[page] = true;
      _rebuild();
    }
    if (n is UserScrollNotification) {
      switch (n.direction) {
        case ScrollDirection.reverse:
          _hide(statusBar: n.context?.findAncestorWidgetOfExactType<HidesStatusBar>() != null);
        case ScrollDirection.forward:
          _show();
        case ScrollDirection.idle:
          break;
      }
    }
    // Back at the top: nothing left to make room for.
    if (n is ScrollEndNotification && n.metrics.pixels <= n.metrics.minScrollExtent) _show();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return widget.child;
    final page = _front;
    final scrolls = page != null && _scrolls[page] == true;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          // Scrolling pages: Android's own see-through strip. Pages that
          // can't scroll: none, so the page shows behind the buttons.
          systemNavigationBarContrastEnforced: scrolls,
        ),
        child: widget.child,
      ),
    );
  }
}
