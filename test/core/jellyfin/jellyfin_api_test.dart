import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/client_info.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';

import '../../support/fake_server.dart';

void main() {
  const clientInfo = ClientInfo(
    clientName: 'Test',
    deviceName: 'Device',
    deviceId: 'id',
    version: '1',
  );

  JellyfinApi buildApi(FakeServer adapter) {
    final dio = Dio()..httpClientAdapter = adapter;
    return JellyfinApi(
      baseUrl: Uri.parse('http://server:8096'),
      clientInfo: clientInfo,
      dio: dio,
    );
  }

  test('authenticateByName stores token and sends it afterwards', () async {
    final adapter = FakeServer({
      '/Users/AuthenticateByName': (
        200,
        {
          'AccessToken': 'secret-token',
          'ServerId': 'srv',
          'User': {
            'Id': 'u1',
            'Name': 'sam',
            'Policy': {'IsAdministrator': true},
          },
        },
      ),
      '/Users/Me': (200, {'Id': 'u1', 'Name': 'sam'}),
    });
    final api = buildApi(adapter);

    final result = await api.authenticateByName('sam', 'pw');
    expect(result.user.name, 'sam');
    expect(result.user.isAdministrator, isTrue);
    expect(api.isAuthenticated, isTrue);
    expect(adapter.requests.first.data, {'Username': 'sam', 'Pw': 'pw'});
    expect(
      adapter.requests.first.headers['Authorization'],
      isNot(contains('Token=')),
    );

    await api.getCurrentUser();
    expect(
      adapter.requests.last.headers['Authorization'],
      contains('Token="secret-token"'),
    );
  });

  test('maps 401 to a readable JellyfinException', () async {
    final api = buildApi(FakeServer({
      '/Users/AuthenticateByName': (401, null),
    }));

    await expectLater(
      api.authenticateByName('sam', 'wrong'),
      throwsA(isA<JellyfinException>()
          .having((e) => e.statusCode, 'statusCode', 401)
          .having((e) => e.message, 'message', contains('Wrong username'))),
    );
    expect(api.isAuthenticated, isFalse);
  });

  test('quick connect flow', () async {
    final api = buildApi(FakeServer({
      '/QuickConnect/Enabled': (200, true),
      '/QuickConnect/Initiate': (
        200,
        {'Secret': 's', 'Code': '123456', 'Authenticated': false},
      ),
      '/QuickConnect/Connect': (
        200,
        {'Secret': 's', 'Code': '123456', 'Authenticated': true},
      ),
      '/Users/AuthenticateWithQuickConnect': (
        200,
        {
          'AccessToken': 'qc-token',
          'ServerId': 'srv',
          'User': {'Id': 'u1', 'Name': 'sam'},
        },
      ),
    }));

    expect(await api.isQuickConnectEnabled(), isTrue);
    final started = await api.initiateQuickConnect();
    expect(started.code, '123456');
    final polled = await api.getQuickConnectState(started.secret);
    expect(polled.authenticated, isTrue);
    final result = await api.authenticateWithQuickConnect(started.secret);
    expect(result.accessToken, 'qc-token');
    expect(api.accessToken, 'qc-token');
  });
}
