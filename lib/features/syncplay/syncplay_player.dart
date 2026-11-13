import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../player/playback_log.dart';
import '../../core/jellyfin/syncplay.dart';
import '../player/media_engine.dart';
import '../player/playback_controller.dart';
import 'syncplay_service.dart';

/// Ties one player to the watch-together group, while there is one:
/// - starting an item that isn't the group's current one starts it for
///   everyone; the group's item waits (paused) until all are ready;
/// - local play / pause / seek become requests to the group, and the
///   group's commands are applied at their server time.
class SyncPlayBinding {
  SyncPlayBinding({
    required this.read,
    required this.engine,
    required this.player,
    required this.itemId,
    required this.opened,
    Duration Function()? position,
  }) : _position = position ?? (() => engine.position);

  /// For the player: from its PlaybackController.
  factory SyncPlayBinding.forPlayer(T Function<T>(ProviderListenable<T>) read, MediaEngine engine, PlaybackController c) =>
      SyncPlayBinding(
        read: read,
        engine: engine,
        player: c,
        itemId: () => c.item?.id,
        opened: () => c.plan != null,
        position: () => c.currentPosition,
      );

  /// `ref.read` (a widget's or a container's).
  final T Function<T>(ProviderListenable<T>) read;
  final MediaEngine engine;

  /// Notifies when what the player plays (or its state) changes.
  final Listenable player;
  final String? Function() itemId;

  /// The stream is open.
  final bool Function() opened;

  /// Where this player is (for a stream just opened: where it opens, not
  /// the 0:00 it reads for a moment).
  final Duration Function() _position;

  SyncPlayController get _sync => read(syncPlayProvider.notifier);
  bool get active => read(syncPlayProvider).inGroup;

  StreamSubscription<SyncPlayCommand>? _commands;
  StreamSubscription<bool>? _playing;
  StreamSubscription<void>? _rejoined;
  StreamSubscription<void>? _resync;
  StreamSubscription<SyncPlayQueue>? _queues;

  /// The group's entry this player last said "ready" for.
  String? _readyFor;
  Timer? _scheduled;

  /// While a small gap is closed by playing a little faster / slower.
  Timer? _nudge;

  /// Gaps under [maxDrift] but over this are closed by a speed nudge.
  static const nudgeFrom = Duration(milliseconds: 200);

  /// The nudge: ±5 %, so a 0.5 s gap closes in 10 s.
  static const nudgeRate = 0.05;

  /// Positions within this of the group's count as the same frame.
  static const sameFrame = Duration(milliseconds: 50);
  Timer? _driftTimer;
  bool _started = false;

  /// Where the group's playback was at a server time, since its last
  /// Unpause; null while paused. The basis for staying in step.
  ({Duration position, DateTime when})? _anchor;

  /// Further off the group than this (twice in a row), and the player
  /// jumps back in step.
  static const maxDrift = Duration(milliseconds: 1500);

  /// No corrections this soon after a group command or a correction: the
  /// stream is still seeking / buffering, and its position means little.
  static const settleTime = Duration(seconds: 15);

  /// More corrections than this within [correctionWindow], and they stop
  /// (something keeps pulling it out of step; jumping again won't help).
  static const maxCorrections = 3;
  static const correctionWindow = Duration(minutes: 2);

  /// The playing state we set ourselves, until [_expectUntil]: changes
  /// matching it are ours, not the user's.
  bool? _expectPlaying;
  DateTime _expectUntil = DateTime(0);

  /// No drift corrections until then (after a command or a correction).
  DateTime _quietUntil = DateTime(0);

  Duration? _lastSeen;
  int _driftStrikes = 0;
  final _corrections = <DateTime>[];
  bool _correctionsStopped = false;

  /// For tests: the clock the binding goes by.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  void start() {
    _commands = _sync.commands.listen(_enqueue);
    _playing = engine.playingStream.listen(_onPlaying);
    // Into a group with this player already open (joined or created while
    // watching, or back after a dropped connection): join in from here,
    // starting this episode for the group if it has none.
    _rejoined = _sync.rejoined.listen((_) {
      if (_closing) return;
      _started = false;
      _readyFor = null;
      _anchor = null;
      _correctionsStopped = false;
      _corrections.clear();
      _onController();
    });
    _resync = _sync.resyncRequests.listen((_) => syncNow());
    // The group's queue now has this player's episode (this device started
    // it, or it changed): say ready for it. The group waits for every
    // device, the one that started it too.
    _queues = _sync.queues.listen((queue) {
      final item = _playlistItemId;
      if (_closing || !_started || item == null || item == _readyFor) return;
      unawaited(_sayReady(item));
    });
    player.addListener(_onController);
    _driftTimer = Timer.periodic(const Duration(seconds: 5), (_) => checkDrift());
  }

  /// This device's sound delay (see syncPlayAudioDelayProvider): it plays
  /// this far ahead.
  Duration get _audioDelay => Duration(milliseconds: read(syncPlayAudioDelayProvider));

  /// Where this device should be: the group's position, plus its delay.
  Duration? get _target => switch (groupPosition) {
        final g? => g + _audioDelay,
        null => null,
      };

  void _stopNudge() {
    if (_nudge == null) return;
    _nudge!.cancel();
    _nudge = null;
    unawaited(engine.setRate(1).catchError(_log));
  }

  Timer? _readyTimer;

  /// Ready (and playing, if the group plays: it carries on once we're in),
  /// said again if the group keeps waiting. First to where the group is, if
  /// that's known and this player is elsewhere: ready from 0:00 made the
  /// server wait for this device to "catch up" for as long as the gap.
  Future<void> _sayReady(String playlistItem) async {
    _readyFor = playlistItem;
    var at = _position();
    final group = _sync.groupPositionNow;
    if (group != null && (group - at).abs() > const Duration(seconds: 1)) {
      PlaybackLog.add('Watch together: to the group at $group first');
      _quietUntil = now().add(settleTime);
      await engine.seek(group);
      at = group;
    }
    PlaybackLog.add('Watch together: ready at $at');
    unawaited(_sync.ready(playlistItem, at, playing: _sync.groupPlaying).catchError(_log));
    _readyAgain(playlistItem);
  }

  /// Still waiting a while after saying ready (a report lost on the way):
  /// say it again, a few times.
  void _readyAgain(String playlistItem, [int left = 3]) {
    _readyTimer?.cancel();
    if (left == 0) return;
    _readyTimer = Timer(const Duration(seconds: 5), () {
      if (_closing || !active || _sync.groupState.value != 'Waiting' || _playlistItemId != playlistItem) return;
      PlaybackLog.add('Watch together: still waiting, ready again');
      unawaited(_sync.ready(playlistItem, _position(), playing: _sync.groupPlaying).catchError(_log));
      _readyAgain(playlistItem, left - 1);
    });
  }

  /// "Sync now": as Jellyfin's own player does it, this device tells the
  /// server it's buffering, then ready where it is; the server then starts
  /// the group again, in step, for everyone. (Moving to where this device
  /// worked out the group to be changed nothing when that guess was off.)
  Future<void> syncNow() async {
    if (!active || !_started || _closing) return;
    final item = _playlistItemId;
    if (item == null) return;
    _stopNudge();
    final playing = engine.isPlaying || _sync.groupPlaying;
    final position = _position();
    PlaybackLog.add('Watch together: sync now (buffering, then ready at $position${playing ? ', playing' : ''})');
    _pauseOurs();
    try {
      await _sync.buffering(item, position, playing: playing);
      await _sync.ready(item, position, playing: playing);
      _readyAgain(item);
    } on Object catch (e) {
      _log(e);
    }
  }

  void dispose() {
    _commands?.cancel();
    _playing?.cancel();
    _rejoined?.cancel();
    _resync?.cancel();
    _queues?.cancel();
    _scheduled?.cancel();
    _driftTimer?.cancel();
    _nudge?.cancel();
    _readyTimer?.cancel();
    player.removeListener(_onController);
  }

  /// The user closed the player: pause the group, rather than have it play
  /// on for everyone else.
  void leftPlayer() {
    if (_closing) return;
    // From now on the group's commands don't move this player: it's closing.
    _closing = true;
    // Called while the player closes: whatever happens here mustn't stop it
    // closing (and its sound stopping).
    try {
      if (active && _started) {
        if (read(syncPlayPauseOnLeaveProvider)) {
          unawaited(_sync.requestPause().catchError(_log));
        } else {
          // The others carry on: the server would wait for this device
          // while it's in the group, so step out (rejoin from the sheet).
          unawaited(_sync.stepOut().catchError(_log));
        }
      }
    } on Object catch (e) {
      _log(e);
    }
  }

  /// Where the group is now, while it plays.
  Duration? get groupPosition {
    final a = _anchor;
    return a == null ? null : a.position - _sync.clock.until(a.when);
  }

  /// Off the group by more than [maxDrift] on two checks running (a slow
  /// device): jump back in step, on this device only. Never alone in the
  /// group, while buffering, or soon after a command or a correction; and
  /// not at all after [maxCorrections] in a short while.
  @visibleForTesting
  Future<void> checkDrift() async {
    final expected = _target;
    final position = engine.position;
    final stalled = position == _lastSeen;
    _lastSeen = position;
    final t = now();
    if (!active || !_started || expected == null || !engine.isPlaying || _correctionsStopped) return;
    if (read(syncPlayProvider).participants.length < 2 || stalled || t.isBefore(_quietUntil)) {
      _driftStrikes = 0;
      return;
    }
    final off = position - expected;
    if (off.abs() <= maxDrift) {
      _driftStrikes = 0;
      // A little off (e.g. this device's player keeps time slightly
      // differently): a slight speed change closes it, unnoticed; no jump.
      if (off.abs() > nudgeFrom && _nudge == null) {
        final rate = off.isNegative ? 1 + nudgeRate : 1 - nudgeRate;
        final takes = Duration(milliseconds: (off.inMilliseconds.abs() / nudgeRate).round());
        PlaybackLog.add('Watch together: ${off.inMilliseconds} ms off, playing at ${rate}x for ${takes.inSeconds} s');
        await engine.setRate(rate);
        _nudge = Timer(takes, _stopNudge);
      }
      return;
    }
    _stopNudge();
    if (++_driftStrikes < 2) return;
    _driftStrikes = 0;
    _corrections
      ..add(t)
      ..removeWhere((c) => t.difference(c) > correctionWindow);
    if (_corrections.length > maxCorrections) {
      _correctionsStopped = true;
      PlaybackLog.add('Watch together: corrections stopped (${_corrections.length} in ${correctionWindow.inMinutes} min)');
      _sync.notice("Watch together couldn't keep this device in step, so it stopped correcting");
      return;
    }
    _quietUntil = t.add(settleTime);
    PlaybackLog.add('Watch together: ${(position - expected).inMilliseconds} ms off the group, back to $expected');
    await engine.seek(expected);
  }

  /// The group's playlist entry for what this player plays, if it's the
  /// group's current item.
  String? get _playlistItemId {
    final current = read(syncPlayProvider).queue?.current;
    final item = itemId();
    return current != null && item != null && current.itemId == normalizeItemId(item) ? current.playlistItemId : null;
  }

  /// Once the stream is open: join in with the group.
  void _onController() {
    if (_started || !active || !opened() || itemId() == null) return;
    _started = true;
    // Hold still until the group says go.
    _pauseOurs();
    final playlistItem = _playlistItemId;
    if (playlistItem == null) {
      // Not the group's item: start it for everyone, from here.
      unawaited(_sync.play(itemId()!, start: _position()).catchError(_log));
    } else {
      unawaited(_sayReady(playlistItem));
    }
  }

  /// A seek from the user. True when the group handles it.
  bool seek(Duration target) {
    if (!active) return false;
    unawaited(_sync.requestSeek(target).catchError(_log));
    return true;
  }

  void _onPlaying(bool playing) {
    // Closing: its own pause (going quiet) isn't the user pausing the group
    // (it raced stepping out, and paused everyone now and then).
    if (!active || !_started || _closing) return;
    final t = now();
    // The change we just made ourselves, not the user's.
    if (t.isBefore(_expectUntil) && playing == _expectPlaying) return;
    // The group is getting everyone ready: it starts by itself; asking it
    // to play now would only bounce back to pause.
    // (For a while only: a group stuck waiting mustn't lock play out.)
    final since = _sync.waitingSince;
    if (playing &&
        _sync.groupState.value == 'Waiting' &&
        since != null &&
        DateTime.now().difference(since) < const Duration(seconds: 10)) {
      _pauseOurs();
      return;
    }
    // The user pressed play / pause: ask the group instead.
    if (playing) {
      _pauseOurs();
      unawaited(_sync.requestUnpause().catchError(_log));
    } else {
      _ownPauseAt = now();
      unawaited(_sync.requestPause().catchError(_log));
    }
  }

  /// When this device last asked the group to pause (so the group's Pause
  /// that follows isn't announced as someone else's).
  DateTime _ownPauseAt = DateTime(0);

  void _expect(bool playing) {
    _expectPlaying = playing;
    _expectUntil = now().add(const Duration(seconds: 2));
  }

  void _pauseOurs() {
    _expect(false);
    if (engine.isPlaying) unawaited(engine.pause());
  }

  void _playOurs() {
    _expect(true);
    if (!engine.isPlaying) unawaited(engine.play());
  }

  /// Commands apply one at a time, in order (a seek mid-way through
  /// another one is what tangled audio and video).
  Future<void> _applying = Future.value();

  void _enqueue(SyncPlayCommand c) => _applying = _applying.then((_) => _apply(c)).catchError(_log);

  /// The player is closing (see [leftPlayer]).
  bool _closing = false;

  Future<void> _apply(SyncPlayCommand c) async {
    if (!active || _closing) return;
    _quietUntil = now().add(settleTime);
    _driftStrikes = 0;
    PlaybackLog.add('Watch together: ${c.command} at ${c.position} (in ${_sync.clock.until(c.when).inMilliseconds} ms)');
    final playlistItem = _playlistItemId;
    if (c.playlistItemId != null && playlistItem != null && c.playlistItemId != playlistItem) return;
    _scheduled?.cancel();
    final wait = _sync.clock.until(c.when);
    switch (c.command) {
      case 'Unpause':
        // Late (wait < 0): start further in, where the others are by now.
        final target = (wait.isNegative ? c.position - wait : c.position) + _audioDelay;
        _stopNudge();
        // On the same frame as the others, not roughly.
        if ((engine.position - target).abs() > sameFrame) await engine.seek(target);
        _anchor = (position: c.position, when: c.when);
        _scheduled = Timer(wait.isNegative ? Duration.zero : wait, _playOurs);
      case 'Pause':
        // Someone else paused, or left the player: say so, briefly.
        if (now().difference(_ownPauseAt) > const Duration(seconds: 3) && _anchor != null) {
          _sync.notice('The group paused (someone paused or left the player)');
        }
        _anchor = null;
        _stopNudge();
        _pauseOurs();
        // Paused on the same frame as the others.
        if ((engine.position - c.position).abs() > sameFrame) await engine.seek(c.position);
      case 'Seek':
        _anchor = null;
        _stopNudge();
        _pauseOurs();
        await engine.seek(c.position);
        if (playlistItem != null) unawaited(_sync.ready(playlistItem, c.position).catchError(_log));
      case 'Stop':
        _anchor = null;
        _stopNudge();
        _pauseOurs();
    }
  }

  static void _log(Object e) => debugPrint('SyncPlay: $e');
}
