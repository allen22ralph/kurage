import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A certificate authority the user chose to trust, e.g. Caddy's local CA.
///
/// Android only trusts public CAs for the app's own connections, so a
/// self-hosted server signed by a private CA needs its root added here.
/// Trusting the root (not the server's certificate) keeps working when the
/// server certificate renews, which Caddy's local CA does every 12 hours.
class TrustedCertificate {
  const TrustedCertificate({required this.pem, required this.name, required this.fingerprint});

  /// Parses one PEM certificate. Throws [FormatException] if it isn't one.
  factory TrustedCertificate.fromPem(String pem) {
    final der = pemToDer(pem);
    return TrustedCertificate(
      pem: _normalise(pem),
      name: commonName(der) ?? 'Unnamed certificate',
      fingerprint: sha256Fingerprint(der),
    );
  }

  factory TrustedCertificate.fromJson(Map<String, dynamic> json) => TrustedCertificate(
        pem: json['pem'] as String,
        name: json['name'] as String,
        fingerprint: json['fingerprint'] as String,
      );

  final String pem;
  final String name;

  /// SHA-256 of the DER bytes, as "AB:CD:...", the format openssl and
  /// Windows' certificate viewer show.
  final String fingerprint;

  Map<String, dynamic> toJson() => {'pem': pem, 'name': name, 'fingerprint': fingerprint};

  static String _normalise(String pem) {
    final der = pemToDer(pem);
    final body = base64.encode(der).replaceAllMapped(RegExp('.{1,64}'), (m) => '${m[0]}\n');
    return '-----BEGIN CERTIFICATE-----\n$body-----END CERTIFICATE-----\n';
  }
}

final _pemBlock = RegExp(
  r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
);

/// DER bytes of the first certificate in [pem].
List<int> pemToDer(String pem) {
  final match = _pemBlock.firstMatch(pem);
  if (match == null) throw const FormatException('Not a PEM certificate');
  try {
    return base64.decode(match[1]!.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    throw const FormatException('Not a PEM certificate');
  }
}

String sha256Fingerprint(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

/// The subject's common name. A certificate lists the issuer's name before
/// the subject's, so the last CN (OID 2.5.4.3) is the subject's.
String? commonName(List<int> der) {
  const oid = [0x06, 0x03, 0x55, 0x04, 0x03];
  String? found;
  for (var i = 0; i + oid.length + 2 < der.length; i++) {
    var match = true;
    for (var j = 0; j < oid.length; j++) {
      if (der[i + j] != oid[j]) {
        match = false;
        break;
      }
    }
    if (!match) continue;
    final lengthAt = i + oid.length + 1; // after the string's tag byte
    final length = der[lengthAt];
    if (length >= 0x80 || lengthAt + 1 + length > der.length) continue;
    found = utf8.decode(der.sublist(lengthAt + 1, lengthAt + 1 + length), allowMalformed: true);
  }
  return found;
}

/// Downloads the certificate at [url] for the user to inspect. The download
/// itself can't be verified (that's the problem being solved), so the user
/// confirms the fingerprint before anything is trusted.
Future<String> fetchCertificatePem(Uri url) async {
  final client = HttpClient()
    ..badCertificateCallback = ((_, _, _) => true)
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final bytes = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    final text = utf8.decode(bytes, allowMalformed: true);
    // Accept DER too (some servers serve .crt as binary).
    return _pemBlock.hasMatch(text)
        ? text
        : '-----BEGIN CERTIFICATE-----\n${base64.encode(bytes)}\n-----END CERTIFICATE-----';
  } finally {
    client.close(force: true);
  }
}

/// Makes every dart:io HttpClient (Dio, image cache) trust [certificates]
/// as well as the system's public CAs.
void applyTrustedCertificates(List<TrustedCertificate> certificates) {
  HttpOverrides.global = certificates.isEmpty ? null : _TrustingOverrides(certificates);
}

class _TrustingOverrides extends HttpOverrides {
  _TrustingOverrides(List<TrustedCertificate> certificates) {
    for (final c in certificates) {
      _context.setTrustedCertificatesBytes(utf8.encode(c.pem));
    }
  }

  final _context = SecurityContext(withTrustedRoots: true);

  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(_context);
}

class TrustedCertificateStore {
  static const _key = 'net.trustedCertificates';

  Future<List<TrustedCertificate>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    try {
      return [
        for (final e in jsonDecode(raw) as List) TrustedCertificate.fromJson(e as Map<String, dynamic>),
      ];
    } on FormatException {
      return [];
    }
  }

  Future<void> save(List<TrustedCertificate> certificates) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final c in certificates) c.toJson()]));
  }
}

final trustedCertificateStoreProvider = Provider((_) => TrustedCertificateStore());

/// Certificates the user trusts. Changes apply to new connections at once.
final trustedCertificatesProvider =
    AsyncNotifierProvider<TrustedCertificatesController, List<TrustedCertificate>>(
  TrustedCertificatesController.new,
);

class TrustedCertificatesController extends AsyncNotifier<List<TrustedCertificate>> {
  TrustedCertificateStore get _store => ref.read(trustedCertificateStoreProvider);

  @override
  Future<List<TrustedCertificate>> build() => _store.load();

  // Both wait for the stored list, or the initial load would overwrite them.
  Future<void> add(TrustedCertificate certificate) async => _set([
        ...(await future).where((c) => c.fingerprint != certificate.fingerprint),
        certificate,
      ]);

  Future<void> remove(TrustedCertificate certificate) async =>
      _set([...(await future).where((c) => c.fingerprint != certificate.fingerprint)]);

  Future<void> _set(List<TrustedCertificate> list) async {
    state = AsyncData(list);
    applyTrustedCertificates(list);
    await _store.save(list);
  }
}

/// How the trust dialog downloads a certificate. Overridden in tests.
final certificateFetcherProvider =
    Provider<Future<String> Function(Uri url)>((_) => fetchCertificatePem);
