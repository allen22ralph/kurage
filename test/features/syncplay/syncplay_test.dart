import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/syncplay.dart';
import 'package:jellyfin_client/features/player/media_engine.dart';
import 'package:jellyfin_client/features/syncplay/syncplay_player.dart';
import 'package:jellyfin_client/features/syncplay/syncplay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

/// Just what the binding touches.
class _Engine implements MediaEngine {
  // Async, like media_kit's streams.
  final _playing = StreamController<bool>.broadcast();
  bool playing = true;
  Duration at = const Duration(minutes: 5);
  final seeks = <Duration>[];

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  bool get isPlaying => playing;
  @override
  Duration get position => at;
  @override
  Future<void> play() async => _playing.add(playing = true);
  @override
  Future<void> pause() async => _playing.add(playing = false);
  @override
  Future<void> seek(Duration p) async => seeks.add(at = p);
  final rates = <double>[];
  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  /// The user pressed play / pause on the controls.
  void userSets(bool value) => _playing.add(playing = value);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('server clock: offset and round trip from one measurement', () {
    final sent = DateTime.utc(2026, 1, 1, 12);
    // Server is 2 s ahead; 100 ms each way; 10 ms on the server.
    final (offset, roundTrip) = ServerClock.measure(
      sent,
      sent.add(const Duration(milliseconds: 2100)),
      sent.add(const Duration(milliseconds: 2110)),
      sent.add(const Duration(milliseconds: 210)),
    );
    expect((offset, roundTrip), (const Duration(seconds: 2), const Duration(milliseconds: 200)));
  });

  test('socket messages: commands and group updates', () {
    final c = parseSocketMessage({
      'MessageType': 'SyncPlayCommand',
      'Data': {'Command': 'Unpause', 'When': '2026-10-28T12:00:00.000Z', 'PositionTicks': 600000000, 'PlaylistItemId': 'p1'},
    });
    expect(c, isA<SyncPlayCommandEvent>());
    final cmd = (c! as SyncPlayCommandEvent).command;
    expect((cmd.command, cmd.position, cmd.playlistItemId), ('Unpause', const Duration(minutes: 1), 'p1'));
    final g = parseSocketMessage({
      'MessageType': 'SyncPlayGroupUpdate',
      'Data': {'GroupId': 'g1', 'Type': 'UserJoined', 'Data': 'ana'},
    }) as SyncPlayGroupEvent;
    expect((g.type, g.groupId, g.data), ('UserJoined', 'g1', 'ana'));
    expect(parseSocketMessage({'MessageType': 'KeepAlive'}), isNull);
  });

  test('"Pause the group when I leave": the saved choice, once loaded (the app loads it at start)', () async {
    SharedPreferences.setMockInitialValues({'syncplay.pauseOnLeave': false});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(syncPlayPauseOnLeaveProvider), isTrue, reason: 'the default until loaded');
    await Future<void>.delayed(Duration.zero);
    expect(c.read(syncPlayPauseOnLeaveProvider), isFalse);
  });

  group('in a group', () {
    late FakeServer server;
    late StreamController<SyncPlayEvent> socket;
    late ProviderContainer c;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues(signedInStorage());
      final now = DateTime.now().toUtc().toIso8601String();
      server = FakeServer({
        '/GetUtcTime': (200, {'RequestReceptionTime': now, 'ResponseTransmissionTime': now}),
        'POST /SyncPlay/New': (204, null),
        'POST /SyncPlay/Join': (204, null),
        'POST /SyncPlay/Ping': (204, null),
        'POST /SyncPlay/Pause': (204, null),
        'POST /SyncPlay/Unpause': (204, null),
        'POST /SyncPlay/Seek': (204, null),
        'POST /SyncPlay/Ready': (204, null),
        'POST /SyncPlay/Buffering': (204, null),
        'POST /SyncPlay/Leave': (204, null),
        'POST /SyncPlay/SetNewQueue': (204, null),
      });
      socket = StreamController<SyncPlayEvent>.broadcast();
      c = ProviderContainer(overrides: [
        ...fakeServerOverrides(server),
        syncPlaySocketProvider.overrideWithValue(() async => socket.stream),
      ]);
      addTearDown(c.dispose);
      await c.read(sessionControllerProvider.future);
    });

    Future<void> joinGroup() async {
      final sync = c.read(syncPlayProvider.notifier);
      await sync.create('Movie night');
      expect(server.requestsTo('/SyncPlay/New').single.data, {'GroupName': 'Movie night'});
      sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night', 'Participants': ['sam']}));
      sync.handleEvent(const SyncPlayGroupEvent('PlayQueue', 'g1', {
        'Playlist': [{'ItemId': 'ep1', 'PlaylistItemId': 'p1'}],
        'PlayingItemIndex': 0,
        'StartPositionTicks': 0,
      }));
    }

    test('joining: state, who joins, the queue', () async {
      final notices = <String>[];
      c.read(syncPlayProvider.notifier).notices.listen(notices.add);
      await joinGroup();
      c.read(syncPlayProvider.notifier).handleEvent(const SyncPlayGroupEvent('UserJoined', 'g1', 'ana'));
      await Future<void>.delayed(Duration.zero);
      final s = c.read(syncPlayProvider);
      expect((s.group?.name, s.queue?.current?.itemId), ('Movie night', 'ep1'));
      expect(s.participants, ['sam', 'ana']);
      expect(notices, ['Joined Movie night', 'ana joined']);
    });

    test("the player: the user's pause goes to the group; a late Unpause starts further in", () async {
      await joinGroup();
      final engine = _Engine();
      final player = ChangeNotifier();
      final binding = SyncPlayBinding(read: c.read, engine: engine, player: player, itemId: () => 'ep1', opened: () => true)..start();
      addTearDown(binding.dispose);

      // Opened: it holds still and tells the group it's ready.
      player.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.playing, isFalse);
      expect(server.requestsTo('/SyncPlay/Ready').single.data, containsPair('PlaylistItemId', 'p1'));

      // The user presses play: asked of the group, not played here yet.
      engine.userSets(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/Unpause'), hasLength(1));
      expect(engine.playing, isFalse);

      // The group's Unpause, sent 2 s ago: start 2 s further in, now.
      final sync = c.read(syncPlayProvider.notifier);
      sync.handleEvent(SyncPlayCommandEvent(SyncPlayCommand(
        command: 'Unpause',
        when: sync.clock.now().subtract(const Duration(seconds: 2)),
        position: const Duration(minutes: 1),
        playlistItemId: 'p1',
      )));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.playing, isTrue);
      expect(engine.seeks.last.inMilliseconds, closeTo(62000, 200));

      // A seek in the bar goes to the group.
      expect(binding.seek(const Duration(minutes: 10)), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/Seek').single.data, {'PositionTicks': const Duration(minutes: 10).inMicroseconds * 10});
    });

    test('a group Seek pauses, seeks, and reports ready there', () async {
      await joinGroup();
      final engine = _Engine();
      final binding = SyncPlayBinding(read: c.read, engine: engine, player: ChangeNotifier(), itemId: () => 'ep1', opened: () => true)..start();
      addTearDown(binding.dispose);
      final sync = c.read(syncPlayProvider.notifier);
      sync.handleEvent(SyncPlayCommandEvent(SyncPlayCommand(command: 'Seek', when: sync.clock.now(), position: const Duration(minutes: 20), playlistItemId: 'p1')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((engine.playing, engine.at), (false, const Duration(minutes: 20)));
      expect(server.requestsTo('/SyncPlay/Ready').last.data, containsPair('PositionTicks', const Duration(minutes: 20).inMicroseconds * 10));
    });
    /// A started binding, past "ready", playing from the group's Unpause.
    Future<(SyncPlayBinding, _Engine)> playing() async {
      await joinGroup();
      final engine = _Engine();
      final player = ChangeNotifier();
      final binding = SyncPlayBinding(read: c.read, engine: engine, player: player, itemId: () => 'ep1', opened: () => true)..start();
      addTearDown(binding.dispose);
      player.notifyListeners();
      final sync = c.read(syncPlayProvider.notifier);
      sync.handleEvent(SyncPlayCommandEvent(SyncPlayCommand(command: 'Unpause', when: sync.clock.now(), position: const Duration(minutes: 1), playlistItemId: 'p1')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.playing, isTrue);
      return (binding, engine);
    }

    /// [binding]'s clock moved on by [by], and the engine played that far.
    void later(SyncPlayBinding binding, _Engine engine, Duration by) {
      final t = binding.now().add(by);
      binding.now = () => t;
      engine.at += by;
    }

    test('drifting off the group: back in step after two checks; a little off is left alone', () async {
      final (binding, engine) = await playing();
      c.read(syncPlayProvider.notifier).handleEvent(const SyncPlayGroupEvent('UserJoined', 'g1', 'ana'));
      later(binding, engine, const Duration(seconds: 20)); // past the settle time
      engine.seeks.clear();
      // About where the group is: nothing to do.
      engine.at = binding.groupPosition! + const Duration(milliseconds: 300);
      await binding.checkDrift();
      expect(engine.seeks, isEmpty);
      // 5 s behind (a slow device): once could be a blip, twice is drift.
      engine.at = binding.groupPosition! - const Duration(seconds: 5);
      await binding.checkDrift();
      expect(engine.seeks, isEmpty, reason: 'one reading is not enough');
      engine.at += const Duration(milliseconds: 100);
      await binding.checkDrift();
      expect(engine.seeks, hasLength(1));
    });

    test('a small gap: a slight speed nudge, not a jump', () async {
      final (binding, engine) = await playing();
      c.read(syncPlayProvider.notifier).handleEvent(const SyncPlayGroupEvent('UserJoined', 'g1', 'ana'));
      later(binding, engine, const Duration(seconds: 20));
      engine.seeks.clear();
      engine.at = binding.groupPosition! - const Duration(milliseconds: 600); // behind
      await binding.checkDrift();
      expect(engine.seeks, isEmpty);
      expect(engine.rates.last, closeTo(1.05, 0.001), reason: 'faster to catch up');
    });

    test('paused on the same frame: even 100 ms off is moved', () async {
      final (_, engine) = await playing();
      final sync = c.read(syncPlayProvider.notifier);
      engine.at = const Duration(minutes: 3, milliseconds: 100);
      engine.seeks.clear();
      sync.handleEvent(SyncPlayCommandEvent(SyncPlayCommand(command: 'Pause', when: sync.clock.now(), position: const Duration(minutes: 3), playlistItemId: 'p1')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.seeks.single, const Duration(minutes: 3));
    });

    test('audio delay: this device plays that far ahead', () async {
      final (binding, engine) = await playing();
      c.read(syncPlayProvider.notifier).handleEvent(const SyncPlayGroupEvent('UserJoined', 'g1', 'ana'));
      await c.read(syncPlayAudioDelayProvider.notifier).set(1000);
      later(binding, engine, const Duration(seconds: 20));
      engine.seeks.clear();
      engine.rates.clear();
      // Exactly where the group is, so 1 s behind where it should be.
      engine.at = binding.groupPosition!;
      await binding.checkDrift();
      expect(engine.rates.last, closeTo(1.05, 0.001), reason: 'catching up to play 1 s ahead');
    });

    test("Sync now: as Jellyfin's player does, buffering then ready, so the server lines everyone up", () async {
      await playing();
      final readies = server.requestsTo('/SyncPlay/Ready').length;
      c.read(syncPlayProvider.notifier).syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/Buffering'), hasLength(1));
      expect(server.requestsTo('/SyncPlay/Ready').length, readies + 1);
    });

    test("a closing player: the group's commands no longer move it", () async {
      final (binding, engine) = await playing();
      binding.leftPlayer();
      engine.seeks.clear();
      final sync = c.read(syncPlayProvider.notifier);
      sync.handleEvent(SyncPlayCommandEvent(SyncPlayCommand(command: 'Seek', when: sync.clock.now(), position: const Duration(minutes: 3), playlistItemId: 'p1')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.seeks, isEmpty);
    });

    test('alone in the group, buffering, or just after a command: never corrected', () async {
      final (binding, engine) = await playing();
      engine.seeks.clear();
      // Alone.
      later(binding, engine, const Duration(seconds: 20));
      engine.at -= const Duration(seconds: 10);
      for (var i = 0; i < 3; i++) {
        engine.at += const Duration(milliseconds: 100);
        await binding.checkDrift();
      }
      expect(engine.seeks, isEmpty, reason: 'alone: nothing to be in step with');
      // With someone, but stalled (position not moving: buffering).
      c.read(syncPlayProvider.notifier).handleEvent(const SyncPlayGroupEvent('UserJoined', 'g1', 'ana'));
      for (var i = 0; i < 3; i++) {
        await binding.checkDrift();
      }
      expect(engine.seeks, isEmpty, reason: 'buffering');
    });

    test('corrections that keep coming stop, with a message', () async {
      final (binding, engine) = await playing();
      final notices = <String>[];
      final sync = c.read(syncPlayProvider.notifier)..notices.listen(notices.add);
      sync.handleEvent(const SyncPlayGroupEvent('UserJoined', 'g1', 'ana'));
      engine.seeks.clear();
      for (var i = 0; i < 10; i++) {
        later(binding, engine, const Duration(seconds: 16));
        engine.at = binding.groupPosition! - const Duration(seconds: 5);
        await binding.checkDrift();
        engine.at += const Duration(milliseconds: 100);
        await binding.checkDrift();
      }
      await Future<void>.delayed(Duration.zero);
      expect(engine.seeks.length, lessThanOrEqualTo(SyncPlayBinding.maxCorrections));
      expect(notices.where((n) => n.contains("couldn't keep this device in step")), hasLength(1));
    });

    test('closing the player pauses the group', () async {
      final (binding, _) = await playing();
      binding.leftPlayer();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/Pause'), hasLength(1));
    });

    test('a dropped connection (screen locked): back in the group, and ready again', () async {
      final (binding, _) = await playing();
      final notices = <String>[];
      final sync = c.read(syncPlayProvider.notifier)..notices.listen(notices.add);
      final readies = server.requestsTo('/SyncPlay/Ready').length;
      // The socket closes: still in the group while it reconnects.
      await socket.close();
      socket = StreamController<SyncPlayEvent>.broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(syncPlayProvider).inGroup, isTrue);
      expect(server.requestsTo('/SyncPlay/Join').single.data, {'GroupId': 'g1'});
      sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night', 'Participants': ['sam']}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notices, contains('Back in Movie night'));
      expect(server.requestsTo('/SyncPlay/Ready').length, readies + 1, reason: 'the player joins in again');
      expect(binding.active, isTrue);
    });

    test('the group ended while away: out of it, with a message', () async {
      await playing();
      final notices = <String>[];
      final sync = c.read(syncPlayProvider.notifier)..notices.listen(notices.add);
      await socket.close();
      socket = StreamController<SyncPlayEvent>.broadcast();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      sync.handleEvent(const SyncPlayGroupEvent('GroupDoesNotExist', 'g1', null));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(syncPlayProvider).inGroup, isFalse);
      expect(notices, contains('The watch-together group has ended'));
    });

    test('closing the player never throws, even if the app state can no longer be read', () async {
      var gone = false;
      T read<T>(ProviderListenable<T> p) => gone ? throw StateError('unmounted') : c.read(p);
      final binding = SyncPlayBinding(read: read, engine: _Engine(), player: ChangeNotifier(), itemId: () => 'ep1', opened: () => true)
        ..start();
      gone = true;
      expect(binding.leftPlayer, returnsNormally);
      binding.dispose();
    });

    test('a video opened at its resume point starts the group there, not at 0:00', () async {
      final sync = c.read(syncPlayProvider.notifier);
      await sync.create('Movie night');
      sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night'}));
      final engine = _Engine()..at = Duration.zero; // not there yet
      final player = ChangeNotifier();
      final binding = SyncPlayBinding(
        read: c.read,
        engine: engine,
        player: player,
        itemId: () => 'ep1',
        opened: () => true,
        position: () => const Duration(minutes: 10, seconds: 27),
      )..start();
      addTearDown(binding.dispose);
      player.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final start = server.requestsTo('/SyncPlay/SetNewQueue').last.data as Map;
      expect(start['StartPositionTicks'], const Duration(minutes: 10, seconds: 27).inMicroseconds * 10);
    });

    test('joining a group while a video is open shares it with the group', () async {
      final engine = _Engine();
      final binding = SyncPlayBinding(read: c.read, engine: engine, player: ChangeNotifier(), itemId: () => 'ep1', opened: () => true)
        ..start();
      addTearDown(binding.dispose);
      expect(server.requestsTo('/SyncPlay/SetNewQueue'), isEmpty, reason: 'not in a group yet');
      final sync = c.read(syncPlayProvider.notifier);
      await sync.create('Movie night');
      sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/SetNewQueue'), hasLength(1));
    });

    test('joining a playing group: ready, playing (it carries on); a paused one: ready, paused', () async {
      final sync = c.read(syncPlayProvider.notifier);
      await sync.create('Movie night');
      sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night', 'State': 'Playing'}));
      sync.handleEvent(const SyncPlayGroupEvent('PlayQueue', 'g1', {
        'Playlist': [
          {'ItemId': 'ep1', 'PlaylistItemId': 'p1'},
        ],
        'PlayingItemIndex': 0,
      }));
      final binding = SyncPlayBinding(read: c.read, engine: _Engine(), player: ChangeNotifier(), itemId: () => 'ep1', opened: () => true)
        ..start();
      addTearDown(binding.dispose);
      sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night', 'State': 'Playing'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((server.requestsTo('/SyncPlay/Ready').last.data as Map)['IsPlaying'], isTrue);

      sync.handleEvent(const SyncPlayGroupEvent('StateUpdate', 'g1', {'State': 'Paused'}));
      expect(sync.groupPlaying, isFalse);
    });

    test('"pause the group when I leave" off: leaving steps out of the group (the others carry on), and can rejoin', () async {
      final (binding, _) = await playing();
      await c.read(syncPlayPauseOnLeaveProvider.notifier).set(false);
      binding.leftPlayer();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/Pause'), isEmpty, reason: "the others aren't paused");
      expect(server.requestsTo('/SyncPlay/Leave'), hasLength(1));
      final sync = c.read(syncPlayProvider.notifier);
      expect(sync.steppedOut?.name, 'Movie night');
      await sync.rejoin();
      expect(server.requestsTo('/SyncPlay/Join').single.data, {'GroupId': 'g1'});
    });

    test('the group getting everyone ready: play stays paused (no bounce), and ready is said again', () async {
      final (binding, engine) = await playing();
      final sync = c.read(syncPlayProvider.notifier);
      sync.handleEvent(const SyncPlayGroupEvent('StateUpdate', 'g1', {'State': 'Waiting'}));
      expect(sync.groupState.value, 'Waiting');
      final unpauses = server.requestsTo('/SyncPlay/Unpause').length;
      binding.now = () => DateTime.now().add(const Duration(seconds: 10)); // past our own changes
      engine.userSets(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.playing, isFalse, reason: 'held until the group starts');
      expect(server.requestsTo('/SyncPlay/Unpause').length, unpauses, reason: 'no request that would bounce');
      sync.handleEvent(const SyncPlayGroupEvent('StateUpdate', 'g1', {'State': 'Playing'}));
      expect(sync.groupState.value, 'Playing');
    });

    test("the group's play command ends waiting, announced or not (no group stuck waiting)", () async {
      await playing();
      final sync = c.read(syncPlayProvider.notifier);
      sync.handleEvent(const SyncPlayGroupEvent('StateUpdate', 'g1', {'State': 'Waiting'}));
      sync.handleEvent(SyncPlayCommandEvent(SyncPlayCommand(command: 'Unpause', when: sync.clock.now(), position: const Duration(minutes: 2), playlistItemId: 'p1')));
      expect(sync.groupState.value, 'Playing');
    });

    test('the device that starts the episode for the group says ready for it too (or the group waits)', () async {
      final sync = c.read(syncPlayProvider.notifier);
      await sync.create('Movie night');
      sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night'}));
      final player = ChangeNotifier();
      final binding = SyncPlayBinding(read: c.read, engine: _Engine(), player: player, itemId: () => 'ep1', opened: () => true)
        ..start();
      addTearDown(binding.dispose);
      player.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/SetNewQueue'), hasLength(1), reason: 'starts it for the group');
      expect(server.requestsTo('/SyncPlay/Ready'), isEmpty);
      // The server's new queue, with this episode:
      sync.handleEvent(const SyncPlayGroupEvent('PlayQueue', 'g1', {
        'Playlist': [
          {'ItemId': 'ep1', 'PlaylistItemId': 'p9'},
        ],
        'PlayingItemIndex': 0,
      }));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((server.requestsTo('/SyncPlay/Ready').single.data as Map)['PlaylistItemId'], 'p9');
    });

    test('joining a group that plays at 1:11: to 1:11 first, then ready there (not from 0:00)', () async {
      await joinGroup();
      final sync = c.read(syncPlayProvider.notifier);
      // The group plays on from 1:11 (the device saw this while on Home).
      sync.handleEvent(SyncPlayCommandEvent(SyncPlayCommand(
        command: 'Unpause',
        when: sync.clock.now(),
        position: const Duration(minutes: 1, seconds: 11),
        playlistItemId: 'p1',
      )));
      final engine = _Engine()..at = Duration.zero;
      final player = ChangeNotifier();
      final binding = SyncPlayBinding(read: c.read, engine: engine, player: player, itemId: () => 'ep1', opened: () => true)
        ..start();
      addTearDown(binding.dispose);
      player.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.seeks.first.inSeconds, inInclusiveRange(71, 72));
      final ready = server.requestsTo('/SyncPlay/Ready').last.data as Map;
      expect(Duration(microseconds: (ready['PositionTicks'] as int) ~/ 10).inSeconds, inInclusiveRange(71, 72));
    });

    test('leaving with "pause the group" off: going quiet never pauses the others', () async {
      final (binding, engine) = await playing();
      await c.read(syncPlayPauseOnLeaveProvider.notifier).set(false);
      binding.now = () => DateTime.now().add(const Duration(seconds: 10)); // past our own changes
      binding.leftPlayer();
      engine.userSets(false); // the closing player going quiet, before the server confirms
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requestsTo('/SyncPlay/Pause'), isEmpty);
    });
  });
}
