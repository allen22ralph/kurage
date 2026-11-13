import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../settings/appearance.dart';
import '../../../app/layout.dart';
import '../../../app/providers.dart';
import '../../../core/jellyfin/items.dart';
import '../../../core/log/app_log.dart';
import '../../player/open_player.dart';
import '../home_header_settings.dart';

/// Home's previews: at most one plays at a time, and the header's trailer
/// pauses while one does.
abstract final class Preview {
  /// The preview playing (its state); null with none.
  static final playing = ValueNotifier<Object?>(null);

  /// The item whose preview has frames on screen; null with none. For
  /// what says a preview is playing: hovering doesn't mean one is.
  static final showing = ValueNotifier<String?>(null);

  /// The one player all previews share, kept once made. Only one plays at a
  /// time, and making and disposing one for each preview, as the mouse passes
  /// over rows, raced with the video package's own setup on other threads: a
  /// player disposed part-way through could take the whole app down.
  static (Player, VideoController)? _shared;

  static (Player, VideoController) _player() {
    final made = _shared;
    if (made != null) return made;
    final player = Player();
    final video = VideoController(player);
    // Previews are all muted and loop.
    unawaited(player.setVolume(0));
    unawaited(player.setPlaylistMode(PlaylistMode.single));
    return _shared = (player, video);
  }
}

/// A muted preview of [item] itself (an episode, a film), from a few
/// seconds before where it was left, fading in over whatever is under it
/// once [active] has held for [delay]. Only while Home is in front and the
/// app is too; on a phone, only on Wi-Fi.
class EpisodePreview extends ConsumerStatefulWidget {
  const EpisodePreview({
    super.key,
    required this.item,
    required this.active,
    this.delay = const Duration(milliseconds: 350),
  });

  final BaseItem item;
  final bool active;
  final Duration delay;

  @override
  ConsumerState<EpisodePreview> createState() => _EpisodePreviewState();
}

class _EpisodePreviewState extends ConsumerState<EpisodePreview> with WidgetsBindingObserver {
  Player? _player;
  VideoController? _video;

  /// Which start this is: the player stays, so an earlier one's frames
  /// mustn't count for a later one.
  int _turn = 0;
  bool _showing = false;
  bool _covered = false;
  bool _appActive = true;
  Timer? _wait;

  /// Mostly on screen: a preview further down the page doesn't play (on a
  /// phone it would start by itself and pause the header's trailer).
  bool _visible = false;
  ScrollPosition? _scroll;

  /// Re-checks [_visible] while [EpisodePreview.active]: the page can move
  /// without scrolling (at launch the header arrives and pushes the rows
  /// down), and a scroll listener alone misses that.
  Timer? _watch;

  /// Off below Full (Settings > Appearance > Effects).
  bool _effectsAllow = false;

  /// Settings > Home. Kept here, as [_sync] also runs for another preview's
  /// stopping, which can be while this one is on its way out of the tree,
  /// where `ref` can't be read.
  bool _previewsOn = true;

  bool get _wanted =>
      _effectsAllow &&
      _previewsOn &&
      widget.active &&
      _visible &&
      !_covered &&
      _appActive &&
      OpenPlayer.itemId.value == null &&
      // One at a time: another waits until this one stops.
      (Preview.playing.value == null || Preview.playing.value == this);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    OpenPlayer.itemId.addListener(_sync);
    Preview.playing.addListener(_sync);
    ref.listenManual(homeHeaderSettingsProvider, fireImmediately: true, (_, next) {
      _previewsOn = next.value?.previews ?? true;
      _sync();
    });
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Another page over Home: no preview behind it.
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll != _scroll) {
      _scroll?.removeListener(_checkVisible);
      _scroll = scroll?..addListener(_checkVisible);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
    final allowed = effectsOf(context).playsPreviews;
    if (allowed != _effectsAllow) {
      _effectsAllow = allowed;
      _sync();
    }
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered != _covered) {
      _covered = covered;
      _sync();
    }
  }

  @override
  void didUpdateWidget(EpisodePreview old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) _stop();
    if (widget.active && !old.active) WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisible());
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _sync();
  }

  /// At least half of it on screen (no scrolling page: always).
  void _checkVisible() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    var visible = true;
    if (_scroll != null && box != null && box.hasSize && box.attached) {
      final top = box.localToGlobal(Offset.zero).dy;
      final screen = MediaQuery.sizeOf(context).height;
      final shown = (math.min(top + box.size.height, screen) - math.max(top, 0)).clamp(0.0, box.size.height);
      visible = box.size.height == 0 || shown >= box.size.height / 2;
    }
    if (visible != _visible) {
      _visible = visible;
      _sync();
    }
  }

  void _sync() {
    if (!mounted) return;
    if (widget.active) {
      _watch ??= Timer.periodic(const Duration(milliseconds: 400), (_) => _checkVisible());
    } else {
      _watch?.cancel();
      _watch = null;
    }
    if (_wanted) {
      if (_player == null && _wait == null) _wait = Timer(widget.delay, _start);
    } else {
      _stop();
    }
  }

  /// A phone: on Wi-Fi, or with mobile data allowed (Settings > Home >
  /// Header > Trailers and previews on mobile data).
  Future<bool> _allowed() async {
    if (!Platform.isAndroid || ref.read(isTvProvider)) return true;
    if (ref.read(homeHeaderSettingsProvider).value?.trailersOnMobileData ?? false) return true;
    try {
      final links = await Connectivity().checkConnectivity();
      return links.contains(ConnectivityResult.wifi) || links.contains(ConnectivityResult.ethernet);
    } on Object {
      return false;
    }
  }

  Future<void> _start() async {
    _wait = null;
    final item = widget.item;
    if (!_wanted || !await _allowed() || !mounted || !_wanted || widget.item.id != item.id) return;
    final api = ref.read(signedInApiProvider);
    try {
      final (player, video) = Preview._player();
      _player = player;
      _video = video;
      final turn = ++_turn;
      Preview.playing.value = this;
      final position = Duration(microseconds: item.userData.playbackPositionTicks ~/ 10);
      final start = position - const Duration(seconds: 5);
      await player.open(
        Media(
          api.resolve('/Videos/${item.id}/stream', {'static': true}).toString(),
          httpHeaders: {'Authorization': api.authorizationHeader},
          start: start.isNegative ? Duration.zero : start,
        ),
      );
      // Shown once frames come (the still stays until then).
      player.stream.width.where((w) => (w ?? 0) > 0).first.then((_) {
        if (mounted && _player == player && _turn == turn) {
          setState(() => _showing = true);
          Preview.showing.value = item.id;
        }
      }, onError: (Object _) {});
      if (mounted) setState(() {});
    } on Object catch (e) {
      AppLog.warning(LogArea.player, 'Home preview: ${item.name}', error: e);
      _stop();
    }
  }

  /// After the current build: this can stop during one, and what listens
  /// rebuilds.
  void _noLongerShowing() {
    if (!_showing) return;
    final id = widget.item.id;
    scheduleMicrotask(() {
      if (Preview.showing.value == id) Preview.showing.value = null;
    });
  }

  void _stop() {
    _wait?.cancel();
    _wait = null;
    final player = _player;
    if (player == null) return;
    _player = null;
    _video = null;
    if (Preview.playing.value == this) Preview.playing.value = null;
    _noLongerShowing();
    player.stop();
    if (mounted) setState(() => _showing = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    OpenPlayer.itemId.removeListener(_sync);
    Preview.playing.removeListener(_sync);
    _scroll?.removeListener(_checkVisible);
    _wait?.cancel();
    _watch?.cancel();
    final player = _player;
    if (player != null) {
      if (Preview.playing.value == this) Preview.playing.value = null;
      _noLongerShowing();
      player.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    if (video == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _showing ? 1 : 0,
        duration: const Duration(milliseconds: 450),
        child: Video(controller: video, fit: BoxFit.cover, controls: NoVideoControls),
      ),
    );
  }
}

/// A phone has no hover: previews play by themselves there.
bool previewsPlayBySelf(BuildContext context) => context.layout.formFactor == FormFactor.phone;
