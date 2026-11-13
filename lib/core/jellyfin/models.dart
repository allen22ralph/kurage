/// Response of `GET /System/Info/Public` (no auth required).
class PublicSystemInfo {
  const PublicSystemInfo({
    required this.id,
    required this.serverName,
    required this.version,
    this.localAddress,
  });

  factory PublicSystemInfo.fromJson(Map<String, dynamic> json) {
    return PublicSystemInfo(
      id: json['Id'] as String,
      serverName: json['ServerName'] as String? ?? 'Jellyfin',
      version: json['Version'] as String? ?? '',
      localAddress: json['LocalAddress'] as String?,
    );
  }

  final String id;
  final String serverName;
  final String version;
  final String? localAddress;
}

class JellyfinUser {
  const JellyfinUser({
    required this.id,
    required this.name,
    this.primaryImageTag,
    this.isAdministrator = false,
  });

  factory JellyfinUser.fromJson(Map<String, dynamic> json) {
    final policy = json['Policy'] as Map<String, dynamic>?;
    return JellyfinUser(
      id: json['Id'] as String,
      name: json['Name'] as String? ?? '',
      primaryImageTag: json['PrimaryImageTag'] as String?,
      isAdministrator: policy?['IsAdministrator'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final String? primaryImageTag;
  final bool isAdministrator;
}

/// Result of a successful login (password or Quick Connect).
class AuthResult {
  const AuthResult({
    required this.accessToken,
    required this.serverId,
    required this.user,
  });

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    return AuthResult(
      accessToken: json['AccessToken'] as String,
      serverId: json['ServerId'] as String,
      user: JellyfinUser.fromJson(json['User'] as Map<String, dynamic>),
    );
  }

  final String accessToken;
  final String serverId;
  final JellyfinUser user;
}

/// State of a Quick Connect request.
///
/// Show [code] to the user; they approve it from another signed-in client.
/// Poll with [secret] until [authenticated] is true.
class QuickConnectState {
  const QuickConnectState({
    required this.secret,
    required this.code,
    required this.authenticated,
  });

  factory QuickConnectState.fromJson(Map<String, dynamic> json) {
    return QuickConnectState(
      secret: json['Secret'] as String,
      code: json['Code'] as String,
      authenticated: json['Authenticated'] as bool? ?? false,
    );
  }

  final String secret;
  final String code;
  final bool authenticated;
}
