import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/seerr/seerr_api.dart';
import '../features/auth/accounts_screen.dart';
import '../features/auth/connect_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/quick_connect_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/home/home_editor.dart';
import '../features/home/home_screen.dart';
import '../features/library/item_detail_screen.dart';
import '../features/library/library_screen.dart';
import '../features/player/player_screen.dart';
import '../features/search/search_screen.dart';
import '../features/seerr/seerr_screens.dart';
import '../features/settings/settings_screen.dart';
import 'providers.dart';
import '../core/log/app_log.dart';
import 'system_nav_bar.dart';
import '../features/watchlist/watchlist_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // Re-run redirects whenever sign-in state changes, without rebuilding
  // the router (which would reset navigation).
  final refresh = ValueNotifier(0);
  late final GoRouter router;
  ref.listen(sessionControllerProvider, (previous, next) {
    refresh.value++;
    // Signing in or switching accounts starts over at home. Redirects alone
    // leave pushed screens (accounts, connect, login) on the stack.
    final key = next.value?.key;
    if (previous?.hasValue != true || key == null) return;
    // Also the same account picked again on a sign-in screen (added again,
    // or picked from the login page's saved accounts): those pages show
    // nothing once the sign-in flow is over, so they mustn't stay on top.
    // Pushed pages, not the location: a redirect can move the location to
    // '/' and leave the pushed sign-in pages on the stack.
    final onSignIn =
        router.routerDelegate.currentConfiguration.matches.any((m) => m.matchedLocation.startsWith('/connect'));
    if (key != previous?.value?.key || onSignIn) {
      router.go('/');
    }
  });
  ref.listen(loginFlowProvider, (_, _) => refresh.value++);

  router = GoRouter(
    initialLocation: '/',
    observers: [AppLogNavigation(), SystemNavBar.observer()],
    refreshListenable: refresh,
    redirect: (context, state) => authRedirect(
      session: ref.read(sessionControllerProvider),
      loginFlow: ref.read(loginFlowProvider),
      location: state.matchedLocation,
    ),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const _SplashScreen()),
      GoRoute(
        path: '/connect',
        builder: (_, _) => const ConnectScreen(),
        routes: [
          GoRoute(path: 'login', builder: (_, _) => const LoginScreen()),
          GoRoute(
            path: 'quick-connect',
            builder: (_, _) => const QuickConnectScreen(),
          ),
        ],
      ),
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/accounts', builder: (_, _) => const AccountsScreen()),
      GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
      GoRoute(path: '/requests', builder: (_, _) => const SeerrRequestsScreen()),
      GoRoute(
        path: '/seerr/:type/:id',
        builder: (_, state) => SeerrDetailScreen(
          type: SeerrMediaType.of(state.pathParameters['type']) ?? SeerrMediaType.tv,
          tmdbId: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, state) => SettingsScreen(initial: SettingsCategory.fromName(state.uri.queryParameters['section'])),
      ),
      GoRoute(path: '/downloads', builder: (_, _) => const DownloadsScreen()),
      GoRoute(path: '/watchlist', builder: (_, _) => const WatchlistScreen()),
      GoRoute(path: '/settings/home', builder: (_, _) => const HomeEditorScreen()),
      GoRoute(
        path: '/favorites',
        builder: (_, _) => const LibraryScreen(viewId: null),
      ),
      GoRoute(
        path: '/genre/:name',
        builder: (_, state) {
          final genre = state.pathParameters['name']!;
          return LibraryScreen(viewId: null, genre: genre, title: genre);
        },
      ),
      GoRoute(
        path: '/library/:id',
        builder: (_, state) => LibraryScreen(viewId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/item/:id',
        builder: (_, state) => ItemDetailScreen(
          itemId: state.pathParameters['id']!,
          seasonId: state.uri.queryParameters['season'],
        ),
      ),
      GoRoute(
        path: '/play/:id',
        builder: (_, state) => PlayerScreen(
          itemId: state.pathParameters['id']!,
          fromStart: state.uri.queryParameters['fromStart'] == '1',
          openedBy: state.uri.queryParameters['via'],
          playlistId: state.uri.queryParameters['playlist'],
        ),
      ),
    ],
  );

  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

/// Where to send the user given their sign-in state, or null to stay.
@visibleForTesting
String? authRedirect({
  required AsyncValue<Object?> session,
  required LoginFlowState loginFlow,
  required String location,
}) {
  if (!session.hasValue && !session.hasError) {
    // Still reading saved sessions from secure storage.
    return location == '/splash' ? null : '/splash';
  }

  // If storage couldn't be read, treat it as signed out.
  final signedIn = session.value != null;
  final inSignIn = location.startsWith('/connect');

  if (!signedIn || loginFlow.addingAccount) {
    if (!inSignIn) {
      if (signedIn) return null;
      // After signing out, stay on the same server's login screen.
      return loginFlow.server == null ? '/connect' : '/connect/login';
    }
    // Later sign-in steps need a server picked on the connect screen.
    if (location != '/connect' && loginFlow.server == null) return '/connect';
    return null;
  }
  return inSignIn || location == '/splash' ? '/' : null;
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

/// Pages opened and closed, in the app log (what led up to a problem).
class AppLogNavigation extends NavigatorObserver {
  static String _name(Route<dynamic>? r) => r?.settings.name ?? r?.settings.toString() ?? '?';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) AppLog.debug(LogArea.navigation, 'Opened ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) AppLog.debug(LogArea.navigation, 'Closed ${_name(route)}');
  }
}
