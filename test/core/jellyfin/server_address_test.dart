import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/server_address.dart';

void main() {
  group('normalizeServerAddress', () {
    test('adds http scheme to bare host:port', () {
      expect(
        normalizeServerAddress('192.168.1.10:8096').toString(),
        'http://192.168.1.10:8096',
      );
    });

    test('keeps https and strips trailing slash', () {
      expect(
        normalizeServerAddress(' https://jellyfin.example.com/ ').toString(),
        'https://jellyfin.example.com',
      );
    });

    test('strips copied web UI path', () {
      expect(
        normalizeServerAddress('https://host:8920/web/#/home.html').toString(),
        'https://host:8920',
      );
    });

    test('keeps reverse-proxy base path', () {
      expect(
        normalizeServerAddress('https://host/jellyfin/web/index.html')
            .toString(),
        'https://host/jellyfin',
      );
    });

    test('candidates try https then http when scheme is missing', () {
      expect(
        serverAddressCandidates('jellyfin.home.arpa').map((u) => '$u'),
        ['https://jellyfin.home.arpa', 'http://jellyfin.home.arpa'],
      );
      expect(
        serverAddressCandidates('http://host:8096').map((u) => '$u'),
        ['http://host:8096'],
      );
    });

    test('rejects empty and non-http input', () {
      expect(() => normalizeServerAddress('  '), throwsFormatException);
      expect(() => normalizeServerAddress('ftp://host'), throwsFormatException);
    });
  });
}
