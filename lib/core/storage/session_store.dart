import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A signed-in user on a specific server.
class StoredSession {
  const StoredSession({
    required this.serverId,
    required this.serverName,
    required this.baseUrl,
    required this.userId,
    required this.userName,
    required this.accessToken,
    List<Uri>? addresses,
  // ignore: prefer_initializing_formals (a private field can't be a named parameter)
  }) : _addresses = addresses;

  factory StoredSession.fromJson(Map<String, dynamic> json) {
    return StoredSession(
      serverId: json['serverId'] as String,
      serverName: json['serverName'] as String,
      baseUrl: Uri.parse(json['baseUrl'] as String),
      userId: json['userId'] as String,
      userName: json['userName'] as String,
      accessToken: json['accessToken'] as String,
      addresses: _readAddresses(json['addresses']),
    );
  }

  final String serverId;
  final String serverName;

  /// The address in use now: one of [addresses].
  final Uri baseUrl;

  /// Every address this server is reached at (at home, over Tailscale, …),
  /// [baseUrl] among them; the app uses whichever answers.
  List<Uri> get addresses {
    final all = _addresses ?? const [];
    return all.contains(baseUrl) ? all : [baseUrl, ...all];
  }

  final List<Uri>? _addresses;
  final String userId;
  final String userName;
  final String accessToken;

  /// Unique per server + user, so multiple users/servers can coexist.
  String get key => '$serverId:$userId';

  StoredSession copyWith({Uri? baseUrl, List<Uri>? addresses, String? serverName}) => StoredSession(
        serverId: serverId,
        serverName: serverName ?? this.serverName,
        baseUrl: baseUrl ?? this.baseUrl,
        userId: userId,
        userName: userName,
        accessToken: accessToken,
        addresses: addresses ?? _addresses,
      );

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'serverName': serverName,
        'baseUrl': baseUrl.toString(),
        'userId': userId,
        'userName': userName,
        'accessToken': accessToken,
        'addresses': [for (final a in addresses) a.toString()],
      };
}

List<Uri>? _readAddresses(Object? raw) => raw is List
    ? [for (final a in raw) if (a is String) ?Uri.tryParse(a)]
    : null;

/// A server signed in to before. Kept after its accounts sign out, so
/// signing back in doesn't mean typing the address again.
class KnownServer {
  const KnownServer({required this.id, required this.name, required this.baseUrl, List<Uri>? addresses})
      // ignore: prefer_initializing_formals (a private field can't be a named parameter)
      : _addresses = addresses;

  factory KnownServer.fromJson(Map<String, dynamic> json) {
    return KnownServer(
      id: json['id'] as String,
      name: json['name'] as String,
      baseUrl: Uri.parse(json['baseUrl'] as String),
      addresses: _readAddresses(json['addresses']),
    );
  }

  final String id;
  final String name;

  /// The address last used.
  final Uri baseUrl;
  final List<Uri>? _addresses;

  /// Every address saved for this server, [baseUrl] among them.
  List<Uri> get addresses {
    final all = _addresses ?? const [];
    return all.contains(baseUrl) ? all : [baseUrl, ...all];
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl.toString(),
        'addresses': [for (final a in addresses) a.toString()],
      };
}

/// Persists sessions (including access tokens) in the OS secure store:
/// Windows Credential Manager / Android Keystore.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _sessionsKey = 'sessions';
  static const _activeKey = 'active_session';
  static const _serversKey = 'servers';

  final FlutterSecureStorage _storage;

  Future<List<StoredSession>> loadAll() async {
    final raw = await _storage.read(key: _sessionsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => StoredSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StoredSession?> loadActive() async {
    final activeKey = await _storage.read(key: _activeKey);
    if (activeKey == null) return null;
    final sessions = await loadAll();
    for (final session in sessions) {
      if (session.key == activeKey) return session;
    }
    return null;
  }

  /// Adds or replaces [session] and makes it the active one. Its server's
  /// addresses are shared by every account on that server: one reached at a
  /// new address (signed in over Tailscale, say) adds it for all of them.
  /// Returns [session] with all of them.
  Future<StoredSession> save(StoredSession session) async {
    final sessions = await loadAll();
    final servers = await loadServers();
    var addresses = session.addresses;
    for (final other in [
      for (final s in sessions) if (s.serverId == session.serverId) s.addresses,
      for (final k in servers) if (k.id == session.serverId) k.addresses,
    ]) {
      for (final a in other) {
        if (!addresses.contains(a)) addresses = [...addresses, a];
      }
    }
    final saved = session.copyWith(addresses: addresses);
    sessions
      ..removeWhere((s) => s.key == saved.key)
      ..add(saved);
    await _write([
      for (final s in sessions) s.serverId == saved.serverId ? s.copyWith(addresses: addresses) : s,
    ]);
    await _storage.write(key: _activeKey, value: saved.key);
    await _rememberServer(KnownServer(
      id: saved.serverId,
      name: saved.serverName,
      baseUrl: saved.baseUrl,
      addresses: addresses,
    ));
    return saved;
  }

  /// Sets server [serverId]'s addresses (for every account on it), and which
  /// one is in use when [inUse] is given.
  Future<void> setAddresses(String serverId, List<Uri> addresses, {Uri? inUse}) async {
    final sessions = await loadAll();
    await _write([
      for (final s in sessions)
        s.serverId == serverId
            ? s.copyWith(
                addresses: addresses,
                baseUrl: inUse ?? (addresses.contains(s.baseUrl) ? s.baseUrl : addresses.first),
              )
            : s,
    ]);
    final servers = await loadServers();
    await _writeServers([
      for (final k in servers)
        k.id == serverId
            ? KnownServer(
                id: k.id,
                name: k.name,
                baseUrl: inUse ?? (addresses.contains(k.baseUrl) ? k.baseUrl : addresses.first),
                addresses: addresses,
              )
            : k,
    ]);
  }

  /// Servers signed in to before, most recently used first.
  Future<List<KnownServer>> loadServers() async {
    final raw = await _storage.read(key: _serversKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => KnownServer.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> forgetServer(String id) async {
    final servers = await loadServers()..removeWhere((s) => s.id == id);
    await _writeServers(servers);
  }

  Future<void> _rememberServer(KnownServer server) async {
    final servers = await loadServers()
      ..removeWhere((s) => s.id == server.id)
      ..insert(0, server);
    await _writeServers(servers);
  }

  Future<void> _writeServers(List<KnownServer> servers) {
    return _storage.write(
      key: _serversKey,
      value: jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> remove(String key) async {
    final sessions = await loadAll()..removeWhere((s) => s.key == key);
    await _write(sessions);
    if (await _storage.read(key: _activeKey) == key) {
      await _storage.delete(key: _activeKey);
    }
  }

  Future<void> _write(List<StoredSession> sessions) {
    return _storage.write(
      key: _sessionsKey,
      value: jsonEncode(sessions.map((s) => s.toJson()).toList()),
    );
  }
}
