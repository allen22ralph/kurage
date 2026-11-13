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
  });

  factory StoredSession.fromJson(Map<String, dynamic> json) {
    return StoredSession(
      serverId: json['serverId'] as String,
      serverName: json['serverName'] as String,
      baseUrl: Uri.parse(json['baseUrl'] as String),
      userId: json['userId'] as String,
      userName: json['userName'] as String,
      accessToken: json['accessToken'] as String,
    );
  }

  final String serverId;
  final String serverName;
  final Uri baseUrl;
  final String userId;
  final String userName;
  final String accessToken;

  /// Unique per server + user, so multiple users/servers can coexist.
  String get key => '$serverId:$userId';

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'serverName': serverName,
        'baseUrl': baseUrl.toString(),
        'userId': userId,
        'userName': userName,
        'accessToken': accessToken,
      };
}

/// A server signed in to before. Kept after its accounts sign out, so
/// signing back in doesn't mean typing the address again.
class KnownServer {
  const KnownServer({required this.id, required this.name, required this.baseUrl});

  factory KnownServer.fromJson(Map<String, dynamic> json) {
    return KnownServer(
      id: json['id'] as String,
      name: json['name'] as String,
      baseUrl: Uri.parse(json['baseUrl'] as String),
    );
  }

  final String id;
  final String name;
  final Uri baseUrl;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'baseUrl': baseUrl.toString()};
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

  /// Adds or replaces [session] and makes it the active one.
  Future<void> save(StoredSession session) async {
    final sessions = await loadAll()
      ..removeWhere((s) => s.key == session.key)
      ..add(session);
    await _write(sessions);
    await _storage.write(key: _activeKey, value: session.key);
    await _rememberServer(KnownServer(
      id: session.serverId,
      name: session.serverName,
      baseUrl: session.baseUrl,
    ));
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
