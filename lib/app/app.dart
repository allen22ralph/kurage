import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'toast.dart';
import '../features/admin/admin_providers.dart';
import '../features/player/open_player.dart';
import '../features/library/library_providers.dart';
import '../features/library/widgets/side_scroll.dart';
import '../features/syncplay/syncplay_service.dart';
import '../features/update/update_ui.dart';
import 'router.dart';
import 'system_nav_bar.dart';
import 'theme.dart';
import '../features/settings/appearance.dart';
import '../theme/fonts.dart';
import '../theme/theme_choice.dart';

class JellyfinClientApp extends ConsumerStatefulWidget {
  const JellyfinClientApp({super.key});

  @override
  ConsumerState<JellyfinClientApp> createState() => _JellyfinClientAppState();
}

class _JellyfinClientAppState extends ConsumerState<JellyfinClientApp> {
  // Back in front (a phone's screen unlocked): rejoin the watch-together
  // group straight away if the connection dropped meanwhile.
  late final AppLifecycleListener _lifecycle;

  /// A newer version of the app on the chosen channel: a notification.
  late final UpdateWatcher _updates;

  /// The group's item last acted on: the server sends the queue again on
  /// many group events, and the same item mustn't reopen the player (e.g.
  /// just after the user left it).
  String? _groupItem;

  /// The group plays something new: the player follows if it's open;
  /// otherwise ask (never a player out of nowhere, e.g. on joining).
  Future<void> _onGroupQueue(String item) async {
    if (item == _groupItem) return;
    _groupItem = item;
    final router = ref.read(routerProvider);
    // Just left it: a group update arriving as the player closed mustn't
    // bring it back.
    if (OpenPlayer.justLeft(item)) return;
    final open = OpenPlayer.itemId.value;
    if (open == item) return;
    if (open != null) {
      router.pushReplacement('/play/$item?via=group');
      return;
    }
    final group = ref.read(syncPlayProvider).group?.name ?? 'The group';
    // Its name straight from the server, briefly: the cached lookup only
    // finished once a page showing it (the player) opened, so the prompt
    // never came on Home and turned up in the player instead.
    final name = await ref
        .read(libraryApiProvider)
        .getItem(item)
        .timeout(const Duration(seconds: 3))
        .then((i) => [i.seriesName, i.episodeLabel, i.name].nonNulls.join(' · '), onError: (Object _) => 'something');
    // Opened meanwhile: no need to ask.
    if (OpenPlayer.itemId.value == item || !ref.read(syncPlayProvider).inGroup) return;
    showToast(
      '$group is watching $name. Join in?',
      actionLabel: 'Join',
      // Joining may come after the player has been opened another way.
      onAction: () => openGroupItem(router, ref.read(syncPlayProvider.notifier), item, via: 'join'),
      duration: const Duration(seconds: 20),
      id: 'syncplay-join',
    );
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => ref.read(syncPlayProvider.notifier).resumed());
    _updates = UpdateWatcher(
      ProviderScope.containerOf(context, listen: false),
      open: (release) {
        final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
        if (context != null) showUpdateDialog(context, release);
      },
    )..start();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _updates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch together's per-device settings, loaded now: read for the first
    // time on leaving the player, they'd still be their defaults.
    ref.watch(syncPlayPauseOnLeaveProvider);
    ref.watch(syncPlayAudioDelayProvider);
    // Known before a card menu or Settings needs it (admin entries).
    ref.listen(isAdminProvider, (_, _) {});
    // Watch together: open what the group plays; say who joins / leaves.
    ref.listen(syncPlayQueueStreamProvider, (_, next) {
      if (next.value?.current?.itemId case final item?) _onGroupQueue(item);
    });
    // Out of the group: a later group starts afresh.
    ref.listen(syncPlayProvider.select((s) => s.inGroup), (_, inGroup) {
      if (!inGroup) _groupItem = null;
    });
    ref.listen(syncPlayNoticeStreamProvider, (_, next) {
      if (next.value case final notice?) {
        showToast(notice);
      }
    });
    final effects = ref.watch(appearanceProvider.select((a) => a.value?.effects)) ?? EffectsLevel.full;
    return MaterialApp.router(
      scaffoldMessengerKey: rootMessengerKey,
      title: 'Kurage',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(
        ref.watch(appearanceProvider).value ?? const AppearanceSettings(),
        ref.watch(activeThemeProvider),
        ref.watch(themeChoiceProvider.select((c) => c.value?.font)),
        ref.watch(addedFontsProvider.select((f) => f.value?.keys.toSet() ?? const <String>{})),
        ref.watch(themeChoiceProvider.select((c) => c.value?.googleFonts ?? false)),
      ),
      routerConfig: ref.watch(routerProvider),
      // Rows can be dragged with a mouse too (desktop).
      scrollBehavior: const AppScrollBehavior(),
      // Text fields keep Up/Down for the caret, which traps a TV remote's
      // D-pad in them. Our fields are all single-line, so Up/Down move
      // focus instead (Left/Right still move the caret). Sits below the
      // app's default text-editing shortcuts, so it takes precedence.
      builder: (context, child) => EffectsScope(
        level: MediaQuery.disableAnimationsOf(context) ? EffectsLevel.lite : effects,
        child: ToastHost(
        child: SystemNavBar(
        child: Shortcuts(
        shortcuts: const {
          // ignoreTextFields: false, or the intent does nothing inside one.
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
            TraversalDirection.up,
            ignoreTextFields: false,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
            TraversalDirection.down,
            ignoreTextFields: false,
          ),
        },
        child: child!,
      ),
      ),
      ),
      ),
    );
  }
}
