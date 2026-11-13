/// Identifies this app to the Jellyfin server.
///
/// Sent on every request in the `Authorization: MediaBrowser ...` header.
/// The server uses [deviceId] to track sessions, so it must stay stable
/// across launches for a given install.
class ClientInfo {
  const ClientInfo({
    required this.clientName,
    required this.deviceName,
    required this.deviceId,
    required this.version,
  });

  final String clientName;
  final String deviceName;
  final String deviceId;
  final String version;

  /// Builds the `Authorization` header value, optionally with an access token.
  ///
  /// Values are URI-encoded because device names can contain quotes,
  /// commas, or non-ASCII characters that would break the header format.
  String authorizationHeader({String? token}) {
    final fields = <String, String>{
      'Client': clientName,
      'Device': deviceName,
      'DeviceId': deviceId,
      'Version': version,
      if (token != null && token.isNotEmpty) 'Token': token,
    };
    final parts = fields.entries
        .map((e) => '${e.key}="${Uri.encodeComponent(e.value)}"')
        .join(', ');
    return 'MediaBrowser $parts';
  }
}
