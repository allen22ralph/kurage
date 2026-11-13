import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'jellyfin_api.dart';

/// A SyncPlay (watch together) group on the server.
class SyncPlayGroup {
  const SyncPlayGroup({required this.id, required this.name, this.participants = const [], this.state});

  factory SyncPlayGroup.fromJson(Map<String, dynamic> j) => SyncPlayGroup(
        id: j['GroupId'] as String,
        name: (j['GroupName'] as String?) ?? 'Group',
        participants: [for (final p in (j['Participants'] as List?) ?? const []) p as String],
        state: j['State'] as String?,
      );

  final String id;
  final String name;
  final List<String> participants;

  /// Idle / Waiting / Paused / Playing.
  final String? state;
}

/// An item id as the rest of the app writes it: SyncPlay sends ids with
/// dashes ("11d6a6bb-2526-…"), the rest of the API without, so the same
/// episode didn't match the one playing.
String normalizeItemId(String id) => id.replaceAll('-', '').toLowerCase();

/// Something the group does, at the server time [when].
class SyncPlayCommand {
  const SyncPlayCommand({required this.command, required this.when, required this.position, this.playlistItemId});

  factory SyncPlayCommand.fromJson(Map<String, dynamic> j) => SyncPlayCommand(
        command: j['Command'] as String,
        when: DateTime.parse(j['When'] as String).toUtc(),
        position: Duration(microseconds: ((j['PositionTicks'] as num?) ?? 0).toInt() ~/ 10),
        playlistItemId: j['PlaylistItemId'] as String?,
      );

  /// Unpause / Pause / Seek / Stop.
  final String command;
  final DateTime when;
  final Duration position;
  final String? playlistItemId;
}

/// The group's queue: what's playing, and from where.
class SyncPlayQueue {
  const SyncPlayQueue({required this.items, required this.index, required this.start, this.reason});

  factory SyncPlayQueue.fromJson(Map<String, dynamic> j) => SyncPlayQueue(
        items: [
          for (final i in (j['Playlist'] as List?) ?? const [])
            (itemId: normalizeItemId((i as Map)['ItemId'] as String), playlistItemId: i['PlaylistItemId'] as String),
        ],
        index: (j['PlayingItemIndex'] as num?)?.toInt() ?? 0,
        start: Duration(microseconds: ((j['StartPositionTicks'] as num?) ?? 0).toInt() ~/ 10),
        reason: j['Reason'] as String?,
      );

  final List<({String itemId, String playlistItemId})> items;
  final int index;
  final Duration start;

  /// NewPlaylist / SetCurrentItem / NextItem / … (why it changed).
  final String? reason;

  ({String itemId, String playlistItemId})? get current => index >= 0 && index < items.length ? items[index] : null;
}

/// An event from the server's session socket that SyncPlay cares about.
sealed class SyncPlayEvent {
  const SyncPlayEvent();
}

class SyncPlayCommandEvent extends SyncPlayEvent {
  const SyncPlayCommandEvent(this.command);

  final SyncPlayCommand command;
}

/// GroupJoined / GroupLeft / UserJoined / UserLeft / PlayQueue /
/// StateUpdate / NotInGroup / GroupDoesNotExist / LibraryAccessDenied.
class SyncPlayGroupEvent extends SyncPlayEvent {
  const SyncPlayGroupEvent(this.type, this.groupId, this.data);

  final String type;
  final String? groupId;
  final Object? data;
}

/// Server time = local time + [offset] (NTP-style estimate from
/// /GetUtcTime), so commands meant for the same instant happen together.
class ServerClock {
  ServerClock([this.offset = Duration.zero]);

  Duration offset;

  DateTime now() => DateTime.now().toUtc().add(offset);

  /// How long until server time [when] (negative: it's past).
  Duration until(DateTime when) => when.difference(now());

  /// One measurement: [sent] / [received] local, [reception] / [transmission]
  /// on the server. Returns (offset, round trip).
  static (Duration, Duration) measure(DateTime sent, DateTime reception, DateTime transmission, DateTime received) {
    final offset = (reception.difference(sent) + transmission.difference(received)) ~/ 2;
    final roundTrip = received.difference(sent) - transmission.difference(reception);
    return (offset, roundTrip);
  }
}

/// The SyncPlay REST calls.
class SyncPlayApi {
  SyncPlayApi(this._api);

  final JellyfinApi _api;

  Future<List<SyncPlayGroup>> groups() async {
    final data = await _api.getList('/SyncPlay/List');
    return [for (final g in data) SyncPlayGroup.fromJson((g as Map).cast<String, dynamic>())];
  }

  Future<void> create(String name) => _api.postJson('/SyncPlay/New', body: {'GroupName': name});
  Future<void> join(String groupId) => _api.postJson('/SyncPlay/Join', body: {'GroupId': groupId});
  Future<void> leave() => _api.postJson('/SyncPlay/Leave');

  Future<void> pause() => _api.postJson('/SyncPlay/Pause');
  Future<void> unpause() => _api.postJson('/SyncPlay/Unpause');
  Future<void> seek(Duration position) => _api.postJson('/SyncPlay/Seek', body: {'PositionTicks': position.inMicroseconds * 10});

  /// Starts [itemIds] for the whole group.
  Future<void> setQueue(List<String> itemIds, {int index = 0, Duration start = Duration.zero}) => _api.postJson(
        '/SyncPlay/SetNewQueue',
        body: {'PlayingQueue': itemIds, 'PlayingItemPosition': index, 'StartPositionTicks': start.inMicroseconds * 10},
      );

  /// This device has loaded / sought and can play.
  Future<void> ready({required DateTime when, required Duration position, required bool playing, required String playlistItemId}) =>
      _api.postJson('/SyncPlay/Ready', body: {
        'When': when.toUtc().toIso8601String(),
        'PositionTicks': position.inMicroseconds * 10,
        'IsPlaying': playing,
        'PlaylistItemId': playlistItemId,
      });

  Future<void> buffering({required DateTime when, required Duration position, required bool playing, required String playlistItemId}) =>
      _api.postJson('/SyncPlay/Buffering', body: {
        'When': when.toUtc().toIso8601String(),
        'PositionTicks': position.inMicroseconds * 10,
        'IsPlaying': playing,
        'PlaylistItemId': playlistItemId,
      });

  Future<void> ping(Duration roundTrip) => _api.postJson('/SyncPlay/Ping', body: {'Ping': roundTrip.inMilliseconds});

  /// The server's clock offset, best of a few measurements (least delay).
  Future<(Duration offset, Duration roundTrip)> measureClock({int samples = 4}) async {
    (Duration, Duration)? best;
    for (var i = 0; i < samples; i++) {
      final sent = DateTime.now().toUtc();
      final data = await _api.getJson('/GetUtcTime');
      final received = DateTime.now().toUtc();
      final m = ServerClock.measure(
        sent,
        DateTime.parse(data['RequestReceptionTime'] as String).toUtc(),
        DateTime.parse(data['ResponseTransmissionTime'] as String).toUtc(),
        received,
      );
      if (best == null || m.$2 < best.$2) best = m;
    }
    return best!;
  }
}

/// The server's session socket (/socket): SyncPlay commands and group
/// updates arrive here. Keeps itself alive.
class SessionSocket {
  SessionSocket._(this._socket) {
    _socket.listen(_onMessage, onDone: _events.close, onError: (Object _) => _events.close());
    _keepAlive = Timer.periodic(const Duration(seconds: 30), (_) => _send('KeepAlive'));
  }

  static Future<SessionSocket> connect(Uri server, {required String token, required String deviceId}) async {
    final base = server.path.endsWith('/') ? server.path : '${server.path}/';
    final uri = server.replace(
      scheme: server.scheme == 'https' ? 'wss' : 'ws',
      path: '${base}socket',
      queryParameters: {'api_key': token, 'deviceId': deviceId},
    );
    return SessionSocket._(await WebSocket.connect(uri.toString()));
  }

  final WebSocket _socket;
  final _events = StreamController<SyncPlayEvent>.broadcast();
  late final Timer _keepAlive;

  Stream<SyncPlayEvent> get events => _events.stream;

  void _send(String type, [Object? data]) {
    if (_socket.readyState == WebSocket.open) {
      _socket.add(jsonEncode({'MessageType': type, 'Data': ?data}));
    }
  }

  void _onMessage(Object? raw) {
    if (raw is! String) return;
    final Map<String, dynamic> m;
    try {
      m = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } on Object {
      return;
    }
    final event = parseSocketMessage(m);
    if (event != null) _events.add(event);
    if (m['MessageType'] == 'ForceKeepAlive') _send('KeepAlive');
  }

  Future<void> close() async {
    _keepAlive.cancel();
    await _socket.close();
  }
}

/// A session socket message as a SyncPlay event, or null.
SyncPlayEvent? parseSocketMessage(Map<String, dynamic> m) {
  final data = m['Data'];
  switch (m['MessageType']) {
    case 'SyncPlayCommand' when data is Map:
      return SyncPlayCommandEvent(SyncPlayCommand.fromJson(data.cast<String, dynamic>()));
    case 'SyncPlayGroupUpdate' when data is Map:
      return SyncPlayGroupEvent(data['Type'] as String? ?? '', data['GroupId'] as String?, data['Data']);
  }
  return null;
}
