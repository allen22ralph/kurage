/// Base URLs to try, in order, for an address typed by the user.
///
/// With an explicit scheme only that URL is tried. Without one, HTTPS is
/// tried first: servers behind a reverse proxy often redirect HTTP to HTTPS,
/// and redirects are not followed for POST requests such as login.
List<Uri> serverAddressCandidates(String input) {
  final text = input.trim();
  if (text.contains('://')) {
    return [normalizeServerAddress(text)];
  }
  return [
    normalizeServerAddress('https://$text'),
    normalizeServerAddress('http://$text'),
  ];
}

/// Normalizes a server address typed by the user into a base URL.
///
/// Accepts things like `192.168.1.10:8096`, `jellyfin.example.com/`,
/// or a copied web URL such as `https://host/web/#/home.html`.
/// Throws [FormatException] if the input can't be turned into a URL.
Uri normalizeServerAddress(String input) {
  var text = input.trim();
  if (text.isEmpty) {
    throw const FormatException('Server address is empty');
  }
  if (!text.contains('://')) {
    text = 'http://$text';
  }

  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) {
    throw FormatException('Invalid server address', input);
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw FormatException('Server address must use http or https', input);
  }

  // Drop the web UI path and anything after it, keeping any reverse-proxy
  // base path (e.g. https://host/jellyfin).
  final segments = <String>[];
  for (final segment in uri.pathSegments) {
    if (segment.isEmpty) continue;
    if (segment.toLowerCase() == 'web') break;
    segments.add(segment);
  }

  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: segments,
  );
}
