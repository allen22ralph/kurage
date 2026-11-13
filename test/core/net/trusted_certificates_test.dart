import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/net/trusted_certificates.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Generated for these tests with openssl (key discarded); fingerprint from
  // `openssl x509 -noout -fingerprint -sha256`.
  final pem = File('test/fixtures/test-root-ca.pem').readAsStringSync();
  const fingerprint = '24:F7:87:8D:55:14:A3:04:5D:5F:33:C3:09:E6:D0:1C:'
      '9C:49:DD:FD:CA:52:E7:9C:6C:03:48:F4:35:42:EB:DB';

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => HttpOverrides.global = null);

  test('reads name and fingerprint from a PEM certificate', () {
    final c = TrustedCertificate.fromPem('junk before\n$pem\njunk after');
    expect(c.name, 'Test Local Authority - ECC Root');
    expect(c.fingerprint, fingerprint);
    expect(c.pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
    expect(TrustedCertificate.fromPem(c.pem).fingerprint, fingerprint);
  });

  test('rejects things that are not certificates', () {
    expect(() => TrustedCertificate.fromPem('<html>Not found</html>'),
        throwsFormatException);
    expect(
      () => TrustedCertificate.fromPem(
          '-----BEGIN CERTIFICATE-----\n%%%\n-----END CERTIFICATE-----'),
      throwsFormatException,
    );
  });

  test('trusting stores the CA and applies it to new connections', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(trustedCertificatesProvider.notifier);
    await container.read(trustedCertificatesProvider.future);

    await controller.add(TrustedCertificate.fromPem(pem));
    await controller.add(TrustedCertificate.fromPem(pem)); // no duplicates
    expect(HttpOverrides.current, isNotNull);
    final saved = await TrustedCertificateStore().load();
    expect(saved.map((c) => c.fingerprint), [fingerprint]);

    await controller.remove(saved.single);
    expect(await TrustedCertificateStore().load(), isEmpty);
    expect(HttpOverrides.current, isNull);
  });
}
