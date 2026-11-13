import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/client_info.dart';

void main() {
  const info = ClientInfo(
    clientName: 'Kurage',
    deviceName: 'Sam\'s "PC"',
    deviceId: 'abc-123',
    version: '0.1.0',
  );

  test('builds header without token', () {
    expect(
      info.authorizationHeader(),
      'MediaBrowser Client="Kurage", '
      'Device="Sam\'s%20%22PC%22", DeviceId="abc-123", Version="0.1.0"',
    );
  });

  test('appends token when present', () {
    expect(info.authorizationHeader(token: 'tok'), endsWith(', Token="tok"'));
    expect(info.authorizationHeader(token: ''), isNot(contains('Token')));
  });
}
