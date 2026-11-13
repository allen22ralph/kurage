import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/layout.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../../core/log/app_log.dart';
import '../library/library_providers.dart';
import '../library/navigation.dart';
import '../library/widgets/card_actions.dart';
import '../library/widgets/item_image.dart';
import '../player/open_player.dart';
import '../settings/playback_settings.dart';
import '../../theme/components.dart';
import '../settings/appearance.dart';
import 'depth/deck_hero.dart';
import 'depth/preview.dart';
import 'depth/programme_hero.dart';
import 'depth/side_deck.dart';
import 'home_components.dart';
import 'home_header_settings.dart';
import '../../app/backdrop.dart';

/// Puts "A mix" in a new order each time. A no-op in tests, to keep them exact.
final featuredShuffleProvider = Provider<void Function(List<BaseItem>)>((ref) => (list) => list.shuffle());

/// "A mix": the first five (all that the programme and the deck's front show)
/// have room for each kind, so random picks always reach the screen: two of
/// what you're [watching], one [fresh] title, two [random]. Whatever is
/// missing comes from the rest, and the rest follows, up to [count].
@visibleForTesting
List<BaseItem> composeFeaturedMix({
  required List<BaseItem> watching,
  required List<BaseItem> fresh,
  required List<BaseItem> random,
  required int count,
  required void Function(List<BaseItem>) shuffle,
}) {
  final pools = [
    (_shuffled(watching, shuffle), 2),
    (_shuffled(fresh, shuffle), 1),
    (_shuffled(random, shuffle), 2),
  ];
  final seen = <String>{};
  final first = <BaseItem>[];
  void take(List<BaseItem> pool, int wanted, List<BaseItem> into) {
    var taken = 0;
    while (taken < wanted && pool.isNotEmpty) {
      final i = pool.removeAt(0);
      if (seen.add(i.id)) {
        into.add(i);
        taken++;
      }
    }
  }

  for (final (pool, wanted) in pools) {
    take(pool, wanted, first);
  }
  final rest = <BaseItem>[];
  for (final (pool, _) in pools) {
    take(pool, count, rest);
  }
  shuffle(rest);
  // Topped up from the rest, then all in a new order.
  while (first.length < 5 && rest.isNotEmpty) {
    first.add(rest.removeAt(0));
  }
  shuffle(first);
  return [...first, ...rest].take(count).toList();
}

List<BaseItem> _shuffled(List<BaseItem> list, void Function(List<BaseItem>) shuffle) {
  final copy = [...list];
  shuffle(copy);
  return copy;
}

/// The shows and movies Home's header features (#100), with what it shows.
final headerFeaturedProvider = FutureProvider<List<BaseItem>>((ref) async {
  final settings = await ref.watch(homeHeaderSettingsProvider.future);
  final api = ref.watch(libraryApiProvider);
  const count = 10;
  final ids = <String>[];
  void add(String? id) {
    if (id != null && !ids.contains(id)) ids.add(id);
  }

  String? showOf(BaseItem i) => i.type == ItemType.episode ? i.seriesId : i.id;

  // A request that fails counts as nothing found; but if nothing at all
  // could be found because they failed, that's an error (retried below).
  Object? failure;
  List<BaseItem> none(Object e) {
    failure ??= e;
    return const [];
  }

  final mode = settings.featured;
  final mix = mode == HeaderFeatured.mix;
  if (mix || mode == HeaderFeatured.continueWatching) {
    final resume = await api.getResume(limit: 12).catchError(none);
    final nextUp = await api.getNextUp(limit: 12).catchError(none);
    for (final i in [...resume, ...nextUp]) {
      add(showOf(i));
    }
  }
  final watching = ids.length;
  if (mix || mode == HeaderFeatured.recentlyAdded) {
    final views = await api.getViews().catchError(none);
    for (final view in views) {
      if (!const {'movies', 'tvshows'}.contains(view.collectionType)) continue;
      final latest = await api.getLatest(view.id, limit: 8).catchError(none);
      for (final i in latest) {
        add(showOf(i));
      }
    }
  }
  final found = await api.getFeatured(ids).catchError(none);
  bool hasArt(BaseItem i) => i.backdropImage != null;
  final List<BaseItem> featured;
  if (mix) {
    final byId = {for (final i in found) i.id: i};
    final random = await api.getRandomFeatured(limit: count * 2).catchError(none);
    featured = composeFeaturedMix(
      watching: [for (final id in ids.take(watching)) if (byId[id] case final i? when hasArt(i)) i],
      fresh: [for (final id in ids.skip(watching)) if (byId[id] case final i? when hasArt(i)) i],
      random: random.where(hasArt).toList(),
      count: count,
      shuffle: ref.read(featuredShuffleProvider),
    );
  } else {
    featured = [...found.where(hasArt).take(count)];
    if (featured.length < count && mode == HeaderFeatured.random) {
      final random = await api.getRandomFeatured(limit: count * 2).catchError(none);
      for (final i in random) {
        if (featured.length >= count) break;
        if (hasArt(i) && featured.every((f) => f.id != i.id)) featured.add(i);
      }
    }
  }
  if (featured.isEmpty && failure != null) throw failure!;
  return featured;
}, retry: _headerRetry);

/// Unreachable or still starting (503): tried again until it answers, so
/// the header comes back by itself (it stayed empty until a restart).
Duration? _headerRetry(int attempt, Object error) {
  final status = error is JellyfinException ? error.statusCode : null;
  if (status != null && status < 500) return null;
  return Duration(seconds: const [3, 5, 15, 30, 60][math.min(attempt, 4)]);
}

/// How long a show stays without a trailer, and at most with one.
const _stillFor = Duration(seconds: 10);
const _trailerAtMost = Duration(seconds: 75);

/// Home's header (#100): the featured show's logo, details and overview over
/// its trailer (its own file, `<show>/Trailers/`) or its backdrop, moving on
/// to the next by itself. Design guide: the user's old Jellyfin web theme.
///
/// [style] "deck" (Depth) draws it as a deck of panels, see [DeckView].
class HomeHeader extends ConsumerStatefulWidget {
  const HomeHeader({super.key, this.style = ComponentStyle.classic});

  final ComponentStyle style;

  bool get deck => style.variant == 'deck';

  /// "programme" (Depth on a PC): a numbered list and one trailer frame,
  /// see [ProgrammeView]; at most five shows.
  bool get programme => style.variant == 'programme';

  /// Drawn by a theme (the deck or the programme), not Classic.
  bool get themed => deck || programme;

  @override
  ConsumerState<HomeHeader> createState() => _HomeHeaderState();
}

class _HomeHeaderState extends ConsumerState<HomeHeader> with WidgetsBindingObserver {
  int _index = 0;
  Duration _elapsed = Duration.zero;
  Timer? _tick;

  bool _hovered = false;
  bool _pausedByUser = false;
  bool _appActive = true;
  bool _onScreen = true;
  bool _covered = false;
  bool? _muted;

  Player? _player;
  VideoController? _video;

  /// The one trailer player every header shares, kept for the life of the
  /// app, as previews keep theirs: making and disposing one per header (a
  /// theme switch rebuilds the header) churned video players, after which
  /// Windows' file picker hung the app. Only its [_owner] drives it.
  static (Player, VideoController)? _shared;
  static _HomeHeaderState? _owner;

  bool get _owns => identical(_owner, this);
  String? _trailerFor;

  /// The show on screen, whose trailer this is (or is about to be).
  String? _shownId;
  bool _trailerShowing = false;
  Duration? _trailerLength;
  StreamSubscription<Object?>? _trailerSubs;
  ScrollPosition? _scroll;
  bool _started = false;

  /// Depth on Lite (Settings > Appearance > Effects): no trailers. Classic
  /// has no such setting.
  bool _noTrailers = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _onTick());
    OpenPlayer.itemId.addListener(_syncPlayback);
    Preview.playing.addListener(_syncPlayback);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Another page over Home: its tickers stop, and the trailer is unloaded,
    // not kept paused underneath. On Windows, a video player
    // left loaded under Settings has hung the app when a file picker opened
    // or the theme changed. Back on Home, the trailer loads again.
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered != _covered) {
      _covered = covered;
      if (covered) {
        _releasePlayer();
      } else if (_started) {
        final items = _featured;
        if (items != null && items.isNotEmpty) _startTrailer(items[_index % items.length]);
      }
    }
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll != _scroll) {
      _scroll?.removeListener(_onScroll);
      _scroll = scroll?..addListener(_onScroll);
    }
    final noTrailers = widget.themed && !effectsOf(context).playsTrailers;
    if (noTrailers != _noTrailers) {
      _noTrailers = noTrailers;
      if (noTrailers) {
        // Nothing left to resume it with, as Lite has no pause button.
        _pausedByUser = false;
        _stopTrailer();
      } else if (_started) {
        final items = _featured;
        if (items != null && items.isNotEmpty) _startTrailer(items[_index % items.length]);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _syncPlayback();
  }

  void _onScroll() {
    final height = context.size?.height ?? 400;
    final onScreen = (_scroll?.pixels ?? 0) < height * 0.6;
    if (onScreen != _onScreen) {
      _onScreen = onScreen;
      _syncPlayback();
    }
  }

  /// The trailer plays only while the header is seen: not paused, not
  /// scrolled away, no page or player over Home, the app in front.
  bool get _canPlay =>
      !_pausedByUser &&
      _appActive &&
      _onScreen &&
      !_covered &&
      OpenPlayer.itemId.value == null &&
      // One video at a time: a preview elsewhere on Home pauses the trailer.
      Preview.playing.value == null;

  void _syncPlayback() {
    final player = _player;
    if (player == null || !_owns) return;
    _canPlay ? player.play() : player.pause();
  }

  /// The featured shows this header goes through (the programme: five).
  List<BaseItem>? get _featured {
    final all = ref.read(headerFeaturedProvider).value;
    return all == null || !widget.programme ? all : all.take(5).toList();
  }

  void _onTick() {
    final items = _featured;
    if (items == null || items.length < 2 || !mounted) return;
    if (!_canPlay || _hovered) return;
    setState(() => _elapsed += const Duration(milliseconds: 250));
    if (_elapsed >= _slideLength) _go(1);
  }

  Duration get _slideLength {
    // The deck: the design's 9s a panel (12 on a TV), longer with a trailer
    // (up to `trailerFor` seconds, 30 by default).
    final still = widget.themed
        ? Duration(seconds: widget.style.param('interval', ref.read(isTvProvider) ? 12 : 9))
        : _stillFor;
    final most = widget.themed ? Duration(seconds: widget.style.param('trailerFor', 30)) : _trailerAtMost;
    if (_trailerFor == null) return still;
    final chosen = ref.read(homeHeaderSettingsProvider).value?.trailerLength ?? TrailerLength.standard;
    return chosen.playFor(most, _trailerLength);
  }

  void _go(int step) {
    final items = _featured;
    if (items == null || items.isEmpty) return;
    setState(() {
      _index = (_index + step) % items.length;
      if (_index < 0) _index += items.length;
      _elapsed = Duration.zero;
    });
    _stopTrailer();
    _startTrailer(items[_index]);
  }

  Future<bool> _trailersAllowed(HomeHeaderSettings settings) async {
    if (!settings.trailers) return false;
    if (!Platform.isAndroid || ref.read(isTvProvider) || settings.trailersOnMobileData) return true;
    // Phones: trailers on Wi-Fi / ethernet only, unless allowed.
    try {
      final links = await Connectivity().checkConnectivity();
      return links.contains(ConnectivityResult.wifi) || links.contains(ConnectivityResult.ethernet);
    } on Object {
      return false;
    }
  }

  /// A new selection (Refresh): if the show on screen is still in it, it
  /// carries on; if not, the selection starts from the top, playing, as what
  /// was paused or playing has gone.
  void _onNewSelection() {
    final shown = _shownId;
    if (shown == null) return;
    final items = _featured ?? const <BaseItem>[];
    final at = items.indexWhere((i) => i.id == shown);
    if (at >= 0) {
      if (at != _index % items.length) setState(() => _index = at);
      return;
    }
    setState(() {
      _index = 0;
      _elapsed = Duration.zero;
      _pausedByUser = false;
    });
    _stopTrailer();
    _shownId = null;
    if (items.isNotEmpty) _startTrailer(items.first);
  }

  Future<void> _startTrailer(BaseItem item) async {
    _shownId = item.id;
    // The page's backdrop follows the show on screen (when it follows art);
    // the deck: once it has settled (a new image uploading while it moved
    // stalled frames).
    if (!widget.themed) {
      if (mounted) BackdropArt.show(item, ProviderScope.containerOf(context, listen: false));
    } else {
      Future<void>.delayed(const Duration(milliseconds: 1300), () {
        // Gone by then (the header rebuilt when its settings changed).
        if (!mounted) return;
        final items = _featured;
        if (items != null && items.isNotEmpty && items[_index % items.length].id == item.id) {
          BackdropArt.show(item, ProviderScope.containerOf(context, listen: false));
        }
      });
    }
    final settings = ref.read(homeHeaderSettingsProvider).value ?? const HomeHeaderSettings();
    if (!settings.trailers || _noTrailers) return;
    // Why there's no trailer, in the log (it said nothing, which left
    // "trailers don't play" a guess).
    if (item.localTrailerCount == 0) {
      AppLog.debug(LogArea.player, 'Home header: ${item.name} has no trailer file');
      return;
    }
    if (!await _trailersAllowed(settings)) {
      AppLog.info(LogArea.player, 'Home header: no trailer for ${item.name}: not on Wi-Fi (Settings > Home > Header)');
      return;
    }
    // A moment on the artwork first, as in the reference.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    // (Covered meanwhile: no player under another page.)
    if (!mounted || _noTrailers || _covered) return;
    final items = _featured;
    if (items == null || items.isEmpty || items[_index % items.length].id != item.id) return;
    try {
      final trailers = await ref.read(libraryApiProvider).getLocalTrailers(item.id);
      if (trailers.isEmpty || !mounted || _noTrailers || _covered) return;
      final api = ref.read(signedInApiProvider);
      final url = api.resolve('/Videos/${trailers.first.id}/stream', {'static': true}).toString();
      final (player, video) = _shared ??= () {
        final made = Player();
        final decoding = (ref.read(playbackSettingsProvider).value ?? const PlaybackSettings()).hardwareDecoding;
        return (
          made,
          Platform.isWindows
              ? VideoController(
                  made,
                  configuration: VideoControllerConfiguration(
                    hwdec: decoding.mpv,
                    enableHardwareAcceleration: decoding != HardwareDecoding.off,
                  ),
                )
              : VideoController(made),
        );
      }();
      _owner = this;
      _player = player;
      _video = video;
      _trailerFor = item.id;
      _trailerLength = null;
      await _applyVolume();
      await _trailerSubs?.cancel();
      _trailerSubs = player.stream.duration.listen((d) {
        if (d > Duration.zero && mounted) setState(() => _trailerLength = d);
      });
      await player.open(Media(url, httpHeaders: {'Authorization': api.authorizationHeader}), play: _canPlay);
      // Either can end without a value (the trailer stopped or the header
      // went first): not an error.
      player.stream.completed.where((done) => done).first.then((_) {
        if (mounted && _trailerFor == item.id) _go(1);
      }, onError: (Object _) {});
      // Shown once frames come (the artwork stays until then).
      player.stream.width.where((w) => (w ?? 0) > 0).first.then((_) {
        if (mounted && _trailerFor == item.id) setState(() => _trailerShowing = true);
      }, onError: (Object _) {});
      AppLog.info(LogArea.player, 'Home header: trailer for ${item.name}');
    } on Object catch (e) {
      AppLog.warning(LogArea.player, 'Home header: no trailer for ${item.name}', error: e);
    }
  }

  void _stopTrailer() {
    _trailerFor = null;
    _trailerShowing = false;
    _trailerLength = null;
    _trailerSubs?.cancel();
    if (_owns) _player?.stop();
  }

  /// Stops the trailer and unloads it: nothing left loaded, paused, under
  /// another page. The player itself stays (disposing one part-way through
  /// loading has crashed the app; previews keep theirs for the same reason).
  void _releasePlayer() {
    if (_player != null) AppLog.debug(LogArea.player, 'Home header: covered, trailer unloaded');
    _stopTrailer();
    if (mounted) setState(() {});
  }

  bool get _isMuted => _muted ?? (ref.read(homeHeaderSettingsProvider).value?.muted ?? true);

  Future<void> _applyVolume() async {
    final volume = ref.read(homeHeaderSettingsProvider).value?.volume ?? 60;
    if (_owns) await _player?.setVolume(_isMuted ? 0 : volume);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    OpenPlayer.itemId.removeListener(_syncPlayback);
    Preview.playing.removeListener(_syncPlayback);
    _scroll?.removeListener(_onScroll);
    _tick?.cancel();
    _trailerSubs?.cancel();
    // The shared player stays; only what this header loaded goes.
    if (_owns) {
      _player?.stop();
      _owner = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final featured = ref.watch(headerFeaturedProvider);
    ref.listen(headerFeaturedProvider, (_, next) {
      if (!next.isLoading && next.hasValue) _onNewSelection();
    });
    // The volume setting changed in Settings: the trailer follows.
    ref.listen(homeHeaderSettingsProvider, (_, _) => _applyVolume());
    final items = widget.programme ? featured.value?.take(5).toList() : featured.value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    // Already loaded when the header was built: the first show's trailer.
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _trailerFor == null) _startTrailer(items[_index % items.length]);
      });
    }
    final chip = _pausedByUser
        ? chipPaused
        : !_trailerShowing
        ? chipFeatured
        : _isMuted
        ? 'Now playing · Trailer'
        : 'Now playing · Sound on';
    Future<void> toggleMute() async {
      setState(() => _muted = !_isMuted);
      await _applyVolume();
    }

    void togglePause() {
      setState(() => _pausedByUser = !_pausedByUser);
      _syncPlayback();
    }

    if (widget.programme) {
      return ProgrammeView(
        items: items,
        index: _index % items.length,
        progress: _slideLength.inMilliseconds == 0 ? 0 : _elapsed.inMilliseconds / _slideLength.inMilliseconds,
        video: _owns ? _video : null,
        trailerShowing: _trailerShowing,
        trailer: _trailerFor != null,
        muted: _isMuted,
        paused: _pausedByUser,
        chip: chip,
        onPick: (i) => _go(i - _index % items.length),
        onHover: (h) => setState(() => _hovered = h),
        onMute: toggleMute,
        onPause: togglePause,
      );
    }
    // A phone: the cards stacked to the side, swiped through.
    if (widget.deck && context.layout.formFactor == FormFactor.phone) {
      return SideDeck(
        items: items,
        index: _index % items.length,
        progress: _slideLength.inMilliseconds == 0 ? 0 : _elapsed.inMilliseconds / _slideLength.inMilliseconds,
        video: _owns ? _video : null,
        trailerShowing: _trailerShowing,
        trailer: _trailerFor != null,
        muted: _isMuted,
        paused: _pausedByUser,
        chip: chip,
        onGo: _go,
        onMute: toggleMute,
        onPause: togglePause,
      );
    }
    if (widget.deck) {
      return DeckView(
        items: items,
        index: _index % items.length,
        progress: _slideLength.inMilliseconds == 0 ? 0 : _elapsed.inMilliseconds / _slideLength.inMilliseconds,
        slideLength: _slideLength,
        video: _owns ? _video : null,
        trailerShowing: _trailerShowing,
        trailer: _trailerFor != null,
        muted: _isMuted,
        paused: _pausedByUser,
        scrolled: HomeComponents.scrolled,
        chip: chip,
        onGo: _go,
        onHover: (h) => setState(() => _hovered = h),
        onMute: toggleMute,
        onPause: togglePause,
      );
    }
    final item = items[_index % items.length];
    final size = MediaQuery.sizeOf(context);
    final phone = context.layout.formFactor == FormFactor.phone;
    final height = phone ? math.min(size.height * 0.62, 520.0) : (size.height * 0.72).clamp(420.0, 760.0);
    final background = Theme.of(context).scaffoldBackgroundColor;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
      },
      child: FocusTraversalGroup(
        child: MouseRegion(
          // The picture opens the show (its buttons keep their own cursor).
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            // A click / tap on the picture (not a button) opens the show's
            // page; the trailer pauses there, as for any page over Home.
            onTap: () => openItem(context, item),
            // Phones: swipe to the next / previous show.
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v.abs() > 300) _go(v < 0 ? 1 : -1);
            },
            child: SizedBox(
              height: height,
              // The panning artwork grows past the header's edges.
              child: ClipRect(
                child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 600),
                    layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                    child: _Artwork(
                      key: ValueKey(item.id),
                      item: item,
                      panFor: _slideLength,
                      pan: ref.watch(homeHeaderSettingsProvider).value?.pan ?? true,
                    ),
                  ),
                  if (_video != null && _owns)
                    AnimatedOpacity(
                      opacity: _trailerShowing ? 1 : 0,
                      duration: const Duration(milliseconds: 600),
                      child: IgnorePointer(
                        child: Video(controller: _video!, fit: BoxFit.cover, controls: NoVideoControls),
                      ),
                    ),
                  // Readable text over bright trailers: dark on the left and
                  // into the page at the bottom.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        // Gradual and light, only behind the text: the
                        // trailer shows through (it covered half of it).
                        stops: const [0, 0.1, 0.2, 0.3, 0.4],
                        colors: [
                          Colors.black.withValues(alpha: 0.55),
                          Colors.black.withValues(alpha: 0.42),
                          Colors.black.withValues(alpha: 0.24),
                          Colors.black.withValues(alpha: 0.09),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // Into the page from halfway down, eased, so the
                        // rows below don't sit on a hard line.
                        // Only the strip above the rows blends into the
                        // page; the top just enough for the bar's icons.
                        stops: const [0, 0.14, 0.62, 0.76, 0.87, 0.95, 1],
                        colors: [
                          Colors.black.withValues(alpha: 0.38),
                          Colors.transparent,
                          Colors.transparent,
                          background.withValues(alpha: 0.2),
                          background.withValues(alpha: 0.55),
                          background.withValues(alpha: 0.86),
                          background,
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    // Clear of the ‹ arrow on wide screens.
                    left: context.layout.gutter + (phone ? 0 : 40),
                    right: context.layout.gutter,
                    bottom: phone ? 28 : 56,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      // Against the left edge (the default centres it).
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.bottomLeft,
                        children: [...previous, ?current],
                      ),
                      child: _Details(key: ValueKey('d-${item.id}'), item: item, phone: phone),
                    ),
                  ),
                  Positioned(
                    right: context.layout.gutter,
                    // A phone's buttons fill the width at the bottom: up here,
                    // under the top bar, these don't land on them.
                    top: phone ? statusBarHeight(context) + 64 : null,
                    bottom: phone ? null : 24,
                    child: _Controls(
                      large: !phone,
                      index: _index % items.length,
                      count: items.length,
                      progress: _slideLength.inMilliseconds == 0 ? 0 : _elapsed.inMilliseconds / _slideLength.inMilliseconds,
                      trailer: _trailerFor != null,
                      muted: _isMuted,
                      paused: _pausedByUser,
                      onMute: () async {
                        setState(() => _muted = !_isMuted);
                        await _applyVolume();
                      },
                      onPause: () {
                        setState(() => _pausedByUser = !_pausedByUser);
                        _syncPlayback();
                      },
                    ),
                  ),
                  if (_hovered && items.length > 1 && !phone) ...[
                    Align(alignment: Alignment.centerLeft, child: _Arrow(left: true, onPressed: () => _go(-1))),
                    Align(alignment: Alignment.centerRight, child: _Arrow(left: false, onPressed: () => _go(1))),
                  ],
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

/// The backdrop, panning slowly while it's shown.
class _Artwork extends StatelessWidget {
  const _Artwork({super.key, required this.item, required this.panFor, this.pan = true});

  /// Off: the backdrop stays perfectly still (Banners, Slow pan off).
  final bool pan;

  final BaseItem item;
  final Duration panFor;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: pan ? 1.08 : 1),
      duration: panFor,
      builder: (context, scale, child) => Transform.scale(scale: scale, alignment: Alignment.topRight, child: child),
      child: ItemImage(image: item.backdropImage, maxWidth: width, alignment: Alignment.topCenter),
    );
  }
}

class _Details extends ConsumerWidget {
  const _Details({super.key, required this.item, required this.phone});

  final BaseItem item;
  final bool phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    const white = Colors.white;
    final logo = item.logoImage;
    // Readable over bright scenes without a heavy fade behind.
    final shadow = [
      const Shadow(blurRadius: 10, color: Colors.black87),
      const Shadow(blurRadius: 3, color: Colors.black54, offset: Offset(0, 1)),
    ];
    final meta = [
      if (item.communityRating case final r?) '★ ${r.toStringAsFixed(1)}',
      if (item.productionYear case final y?) '$y',
      if (item.type == ItemType.series && (item.childCount ?? 0) > 0)
        '${item.childCount} season${item.childCount == 1 ? '' : 's'}',
      if (item.type == ItemType.movie && item.runTimeTicks != null) '${item.runTimeTicks! ~/ 600000000} min',
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: phone ? double.infinity : 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (logo != null)
            SizedBox(
              height: phone ? 72 : 160,
              width: phone ? 260 : 520,
              child: ItemImage(image: logo, maxWidth: 460, fit: BoxFit.contain, alignment: Alignment.bottomLeft,
                  placeholder: _Title(item.name, phone: phone)),
            )
          else
            _Title(item.name, phone: phone),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final m in meta) Text(m, style: theme.textTheme.labelLarge?.copyWith(color: white, shadows: shadow)),
              if (item.officialRating case final rating?)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: Colors.white70), borderRadius: BorderRadius.circular(4)),
                  child: Text(rating, style: theme.textTheme.labelSmall?.copyWith(color: white)),
                ),
            ],
          ),
          if (item.genres.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(item.genres.take(4).join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70, shadows: shadow)),
          ],
          if (item.overview case final overview? when overview.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              overview,
              maxLines: phone ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white, shadows: shadow, height: 1.4),
            ),
          ],
          const SizedBox(height: 18),
          _Buttons(item: item, large: !phone),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.name, {required this.phone});

  final String name;
  final bool phone;

  @override
  Widget build(BuildContext context) => Text(
        name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: (phone ? Theme.of(context).textTheme.headlineMedium : Theme.of(context).textTheme.displaySmall)
            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700, shadows: const [Shadow(blurRadius: 12)]),
      );
}

/// Info, Play / Resume S1:E5, and Favourite.
class _Buttons extends ConsumerWidget {
  const _Buttons({required this.item, required this.large});

  final BaseItem item;

  /// A PC: bigger buttons.
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final series = item.type == ItemType.series;
    final next = series ? ref.watch(nextUpForSeriesProvider(item.id)).value : null;
    final playLabel = switch ((series, next)) {
      (true, final BaseItem n) when n.userData.hasProgress => 'Resume ${n.episodeLabel ?? ''}',
      (true, final BaseItem n) => 'Play ${n.episodeLabel ?? ''}',
      (false, _) when item.userData.hasProgress => 'Resume',
      _ => 'Play',
    };
    final favorite = item.userData.isFavorite;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton.filledTonal(
          iconSize: large ? 28 : 24,
          tooltip: 'More info',
          icon: const Icon(Icons.info_outline),
          onPressed: () => openItem(context, item),
        ),
        FilledButton.icon(
          // On a TV the header takes focus first.
          autofocus: ref.watch(isTvProvider),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            padding: large ? const EdgeInsets.symmetric(horizontal: 28, vertical: 18) : null,
            textStyle: large ? const TextStyle(fontSize: 17, fontWeight: FontWeight.w600) : null,
            iconSize: large ? 26 : null,
          ),
          icon: const Icon(Icons.play_arrow),
          label: Text(playLabel.trim()),
          onPressed: () => openItem(context, next ?? item, play: next != null || !series),
        ),
        IconButton.filledTonal(
          iconSize: large ? 28 : 24,
          tooltip: favorite ? 'Remove from favourites' : 'Add to favourites',
          icon: Icon(favorite ? Icons.favorite : Icons.favorite_border, color: favorite ? Colors.redAccent : null),
          onPressed: () async {
            await CardActions(context).setFavorite(item, !favorite);
            ref.invalidate(headerFeaturedProvider);
          },
        ),
      ],
    );
  }
}

/// Mute, pause, "4 / 10" and the time to the next show.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.large,
    required this.index,
    required this.count,
    required this.progress,
    required this.trailer,
    required this.muted,
    required this.paused,
    required this.onMute,
    required this.onPause,
  });

  /// A PC: bigger buttons (they looked small on a large window).
  final bool large;
  final int index;
  final int count;
  final double progress;
  final bool trailer;
  final bool muted;
  final bool paused;
  final VoidCallback onMute;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      backgroundColor: Colors.black45,
      foregroundColor: Colors.white,
      iconSize: large ? 28 : 24,
      padding: EdgeInsets.all(large ? 12 : 8),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailer)
              IconButton(
                style: style,
                tooltip: muted ? 'Unmute' : 'Mute',
                icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
                onPressed: onMute,
              ),
            const SizedBox(width: 6),
            IconButton(
              style: style,
              tooltip: paused ? 'Play' : 'Pause',
              icon: Icon(paused ? Icons.play_arrow : Icons.pause),
              onPressed: onPause,
            ),
          ],
        ),
        if (count > 1) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
            child: Text('${index + 1} / $count', style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 3,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.left, required this.onPressed});

  final bool left;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: IconButton(
          style: IconButton.styleFrom(backgroundColor: Colors.black38, foregroundColor: Colors.white),
          tooltip: left ? 'Previous' : 'Next',
          iconSize: 40,
          icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
          onPressed: onPressed,
        ),
      );
}
