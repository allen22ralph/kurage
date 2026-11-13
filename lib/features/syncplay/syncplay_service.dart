import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/open_player.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/syncplay.dart';

/// Where SyncPlay stands on this device.
class SyncPlayState {
  const SyncPlayState({this.group, this.participants = const [], this.queue, this.busy = false, this.error});

  /// The group this device is in, or null.
  final SyncPlayGroup? group;
  final List<String> participants;
  final SyncPlayQueue? queue;
  final bool busy;
  final String? error;

  bool get inGroup => group != null;

  SyncPlayState copyWith({
    SyncPlayGroup? Function()? group,
    List<String>? participants,
    SyncPlayQueue? Function()? queue,
    bool? busy,
    String? Function()? error,
  }) =>
      SyncPlayState(
        group: group == null ? this.group : group(),
        participants: participants ?? this.participants,
        queue: queue == null ? this.queue : queue(),
        busy: busy ?? this.busy,
        error: error == null ? this.error : error(),
      );
}

final syncPlayApiProvider = Provider<SyncPlayApi>((ref) => SyncPlayApi(ref.watch(signedInApiProvider)));

/// Connects to a session socket (overridable in tests).
typedef SocketConnector = Future<Stream<SyncPlayEvent>> Function();

final syncPlaySocketProvider = Provider<SocketConnector>((ref) {
  final api = ref.watch(signedInApiProvider);
  final deviceId = ref.watch(clientInfoProvider).deviceId;
  return () async {
    final socket = await SessionSocket.connect(api.baseUrl, token: api.accessToken ?? '', deviceId: deviceId);
    ref.onDispose(socket.close);
    return socket.events;
  };
});

final syncPlayProvider = NotifierProvider<SyncPlayController, SyncPlayState>(SyncPlayController.new);

/// Opens what the group plays ([itemId]) — never as a second player: if
/// it's already playing here, that player re-syncs; another player is
/// replaced. (A player opened on top, from Join, played over the one
/// underneath and left it behind on going back.)
void openGroupItem(GoRouter router, SyncPlayController sync, String itemId, {String via = 'group'}) {
  final open = OpenPlayer.itemId.value;
  if (open == itemId) {
    sync.syncNow();
  } else if (open != null) {
    router.pushReplacement('/play/$itemId?via=$via');
  } else {
    router.push('/play/$itemId?via=$via');
  }
}

/// "When I leave the player": pause the group (wait for me) or not (the
/// others carry on). Per device; default wait.
final syncPlayPauseOnLeaveProvider = NotifierProvider<SyncPlayPauseOnLeave, bool>(SyncPlayPauseOnLeave.new);

class SyncPlayPauseOnLeave extends Notifier<bool> {
  static const _key = 'syncplay.pauseOnLeave';

  @override
  bool build() {
    SharedPreferences.getInstance().then((p) {
      final saved = p.getBool(_key);
      if (saved != null && saved != state) state = saved;
    }, onError: (Object _) {});
    return true;
  }

  Future<void> set(bool on) async {
    state = on;
    await (await SharedPreferences.getInstance()).setBool(_key, on);
  }
}

/// How much later this device's sound comes out than the others' (e.g. a
/// phone's speaker), in ms: watch together plays this far ahead to make up
/// for it. Set per device in the watch-together sheet.
final syncPlayAudioDelayProvider = NotifierProvider<SyncPlayAudioDelay, int>(SyncPlayAudioDelay.new);

class SyncPlayAudioDelay extends Notifier<int> {
  static const _key = 'syncplay.audioDelayMs';

  @override
  int build() {
    SharedPreferences.getInstance().then((p) {
      final saved = p.getInt(_key);
      if (saved != null && saved != state) state = saved;
    }, onError: (Object _) {});
    return 0;
  }

  Future<void> set(int ms) async {
    state = ms.clamp(-500, 500);
    await (await SharedPreferences.getInstance()).setInt(_key, state);
  }
}

/// The group's queue changes and notices, for the app shell (it opens what
/// the group plays, and shows who joined / left).
final syncPlayQueueStreamProvider =
    StreamProvider<SyncPlayQueue>((ref) => ref.watch(syncPlayProvider.notifier).queues);
final syncPlayNoticeStreamProvider = StreamProvider<String>((ref) => ref.watch(syncPlayProvider.notifier).notices);

/// Watch together: joining / leaving groups, the server clock, and the
/// group's commands and queue for the player.
class SyncPlayController extends Notifier<SyncPlayState> {
  final clock = ServerClock();
  final _commands = StreamController<SyncPlayCommand>.broadcast();
  final _queues = StreamController<SyncPlayQueue>.broadcast();
  final _notices = StreamController<String>.broadcast();
  StreamSubscription<SyncPlayEvent>? _events;
  Timer? _clockTimer;
  final _rejoined = StreamController<void>.broadcast();
  final _resync = StreamController<void>.broadcast();

  /// The group plays (not paused): a device joining or re-syncing reports
  /// "ready, playing" then, so the server carries on rather than waiting
  /// for someone to press play.
  bool groupPlaying = false;

  /// The group's state as the server last said: Idle, Waiting (for
  /// everyone to be ready), Paused, Playing.
  final groupState = ValueNotifier<String?>(null);

  /// When the group last started waiting (for play to be held only a while).
  DateTime? waitingSince;

  /// The group's last position from its commands, at the server time
  /// [when], and whether it plays on from there.
  ({Duration position, DateTime when, bool playing})? _lastGroup;

  /// Where the group is now, as far as its commands say; null unknown.
  /// A joining device starts here: saying "ready" from 0:00 made the server
  /// wait for it to catch up (the 20–70 s stalls).
  Duration? get groupPositionNow {
    final g = _lastGroup;
    if (g == null) return null;
    return g.playing ? g.position - clock.until(g.when) : g.position;
  }

  /// "Sync now" (the sheet): the player puts itself back where the group is.
  Stream<void> get resyncRequests => _resync.stream;
  void syncNow() => _resync.add(null);

  /// The group to get back into after the connection dropped (a phone's
  /// screen locking closes it), while reconnecting.
  SyncPlayGroup? _rejoining;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// Reconnect attempts before giving up (spaced out: 2 s, 4 s, … 30 s).
  static const maxReconnectAttempts = 12;

  /// In a group: joined, created, or back after a dropped connection. A
  /// player already open joins in (starts its episode for the group, or
  /// gets in step with it).
  Stream<void> get rejoined => _rejoined.stream;

  /// Play / pause / seek for the whole group, at a server time.
  Stream<SyncPlayCommand> get commands => _commands.stream;

  /// The group's queue changed (someone started something).
  Stream<SyncPlayQueue> get queues => _queues.stream;

  /// "sam joined", for a snackbar.
  Stream<String> get notices => _notices.stream;

  SyncPlayApi get _api => ref.read(syncPlayApiProvider);

  @override
  SyncPlayState build() {
    ref.onDispose(() {
      _events?.cancel();
      _clockTimer?.cancel();
      _reconnectTimer?.cancel();
    });
    return const SyncPlayState();
  }

  Future<List<SyncPlayGroup>> groups() => _api.groups();

  Future<void> create(String name) => _enter(() => _api.create(name));
  Future<void> join(String groupId) => _enter(() => _api.join(groupId));

  Future<void> _enter(Future<void> Function() request) async {
    state = state.copyWith(busy: true, error: () => null);
    try {
      await _listen();
      await _syncClock();
      await request();
      // The server answers on the socket (GroupJoined).
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: () => '$e');
    }
  }

  /// The group this device stepped out of on leaving the player (with
  /// "pause the group when I leave" off), to rejoin from the sheet.
  SyncPlayGroup? steppedOut;

  /// Leaving the player without holding the others up: the server waits
  /// for every member, so this device leaves the group (and can rejoin).
  Future<void> stepOut() async {
    final group = state.group;
    if (group == null) return;
    await leave();
    steppedOut = group;
    _notices.add('You stepped out of ${group.name}: the others carry on. Rejoin from Watch together.');
  }

  Future<void> rejoin() async {
    final group = steppedOut;
    if (group == null) return;
    await join(group.id);
  }

  Future<void> leave() async {
    steppedOut = null;
    _stopReconnecting();
    try {
      await _api.leave();
    } on Object catch (e) {
      debugPrint('SyncPlay leave: $e');
    }
    _left();
  }

  Future<void> _listen() async {
    if (_events != null) return;
    final events = await ref.read(syncPlaySocketProvider)();
    _events = events.listen(_onEvent, onDone: () {
      _events = null;
      // Dropped (the screen locked, the network changed): get back in.
      if (state.inGroup) {
        _notices.add('Lost the connection to the group, reconnecting…');
        _reconnect(state.group!);
      }
    });
  }

  void _reconnect(SyncPlayGroup group) {
    _rejoining = group;
    _reconnectTimer?.cancel();
    if (_reconnectAttempt >= maxReconnectAttempts) {
      _stopReconnecting();
      _left(notice: 'Lost the connection to the watch-together group');
      return;
    }
    final delay = Duration(seconds: (2 << _reconnectAttempt).clamp(2, 30));
    _reconnectAttempt++;
    _reconnectTimer = Timer(_reconnectAttempt == 1 ? Duration.zero : delay, () async {
      try {
        await _listen();
        await _syncClock();
        await _api.join(group.id);
        // The server answers on the socket (GroupJoined): see _onEvent.
      } on Object catch (e) {
        debugPrint('SyncPlay reconnect: $e');
        if (_rejoining != null) _reconnect(group);
      }
    });
  }

  /// The app is back in front (after the screen was locked): reconnect now
  /// rather than at the next attempt.
  void resumed() {
    final group = _rejoining;
    if (group != null && _events == null) {
      _reconnectAttempt = 0;
      _reconnect(group);
    }
  }

  void _stopReconnecting() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _rejoining = null;
    _reconnectAttempt = 0;
  }

  Future<void> _syncClock() async {
    try {
      final (offset, roundTrip) = await _api.measureClock();
      clock.offset = offset;
      if (state.inGroup) unawaited(_api.ping(roundTrip).catchError((Object _) {}));
    } on Object catch (e) {
      debugPrint('SyncPlay clock: $e');
    }
    // Clocks drift: measure again now and then while in a group.
    _clockTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (state.inGroup) _syncClock();
    });
  }

  void _left({String? notice}) {
    groupState.value = null;
    _lastGroup = null;
    _clockTimer?.cancel();
    _clockTimer = null;
    state = const SyncPlayState();
    if (notice != null) _notices.add(notice);
  }

  @visibleForTesting
  void handleEvent(SyncPlayEvent e) => _onEvent(e);

  void _onEvent(SyncPlayEvent e) {
    switch (e) {
      case SyncPlayCommandEvent(:final command):
        // The group's own commands are its state too: the server doesn't
        // always announce leaving Waiting, and a group left "waiting" held
        // play for good.
        _lastGroup = (position: command.position, when: command.when, playing: command.command == 'Unpause');
        if (command.command == 'Unpause') {
          groupPlaying = true;
          groupState.value = 'Playing';
        }
        if (command.command == 'Pause' || command.command == 'Stop') {
          groupPlaying = false;
          if (groupState.value != 'Waiting') groupState.value = 'Paused';
        }
        if (state.inGroup) _commands.add(command);
      case SyncPlayGroupEvent(type: 'GroupJoined', :final data):
        final group = data is Map ? SyncPlayGroup.fromJson(data.cast<String, dynamic>()) : null;
        // Joining a group that plays (or is just waiting for us to catch up).
        groupPlaying = group?.state == 'Playing' || group?.state == 'Waiting';
        groupState.value = group?.state;
        if (group?.state == 'Waiting') waitingSince = DateTime.now();
        final back = _rejoining != null && group?.id == _rejoining!.id;
        _stopReconnecting();
        state = state.copyWith(group: () => group, participants: group?.participants ?? const [], busy: false);
        if (group != null) steppedOut = null;
        if (back) {
          _notices.add('Back in ${group!.name}');
        } else if (group != null) {
          _notices.add('Joined ${group.name}');
        }
        if (group != null) _rejoined.add(null);
      case SyncPlayGroupEvent(type: 'UserJoined', :final data):
        final name = '$data';
        state = state.copyWith(participants: {...state.participants, name}.toList());
        _notices.add('$name joined');
      case SyncPlayGroupEvent(type: 'UserLeft', :final data):
        final name = '$data';
        state = state.copyWith(participants: [for (final p in state.participants) if (p != name) p]);
        _notices.add('$name left');
      case SyncPlayGroupEvent(type: 'PlayQueue', :final data) when data is Map:
        final queue = SyncPlayQueue.fromJson(data.cast<String, dynamic>());
        state = state.copyWith(queue: () => queue);
        _queues.add(queue);
      case SyncPlayGroupEvent(type: 'StateUpdate', :final data) when data is Map:
        if (data['State'] case final String s) {
          if (s == 'Waiting' && groupState.value != 'Waiting') waitingSince = DateTime.now();
          groupState.value = s;
        }
        if (data['State'] case 'Playing') groupPlaying = true;
        if (data['State'] case 'Paused' || 'Idle') groupPlaying = false;
      case SyncPlayGroupEvent(type: 'GroupLeft' || 'NotInGroup'):
        _left();
      case SyncPlayGroupEvent(type: 'GroupDoesNotExist'):
        if (_rejoining != null) {
          // It ended while this device was away.
          _stopReconnecting();
          _left(notice: 'The watch-together group has ended');
        } else {
          state = state.copyWith(busy: false, error: () => 'That group no longer exists');
        }
      case SyncPlayGroupEvent(type: 'LibraryAccessDenied'):
        state = state.copyWith(busy: false, error: () => "You don't have access to what the group is watching");
      case SyncPlayGroupEvent():
        break;
    }
  }

  /// A message for the user (the app shell shows it).
  void notice(String message) => _notices.add(message);

  // --- the player's side, while in a group ---

  /// Starts [itemId] for everyone (from [start]).
  Future<void> play(String itemId, {Duration start = Duration.zero}) => _api.setQueue([itemId], start: start);

  Future<void> requestPause() => _api.pause();
  Future<void> requestUnpause() => _api.unpause();
  Future<void> requestSeek(Duration position) => _api.seek(position);

  /// This device has [playlistItemId] loaded at [position] and can play.
  Future<void> ready(String playlistItemId, Duration position, {bool playing = false}) =>
      _api.ready(when: clock.now(), position: position, playing: playing, playlistItemId: playlistItemId);

  Future<void> buffering(String playlistItemId, Duration position, {bool playing = false}) =>
      _api.buffering(when: clock.now(), position: position, playing: playing, playlistItemId: playlistItemId);
}
