import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback_log.dart';
import '../../app/toast.dart';
import '../../core/jellyfin/syncplay.dart';
import 'open_player.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/playback_api.dart';
import '../anime/anime_providers.dart';
import '../anime/anime_settings.dart';
import '../anime/mal_account.dart';
import '../anime/widgets/mal_widgets.dart';
import '../library/library_providers.dart';
import '../library/navigation.dart';
import '../settings/keybindings.dart';
import '../settings/series_tracks.dart';
import '../settings/playback_settings.dart';
import 'device_levels.dart';
import '../downloads/downloads.dart';
import 'media_kit_engine.dart';
import 'mini_player.dart';
import 'system_media_controls.dart';
import '../syncplay/syncplay_player.dart';
import '../syncplay/syncplay_service.dart';
import '../syncplay/syncplay_sheet.dart';
import 'playback_controller.dart';
import 'player_shortcuts.dart';
import 'widgets/chapter_seek_bar.dart';
import 'widgets/player_overlays.dart';
import 'widgets/swipe_levels.dart';
import 'widgets/track_menu.dart';
import 'widgets/trickplay_thumbnail.dart';
import '../../core/jellyfin/trickplay.dart';
import 'player_look.dart';
import 'widgets/player_controls.dart';

/// Keeps the player's icons and text readable over bright video.
const _controlShadows = [Shadow(blurRadius: 6, color: Colors.black87)];

/// Around a phone's controls: clear of the screen edges, rounded corners and
/// any camera cutout, and the same on opposite sides, or a cutout on one would
/// push what's in the middle (play / pause) off the middle of the screen.
EdgeInsets mobileControlsPadding(EdgeInsets insets) {
  final side = (insets.left > insets.right ? insets.left : insets.right) + 24;
  final ends = (insets.top > insets.bottom ? insets.top : insets.bottom) + 10;
  return EdgeInsets.symmetric(horizontal: side, vertical: ends);
}

final playbackApiProvider = Provider<PlaybackApi>((ref) {
  final session = ref.watch(currentSessionProvider);
  return PlaybackApi(ref.watch(signedInApiProvider), userId: session.userId);
});

/// Full-screen video player for one item.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.itemId, this.fromStart = false, this.openedBy, this.playlistId});

  final String itemId;

  /// What opened it ("group", "join"; null: the user), for the log.
  final String? openedBy;

  /// Ignore the saved position and start at 0:00.
  final bool fromStart;

  /// Played from this playlist: next and previous follow it.
  final String? playlistId;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final MediaKitEngine _engine;
  late final VideoController _video;
  late final PlaybackController _controller;
  late final ProviderContainer _container;
  final _videoKey = GlobalKey<VideoState>();
  StreamSubscription<BaseItem>? _nextSub;
  ProviderSubscription<Uri?>? _addressSub;

  bool _checkingAddress = false;

  /// The stream stopped coming: if the server's address stopped answering,
  /// another of its addresses that answers is switched to (the stream then
  /// follows, see _addressSub). Asked a few times over half a minute, as
  /// the other network can take a while to come up (mobile data, a VPN).
  Future<void> _checkAddress() async {
    if (_checkingAddress) return;
    _checkingAddress = true;
    try {
      for (final wait in const [0, 3, 6, 10, 15]) {
        await Future<void>.delayed(Duration(seconds: wait));
        if (!mounted) return;
        final session = _container.read(sessionControllerProvider).value;
        if (session == null || session.addresses.length < 2) return;
        if (await _container.read(sessionControllerProvider.notifier).useAnsweringAddress(onlyIfDown: true)) return;
      }
    } finally {
      _checkingAddress = false;
    }
  }

  /// The window itself is fullscreen (desktop): it must be restored when
  /// the player closes, or the rest of the app is stuck fullscreen with no
  /// window buttons.
  bool _windowFullscreen = false;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Players alive right now. "Next episode" opens the new player before
  /// the old one closes, so only the last one out restores portrait.
  static int _openPlayers = 0;

  /// The players alive now. Only the newest may be heard: when one opens,
  /// the others go quiet at once (they're closing anyway, e.g. moving on
  /// to the next episode; and two never play over each other).
  static final _alive = <_PlayerScreenState>{};

  static const _device = DeviceLevels();

  /// Picture-in-picture: the window is the small always-on-top one.
  final _mini = ValueNotifier(false);

  /// Fullscreen when the mini player was entered: it goes back to that.
  bool _fullscreenBeforeMini = false;

  /// Fullscreen and the mini player each save and restore the window, so
  /// they never overlap: one is left (and settles) before the other.
  Future<void> _toggleMini() async {
    if (!MiniPlayer.supported) return;
    if (_mini.value) {
      await _leaveMini();
      if (_fullscreenBeforeMini) await _videoKey.currentState?.enterFullscreen();
      return;
    }
    _fullscreenBeforeMini = _windowFullscreen;
    if (_windowFullscreen) {
      await _videoKey.currentState?.exitFullscreen();
      // The window restores itself a moment later.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await MiniPlayer.enter();
    _mini.value = true;
  }

  Future<void> _leaveMini() async {
    if (!_mini.value) return;
    _mini.value = false;
    await MiniPlayer.exit();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  StreamSubscription<MediaButton>? _mediaButtonSub;

  /// The picture's shape, checked once the file is loaded.
  StreamSubscription<int?>? _sizeSub;

  /// Some encodes (often Blu-ray rips) carry display / crop flags that give
  /// the player a different shape than the picture (e.g. 1.89:1 for 16:9):
  /// it drew a stretched picture with a black strip. When the player's shape
  /// is off Jellyfin's ratio for the stream, the stream's is used.
  /// The video as the player sees it, for Playback info.
  String? _playerView;

  Future<void> _checkAspect() async {
    final geometry = await _engine.videoGeometry();
    final decoder = await _engine.decoder();
    if (geometry != null) {
      _playerView = '${geometry.w}×${geometry.h}, shown ${geometry.dw}×${geometry.dh}'
          '${geometry.crop.isEmpty ? '' : ', cropped ${geometry.crop}'}'
          '${decoder == null ? '' : ', decoder $decoder'}';
    }
    if (decoder != null) PlaybackLog.add('Decoding: $decoder');
    final ratio = _controller.plan?.source.streamsOfType('Video').firstOrNull?.aspectRatio;
    if (geometry == null || ratio == null || geometry.dh == 0) return;
    final parts = ratio.split(':');
    final expected = parts.length == 2 ? (double.tryParse(parts[0]) ?? 0) / (double.tryParse(parts[1]) ?? 1) : 0.0;
    final shown = geometry.dw / geometry.dh;
    PlaybackLog.add('Video ${geometry.w}x${geometry.h}, shown ${geometry.dw}x${geometry.dh}'
        '${geometry.crop.isEmpty ? '' : ', crop ${geometry.crop}'}, Jellyfin says $ratio');
    if (expected > 0 && (shown / expected - 1).abs() > 0.03) {
      PlaybackLog.add('Shape off by ${((shown / expected - 1) * 100).round()} %: using $ratio');
      await _engine.setAspect(ratio);
    }
  }
  StreamSubscription<bool>? _playingSub;
  String? _publishedMedia;

  /// Tells Windows what's playing (only when something changed).
  void _publishMedia() {
    final item = _controller.item;
    if (item == null || !mounted) return;
    final playing = _engine.isPlaying;
    final episode = item.type == ItemType.episode;
    final title = episode ? item.name : preferredAnimeTitle(ref, item, item.name);
    final subtitle = episode
        ? '${preferredAnimeTitle(ref, item, item.seriesName ?? '')} · ${item.episodeLabel ?? ''}'
        : item.yearLabel;
    final key = '$title|$subtitle|$playing|${_controller.canSkipForward}|${_controller.canSkipBack}';
    if (key == _publishedMedia) return;
    _publishedMedia = key;
    final base = ref.read(signedInApiProvider).baseUrl;
    final imageItem = episode ? (item.seriesId ?? item.id) : item.id;
    unawaited(SystemMediaControls.instance.update(
      title: title,
      subtitle: subtitle,
      // Works for servers on a sub-path too (https://host/jellyfin).
      thumbnail: Uri.parse('${base.toString().replaceFirst(RegExp(r'/+$'), '')}/Items/$imageItem/Images/Primary?maxHeight=300'),
      playing: playing,
      canNext: _controller.canSkipForward,
      canPrevious: _controller.canSkipBack,
    ));
  }

  late final SyncPlayBinding _syncPlay;

  /// Picture subtitles that can be burned into the converted stream, named
  /// as the menus show tracks.
  List<(int, String)> _burnable() => [
        for (final s in _controller.burnable)
          (s.index, trackLabel(s.title ?? s.displayTitle, s.language, s.codec, '${s.index}')),
      ];

  /// A seek from the user: the group's, when watching together.
  void _seek(Duration target) {
    if (!_syncPlay.seek(target)) _engine.seek(target);
  }

  /// Phones: landscape + fullscreen have taken effect. media_kit's controls
  /// keep the layout of their first frame, so they're drawn only after
  /// that, or the system bars' space stays reserved (bottom bar too high).
  bool _systemUiSettled = false;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _engine = MediaKitEngine(title: 'Kurage');
    final decoding = (ref.read(playbackSettingsProvider).value ?? const PlaybackSettings()).hardwareDecoding;
    // Windows: as Jellyfin Media Player, frames are copied back from the
    // graphics card by default (10-bit HEVC handed over directly came out
    // stretched, with a black strip). Phones keep media_kit's own choice.
    _video = Platform.isWindows
        ? VideoController(
            _engine.player,
            configuration: VideoControllerConfiguration(
              hwdec: decoding.mpv,
              enableHardwareAcceleration: decoding != HardwareDecoding.off,
            ),
          )
        : VideoController(_engine.player);
    _controller = PlaybackController(
      engine: _engine,
      playback: ref.read(playbackApiProvider),
      library: ref.read(libraryApiProvider),
      settings: ref.read(playbackSettingsProvider).value ?? const PlaybackSettings(),
      authorizationHeader: ref.read(signedInApiProvider).authorizationHeader,
      fallbackSegments: (item) => aniSkipSegments(_container, item),
      preferFallbackSegments: () async => (await _container.read(animeSettingsProvider.future)).preferAniSkip,
      trackChoiceFor: (item) => item.seriesId == null
          ? null
          : ref.read(seriesTracksProvider).value?[item.seriesId],
      // Downloaded: play the file (and without the server, if offline).
      localCopy: ref.read(downloadsProvider.notifier).localCopy,
      onUnreportedStop: (id, position, finished) =>
          unawaited(_container.read(downloadsProvider.notifier).addPending(id, position, finished)),
      onReportedAgain: (id) => unawaited(_container.read(downloadsProvider.notifier).removePending(id)),
      onNotice: (message) => showToast(message, duration: const Duration(seconds: 5)),
      playlistId: widget.playlistId,
      // The stream stopped coming: if the server's address stopped
      // answering, another of its addresses is switched to (below).
      onLongWait: () => unawaited(_checkAddress()),
    );
    // Switched to another of the server's addresses: the stream follows.
    _addressSub = _container.listen(sessionControllerProvider.select((s) => s.value?.baseUrl), (before, now) {
      if (before == null || now == null || before == now) return;
      unawaited(_controller.moveTo(
        playback: _container.read(playbackApiProvider),
        library: _container.read(libraryApiProvider),
      ));
    });
    _nextSub = _controller.nextRequests.listen((next) {
      final playlist = widget.playlistId;
      if (mounted) context.pushReplacement('/play/${next.id}${playlist == null ? '' : '?playlist=$playlist'}');
    });
    _controller.load(widget.itemId, fromStart: widget.fromStart);

    // Windows: media overlay / media keys / taskbar thumbnail buttons.
    final media = SystemMediaControls.instance;
    if (media.supported) {
      _mediaButtonSub = media.buttons.listen((b) => switch (b) {
            MediaButton.play => _engine.player.play(),
            MediaButton.pause || MediaButton.stop => _engine.player.pause(),
            MediaButton.next => _controller.skipForward(),
            MediaButton.previous => _controller.skipBack(),
          });
      _playingSub = _engine.playingStream.listen((_) => _publishMedia());
      _controller.addListener(_publishMedia);
    }
    _sizeSub = _engine.player.stream.height.where((h) => h != null && h > 0).take(1).listen((_) => _checkAspect());

    // Watch together: play / pause / seek go through the group.
    // The container's read, not the widget's: the binding is also used from
    // dispose(), when the widget's ref can no longer be (it throws).
    _syncPlay = SyncPlayBinding.forPlayer(_container.read, _engine, _controller)..start();
    // Skip intro, chapter jumps: the group's seeks too.
    _controller.seekVia = (target) async => _seek(target);

    _openPlayers++;
    for (final other in _alive) {
      // Off the group first, or its pause would pause everyone (this one too).
      other._syncPlay.dispose();
      unawaited(other._engine.pause().catchError((Object _) {}));
    }
    if (_alive.isNotEmpty) PlaybackLog.add('Another player was still open: paused it');
    _alive.add(this);
    OpenPlayer.itemId.value = normalizeItemId(widget.itemId);
    // Watching now: a "… is watching, Join in?" still showing is done with.
    dismissToast('syncplay-join');
    PlaybackLog.add('Player opened for ${widget.itemId} (by ${widget.openedBy ?? 'you'})');
    if (_isMobile) {
      () async {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        // The new insets reach MediaQuery a frame or two later.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (mounted) setState(() => _systemUiSettled = true);
      }();
    }
  }

  @override
  void dispose() {
    _showLink.dispose();
    _episodeLink.dispose();
    // Stop playback first: nothing below may keep the player (and its sound)
    // going after the screen has gone.
    final container = _container;
    // Report the final position, then refresh progress shown elsewhere.
    final itemId = _controller.item?.id ?? widget.itemId;
    _controller.stop().whenComplete(() {
      refreshWatchState(container.invalidate);
      // If the server now counts it as watched, update MyAnimeList.
      container.read(malSyncServiceProvider).playbackEnded(itemId);
    });
    _nextSub?.cancel();
    _addressSub?.close();
    _mediaButtonSub?.cancel();
    _sizeSub?.cancel();
    // Leaving from the mini player: the window goes back as it was.
    if (_mini.value) unawaited(MiniPlayer.exit());
    _mini.dispose();
    _volumeTimer?.cancel();
    _volumeShown.dispose();
    _playingSub?.cancel();
    // The next episode's player (opened first) has taken over already.
    if (_openPlayers == 1) unawaited(SystemMediaControls.instance.clear());
    // Closing the player (not moving on to the next episode, whose player
    // opened first and is in the group now): the group pauses rather than
    // plays on without us.
    if (_alive.length == 1) _syncPlay.leftPlayer();
    _syncPlay.dispose();
    _controller.dispose();
    if (_windowFullscreen && !_isMobile) {
      unawaited(defaultExitNativeFullscreen().then((_) => MiniPlayer.afterFullscreen()));
    }
    if (_isMobile) unawaited(_device.resetBrightness());
    _alive.remove(this);
    if (OpenPlayer.itemId.value == normalizeItemId(widget.itemId)) {
      OpenPlayer.itemId.value = _alive.isEmpty ? null : normalizeItemId(_alive.last.widget.itemId);
    }
    if (--_openPlayers == 0 && _isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const []);
    }
    super.dispose();
  }

  /// Leaves the player: for the page at [to], else back where it came from.
  void _exit({String? to}) {
    // Stop at once, before the screen changes: nothing (a group update, an
    // automatic reconnect) may start this player again as it closes.
    final itemId = _controller.item?.id ?? widget.itemId;
    OpenPlayer.left(itemId);
    PlaybackLog.add('Leaving the player');
    if (_alive.length == 1) _syncPlay.leftPlayer();
    _controller.leave();
    if (to != null) {
      exitPlayerTo(context, to);
    } else {
      exitPlayer(context);
    }
  }

  /// The title's links: the show's page, and the episode's.
  late final _showLink = TapGestureRecognizer()..onTap = () => _openFromTitle(series: true);
  late final _episodeLink = TapGestureRecognizer()..onTap = () => _openFromTitle(series: false);

  void _openFromTitle({required bool series}) {
    final item = _controller.item;
    if (item == null) return;
    final toShow = series && item.type == ItemType.episode && item.seriesId != null;
    _exit(to: toShow ? seriesPathOf(item) : '/item/${item.id}');
  }

  void _seekBy(Duration offset) {
    final target = _engine.player.state.position + offset;
    _seek(target < Duration.zero ? Duration.zero : target);
  }

  void _changeVolume(double delta) {
    final volume = (_engine.player.state.volume + delta).clamp(0.0, 100.0);
    _engine.player.setVolume(volume);
    if (!_isMobile) _flashVolume(volume);
  }

  /// Desktop: the volume, shown for a moment while it changes (wheel, keys).
  final _volumeShown = ValueNotifier<double?>(null);
  Timer? _volumeTimer;

  void _flashVolume(double volume) {
    _volumeShown.value = volume;
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 900), () => _volumeShown.value = null);
  }

  /// The user's key bindings (Settings > Player controls) wired to actions.
  Map<ShortcutActivator, VoidCallback> _shortcuts(BuildContext context) {
    final bindings = ref.watch(keybindingsProvider).value ?? Keybindings.defaults;
    return playerShortcuts(bindings, {
      PlayerAction.playPause: _engine.playOrPause,
      PlayerAction.seekBack10: () => _seekBy(const Duration(seconds: -10)),
      PlayerAction.seekForward10: () => _seekBy(const Duration(seconds: 10)),
      PlayerAction.seekBackSmall: () => _seekBy(const Duration(seconds: -2)),
      PlayerAction.seekForwardSmall: () => _seekBy(const Duration(seconds: 2)),
      PlayerAction.volumeUp: () => _changeVolume(5),
      PlayerAction.volumeDown: () => _changeVolume(-5),
      PlayerAction.toggleFullscreen: () => _videoKey.currentState?.toggleFullscreen(),
      PlayerAction.exitFullscreen: () => _videoKey.currentState?.exitFullscreen(),
      PlayerAction.skipSegment: _controller.skipSegment,
      PlayerAction.nextEpisode: _controller.playNext,
      PlayerAction.previousEpisode: _controller.playPrevious,
      // Like the ⏭ ⏮ buttons: chapters, then on into the next / previous episode.
      PlayerAction.nextChapter: _controller.skipForward,
      PlayerAction.previousChapter: _controller.skipBack,
      PlayerAction.playbackInfo: () => showPlaybackInfo(context, _controller, player: _playerView),
      PlayerAction.miniPlayer: _toggleMini,
    }, systemMediaKeys: SystemMediaControls.instance.supported);
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = _shortcuts(context);
    // System back (Android, TV remote) leaves the same way as the ← button.
    // No dragging with the mouse in here (the rest of the app lets rows be
    // dragged): on desktop, clicks and drags on the player do only what
    // its controls say. Touch keeps every gesture.
    return ScrollConfiguration(
      behavior: const MaterialScrollBehavior(),
      child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      // Desktop controls take the same map (see _themedVideo); this covers
      // the mobile/TV controls, which have no keyboard handling of their own.
      body: CallbackShortcuts(
        bindings: shortcuts,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              _themedVideo(context, shortcuts),
              if (_isMobile) _swipeLevels(),
              if (_controller.loading)
                const Center(child: CircularProgressIndicator()),
              if (_controller.error != null)
                PlayerErrorPanel(
                  message: _controller.error!,
                  details: _controller.errorDetails,
                  onRetry: _controller.plan == null ? null : _controller.retry,
                  onBack: _exit,
                ),
              // Desktop: drawn with the controls (see _themedVideo).
              if (_isMobile) PlayerOverlays(controller: _controller),
              // The group holds everyone until all are ready (after a join,
              // a seek): say so, rather than play doing nothing.
              ValueListenableBuilder<String?>(
                valueListenable: ref.read(syncPlayProvider.notifier).groupState,
                builder: (context, state, _) => state != 'Waiting' || !ref.read(syncPlayProvider).inGroup
                    ? const SizedBox.shrink()
                    : Center(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                                  SizedBox(width: 12),
                                  Text('Waiting for the group…', style: TextStyle(color: Colors.white, fontSize: 16)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              if (!_isMobile)
                ValueListenableBuilder<double?>(
                  valueListenable: _volumeShown,
                  builder: (context, volume, _) => volume == null
                      ? const SizedBox.shrink()
                      : Center(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(volume == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.white),
                                    const SizedBox(width: 8),
                                    Text('${volume.round()}%', style: const TextStyle(color: Colors.white, fontSize: 18)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
      ),
      ),
    );
  }

  /// Rebuilds [builder] whenever the playback state changes.
  Widget _live(Widget Function() builder) =>
      ListenableBuilder(listenable: _controller, builder: (_, _) => builder());

  Widget _themedVideo(
    BuildContext context,
    Map<ShortcutActivator, VoidCallback> shortcuts,
  ) {
    // media_kit's controls theme only notifies dependents when the new
    // theme is *identical* to the old one (inverted check in
    // MaterialDesktopVideoControlsTheme.updateShouldNotify), so the bars
    // keep whatever they were first built with. Everything that changes
    // after loading (title, chapters, prev/next) therefore rebuilds itself.
    // (So a change to the player's look applies from the next video.)
    final look = _look = ref.watch(playerLookProvider).value ?? const PlayerLook();
    final iconSize = look.iconSize;
    final topBar = <Widget>[
      IconButton(
        tooltip: 'Back',
        color: Colors.white,
        iconSize: iconSize,
        icon: const Icon(Icons.arrow_back, shadows: _controlShadows),
        onPressed: _exit,
      ),
      const SizedBox(width: 8),
      if (look.titleArea == TitleArea.hidden) const Spacer() else Expanded(child: _live(_titleBlock)),
      if (MiniPlayer.supported)
        // The bars keep their first build (see above): this one listens.
        ValueListenableBuilder<bool>(
          valueListenable: _mini,
          builder: (_, mini, _) => IconButton(
            tooltip: mini ? 'Leave mini player' : 'Mini player',
            color: Colors.white,
            iconSize: iconSize,
            icon: Icon(mini ? Icons.open_in_full : Icons.picture_in_picture_alt_outlined, shadows: _controlShadows),
            onPressed: _toggleMini,
          ),
        ),
      // The bars keep their first build (see above): this one listens.
      Consumer(
        builder: (context, ref, _) {
          final inGroup = ref.watch(syncPlayProvider.select((s) => s.inGroup));
          return IconButton(
            tooltip: inGroup ? 'Watching together' : 'Watch together',
            color: inGroup ? Theme.of(context).colorScheme.primary : Colors.white,
            iconSize: iconSize,
            icon: Icon(inGroup ? Icons.groups : Icons.groups_outlined, shadows: _controlShadows),
            onPressed: () => showSyncPlaySheet(context),
          );
        },
      ),
      IconButton(
        tooltip: 'Playback info',
        color: Colors.white,
        iconSize: iconSize,
        icon: const Icon(Icons.info_outline, shadows: _controlShadows),
        onPressed: () => showPlaybackInfo(context, _controller, player: _playerView),
      ),
    ];

    final trackButton = Builder(
      builder: (context) => IconButton(
        tooltip: 'Audio & subtitles',
        color: Colors.white,
        iconSize: iconSize,
        icon: const Icon(Icons.subtitles_outlined, shadows: _controlShadows),
        onPressed: () => showTrackMenu(
          context,
          _engine,
          // Remembered for the show's other episodes.
          onAudioChosen: (track) {
            final series = _controller.item?.seriesId;
            if (series != null) ref.read(seriesTracksProvider.notifier).setAudio(series, track.language);
          },
          onSubtitleChosen: (track) {
            final series = _controller.item?.seriesId;
            if (series == null) return;
            ref.read(seriesTracksProvider.notifier).setSubtitle(series, track?.language, off: track == null);
          },
          burnable: _burnable(),
          burnedIn: _controller.burnedIn,
          onBurnIn: _controller.setBurnIn,
        ),
      ),
    );
    // Chapters when the file has them, else episodes (like most players).
    final previousButton = _live(() => !_controller.canSkipBack
        ? const SizedBox.shrink()
        : IconButton(
            tooltip: _controller.skipBackLabel,
            color: Colors.white,
            iconSize: iconSize,
            icon: const Icon(Icons.skip_previous, shadows: _controlShadows),
            onPressed: _controller.skipBack,
          ));
    final nextButton = _live(() => _controller.nextEpisode == null && _controller.chapters.isEmpty
        ? const SizedBox.shrink()
        : IconButton(
            tooltip: _controller.canSkipForward ? _controller.skipForwardLabel : 'No next episode',
            color: Colors.white,
            iconSize: iconSize,
            icon: const Icon(Icons.skip_next, shadows: _controlShadows),
            onPressed: _controller.canSkipForward ? _controller.skipForward : null,
          ));

    // Right-click (audio, subtitles, chapters, speed… at the mouse) and the
    // mouse wheel (volume) belong to the controls: media_kit takes the
    // controls into fullscreen, but not what's wrapped around the video.
    final menuActions = PlayerMenuActions(
            quality: () => _controller.quality,
            qualityAutoLabel: () => _controller.quality == StreamQuality.auto ? _controller.qualityLabel : 'Auto',
            onQuality: _controller.setQuality,
            burnable: _burnable,
            burnedIn: () => _controller.burnedIn,
            onBurnIn: _controller.setBurnIn,
            engine: _engine,
            chapters: () => _controller.chapters,
            chapterLabel: _controller.chapterLabel,
            currentChapter: () => _controller.currentChapter,
            seek: _seek,
            watchTogether: () => showSyncPlaySheet(context),
            miniPlayer: MiniPlayer.supported ? _toggleMini : null,
            playbackInfo: () => showPlaybackInfo(context, _controller, player: _playerView),
            position: () => _engine.player.state.position,
            onAudioChosen: (track) {
              final series = _controller.item?.seriesId;
              if (series != null) ref.read(seriesTracksProvider.notifier).setAudio(series, track.language);
            },
            onSubtitleChosen: (track) {
              final series = _controller.item?.seriesId;
              if (series == null) return;
              ref.read(seriesTracksProvider.notifier).setSubtitle(series, track?.language, off: track == null);
            },
          );
    final video = Video(
      key: _videoKey,
      controller: _video,
      controls: _isMobile
          ? AdaptiveVideoControls
          : (state) => Stack(
                fit: StackFit.expand,
                children: [
                  Listener(
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent && e.scrollDelta.dy != 0) _changeVolume(e.scrollDelta.dy < 0 ? 5 : -5);
                    },
                    child: PlayerContextMenuArea(actions: menuActions, child: MaterialDesktopVideoControls(state)),
                  ),
                  // Skip and up next go with the controls, so they're there
                  // in fullscreen too (media_kit shows only the controls).
                  ListenableBuilder(
                    listenable: _controller,
                    builder: (context, _) => PlayerOverlays(controller: _controller),
                  ),
                ],
              ),
      onEnterFullscreen: () async {
        // Double-click in the mini player: out of it first, or fullscreen
        // would remember the mini size as the one to go back to.
        await _leaveMini();
        _windowFullscreen = true;
        await MiniPlayer.beforeFullscreen();
        await defaultEnterNativeFullscreen();
        // The window's real (fullscreen) size, so no black band is left.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await MiniPlayer.relayout();
      },
      onExitFullscreen: () async {
        _windowFullscreen = false;
        await defaultExitNativeFullscreen();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await MiniPlayer.afterFullscreen();
      },
      // libass renders subtitles inside the video; hide Flutter's renderer.
      subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
    );

    final player = _engine.player;
    Widget seekBar() => _live(() => ChapterSeekBar(
          position: player.stream.position,
          duration: player.stream.duration,
          buffer: player.stream.buffer,
          initialPosition: player.state.position,
          initialDuration: player.state.duration,
          initialBuffer: player.state.buffer,
          chapters: look.chapterMarks ? _controller.chapters : const [],
          chapterLabel: _controller.chapterLabel,
          onSeek: _seek,
          preview: look.trickplay ? _trickplayPreview() : null,
        ));
    final time = PlayerTimeLabel(player: player, display: look.time, fontSize: look.large ? 15 : 13);
    // The optional buttons (Settings > Player controls > Player layout).
    final speed = look.shows(PlayerButton.speed) ? speedButton(player, iconSize) : null;
    final aspect = look.shows(PlayerButton.aspect) ? aspectButton(_engine, iconSize) : null;
    final quality = look.shows(PlayerButton.quality)
        ? qualityButton(
            current: () => _controller.quality,
            autoLabel: () => _controller.quality == StreamQuality.auto ? _controller.qualityLabel : 'Auto',
            onSelected: _controller.setQuality,
            iconSize: iconSize,
          )
        : null;
    final chapterList = look.shows(PlayerButton.chapters)
        ? _live(() => _controller.chapters.isEmpty
            ? const SizedBox.shrink()
            : chaptersButton(
                chapters: () => _controller.chapters,
                label: _controller.chapterLabel,
                current: () => _controller.currentChapter,
                seek: _seek,
                iconSize: iconSize,
              ))
        : null;
    Widget skip(int seconds) => IconButton(
          tooltip: seconds < 0 ? 'Back 10 seconds' : 'Ahead 10 seconds',
          color: Colors.white,
          iconSize: iconSize,
          icon: Icon(seconds < 0 ? Icons.replay_10 : Icons.forward_10, shadows: _controlShadows),
          onPressed: () => _seekBy(Duration(seconds: seconds)),
        );
    final skips = look.shows(PlayerButton.skip10) && look.theme != PlayerTheme.minimal;
    final prevNext = look.shows(PlayerButton.previousNext);

    if (_isMobile) {
      final media = MediaQuery.of(context);
      if (!_systemUiSettled || media.orientation != Orientation.landscape) {
        return const ColoredBox(color: Colors.black);
      }
      final settings = ref.read(playbackSettingsProvider).value ?? const PlaybackSettings();
      final skip = Duration(seconds: settings.doubleTapSeconds);
      final theme = MaterialVideoControlsThemeData(
        padding: mobileControlsPadding(MediaQuery.viewPaddingOf(context)),
        topButtonBar: topBar,
        // Our seek bar (with chapter marks) sits in the bottom bar.
        displaySeekBar: false,
        controlsHoverDuration: Duration(seconds: look.hideAfterSeconds),
        buttonBarButtonSize: iconSize,
        // Cinema: one big play / pause in the middle.
        primaryButtonBar: look.theme == PlayerTheme.cinema
            ? [MaterialPlayOrPauseButton(iconSize: look.large ? 72 : 60)]
            : const [Spacer(flex: 2), MaterialSkipPreviousButton(), Spacer(), MaterialPlayOrPauseButton(iconSize: 48), Spacer(), MaterialSkipNextButton(), Spacer(flex: 2)],
        bottomButtonBar: _themedBar(look, [
          time,
          const SizedBox(width: 16),
          Expanded(child: seekBar()),
          const SizedBox(width: 8),
          ?speed,
          ?chapterList,
          ?aspect, ?quality,
          if (look.shows(PlayerButton.tracks)) trackButton,
          if (prevNext) previousButton,
          if (prevNext) nextButton,
          if (look.shows(PlayerButton.fullscreen)) MaterialFullscreenButton(iconSize: iconSize),
        ]),
        seekOnDoubleTap: settings.doubleTapSeek,
        seekOnDoubleTapEnabledWhileControlsVisible: true,
        seekOnDoubleTapBackwardDuration: skip,
        seekOnDoubleTapForwardDuration: skip,
        // Volume / brightness swipes are ours (SwipeLevels): media_kit's
        // can't follow the volume keys.
        volumeGesture: false,
        brightnessGesture: false,
        seekBarPositionColor: Theme.of(context).colorScheme.primary,
        seekBarThumbColor: Theme.of(context).colorScheme.primary,
      );
      return MaterialVideoControlsTheme(normal: theme, fullscreen: theme, child: video);
    }

    final minimal = look.theme == PlayerTheme.minimal;
    final theme = MaterialDesktopVideoControlsThemeData(
      topButtonBar: topBar,
      // Our own seek bar, inline in the bottom bar, shows chapter marks.
      displaySeekBar: false,
      // The mouse goes with the controls, back as soon as it moves.
      hideMouseOnControlsRemoval: true,
      // Bigger, with more room around the bars on a PC (Settings > Player
      // controls > Player layout > Size).
      buttonBarHeight: look.barHeight,
      buttonBarButtonSize: iconSize,
      padding: EdgeInsets.symmetric(vertical: look.edgePadding),
      topButtonBarMargin: EdgeInsets.symmetric(horizontal: look.edgePadding + 8),
      bottomButtonBarMargin: EdgeInsets.symmetric(horizontal: look.edgePadding + 8),
      controlsHoverDuration: Duration(seconds: minimal ? 2 : look.hideAfterSeconds),
      // Cinema: one big play / pause in the middle.
      primaryButtonBar: look.theme == PlayerTheme.cinema
          ? [MaterialDesktopPlayOrPauseButton(iconSize: look.large ? 80 : 64)]
          : const [],
      bottomButtonBar: _themedBar(look, [
        if (prevNext && !minimal) previousButton,
        if (skips) skip(-10),
        if (look.theme != PlayerTheme.cinema) MaterialDesktopPlayOrPauseButton(iconSize: iconSize),
        if (skips) skip(10),
        if (prevNext && !minimal) nextButton,
        if (look.shows(PlayerButton.volume) && !minimal) MaterialDesktopVolumeButton(iconSize: iconSize),
        time,
        const SizedBox(width: 12),
        Expanded(child: seekBar()),
        const SizedBox(width: 12),
        if (!minimal) ...[?speed, ?chapterList, ?aspect],
        ?quality,
        if (look.shows(PlayerButton.tracks)) trackButton,
        if (look.shows(PlayerButton.fullscreen)) MaterialDesktopFullscreenButton(iconSize: iconSize),
      ]),
      seekBarPositionColor: Theme.of(context).colorScheme.primary,
      seekBarThumbColor: Theme.of(context).colorScheme.primary,
      keyboardShortcuts: shortcuts,
      playAndPauseOnTap:
          ref.watch(playbackSettingsProvider).value?.clickToPlayPause ?? true,
      // media_kit's switch also makes a drag on the video change the volume:
      // off, and the wheel is handled below.
      modifyVolumeOnScroll: false,
    );
    return MaterialDesktopVideoControlsTheme(
      normal: theme,
      fullscreen: theme,
      child: video,
    );
  }

  /// Classic / Glass put the bottom bar's controls on a panel.
  List<Widget> _themedBar(PlayerLook look, List<Widget> row) =>
      look.theme == PlayerTheme.classic || look.theme == PlayerTheme.glass
          ? [Expanded(child: PlayerBarPanel(theme: look.theme, child: Row(children: row)))]
          : row;

  /// The player's look as last built (the title block reads it).
  PlayerLook _look = const PlayerLook();

  /// Seek bar thumbnails from Jellyfin's trickplay images, when the server
  /// has made them for this item.
  Widget Function(Duration)? _trickplayPreview() {
    final item = _controller.item;
    if (item == null) return null;
    final trickplay = Trickplay.of(item, mediaSourceId: _controller.plan?.source.id);
    if (trickplay == null) return null;
    final api = ref.read(signedInApiProvider);
    final token = api.accessToken ?? '';
    return (time) => TrickplayThumbnail(
          trickplay: trickplay,
          time: time,
          tileUrl: (tile) => trickplay.tileUrl(api.baseUrl, item.id, tile, token),
        );
  }

  /// Brightness (left) and volume (right) swipes over the video, phones.
  Widget _swipeLevels() {
    final settings = ref.watch(playbackSettingsProvider).value ?? const PlaybackSettings();
    final system = settings.swipeSystemVolume;
    final player = _engine.player;
    return SwipeLevels(
      // Rebuilt when the volume target changes, so it reads the right level.
      key: ValueKey(system),
      volume: system ? _device.volume : () async => player.state.volume / 100,
      brightness: _device.brightness,
      volumeChanges: system ? _device.volumeChanges() : null,
      onVolume: !settings.swipeVolume
          ? null
          : system
              ? (v) => unawaited(_device.setVolume(v))
              : (v) => unawaited(player.setVolume(v * 100)),
      onBrightness: settings.swipeBrightness ? (v) => unawaited(_device.setBrightness(v)) : null,
      atSide: settings.levelsAtSide,
    );
  }

  Widget _titleBlock() {
    final item = _controller.item;
    // Show and episode names follow Settings > MyAnimeList > Anime titles.
    // The show in bold, then "· S1:E1 Episode name" in normal weight. Each
    // opens its page.
    final (show, rest) = item == null
        ? ('', '')
        : item.type == ItemType.episode
            ? (
                preferredAnimeTitle(ref, item, item.seriesName ?? ''),
                '${item.episodeLabel ?? ''} ${preferredEpisodeTitle(ref, item, item.name)}'.trim(),
              )
            : (preferredAnimeTitle(ref, item, item.name), '');
    return Padding(
      // Phones: a little lower than the buttons beside it.
      padding: EdgeInsets.only(top: _isMobile ? 6 : 0),
      child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: show,
              style: const TextStyle(fontWeight: FontWeight.bold),
              recognizer: _showLink,
              mouseCursor: SystemMouseCursors.click,
            ),
            if (rest.isNotEmpty) ...[
              const TextSpan(text: ' · '),
              TextSpan(text: rest, recognizer: _episodeLink, mouseCursor: SystemMouseCursors.click),
            ],
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: switch ((_look.theme, _look.large)) {
              (PlayerTheme.cinema, _) => _look.large ? 28 : 24,
              (_, true) => 21,
              _ => 18,
            },
            shadows: _controlShadows,
          ),
        ),
        if (_look.titleArea == TitleArea.full && _controller.currentChapter != null)
          Text(
            _controller.chapterLabel(_controller.currentChapter!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 13, shadows: _controlShadows),
          ),
      ],
      ),
    );
  }
}

/// Explains how the item is being played and why it's transcoding.
/// [player]: the video as the player sees it (its shape), when known.
void showPlaybackInfo(BuildContext context, PlaybackController controller, {String? player}) {
  final plan = controller.plan;
  if (plan == null) return;
  final video = plan.source.streamsOfType('Video').firstOrNull;
  final audio = plan.source.streamsOfType('Audio').length;
  final subs = plan.source.streamsOfType('Subtitle').length;

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Playback info'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('Method', plan.method.label),
          _infoRow('Quality', controller.qualityLabel),
          if (plan.transcodeReasons.isNotEmpty)
            _infoRow('Why', plan.transcodeReasons.map(describeTranscodeReason).join('\n')),
          _infoRow('Container', plan.source.container ?? '?'),
          if (video != null)
            _infoRow(
              'Video',
              [
                video.codec?.toUpperCase(),
                if (video.width != null) '${video.width}×${video.height}',
                video.videoRange,
              ].nonNulls.join(' · '),
            ),
          if (video?.aspectRatio case final r?) _infoRow('Shape', r),
          if (player != null) _infoRow('Player', player),
          _infoRow('Tracks', '$audio audio, $subs subtitle'),
          if (plan.source.bitrate case final b?)
            _infoRow('File bitrate', '${(b / 1000000).toStringAsFixed(1)} Mbps'),
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Widget _infoRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 96, child: Text(label, style: const TextStyle(color: Colors.white70))),
          Expanded(child: Text(value)),
        ],
      ),
    );

/// Human-readable text for the server's TranscodeReasons values.
String describeTranscodeReason(String reason) => switch (reason) {
      'ContainerNotSupported' => 'Container not supported by this player',
      'VideoCodecNotSupported' => 'Video codec not supported',
      'AudioCodecNotSupported' => 'Audio codec not supported',
      'SubtitleCodecNotSupported' => 'Subtitles need burning in',
      'ContainerBitrateExceedsLimit' || 'VideoBitrateNotSupported' =>
        'Bitrate is above the streaming limit',
      'AudioChannelsNotSupported' => 'Too many audio channels',
      'DirectPlayError' => 'Direct play failed',
      _ => reason,
    };
